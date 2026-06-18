defmodule Mutare.Transform.FunctionPlan do
  @moduledoc false

  # The plan for one *lifted* clause group: a function whose guard, head-pattern
  # literal, and/or clause-structure mutations are delivered behind a dispatcher. A
  # `case` can't live in a guard or a pattern, and guards drive dispatch *across*
  # clauses, so none of these can be mutated in place — gating clauses by the active
  # id is the only way.
  #
  # This is the discovery half of lifting — pure, id-free. `Mutare.Transform` owns
  # the emission half (assigning ids, building the dispatcher and the gated
  # clauses) because that shares the `Ctx` id-threading discipline with the in-place
  # path. What lives here is the *vocabulary*: which mutants a group admits, and —
  # per candidate — *which one clause* it mutates and *how* (`mutated_clause/2`).
  #
  # ## The shared tagged clause group
  #
  # Each guard / pattern candidate is "this one clause with this one node swapped."
  # An earlier design stored that materialized clause group on each candidate — N
  # near-identical copies for N mutants. Instead the plan holds the group *once*,
  # with every mutatable guard operator *and* head-pattern literal tagged by a
  # unique `meta[:mutare_tag]` (`tagged_clauses`); each `Candidate.Guard` /
  # `Candidate.Pattern` carries only its `tag`, its `clause_index`, and the
  # replacement node. `mutated_clause/2` reconstructs *just the one tagged clause*
  # on demand by replacing the tagged node. Tags are stripped before rendering, so a
  # leftover tag on a sibling node is harmless. Guards and pattern literals share one
  # tag counter (`build_lifted/2`) so their tags are unique group-wide.
  #
  # ## Why only literals in a head
  #
  # A head is a pattern, so only a *literal* replacement is legal there (a swapped
  # operator or a selector `case` is not). `tag_pattern_targets/3` therefore offers
  # a node to the mutators only when it is a scalar literal and keeps only the
  # mutations whose replacement is *also* a literal — which selects exactly the
  # literal families (and any future literal mutator) and guarantees the mutant
  # clause compiles. Bitstring type specifiers and keyword/map *keys* are skipped
  # (a `unit(0)` would not compile; a key is a label, not a value), mirroring the
  # in-place `:pattern` routing in `Mutare.Transform`.

  alias Mutare.AST
  alias Mutare.Mutator
  alias Mutare.Transform.{Candidate, NodeRange, PatternStructure}

  @type signature :: {:def | :defp, atom(), non_neg_integer()}

  @type t :: %__MODULE__{
          signature: signature(),
          clauses: [Macro.t()],
          tagged_clauses: [Macro.t()],
          guards: [Candidate.Guard.t()],
          patterns: [Candidate.Pattern.t()],
          pattern_structures: [Candidate.PatternStructure.t()],
          drops: [Candidate.Drop.t()]
        }

  defstruct [
    :signature,
    :clauses,
    :tagged_clauses,
    :guards,
    :patterns,
    :pattern_structures,
    :drops
  ]

  @doc """
  Plan a consecutive same-signature clause group.

  Returns `{:lift, plan}` when the group both *admits* a lifted mutant (a guard
  swap, a head-pattern literal swap, or a droppable clause) and *can host* a
  dispatcher (`liftable?/2`), else `:in_place` — its clauses stay where they are
  and only their bodies mutate.
  """
  @spec plan(signature(), [Macro.t()], [Mutator.Spec.t()]) :: {:lift, t()} | :in_place
  def plan({_vis, name, _arity} = signature, clauses, mutators) do
    {tagged_clauses, guards, patterns} = build_lifted(clauses, mutators)
    pattern_structures = build_pattern_structures(clauses, mutators)
    drops = build_drops(clauses)

    if (guards != [] or patterns != [] or pattern_structures != [] or drops != []) and
         liftable?(name) do
      plan = %__MODULE__{
        signature: signature,
        clauses: clauses,
        tagged_clauses: tagged_clauses,
        guards: guards,
        patterns: patterns,
        pattern_structures: pattern_structures,
        drops: drops
      }

      {:lift, plan}
    else
      :in_place
    end
  end

  @doc """
  The lifted candidates of this group: guard swaps, then head-pattern literal
  swaps, then head-pattern structure rewrites (variable swaps / wildcards), then
  clause drops.

  Emission walks these in order to assign ids and build one gated `defp` clause
  per candidate, so the order fixes id assignment within a lifted function.
  """
  @spec candidates(t()) :: [Candidate.t()]
  def candidates(%__MODULE__{
        guards: guards,
        patterns: patterns,
        pattern_structures: pattern_structures,
        drops: drops
      }),
      do: guards ++ patterns ++ pattern_structures ++ drops

  @doc """
  Materialize the *single* clause a candidate mutates, with its position.

  Returns `{clause_index, mutated_clause | :drop}`. Each lifted candidate touches
  exactly one source clause — a guard/head-literal swap rewrites that clause's
  head, a structure rewrite replaces its head args, a drop removes it — so emission
  needs only the one affected clause, not a full copy of the group. The returned
  clause carries a **raw body** (no in-place selectors); `Mutare.Transform`
  assembles it into the shared lifted function as a guarded mutant clause, while
  the *unchanged* clauses are emitted once as the lifted function's originals.

    * `Candidate.Guard` / `Candidate.Pattern` — the tagged clause at `clause_index`
      with the tagged node (guard operator / head literal) replaced by `mutated`.
    * `Candidate.PatternStructure` — the clause at `clause_index` with its head args
      replaced by `mutated_args`.
    * `Candidate.Drop` — `:drop`; no clause, the original is simply gated off when
      this mutant is active.
  """
  @spec mutated_clause(t(), Candidate.t()) :: {non_neg_integer(), Macro.t() | :drop}
  def mutated_clause(%__MODULE__{tagged_clauses: tagged}, %Candidate.Guard{
        clause_index: index,
        tag: tag,
        mutated: mutated
      }),
      do: {index, replace_tag(Enum.at(tagged, index), tag, mutated)}

  def mutated_clause(%__MODULE__{tagged_clauses: tagged}, %Candidate.Pattern{
        clause_index: index,
        tag: tag,
        mutated: mutated
      }),
      do: {index, replace_tag(Enum.at(tagged, index), tag, mutated)}

  def mutated_clause(%__MODULE__{clauses: clauses}, %Candidate.PatternStructure{
        clause_index: index,
        mutated_args: mutated_args
      }),
      do: {index, put_head_args(Enum.at(clauses, index), mutated_args)}

  def mutated_clause(%__MODULE__{}, %Candidate.Drop{clause_index: index}), do: {index, :drop}

  # === lifted candidates (guards + head-pattern literals) ====================

  # Discover both head-resident lifted kinds over one shared tagged clause group,
  # threading a single tag counter so guard and pattern tags never collide. Guards
  # are tagged first (so their tags — and the ids derived from them — are unchanged
  # by adding pattern literals), then head-pattern literals on the already-tagged
  # clauses. The two passes touch disjoint parts of a clause — its `when` vs its
  # head args — so neither disturbs the other's tags.
  defp build_lifted(clauses, mutators) do
    {guard_tagged, guards, next_tag} = build_guards(clauses, mutators, 0)
    {tagged, patterns, _next_tag} = build_pattern_literals(guard_tagged, mutators, next_tag)
    {tagged, guards, patterns}
  end

  # === guard candidates ======================================================

  # Tag every mutatable guard operator across the group with a unique
  # `meta[:mutare_tag]`, returning the once-tagged clause group, a `Candidate.Guard`
  # per mutation, and the next free tag. Clauses are visited in order and, within a
  # clause, targets in post-order DFS (matching the in-place emit ordering), so ids
  # land in source order. The tag counter is threaded across clauses (from
  # `start_tag`) so tags are unique group-wide — that uniqueness is what lets the
  # group be stored once.
  defp build_guards(clauses, mutators, start_tag) do
    {tagged_rev, candidates, next_tag} =
      clauses
      |> Enum.with_index()
      |> Enum.reduce({[], [], start_tag}, fn {clause, index}, {tagged_acc, cand_acc, next_tag} ->
        guard_candidates_for(clause, index, next_tag, tagged_acc, cand_acc, mutators)
      end)

    {Enum.reverse(tagged_rev), candidates, next_tag}
  end

  defp guard_candidates_for(clause, index, next_tag, tagged_acc, cand_acc, mutators) do
    case guards_of(clause) do
      [] ->
        {[clause | tagged_acc], cand_acc, next_tag}

      guards ->
        {tagged_guards, {next_tag, targets}} =
          Enum.map_reduce(guards, {next_tag, []}, fn guard, acc ->
            tag_targets(guard, acc, mutators)
          end)

        tagged_clause = put_guards(clause, tagged_guards)

        new_candidates =
          targets
          |> Enum.reverse()
          |> Enum.flat_map(fn {tag, original, muts} ->
            Enum.map(muts, fn {mutator, mutated} ->
              %Candidate.Guard{
                tag: tag,
                clause_index: index,
                mutator: mutator,
                original: original,
                mutated: mutated,
                range: NodeRange.get(original)
              }
            end)
          end)

        {[tagged_clause | tagged_acc], cand_acc ++ new_candidates, next_tag}
    end
  end

  # Tag every mutatable operator in one guard, accumulating `{tag, original, muts}`.
  # Post-order DFS so children are tagged before parents. A nested operator's child
  # may already carry a `:mutare_tag` — harmless, since tags don't affect
  # ranges/rendering and are stripped before output.
  #
  # This is an explicit descent (not `Macro.postwalk`) so it can mirror the in-place
  # analyzer's `recurse`: descend a node's *args* only, never its *form*. That keeps
  # the module side of a remote call opaque — without it the `Integer` of a guard-safe
  # `Integer.is_even(n)` would be offered to `AliasLiteral` and swapped into a
  # guard-illegal `Mutare.Mutant.is_even(n)`, poisoning the lifted `__mut` copy
  # (`Macro.postwalk` descends the `{:., _, [mod, fun]}` form and visits that alias).
  # The whole call node is still offered (so the call itself — `is_even` → `is_odd` —
  # is taggable) and the args still descend (a literal/operator argument still mutates).
  #
  # The explicit descent also mirrors the analyzer's bitstring handling: a `<<…>>`
  # construction is a legal guard, and its type-specifier side (`integer-size(8)`)
  # must stay raw — a swapped `-` separator is an illegal specifier. `tag_segment/3`
  # / `tag_spec/3` keep the spec opaque (except `size(expr)` args), exactly as
  # `analyze_segment/3` / `analyze_spec/3` do in place.
  defp tag_targets(guard, acc, mutators), do: tag_walk(guard, acc, mutators)

  # `not in` in a guard: `x not in y` is `not(x in y)`. The inner `in` is descended
  # (so a literal operand still mutates) but never *offered* to a mutator — exactly
  # as the in-place analyzer does (see `Mutare.Transform`): Conditional forcing it
  # `true`/`false` would duplicate the outer `not`'s, and Relational's `in` → `not in`
  # would re-negate to `x in y`, duplicating Logical's strip of the outer `not`. The
  # outer `not` is still offered (strip / true / false).
  defp tag_walk({:not, meta, [{:in, in_meta, [left, right]}]}, acc, mutators) do
    {left, acc} = tag_walk(left, acc, mutators)
    {right, acc} = tag_walk(right, acc, mutators)
    offer_target({:not, meta, [{:in, in_meta, [left, right]}]}, acc, mutators)
  end

  # A bitstring construction in a guard (`<<x::integer-size(8)>> == <<0>>` is a
  # legal guard). Mirror the in-place analyzer's `analyze_segment`/`analyze_spec`
  # (`Mutare.Transform.Analyze`) instead of descending the segments blindly: tag
  # each segment's *value* side, but keep the *spec* side raw — except `size(expr)`
  # args, the one genuine runtime sub-position. A blind walk would offer the `-`
  # separator to Arithmetic and lift `<<x::(integer + size(8))>>`, an "unknown
  # bitstring specifier" that poisons the whole build. The `<<>>` node itself is
  # still offered (BitstringLiteral collapses it to `<<>>`).
  defp tag_walk({:<<>>, meta, segments}, acc, mutators) do
    {segments, acc} = Enum.map_reduce(segments, acc, &tag_segment(&1, &2, mutators))
    offer_target({:<<>>, meta, segments}, acc, mutators)
  end

  # An n-ary node: descend its args (not its form), then offer the node itself.
  defp tag_walk({form, meta, args}, acc, mutators) when is_list(args) do
    {args, acc} = Enum.map_reduce(args, acc, &tag_walk(&1, &2, mutators))
    offer_target({form, meta, args}, acc, mutators)
  end

  # A 2-tuple (a keyword/map pair shape): descend both sides; never node-offered
  # (`Mutator.mutations` matches no bare 2-tuple).
  defp tag_walk({left, right}, acc, mutators) do
    {left, acc} = tag_walk(left, acc, mutators)
    {right, acc} = tag_walk(right, acc, mutators)
    {{left, right}, acc}
  end

  defp tag_walk(list, acc, mutators) when is_list(list),
    do: Enum.map_reduce(list, acc, &tag_walk(&1, &2, mutators))

  # A leaf — a var (`{:x, _, nil}`), a bare literal, an atom: offer it (a bare `0` in
  # `x > 0` is mutatable) but there is nothing to descend.
  defp tag_walk(leaf, acc, mutators), do: offer_target(leaf, acc, mutators)

  # A bitstring segment `<<value::spec>>`: tag-walk the value, keep the spec raw
  # except `size(expr)` args (`tag_spec/3`). The twin of `analyze_segment/3`.
  defp tag_segment({:"::", meta, [value, spec]}, acc, mutators) do
    {value, acc} = tag_walk(value, acc, mutators)
    {spec, acc} = tag_spec(spec, acc, mutators)
    {{:"::", meta, [value, spec]}, acc}
  end

  defp tag_segment(segment, acc, mutators), do: tag_walk(segment, acc, mutators)

  # The type-specifier side of a bitstring segment. Separators (`-`), type atoms
  # and `unit(...)` stay raw — a swapped `-` is an illegal specifier. `size(expr)`
  # is the one runtime sub-position: its arg is tag-walked (a literal/operator
  # there still lifts a mutant). The twin of `analyze_spec/3`.
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

  defp offer_target(node, {next, targets}, mutators) do
    case Mutator.mutations(node, mutators) do
      [] -> {node, {next, targets}}
      muts -> {put_tag(node, next), {next + 1, [{next, node, muts} | targets]}}
    end
  end

  defp put_tag({form, meta, args}, tag), do: {form, [{:mutare_tag, tag} | meta], args}

  defp replace_tag(ast, tag, replacement) do
    Macro.prewalk(ast, fn
      {_form, meta, _args} = node when is_list(meta) ->
        if Keyword.get(meta, :mutare_tag) == tag, do: replacement, else: node

      node ->
        node
    end)
  end

  defp guards_of({_vis, _meta, [{:when, _, [_call | guards]} | _rest]}), do: guards
  defp guards_of(_), do: []

  defp put_guards({vis, meta, [{:when, when_meta, [call | _guards]} | rest]}, new_guards),
    do: {vis, meta, [{:when, when_meta, [call | new_guards]} | rest]}

  # === head-pattern literal candidates =======================================

  # Tag every mutatable literal in each clause *head* with a unique
  # `meta[:mutare_tag]`, returning the (further) tagged clause group, a
  # `Candidate.Pattern` per mutation, and the next free tag. Mirrors `build_guards/3`
  # but walks head args (the patterns) rather than guards, and only literal-valued
  # mutations survive (`tag_pattern_targets/3`). The tag counter continues from
  # `start_tag` so pattern tags never collide with guard tags.
  defp build_pattern_literals(clauses, mutators, start_tag) do
    {tagged_rev, candidates, next_tag} =
      clauses
      |> Enum.with_index()
      |> Enum.reduce({[], [], start_tag}, fn {clause, index}, {tagged_acc, cand_acc, next_tag} ->
        {tagged_clause, new_cands, next_tag} =
          pattern_candidates_for(clause, index, next_tag, mutators)

        {[tagged_clause | tagged_acc], cand_acc ++ new_cands, next_tag}
      end)

    {Enum.reverse(tagged_rev), candidates, next_tag}
  end

  defp pattern_candidates_for(clause, index, next_tag, mutators) do
    {tagged_args, {next_tag, targets}} =
      clause
      |> clause_head_args()
      |> Enum.map_reduce({next_tag, []}, &tag_pattern_targets(&1, &2, mutators))

    case targets do
      # No literal in this head (or a 0-arity head): leave the clause untouched —
      # in particular don't rebuild a `nil`-context head into an empty arg list.
      [] ->
        {clause, [], next_tag}

      _ ->
        {put_head_args(clause, tagged_args), build_pattern_candidates(targets, index), next_tag}
    end
  end

  # `targets` arrives in reverse post-order; reverse to source order. One literal
  # can admit several mutations (an integer → `n+1`, `n-1`, `0`), each a separate
  # `Candidate.Pattern` sharing the tag but carrying its own replacement.
  defp build_pattern_candidates(targets, index) do
    targets
    |> Enum.reverse()
    |> Enum.flat_map(fn {tag, original, muts} ->
      Enum.map(muts, fn {mutator, mutated} ->
        %Candidate.Pattern{
          tag: tag,
          clause_index: index,
          mutator: mutator,
          original: original,
          mutated: mutated,
          range: NodeRange.get(original)
        }
      end)
    end)
  end

  # A context-aware descent over one head pattern, threading `{next_tag, targets}`.
  # Unlike the guard tagger's context-free `Macro.postwalk`, a pattern walk must
  # not offer keyword/map *keys* (labels, not values) or bitstring type specifiers
  # (a `unit(0)` swap would not compile) to a mutator — so it descends explicitly,
  # tagging only scalar literals that admit a literal replacement
  # (`literal_pattern_mutations/2`). `targets` accumulates `{tag, raw_node, muts}` in
  # reverse post-order; the raw (pre-tag) node is kept for the candidate's
  # `original`/`range`.

  # A scalar literal — the only thing mutated in a pattern. No children to descend.
  defp tag_pattern_targets({:__block__, _meta, [value]} = node, {next, targets}, mutators)
       when is_integer(value) or is_float(value) or is_binary(value) or is_atom(value) do
    case literal_pattern_mutations(node, mutators) do
      [] -> {node, {next, targets}}
      muts -> {put_tag(node, next), {next + 1, [{next, node, muts} | targets]}}
    end
  end

  # A bitstring segment `value :: spec`: descend the value, keep the spec raw — a
  # spec is not a runtime value and a `size`/`unit` literal swap risks an illegal
  # specifier (`unit(0)`) that would compile-poison the single build.
  defp tag_pattern_targets({:"::", meta, [value, spec]}, acc, mutators) do
    {value, acc} = tag_pattern_targets(value, acc, mutators)
    {{:"::", meta, [value, spec]}, acc}
  end

  # A default argument `pattern \\ default`: descend the *pattern* (a literal there
  # — e.g. the `0` in `def f({0, y} \\ {1, 2})` — is a head literal mutated by
  # lifting), but keep the default value raw. The default is a *runtime* position,
  # already mutated in place on the dispatcher (the base clause strips the `\\`), so
  # it must never be tagged as a pattern literal — mirroring the `::` spec clause.
  defp tag_pattern_targets({:\\, meta, [pattern, default]}, acc, mutators) do
    {pattern, acc} = tag_pattern_targets(pattern, acc, mutators)
    {{:\\, meta, [pattern, default]}, acc}
  end

  # A map pattern. A key literal that mutated to *another key's* value would make a
  # **duplicate map key** — a compile error — so each key's mutations are filtered
  # against the map's other keys (`map_key_values/1`) before tagging, catching the
  # `%{1 => a, 0 => b}` collision directly instead of leaving it to poison recovery.
  # Values mutate normally (duplicate values are legal). A mutation never reproduces
  # the original key value, so a replacement clashes with a sibling key iff it is in
  # the full key-value set — no per-key bookkeeping needed. (A non-scalar key, e.g.
  # `%{{1, 2} => v}`, descends generically and stays poison-backstopped.)
  defp tag_pattern_targets({:%{}, meta, pairs}, acc, mutators) when is_list(pairs) do
    key_values = map_key_values(pairs)
    {pairs, acc} = Enum.map_reduce(pairs, acc, &tag_map_pair(&1, key_values, &2, mutators))
    {{:%{}, meta, pairs}, acc}
  end

  # A keyword/map-key pair: skip the key (a structural label), descend only the
  # value. A non-label pair — a tuple `{1, 2}` or an arrow entry `1 => 2` — has no
  # `format: :keyword` key, so both sides descend and both literals mutate.
  defp tag_pattern_targets({key, value}, acc, mutators) do
    if AST.keyword_label?(key) do
      {value, acc} = tag_pattern_targets(value, acc, mutators)
      {{key, value}, acc}
    else
      {key, acc} = tag_pattern_targets(key, acc, mutators)
      {value, acc} = tag_pattern_targets(value, acc, mutators)
      {{key, value}, acc}
    end
  end

  # Structural descent over an n-ary node (lists, tuples, maps, structs, nested
  # patterns): re-tag every child in order.
  defp tag_pattern_targets({form, meta, args}, acc, mutators) when is_list(args) do
    {args, acc} = Enum.map_reduce(args, acc, &tag_pattern_targets(&1, &2, mutators))
    {{form, meta, args}, acc}
  end

  defp tag_pattern_targets(list, acc, mutators) when is_list(list),
    do: Enum.map_reduce(list, acc, &tag_pattern_targets(&1, &2, mutators))

  # A var (`{:x, _, nil}`), a bare leaf, or anything else: no literal to tag.
  defp tag_pattern_targets(other, acc, _mutators), do: {other, acc}

  # The literal-valued mutations a node admits — `Mutator.mutations/2` filtered to
  # those whose replacement is itself a scalar literal. A literal is legal in any
  # pattern sub-position, so this both selects the literal families (no other
  # built-in matches a scalar-literal node) and fences out a custom mutator that
  # would emit a pattern-illegal replacement.
  defp literal_pattern_mutations(node, mutators) do
    node
    |> Mutator.mutations(mutators)
    |> Enum.filter(fn {_mutator, mutated} -> literal_node?(mutated) end)
  end

  defp literal_node?({:__block__, _meta, [value]}),
    do: is_integer(value) or is_float(value) or is_binary(value) or is_atom(value)

  defp literal_node?(_), do: false

  # === map-key collision avoidance ===========================================

  # One pair of a map pattern. A label key (`a:`) is left raw; a value-position key
  # (an arrow literal `1 =>`) is tagged with its mutations filtered so none equals a
  # sibling key. The value always descends normally.
  defp tag_map_pair({key, value}, key_values, acc, mutators) do
    {key, acc} =
      if AST.keyword_label?(key),
        do: {key, acc},
        else: tag_pattern_key(key, key_values, acc, mutators)

    {value, acc} = tag_pattern_targets(value, acc, mutators)
    {{key, value}, acc}
  end

  # Any non-pair map arg (no valid head-pattern map has one, but stay total):
  # descend generically without collision filtering.
  defp tag_map_pair(other, _key_values, acc, mutators),
    do: tag_pattern_targets(other, acc, mutators)

  # A scalar-literal map key, tagged only with collision-free mutations. A
  # structured key (`{1, 2}`, `[1]`) descends generically — its collisions are rarer
  # and stay poison-backstopped.
  defp tag_pattern_key({:__block__, _meta, [value]} = node, key_values, {next, targets}, mutators)
       when is_integer(value) or is_float(value) or is_binary(value) or is_atom(value) do
    case key_pattern_mutations(node, key_values, mutators) do
      [] -> {node, {next, targets}}
      muts -> {put_tag(node, next), {next + 1, [{next, node, muts} | targets]}}
    end
  end

  defp tag_pattern_key(other, _key_values, acc, mutators),
    do: tag_pattern_targets(other, acc, mutators)

  # Literal key mutations minus any whose replacement value already names a key in
  # the same map (which would compile-error on the duplicate). The original value is
  # never re-emitted, so membership in the full key-value set means "equals a *sibling*".
  defp key_pattern_mutations(node, key_values, mutators) do
    node
    |> literal_pattern_mutations(mutators)
    |> Enum.reject(fn {_mutator, mutated} -> literal_value_in?(mutated, key_values) end)
  end

  defp literal_value_in?({:__block__, _meta, [value]}, key_values),
    do: MapSet.member?(key_values, value)

  defp literal_value_in?(_node, _key_values), do: false

  # The set of scalar-literal key *values* of a map pattern — covering both arrow
  # keys (`1 =>`, `:a =>`) and keyword keys (`a:`, themselves `:a`), since a mutated
  # arrow key colliding with a keyword key is just as illegal. Non-literal keys
  # (`^pin`, a structured key) contribute nothing and are not protected here.
  defp map_key_values(pairs) do
    for {{:__block__, _meta, [value]}, _v} <- pairs,
        is_integer(value) or is_float(value) or is_binary(value) or is_atom(value),
        into: MapSet.new(),
        do: value
  end

  # === head-pattern structure candidates =====================================

  # Discover whole-head pattern restructurings (variable swaps, duplicate-variable
  # wildcards) for each clause. Unlike guards/literals these don't tag a single node:
  # the rewrite spans sibling positions or repeated variables (and a 2-tuple/list has
  # no taggable meta), so each candidate carries the mutated head args and is applied by
  # whole-clause rebuild (`mutated_clause/2`, like a `Drop`). A clause is indexed
  # so the rebuild targets the right one.
  #
  # The participating mutators are the enabled ones exporting `pattern_mutations/2`
  # (`PatternSwap`/`PatternWildcard`, or any custom mutator), so this needs no hard-coded
  # list — toggling them off via `:mutators` simply drops them from `mutators`.
  defp build_pattern_structures(clauses, mutators) do
    case PatternStructure.mutators(mutators) do
      [] ->
        []

      structural ->
        clauses
        |> Enum.with_index()
        |> Enum.flat_map(&pattern_structures_for(&1, structural))
    end
  end

  defp pattern_structures_for({clause, index}, structural) do
    case clause_head_args(clause) do
      [] ->
        []

      raw_args ->
        call = clause_head_call(clause)

        # A default arg `pattern \\ default` is offered as just its `pattern`: the
        # default is not part of the match, and swapping/wildcarding *across* it
        # (or treating `\\` as a swappable container) would be illegal. Strip
        # before the mutators run, then re-attach each `\\ default` to its (same)
        # position afterwards — swaps/wildcards never move top-level args, so the
        # default lands back where it belongs and the base clause (which strips
        # `\\` anyway) and the diff both stay correct.
        args = strip_defaults(raw_args)

        # A head with no rangeable call can't be diffed; skip rather than emit a site
        # the report would crash on (mirrors the return-value `get_range` guard).
        case NodeRange.get(call) do
          %{} = range ->
            used = clause_used_outside(clause)
            original = put_call_args(call, raw_args)

            Enum.flat_map(structural, fn mutator ->
              args
              |> mutator.module.pattern_mutations(used)
              |> Enum.map(fn mutated_args ->
                mutated_args = reattach_defaults(mutated_args, raw_args)

                %Candidate.PatternStructure{
                  clause_index: index,
                  mutator: mutator,
                  mutated_args: mutated_args,
                  original: original,
                  mutated: put_call_args(call, mutated_args),
                  range: range
                }
              end)
            end)

          _ ->
            []
        end
    end
  end

  # Drop each arg's `\\ default` down to its bare pattern (a no-op for a plain arg).
  defp strip_defaults(args), do: Enum.map(args, &strip_default/1)
  defp strip_default({:\\, _meta, [pattern, _default]}), do: pattern
  defp strip_default(arg), do: arg

  # Re-wrap the positions that originally carried a default. A structural mutation
  # never changes the arg-list length or reorders top-level positions, so a
  # positional zip restores `\\ default` exactly where the source had it.
  defp reattach_defaults(mutated_args, raw_args) do
    Enum.zip_with(mutated_args, raw_args, fn
      pattern, {:\\, meta, [_pattern, default]} -> {:\\, meta, [pattern, default]}
      pattern, _raw -> pattern
    end)
  end

  # The variable names read in a clause's guard(s) and body — the `used_outside` set a
  # structural pattern mutator needs to know a variable stays bound after wildcarding.
  defp clause_used_outside({_vis, _meta, [head | rest]}) do
    guards =
      case head do
        {:when, _, [_call | gs]} -> gs
        _ -> []
      end

    PatternStructure.used_names(guards ++ rest)
  end

  # The clause's head *call* node (`{name, meta, args}`), peeling any `when` — the node
  # the report ranges and renders (`f(x, x)` → `f(_, x)`), guard left intact.
  defp clause_head_call({_vis, _meta, [head | _rest]}), do: head_call(head)

  defp head_call({:when, _meta, [call | _guards]}), do: call
  defp head_call(call), do: call

  # === clause-drop candidates ================================================

  # Drop one clause of a multi-clause function. Inputs the dropped clause handled
  # now fall to a later clause (or raise FunctionClauseError) — killed if tested.
  #
  # Only *body-bearing* clauses are droppable, and at least two must remain in play:
  # a **bodiless head** (`def f(a, b)` with no `do` — a header declaration, e.g. for
  # default args or docs) is not a clause to drop. Dropping it is a no-op, and
  # dropping the implementation while a header remains leaves a `defp …(args)` with
  # no body → "implementation not provided" (a poison). The `clause_index` stays the
  # position in the *full* clause list (what `drop_clause/2` deletes by), so the
  # header is simply never offered as a drop and never left as the lone clause.
  defp build_drops(clauses) do
    droppable =
      for {clause, index} <- Enum.with_index(clauses), body_bearing?(clause), do: {clause, index}

    if length(droppable) < 2 do
      []
    else
      Enum.map(droppable, fn {clause, index} ->
        %Candidate.Drop{clause_index: index, original: clause, range: NodeRange.get(clause)}
      end)
    end
  end

  # A real clause carries a body keyword (`[head, [do: …]]`); a bodiless head is just
  # `[head]`. (A `when` guard lives *inside* the head, so a guarded clause with a body
  # is still `[head_with_when, body_kw]` — two elements — and counts as body-bearing.)
  defp body_bearing?({_vis, _meta, [_head, _body | _]}), do: true
  defp body_bearing?(_), do: false

  # === liftability ===========================================================

  # We can only lift functions whose name is a plain identifier (operator names
  # like `<>` can't be spelled as `__mutare_<>_2_g1(...)`). Default arguments are
  # supported: their `\\ default` annotations ride on the public dispatcher (which
  # keeps the original multi-arity contract), while the lifted base function takes
  # the full arity with the defaults stripped — see `Mutare.Transform`.
  defp liftable?(name) do
    Regex.match?(~r/\A[a-z_][a-zA-Z0-9_]*[?!]?\z/, Atom.to_string(name))
  end

  defp head_args({:when, _, [call | _guards]}), do: head_args(call)
  defp head_args({_name, _, args}) when is_list(args), do: args
  defp head_args(_), do: []

  # === head args (shared by guard-liftability and pattern tagging) ===========

  # The pattern args of a *clause* (peeling the clause wrapper, then any `when`).
  # `[]` for a 0-arity head, whose call carries a `nil` context rather than an arg
  # list — so the pattern pass finds nothing to tag.
  defp clause_head_args({_vis, _meta, [head | _rest]}), do: head_args(head)
  defp clause_head_args(_), do: []

  # Replace a clause's head pattern args with `new_args` (the tagged copies),
  # peeling and restoring a `when` guard. Only called when there was at least one
  # tagged arg, so the head always has an arg list to overwrite.
  defp put_head_args({vis, meta, [head | rest]}, new_args),
    do: {vis, meta, [put_call_args(head, new_args) | rest]}

  defp put_call_args({:when, when_meta, [call | guards]}, new_args),
    do: {:when, when_meta, [put_call_args(call, new_args) | guards]}

  defp put_call_args({name, meta, _args}, new_args), do: {name, meta, new_args}
end
