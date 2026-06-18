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
  # [{mutator, mutated}]}` per target. A caller then materialises one mutant by
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
  legal. Same `acc`/return contract as `guard_targets/3`.
  """
  @spec pattern_literal_targets(Macro.t(), {non_neg_integer(), list()}, [Mutator.Spec.t()]) ::
          {Macro.t(), {non_neg_integer(), list()}}
  def pattern_literal_targets(pattern, acc, mutators),
    do: tag_pattern_targets(pattern, acc, mutators)

  @doc "Replace the node carrying `meta[:mutare_tag] == tag` anywhere in `ast` with `replacement`."
  @spec replace_tag(Macro.t(), non_neg_integer(), Macro.t()) :: Macro.t()
  def replace_tag(ast, tag, replacement) do
    Macro.prewalk(ast, fn
      {_form, meta, _args} = node when is_list(meta) ->
        if Keyword.get(meta, :mutare_tag) == tag, do: replacement, else: node

      node ->
        node
    end)
  end

  # === guard tagging =========================================================

  # `not in` in a guard: `x not in y` is `not(x in y)`. The inner `in` is descended
  # (so a literal operand still mutates) but never *offered* to a mutator — exactly
  # as the in-place analyzer does: Conditional forcing it `true`/`false` would
  # duplicate the outer `not`'s, and Relational's `in` → `not in` would re-negate to
  # `x in y`, duplicating Logical's strip of the outer `not`. The outer `not` is
  # still offered (strip / true / false).
  defp tag_walk({:not, meta, [{:in, in_meta, [left, right]}]}, acc, mutators) do
    {left, acc} = tag_walk(left, acc, mutators)
    {right, acc} = tag_walk(right, acc, mutators)
    offer_target({:not, meta, [{:in, in_meta, [left, right]}]}, acc, mutators)
  end

  # A bitstring construction in a guard (`<<x::integer-size(8)>> == <<0>>` is a
  # legal guard). Mirror the in-place analyzer's segment/spec handling: tag each
  # segment's *value* side, keep the *spec* side raw — except `size(expr)` args, the
  # one genuine runtime sub-position. A blind walk would offer the `-` separator to
  # Arithmetic and lift an "unknown bitstring specifier" that poisons the build.
  defp tag_walk({:<<>>, meta, segments}, acc, mutators) do
    {segments, acc} = Enum.map_reduce(segments, acc, &tag_segment(&1, &2, mutators))
    offer_target({:<<>>, meta, segments}, acc, mutators)
  end

  # An n-ary node: descend its args (not its form), then offer the node itself.
  defp tag_walk({form, meta, args}, acc, mutators) when is_list(args) do
    {args, acc} = Enum.map_reduce(args, acc, &tag_walk(&1, &2, mutators))
    offer_target({form, meta, args}, acc, mutators)
  end

  # A 2-tuple (a keyword/map pair shape): descend both sides; never node-offered.
  defp tag_walk({left, right}, acc, mutators) do
    {left, acc} = tag_walk(left, acc, mutators)
    {right, acc} = tag_walk(right, acc, mutators)
    {{left, right}, acc}
  end

  defp tag_walk(list, acc, mutators) when is_list(list),
    do: Enum.map_reduce(list, acc, &tag_walk(&1, &2, mutators))

  # A leaf — a var, a bare literal, an atom: offer it (a bare `0` in `x > 0` is
  # mutatable) but there is nothing to descend.
  defp tag_walk(leaf, acc, mutators), do: offer_target(leaf, acc, mutators)

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

  defp offer_target(node, {next, targets}, mutators) do
    case Mutator.mutations(node, mutators) do
      [] -> {node, {next, targets}}
      muts -> {put_tag(node, next), {next + 1, [{next, node, muts} | targets]}}
    end
  end

  # === pattern-literal tagging ===============================================

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
  # is a head literal mutated by lifting), but keep the default value raw — the
  # default is a runtime position, mutated in place elsewhere.
  defp tag_pattern_targets({:\\, meta, [pattern, default]}, acc, mutators) do
    {pattern, acc} = tag_pattern_targets(pattern, acc, mutators)
    {{:\\, meta, [pattern, default]}, acc}
  end

  # A map pattern. A key literal that mutated to *another key's* value would make a
  # duplicate map key — a compile error — so each key's mutations are filtered
  # against the map's other keys (`map_key_values/1`) before tagging. Values mutate
  # normally (duplicate values are legal).
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
  # never re-emitted, so membership in the full key-value set means "equals a sibling".
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
  # arrow key colliding with a keyword key is just as illegal.
  defp map_key_values(pairs) do
    for {{:__block__, _meta, [value]}, _v} <- pairs,
        is_integer(value) or is_float(value) or is_binary(value) or is_atom(value),
        into: MapSet.new(),
        do: value
  end

  # === tagging ===============================================================

  defp put_tag({form, meta, args}, tag), do: {form, [{:mutare_tag, tag} | meta], args}
end
