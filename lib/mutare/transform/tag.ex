defmodule Mutare.Transform.Tag do
  @moduledoc false

  # Shared *replace-by-tag* discovery primitives for the two clause kinds whose
  # mutations are delivered by **replacing a single node in a copy of the clause**
  # rather than by an in-place selector:
  #
  #   * a `when` **guard** operator (`Mutare.Transform.FunctionPlan` for lifted
  #     function clauses; `Mutare.Transform.Analyze` for `case`/`receive`/`fn`
  #     clause guards), and
  #   * a head/clause **pattern literal** (the same two callers).
  #
  # Both work the same way: walk the guard / pattern, tag every mutatable node with
  # a unique `meta[:mutare_tag]`, and return the tagged copy plus a `{tag, original,
  # [%Mutare.Mutator.Dispatch.Result{}]}` per target. A caller then materialises one mutant by
  # `replace_tag/3`-ing the tagged copy. Tags are stripped before rendering
  # (`Mutare.Transform.Render`), so a leftover tag on a sibling node is harmless.
  #
  # The walks are deliberately *not* a context-free `Macro.postwalk`: they mirror
  # the in-place analyzer's positional routing so the *form* side of a remote call
  # stays opaque (an aliased module in a guard-safe `Integer.is_even(n)` must not be
  # offered to AliasLiteral and swapped into a guard-illegal call) and a bitstring
  # type specifier / a keyword-or-map *key* is never offered (a swapped `-`
  # separator, a `unit(0)`, or a mutated label would not compile). The subtleties
  # (bitstring specs, map-key collisions) therefore live here once.

  alias Mutare.{AST, Mutator}
  alias Mutare.Mutator.Dispatch
  alias Mutare.Mutators.StringLiteral
  alias Mutare.Transform.{Meta, NodeRange, Suppression}
  alias Mutare.Transform.Analyze.{CallOptions, Syntax}

  # The suppression operator vocabulary, in guard position (see `Suppression`'s twin-map):
  # the guard path matches the guard-legal subset of the body path's sets, so its clauses
  # use the same shared `defguard`s as `Mutare.Transform.Analyze` rather than independent
  # literal lists. (`!`/`&&`/`||` are guard-illegal, so the negation/double-negation clauses
  # below match a bare `:not` head and there is no `is_negation_op` use here.)
  import Suppression, only: [is_equality_op: 1, is_guard_connective: 1]

  @doc """
  Tag every mutatable operator in one guard expression.

  `acc` is `{next_tag, targets}` threaded across a clause's guards (and, by the
  caller, across a whole clause group) so tags are unique. Returns `{tagged_guard,
  {next_tag, targets}}`, `targets` accumulated in reverse post-order (the caller
  reverses to source order).
  """
  @spec guard_targets(Macro.t(), {non_neg_integer(), list()}, [Mutator.Spec.t()]) ::
          {Macro.t(), {non_neg_integer(), list()}}
  def guard_targets(guard, acc, mutators), do: tag_walk(guard, acc, mutators)

  @doc """
  Tag every mutatable scalar literal in one pattern (a head arg or a clause
  pattern), keeping only literal-valued mutations so the mutant pattern is always
  legal. An ordinary exact string pattern keeps one canonical retargeting mutant;
  strings below a binary-composing `<>` or `<<>>` keep both the empty and sentinel
  variants because emptying a segment can remove a structural constraint. Same
  `acc`/return contract as `guard_targets/3`.
  """
  @spec pattern_literal_targets(Macro.t(), {non_neg_integer(), list()}, [Mutator.Spec.t()]) ::
          {Macro.t(), {non_neg_integer(), list()}}
  def pattern_literal_targets(pattern, acc, mutators),
    do: tag_pattern_targets(pattern, acc, mutators, :exact)

  @doc """
  Expand a clause's accumulated `{tag, original, [%Mutare.Mutator.Dispatch.Result{}]}` targets into
  candidates, one per `Result`.

  Targets arrive in reverse post-order (`guard_targets/3` / `pattern_literal_targets/3`
  accumulate that way); they are reversed to source order so ids land in source order.
  `build.(tag, original, mutator, mutated, note, variant, range)` constructs each candidate — `tag`
  to `replace_tag/3` the tagged copy, `original` for the diff, `note` the producing mutator's
  optional advisory and `variant` its production-time `# mutare:ignore` tag (both `nil` for an
  ordinary/untagged mutation), `range` its source range.

  A target whose node Sourceror can't range is **dropped**: a candidate with no range
  can't be diffed or lifted. This matches the structural discovery paths, which already
  skip an unrangeable node — the tagged paths now agree.
  """
  @spec expand_targets(
          [{non_neg_integer(), Macro.t(), [Mutare.Mutator.Dispatch.Result.t()]}],
          function()
        ) :: [term()]
  def expand_targets(targets, build) do
    targets
    # mutare:ignore[collection_arity] equivalent — targets accrue in strictly monotonic tag order, so sorting by the unique integer tag yields the same ascending source order as reversing the accumulation (`call_removal` dropping the reverse IS genuinely killed).
    |> Enum.reverse()
    |> Enum.flat_map(fn {tag, original, muts} ->
      case NodeRange.get(original) do
        %{} = range ->
          Enum.map(muts, fn %Dispatch.Result{
                              spec: mutator,
                              node: mutated,
                              note: note,
                              variant: variant
                            } ->
            build.(tag, original, mutator, mutated, note, variant, range)
          end)

        _ ->
          []
      end
    end)
  end

  @doc "Replace the node carrying `meta[:mutare_tag] == tag` anywhere in `ast` with `replacement`."
  @spec replace_tag(Macro.t(), non_neg_integer(), Macro.t()) :: Macro.t()
  def replace_tag(ast, tag, replacement) do
    Macro.prewalk(ast, fn node ->
      if Meta.tag(node) == tag, do: replacement, else: node
    end)
  end

  # === guard tagging =========================================================

  # Every guard-walk clause is reached through here, so a call-level `:skip` — a route on the
  # resolved head: `is_integer/1`, but equally `and/2` or `in/2`, which have clauses of their own
  # below — is honoured first: the node is an inert leaf, nothing offered, nothing descended.
  # Mirrors `Mutare.Transform.Analyze.analyze/3`'s dispatcher (and, like it, the negation
  # clauses check their inner operand, so a skipped `in` under `not` is a leaf too).
  defp tag_walk(node, acc, mutators) do
    if Meta.skipped?(node), do: {node, acc}, else: tag_walk_form(node, acc, mutators)
  end

  # Redundancy suppression in guards — the guard-legal subset of the in-place analyzer's
  # equivalent-sibling clauses (`Mutare.Transform.Analyze`). The shared move is identical:
  # descend operands (a literal still mutates) but offer only the outer node, never the
  # inner/redundant one. `!`/`&&`/`||` are forbidden in guards, so only `not` is handled.
  #
  # `not in`: `x not in y` is `not(x in y)`. The inner `in`'s only Relational mutation
  # (`in` → `not in`) re-negates to `x in y` ≡ Logical's strip of the outer; Conditional
  # on the inner (`not true`/`not false`) ≡ the outer's `true`/`false`. So the inner `in`
  # is not offered, and its RHS list is List-suppressed too (`x in []` ≡ `false`, the
  # outer's Conditional — sound here because guards have no observable side effects and
  # guard errors fail the guard; see `tag_in_rhs/3`). The outer `not` is offered
  # (strip/true/false).
  defp tag_walk_form({:not, meta, [{:in, in_meta, [left, right]} = inner]} = node, acc, mutators) do
    if Meta.skipped?(inner) do
      tag_generic(node, acc, mutators)
    else
      {left, acc} = tag_walk(left, acc, mutators)
      {right, acc} = tag_in_rhs(right, acc, mutators)
      offer_target({:not, meta, [{:in, in_meta, [left, right]}]}, acc, mutators)
    end
  end

  # `not` over an equality operator (`==`/`!=`/`===`/`!==`) — `not in` generalised: each
  # equality operator is its own exact polarity complement, so Relational's flip under the
  # `not` ≡ Logical's strip and Conditional on the inner ≡ the outer's `true`/`false`.
  # (Ordering operators are excluded — their boundary/reversal swaps survive negation as
  # new mutants.) The inner node *is* offered, but with those two negation-redundant
  # mutations dropped (`offer_negation_survivors/4`): a strictness relaxation
  # (`===` → `==`, `Mutare.Mutators.StrictEquality`, guard-legal) is neither the complement
  # nor a constant, so `not (a == b)` ≢ `a === b` survives. Mirrors the body-side clause in
  # `Mutare.Transform.Analyze`.
  defp tag_walk_form(
         {:not, meta, [{op, op_meta, [_left, _right]} = raw_inner]} = node,
         acc,
         mutators
       )
       when is_equality_op(op) do
    if Meta.skipped?(raw_inner) do
      tag_generic(node, acc, mutators)
    else
      # The operands by the inner node's own positions (a positional route on `==` holds under
      # `not` as it does bare); only the redundancy drop is this clause's.
      {[left, right], acc} = tag_args(raw_inner, acc, mutators)
      {inner, acc} = offer_negation_survivors({op, op_meta, [left, right]}, op, acc, mutators)
      offer_target({:not, meta, [inner]}, acc, mutators)
    end
  end

  # Double negation `not not x` in a guard (same operator — `!` is not guard-legal). Both
  # strips are the identical `not x`, and Conditional on the inner ≡ the outer's
  # `true`/`false`. Suppress the inner `not`; offer only the outer.
  defp tag_walk_form({:not, meta, [{:not, inner_meta, [operand]} = inner]} = node, acc, mutators) do
    if Meta.skipped?(inner) do
      tag_generic(node, acc, mutators)
    else
      {operand, acc} = tag_walk(operand, acc, mutators)
      offer_target({:not, meta, [{:not, inner_meta, [operand]}]}, acc, mutators)
    end
  end

  # A bare `x in [list]` guard: offer the `in` node (Conditional `true`/`false`,
  # Relational → `not in`), but List-suppress the RHS list literal (`x in []` ≡ `false`,
  # already the Conditional).
  defp tag_walk_form({:in, meta, [left, right]}, acc, mutators) do
    {left, acc} = tag_walk(left, acc, mutators)
    {right, acc} = tag_in_rhs(right, acc, mutators)
    offer_target({:in, meta, [left, right]}, acc, mutators)
  end

  # A bitstring construction in a guard (`<<x::integer-size(8)>> == <<0>>` is a
  # legal guard). Mirror the in-place analyzer's segment/spec handling: tag each
  # segment's *value* side, keep the *spec* side raw — except `size(expr)` args, the
  # one genuine runtime sub-position. A blind walk would offer the `-` separator to
  # Arithmetic and lift an "unknown bitstring specifier" that poisons the build.
  defp tag_walk_form({:<<>>, meta, segments}, acc, mutators) do
    {segments, acc} = Enum.map_reduce(segments, acc, &tag_segment(&1, &2, mutators))
    offer_target({:<<>>, meta, segments}, acc, mutators)
  end

  # A short-circuit connective in a guard whose left operand is itself a boolean op
  # (`and`/`or` only — `&&`/`||` are guard-illegal, so they never reach here). Conditional
  # forces the connective to `true`/`false`, but `(L and R) → false` ≡ `L → false` and
  # `(L or R) → true` ≡ `L → true` (the left short-circuits the whole node), so the
  # connective-node constant duplicates the operand's and is dropped — the operand keeps its
  # precise diff, the other constant and Logical's `and`↔`or` stay. A non-boolean-op left has
  # no subsuming sibling, so it is offered in full. Mirrors `Mutare.Transform.Analyze`'s
  # body-side clause.
  defp tag_walk_form({op, meta, [left, right]}, acc, mutators) when is_guard_connective(op) do
    {left_t, acc} = tag_walk(left, acc, mutators)
    {right_t, acc} = tag_walk(right, acc, mutators)
    rebuilt = {op, meta, [left_t, right_t]}

    if Suppression.boolean_op_node?(left) and not Meta.skipped?(left),
      do: offer_without_constant(rebuilt, Suppression.redundant_constant(op), acc, mutators),
      else: offer_target(rebuilt, acc, mutators)
  end

  # An n-ary node: descend its args (not its form), then offer the node itself — honouring a
  # call route stamped by `Mutare.Transform.Resolve` the same way the body path does, so a
  # routed call in a `when` guard can't leak mutants the body offer would hold back (the same
  # both-offer-paths discipline the position marks follow, NOTES "Argument marks"). Each argument
  # goes by its position (`tag_routed_arg/4`); the call-level `:skip` was honoured at
  # `tag_walk/3`, before any clause.
  defp tag_walk_form({form, meta, args}, acc, mutators) when is_list(args),
    do: tag_generic({form, meta, args}, acc, mutators)

  # A 2-tuple (a keyword/map pair shape): descend both sides; never node-offered.
  defp tag_walk_form({left, right}, acc, mutators) do
    {left, acc} = tag_walk(left, acc, mutators)
    {right, acc} = tag_walk(right, acc, mutators)
    {{left, right}, acc}
  end

  defp tag_walk_form(list, acc, mutators) when is_list(list),
    do: Enum.map_reduce(list, acc, &tag_walk(&1, &2, mutators))

  # A leaf — a var, a bare literal, an atom: offer it (a bare `0` in `x > 0` is
  # mutatable) but there is nothing to descend.
  defp tag_walk_form(leaf, acc, mutators), do: offer_target(leaf, acc, mutators)

  # The n-ary walk: every argument by its position (`tag_args/3`), then the node offered.
  defp tag_generic({form, meta, args}, acc, mutators) do
    {args, acc} = tag_args({form, meta, args}, acc, mutators)
    offer_target({form, meta, args}, acc, mutators)
  end

  # A node's arguments — each by its stamped position when the node carries a route
  # (`tag_routed_arg/4`), else the ordinary walk. Shared by the generic n-ary clause and the
  # negated-equality clause, which builds its inner node from the operands directly.
  defp tag_args({_form, meta, args}, acc, mutators) do
    case Meta.routing(meta) do
      routing when is_list(routing) ->
        args
        |> Enum.with_index()
        |> Enum.map_reduce(acc, fn {arg, i}, acc ->
          tag_routed_arg(arg, Enum.at(routing, i, :expression), acc, mutators)
        end)

      _unrouted ->
        Enum.map_reduce(args, acc, &tag_walk(&1, &2, mutators))
    end
  end

  # One routed argument of a guard call, by its position — the guard twin of
  # `Mutare.Transform.Analyze.Routed.route_macro_arg/4` for the positions a guard-legal value can
  # take. `:raw`: left as written. `:interior`: walked, then the target registered for the
  # argument's *own* node is dropped (`strip_own_target/1`) while its descendants keep theirs —
  # `is_tuple({x, 1})` under `:interior` loses the `{x, 1} → {}` collapse but keeps the `1`'s
  # mutants. A keyed refinement over a literal keyword list: each named pair's value takes its
  # key's position; the container is offered (or not) by the leading treatment, and the keys and
  # unnamed values take the leading treatment's descendant reading (`:interior` reads as
  # `:expression` one level down — the container is the node it withholds). A non-keyword
  # argument takes the leading treatment alone, as in the body. Everything else —
  # `:expression`, and the positions with no guard meaning (`:pattern`/`:binding_pattern`, the
  # adapter-grade words: a pattern or a DSL fragment is not guard-legal) — is the ordinary walk.
  defp tag_routed_arg(arg, :raw, acc, _mutators), do: {arg, acc}

  defp tag_routed_arg(arg, :interior, acc, mutators),
    do: arg |> tag_walk(acc, mutators) |> strip_own_target()

  defp tag_routed_arg(arg, {:keyed, leading, pairs}, acc, mutators) do
    case CallOptions.keyword_pairs(arg) do
      {:ok, kw_pairs, rewrap} ->
        inner = descendant_position(leading)

        {kw_pairs, acc} =
          Enum.map_reduce(kw_pairs, acc, fn {key, value}, acc ->
            position =
              case List.keyfind(pairs, AST.key_atom(key), 0) do
                {_key, position} -> position
                nil -> inner
              end

            {key, acc} = tag_key(key, inner, acc, mutators)
            {value, acc} = tag_routed_arg(value, position, acc, mutators)
            {{key, value}, acc}
          end)

        offer_container(rewrap.(kw_pairs), leading, acc, mutators)

      :error ->
        tag_routed_arg(arg, leading, acc, mutators)
    end
  end

  defp tag_routed_arg(arg, _position, acc, mutators), do: tag_walk(arg, acc, mutators)

  # A keyword key under a keyed refinement: a block key (`do:`/`else:`/…) is a structural label
  # and stays raw, as the body path keeps it (`Analyze.Routed`); a data key follows the leading
  # treatment's reading.
  defp tag_key(key, inner, acc, mutators) do
    if Syntax.block_key?(key), do: {key, acc}, else: tag_routed_arg(key, inner, acc, mutators)
  end

  # What a leading treatment means one level down: `:interior` withholds only the container, so
  # its children are ordinary expressions; `:raw` and `:expression` mean the same at every depth.
  defp descendant_position(:interior), do: :expression
  defp descendant_position(other), do: other

  # The keyword container's own offer, by the leading treatment. Only the Sourceror-wrapped
  # explicit list (`{:__block__, _, [list]}`) is a node the ordinary walk offers (the `[…] → []`
  # collapse); the bare trailing sugar is a plain list and never was.
  defp offer_container({:__block__, _meta, _args} = node, :expression, acc, mutators),
    do: offer_target(node, acc, mutators)

  defp offer_container(node, _leading, acc, _mutators), do: {node, acc}

  # Drop the target registered for a node *itself*, keeping every descendant's — the guard twin
  # of `Routed`'s `strip_own_inplace_candidates/1`. The tag counter is not rewound: tags are
  # identifiers, so a gap is harmless.
  defp strip_own_target({node, {next, targets}}) do
    case Meta.tag(node) do
      nil -> {node, {next, targets}}
      tag -> {Meta.delete_tag(node), {next, List.keydelete(targets, tag, 0)}}
    end
  end

  # The RHS of a guard `in`: descend its children exactly as the generic walk would, then
  # offer the top node with any *empty-collection* mutation dropped — `x in <empty>` ≡
  # `false`, the mutant Conditional already produces on the `in`. The drop is per mutation,
  # so a `~w(a b)` / `~c"ab"` keeps its non-empty sentinel and loses only its empty sibling;
  # `List`'s sole `[]` collapse is removed outright. A map-valued custom mutation is also
  # rejected: although maps are valid membership RHS values in a body, Elixir forbids them
  # on the RHS of a guard `in`. This suppression is guard-only:
  # in a body, replacing the whole membership expression with `false` skips evaluation of
  # the left operand, while emptying only the RHS does not.
  # mutare:ignore[guard_drop] equivalent — Sourceror wraps every collection literal as a 3-tuple with list args, so this guard never fails for valid input.
  defp tag_in_rhs({form, meta, args} = node, acc, mutators) when is_list(args) do
    # The RHS head's own route first, as `tag_walk/3` would: a skipped `1..5` is a leaf, a
    # positional route on `..` reaches its endpoints (`tag_args/3`).
    if Meta.skipped?(node) do
      {node, acc}
    else
      {args, acc} = tag_args(node, acc, mutators)
      offer_legal_in_rhs({form, meta, args}, acc, mutators)
    end
  end

  # mutare:ignore[clause_drop] equivalent — a variable can't be a guard `in`-RHS, so this fallback is unreachable for valid input.
  defp tag_in_rhs(other, acc, mutators), do: tag_walk(other, acc, mutators)

  # `offer_target/3` minus redundant empty-collection mutations and guard-illegal map
  # replacements (see `tag_in_rhs/3`).
  defp offer_legal_in_rhs(node, acc, mutators) do
    muts = Enum.reject(mutations(node, mutators), &invalid_in_rhs_mutation?/1)
    tag_node(node, muts, acc)
  end

  defp invalid_in_rhs_mutation?(%Dispatch.Result{node: {:%{}, _meta, _pairs}}), do: true

  defp invalid_in_rhs_mutation?(%Dispatch.Result{node: mutated}),
    do: AST.empty_collection_literal?(mutated)

  # `offer_target/3` minus the Conditional mutant forcing the node to `bool` — the redundant
  # short-circuit constant (see the `and`/`or` clause and `Mutare.Transform.Analyze`).
  defp offer_without_constant(node, bool, acc, mutators) do
    muts = Enum.reject(mutations(node, mutators), &constant_mutation?(&1, bool))
    tag_node(node, muts, acc)
  end

  defp constant_mutation?(%Dispatch.Result{node: mutated}, bool),
    do: Suppression.boolean_literal?(mutated, bool)

  # `offer_target/3` for an equality op *under a `not`* minus its negation-redundant
  # mutations: the polarity complement (Relational, ≡ Logical's strip) and the `true`/`false`
  # constants (Conditional, ≡ the outer's). A strictness relaxation (`===` → `==`) is neither,
  # so it stays. Mirrors `Mutare.Transform.Analyze.drop_negation_redundant_candidates/2`.
  defp offer_negation_survivors(node, op, acc, mutators) do
    muts = Enum.reject(mutations(node, mutators), &negation_redundant_mutation?(&1, op))
    tag_node(node, muts, acc)
  end

  defp negation_redundant_mutation?(%Dispatch.Result{node: mutated}, op),
    do: Suppression.negation_redundant?(mutated, op)

  # A bitstring segment `<<value::spec>>`: tag-walk the value, keep the spec raw
  # except `size(expr)` args (`tag_spec/3`).
  defp tag_segment({:"::", meta, [value, spec]}, acc, mutators) do
    {value, acc} = tag_walk(value, acc, mutators)
    {spec, acc} = tag_spec(spec, acc, mutators)
    {{:"::", meta, [value, spec]}, acc}
  end

  defp tag_segment(segment, acc, mutators), do: tag_walk(segment, acc, mutators)

  # The type-specifier side of a bitstring segment. Separators (`-`), type atoms and
  # `unit(...)` stay raw — a swapped `-` is an illegal specifier. `size(expr)` is the
  # one runtime sub-position: its arg is tag-walked (a literal/operator there still
  # lifts a mutant).
  defp tag_spec({:-, meta, [left, right]}, acc, mutators) do
    {left, acc} = tag_spec(left, acc, mutators)
    {right, acc} = tag_spec(right, acc, mutators)
    {{:-, meta, [left, right]}, acc}
  end

  defp tag_spec({:size, meta, [arg]}, acc, mutators) do
    {arg, acc} = tag_walk(arg, acc, mutators)
    {{:size, meta, [arg]}, acc}
  end

  defp tag_spec(other, acc, _mutators), do: {other, acc}

  # The mutations `node` admits, with any position marks stamped on it by
  # `Mutare.Transform.Resolve.ArgumentMarks` surfaced to the mutators as `context.marks` — the same
  # enrichment `Mutare.Transform.Analyze.Attach.offer/4` applies on the in-place path, so a
  # guard-safe call's marked argument (`is_integer(t)` with an `argument_marks`
  # mark on arg 0) is declined here too, not only when the same call sits in a body. Guards and
  # patterns are never pipe stages, so the base context is `:unpiped`; a leaf that carries no marks
  # (the overwhelming majority) is dispatched with that base untouched.
  defp mutations(node, mutators),
    do: Dispatch.mutations(node, mutators, Meta.context_with_marks(%{pipe_mode: :unpiped}, node))

  defp offer_target(node, acc, mutators),
    do: tag_node(node, mutations(node, mutators), acc)

  # === pattern-literal tagging ===============================================

  # The pattern walk's entry, honouring a call-level `:skip` the same way `tag_walk/3` does — a
  # head pattern is walked by the resolver too, so a skipped special form (`%{}`, `=`, `<<>>`) is
  # an inert leaf there as well.
  defp tag_pattern_targets(node, acc, mutators, context) do
    if Meta.skipped?(node),
      do: {node, acc},
      else: tag_pattern_form(node, acc, mutators, context)
  end

  # A scalar literal — the only thing mutated in a pattern. No children to descend.
  defp tag_pattern_form({:__block__, _meta, [value]} = node, acc, mutators, context)
       when is_integer(value) or is_float(value) or is_binary(value) or is_atom(value),
       do: tag_node(node, literal_pattern_mutations(node, mutators, context), acc)

  # A negative numeric literal `-n` parses as a unary minus over its positive
  # magnitude (`{:-, _, [{:__block__, _, [n]}]}`). Descending to mutate the *magnitude*
  # in place would splice the replacement back under that minus — legal in a guard
  # (`-(-0.5)` is a valid guard expression) but **illegal in a match**, where `-(...)`
  # demands a literal operand (`:erlang.-/1` can't run inside a pattern). So in pattern
  # context tag the *whole* node and offer mutations of the literal **value** `-n`,
  # every replacement a clean self-contained literal (`-0.5` → `0.5`, `-1.5`, `0.0`) —
  # never a nested `-(-x)`. Guards keep the in-place magnitude walk (`guard_targets/3`),
  # where the nested minus compiles fine.
  # mutare:ignore[guard_drop] equivalent — in a pattern, unary minus only ever wraps a numeric literal, so `is_number(n)` always holds and removing it can't change which inputs match.
  defp tag_pattern_form(
         {:-, _meta, [{:__block__, _bmeta, [n]}]} = node,
         acc,
         mutators,
         _context
       )
       when is_number(n),
       do: tag_node(node, value_literal_mutations(-n, mutators), acc)

  # A string nested below binary-composing pattern syntax has two meaningfully
  # different replacements: `""` can remove a prefix/segment constraint, while
  # `"mutare"` keeps a non-empty constraint and retargets it. Mark every descendant
  # of `<>` / `<<>>` as binary-composing; other literal families are unchanged by
  # the context, and a conservative singleton `<<"foo">>` keeps both string mutants.
  defp tag_pattern_form({form, meta, args}, acc, mutators, _context)
       when form in [:<>, :<<>>] and is_list(args) do
    {args, acc} =
      Enum.map_reduce(args, acc, &tag_pattern_targets(&1, &2, mutators, :binary_composition))

    {{form, meta, args}, acc}
  end

  # A bitstring segment `value :: spec`: descend the value, keep the spec raw — a
  # spec is not a runtime value and a `size`/`unit` literal swap risks an illegal
  # specifier (`unit(0)`) that would compile-poison the single build.
  defp tag_pattern_form({:"::", meta, [value, spec]}, acc, mutators, context) do
    {value, acc} = tag_pattern_targets(value, acc, mutators, context)
    {{:"::", meta, [value, spec]}, acc}
  end

  # A default argument `pattern \\ default`: descend the *pattern* (a literal there
  # is a head literal mutated by lifting), but keep the default value raw — the
  # default is a runtime position, mutated in place elsewhere.
  defp tag_pattern_form({:\\, meta, [pattern, default]}, acc, mutators, context) do
    {pattern, acc} = tag_pattern_targets(pattern, acc, mutators, context)
    {{:\\, meta, [pattern, default]}, acc}
  end

  # A map pattern. A key literal that mutated to *another key's* value would make a
  # duplicate map key — a compile error — so each key's mutations are filtered
  # against the map's other keys (`map_key_values/1`) before tagging. Values mutate
  # normally (duplicate values are legal).
  # mutare:ignore[guard_drop] equivalent — a `%{}` node's args are always a list, so this guard never fails for valid input.
  defp tag_pattern_form({:%{}, meta, pairs}, acc, mutators, context) when is_list(pairs) do
    key_values = map_key_values(pairs)

    {pairs, acc} =
      Enum.map_reduce(pairs, acc, &tag_map_pair(&1, key_values, &2, mutators, context))

    {{:%{}, meta, pairs}, acc}
  end

  # A keyword/map-key pair: skip the key (a structural label), descend only the
  # value. A non-label pair — a tuple `{1, 2}` or an arrow entry `1 => 2` — has no
  # `format: :keyword` key, so both sides descend and both literals mutate.
  defp tag_pattern_form({key, value}, acc, mutators, context) do
    if AST.keyword_label?(key) do
      {value, acc} = tag_pattern_targets(value, acc, mutators, context)
      {{key, value}, acc}
    else
      {key, acc} = tag_pattern_targets(key, acc, mutators, context)
      {value, acc} = tag_pattern_targets(value, acc, mutators, context)
      {{key, value}, acc}
    end
  end

  # Structural descent over an n-ary node (lists, tuples, maps, structs, nested
  # patterns): re-tag every child in order.
  defp tag_pattern_form({form, meta, args}, acc, mutators, context) when is_list(args) do
    {args, acc} =
      Enum.map_reduce(args, acc, &tag_pattern_targets(&1, &2, mutators, context))

    {{form, meta, args}, acc}
  end

  defp tag_pattern_form(list, acc, mutators, context) when is_list(list),
    do: Enum.map_reduce(list, acc, &tag_pattern_targets(&1, &2, mutators, context))

  # A var (`{:x, _, nil}`), a bare leaf, or anything else: no literal to tag.
  defp tag_pattern_form(other, acc, _mutators, _context), do: {other, acc}

  # The literal-valued mutations a node admits — the local `mutations/2` (mark-aware) filtered to
  # those whose replacement is itself a scalar literal. A literal is legal in any
  # pattern sub-position, so this both selects the literal families (no other
  # built-in matches a scalar-literal node) and fences out a custom mutator that
  # would emit a pattern-illegal replacement.
  defp literal_pattern_mutations(node, mutators, context) do
    node
    |> raw_literal_pattern_mutations(mutators)
    |> collapse_exact_string_mutations(context)
  end

  defp raw_literal_pattern_mutations(node, mutators) do
    node
    |> mutations(mutators)
    |> Enum.filter(fn %Dispatch.Result{node: mutated} -> literal_node?(mutated) end)
  end

  # The literal-valued mutations of a scalar *value* rather than the node the walk
  # reached — used for a negative literal, whose value `-n` lives one node deeper than
  # the unary-minus we tag. The block is built directly (not via `AST.literal/1`, which
  # re-wraps a negative as `{:-, …}` the literal families don't match), so `FloatLiteral`/
  # `Literal` mutate the value; each clean result then *replaces the whole `-n` node*.
  defp value_literal_mutations(value, mutators) do
    {:__block__, [], [value]}
    |> mutations(mutators)
    |> Enum.filter(fn %Dispatch.Result{node: mutated} -> literal_node?(mutated) end)
  end

  # NOTE (suspected-equivalent survivors, deliberately not `# mutare:ignore`d): the
  # `conditional` mutants forcing this scalar-type chain to `true` are equivalent — no
  # built-in yields a compound `{:__block__, _, [_]}` for a scalar node, so the chain
  # always holds for the inputs `literal_node?/1` receives. We do NOT ignore them: the
  # sibling `→ false` conditionals (and the `or → and` logical mutants) on this line are
  # genuinely killed, and a line-level `# mutare:ignore[conditional]` would hide those.
  defp literal_node?({:__block__, _meta, [value]}),
    do: is_integer(value) or is_float(value) or is_binary(value) or is_atom(value)

  # A negative number is built by `Mutare.AST.literal/1` as the canonical unary-minus
  # over its positive magnitude (`{:-, _, [{:__block__, _, [n]}]}`) — a perfectly legal
  # pattern (`def f(-1)`, `-0.5 -> …`). Recognise it so a negative-literal replacement
  # isn't silently dropped from a head/clause pattern mutant.
  # NOTE (suspected-equivalent survivor, deliberately not `# mutare:ignore`d): the
  # `return_value` mutant forcing this to `:mutare` is equivalent — every caller uses
  # `literal_node?/1` only for truthiness (an `Enum.filter`) and a built-in never yields
  # `-(<non-literal>)`, so the result is already truthy here. We do NOT ignore it: the
  # sibling `→ nil` return mutant is genuinely killed (it drops every negative-literal
  # replacement), and `# mutare:ignore[return_value]` would hide that kill.
  defp literal_node?({:-, _meta, [operand]}), do: literal_node?(operand)

  defp literal_node?(_), do: false

  # === map-key collision avoidance ===========================================

  # One pair of a map pattern. A label key (`a:`) is left raw; a value-position key
  # (an arrow literal `1 =>`) is tagged with its mutations filtered so none equals a
  # sibling key. The value always descends normally.
  defp tag_map_pair({key, value}, key_values, acc, mutators, context) do
    {key, acc} =
      if AST.keyword_label?(key),
        do: {key, acc},
        else: tag_pattern_key(key, key_values, acc, mutators, context)

    {value, acc} = tag_pattern_targets(value, acc, mutators, context)
    {{key, value}, acc}
  end

  # mutare:ignore[clause_drop] equivalent — a map pattern's entries are always `{key, value}` pairs, so this fallback is unreachable for valid input.
  defp tag_map_pair(other, _key_values, acc, mutators, context),
    do: tag_pattern_targets(other, acc, mutators, context)

  # A scalar-literal map key, tagged only with collision-free mutations. A
  # structured key (`{1, 2}`, `[1]`) descends generically — its collisions are rarer
  # and stay poison-backstopped.
  defp tag_pattern_key(
         {:__block__, _meta, [value]} = node,
         key_values,
         acc,
         mutators,
         context
       )
       when is_integer(value) or is_float(value) or is_binary(value) or is_atom(value),
       do: tag_node(node, key_pattern_mutations(node, key_values, mutators, context), acc)

  defp tag_pattern_key(other, _key_values, acc, mutators, context),
    do: tag_pattern_targets(other, acc, mutators, context)

  # Literal key mutations minus any whose replacement value already names a key in
  # the same map (which would compile-error on the duplicate). The original value is
  # never re-emitted, so membership in the full key-value set means "equals a sibling".
  defp key_pattern_mutations(node, key_values, mutators, context) do
    node
    |> raw_literal_pattern_mutations(mutators)
    |> Enum.reject(fn %Dispatch.Result{node: mutated} ->
      literal_value_in?(mutated, key_values)
    end)
    |> collapse_exact_string_mutations(context)
  end

  # In an ordinary exact pattern, `"foo" -> ""` and `"foo" -> "mutare"` both
  # retarget the same scalar match and are usually killed by the same execution of
  # the original pattern. Keep the sentinel as the canonical replacement because
  # it is least likely to collide with a real sibling key/clause. Map-key legality
  # runs before this helper, so if the sentinel collides, the empty replacement is
  # retained as a deterministic fallback. A source equal to either replacement
  # already produces only the other one and therefore passes through unchanged.
  defp collapse_exact_string_mutations(mutations, :binary_composition), do: mutations

  defp collapse_exact_string_mutations(mutations, :exact) do
    sentinel_specs =
      for %Dispatch.Result{
            spec: %Mutator.Spec{module: StringLiteral} = spec,
            variant: "sentinel"
          } <- mutations,
          into: MapSet.new(),
          do: spec

    Enum.reject(mutations, fn
      %Dispatch.Result{
        spec: %Mutator.Spec{module: StringLiteral} = spec,
        variant: "empty"
      } ->
        MapSet.member?(sentinel_specs, spec)

      _other ->
        false
    end)
  end

  defp literal_value_in?({:__block__, _meta, [value]}, key_values),
    do: MapSet.member?(key_values, value)

  defp literal_value_in?(_node, _key_values), do: false

  # The set of scalar-literal key *values* of a map pattern — covering both arrow
  # keys (`1 =>`, `:a =>`) and keyword keys (`a:`, themselves `:a`), since a mutated
  # arrow key colliding with a keyword key is just as illegal.
  # NOTE (suspected-equivalent survivors, deliberately not `# mutare:ignore`d): the
  # `conditional` mutants forcing the scalar-type filter below to `true` are equivalent —
  # every key value reaching it is already scalar, so the filter admits the same keys.
  # We do NOT ignore them: the sibling `→ false` conditional (which empties the
  # collision-guard set) and the `or → and` logical mutant are genuinely killed, and a
  # line-level `# mutare:ignore[conditional]` would hide those real kills.
  defp map_key_values(pairs) do
    for {{:__block__, _meta, [value]}, _v} <- pairs,
        is_integer(value) or is_float(value) or is_binary(value) or is_atom(value),
        into: MapSet.new(),
        do: value
  end

  # === tagging ===============================================================

  defp put_tag(node, tag), do: Meta.put_tag(node, tag)

  # Tag `node` with the next free tag and record its target, given the node's mutation list —
  # or leave it untagged when there are none. The shared tail of every tagger (guards, pattern
  # literals, collection/map keys): a strictly-monotonic counter hands out one unique tag per
  # mutated node.
  #
  # `integer 1 → 2` (on the `next + 1` below) is equivalent too — still a unique, monotonic tag
  # — but left un-ignored: its sibling `1 → 0` freezes the counter (a real collision) and is
  # genuinely killed, which a `[integer]` filter would hide. See `TagTest` moduledoc.
  defp tag_node(node, [], acc), do: {node, acc}

  defp tag_node(node, muts, {next, targets}) do
    {
      put_tag(node, next),
      # mutare:ignore[arithmetic] equivalent — a strictly-monotonic tag counter; `-1` still hands out unique tags.
      {next + 1, [{next, node, muts} | targets]}
    }
  end
end
