defmodule Mutare.Mutators.PatternSwap do
  @moduledoc """
  Swap two variables inside a pattern container — `{x, y}` → `{y, x}`,
  `[a, b]` → `[b, a]`, `%{k1: x, k2: y}` → `%{k1: y, k2: x}`, and the segment *values*
  of a bitstring `<<a::8, b::16>>` → `<<b::8, a::16>>`.

  This asks a precise question: *does any test depend on which value lands in which
  position?* If a function destructures `{lat, lng}` and nothing distinguishes the two,
  swapping them survives — a located gap.

  ## Why this is structural, not a node-level `mutate/1`

  Like `Mutare.Mutators.ReturnValue`, a swap is not a rewrite of a single node a
  `mutate/1` could match — it exchanges two *sibling* sub-patterns, so it needs the
  whole container. The real entry point is `pattern_mutations/2`, which
  `Mutare.Transform.FunctionPlan` calls for each `def`/`defp` clause head; `mutate/1`
  is `:skip`. The module still implements `Mutare.Mutator` so it sits in the
  `Mutare.Mutators` registry — on by default, named in reports, toggleable via
  `:mutators`, filterable by `# mutare:ignore[pattern_swap]`.

  Delivery is **lifting**: a selector `case` is illegal in a pattern, so the clause
  group is duplicated into `__orig`/`__mut` copies behind a dispatcher, exactly as
  head-pattern literals and guards are (see `Mutare.Transform.FunctionPlan`).

  ## Scope and compile-safety

  Only `def`/`defp` *heads* are mutated (the only pattern position Mutare lifts), and
  only **within containers** — tuples, lists, the *values* of a map pattern, and the
  segment *values* of a bitstring (the bindable left of each `::`, the spec staying put).
  The top-level argument list is deliberately not a swap site (transposing whole
  arguments is a separate, noisier mutation the project chose not to emit).

  A swap is **compile-safe**: it only reorders existing variables/pins, so the set of
  bound names and their usage is unchanged (no unbound or unused variable can appear).
  **Pins participate** (`{^a, ^b}` → `{^b, ^a}`, and a pin can trade places with a
  distinct-named binding, `{^a, b}` → `{b, ^a}`): a pin only *references* a binding from an
  enclosing scope, so if the original compiled the reference still resolves after the swap
  — pins therefore show up wherever an outer variable is in scope (`case`/`fn`/`receive`
  clauses), essentially never in a `def` head. The only nuance pins add over plain
  bindings is that they change *which* value a position must equal, so in a rare
  multi-clause arrangement a swap can broaden one clause to shadow a later same-arity one
  — a benign "cannot match" warning that fails only under `--warnings-as-errors` and is
  then dropped by poison-recovery (a plain-binding swap, which preserves refutability
  exactly, can never even do that). Only two **distinct-named** variables/pins are swapped
  — a same-name swap (`{x, x}`, `{^a, a}`) is a no-op (repetition is the
  `Mutare.Mutators.PatternWildcard` family's domain), and `_`/`_`-prefixed names are never
  swapped. For a bitstring the type/size specs stay pinned
  to their positions, and a value read as a *size* elsewhere in the same binary
  (`<<n, rest::binary-size(n)>>`) is never moved — Elixir requires a size variable to be
  bound earlier in the binary, so relocating its binding would not compile.
  """
  @behaviour Mutare.Mutator

  @impl Mutare.Mutator
  def name, do: :pattern_swap

  # Structural, not node-level: a swap targets two sibling positions in a head
  # pattern, which a node mutator can't see. `pattern_mutations/2` is the real entry
  # point, driven by the transform. See the moduledoc.
  @impl Mutare.Mutator
  def mutate(_node), do: :skip

  @doc """
  Every single-swap variant of a `def`/`defp` clause's head argument list.

  Returns a list of mutated argument lists, one per swap of two distinct-named
  variables that sit as siblings inside a container (tuple / list / map value) anywhere
  in `head_args`. `used_outside` (the names read in the clause body/guard) is ignored —
  a swap never changes variable usage, so it has no bearing here. `[]` when no container
  holds two swappable variables.
  """
  @impl Mutare.Mutator
  @spec pattern_mutations([Macro.t()], MapSet.t()) :: [[Macro.t()]]
  def pattern_mutations(head_args, _used_outside) when is_list(head_args) do
    # Swap *within* each argument (containers only); never transpose the top-level
    # arguments themselves.
    for {arg, index} <- Enum.with_index(head_args),
        variant <- swaps_within(arg) do
      List.replace_at(head_args, index, variant)
    end
  end

  # All single-swap variants of `node`: a swap of two of its own variable siblings
  # (if it is a container), plus every swap found deeper in its children.
  defp swaps_within(node), do: own_swaps(node) ++ child_swaps(node)

  # --- own swaps: exchange two variable siblings of a container -------------------

  # An n-tuple `{:{}, _, elems}` (arity ≠ 2) — siblings are the elements.
  defp own_swaps({:{}, meta, elems}) when is_list(elems),
    do: sibling_swaps(elems, &{:{}, meta, &1})

  # A bitstring pattern `<<v1::s1, v2::s2, …>>` — siblings are the segment *values* (the
  # bindable left of each `::`); each type/size spec stays pinned to its position
  # (`<<a::8, b::16>>` → `<<b::8, a::16>>`).
  defp own_swaps({:<<>>, meta, segments}) when is_list(segments),
    do: bitstring_value_swaps(meta, segments)

  # A map pattern — siblings are the *values* (keys stay fixed). Swapping values
  # across two keys: `%{a: x, b: y}` → `%{a: y, b: x}`.
  defp own_swaps({:%{}, meta, pairs}) when is_list(pairs),
    do: map_value_swaps(meta, pairs)

  # A literal 2-tuple `{a, b}` (Sourceror keeps small tuples unwrapped) — its two
  # elements are the siblings.
  defp own_swaps(node) when is_tuple(node) and tuple_size(node) == 2 do
    [a, b] = Tuple.to_list(node)
    sibling_swaps([a, b], fn [x, y] -> {x, y} end)
  end

  # A list pattern `[a, b, …]` — siblings are the elements. A cons tail (`[a, b | t]`,
  # parsed as a trailing `{:|, _, [last, t]}`) is unwrapped first: the elements *before*
  # the bar — including `last` — are all swap-symmetric, while the tail `t` (which binds
  # the *remainder*, not one element) stays pinned. So `[a, b, c | _]` swaps a/b/c but
  # never the `_`, whereas `[a, b | c]` swaps only a/b (c is the tail).
  defp own_swaps(node) when is_list(node) do
    {elements, rebuild} = list_shape(node)
    sibling_swaps(elements, rebuild)
  end

  defp own_swaps(_node), do: []

  # Split a list pattern into its swappable {elements, rebuild} pair. A proper list keeps
  # its elements as-is; a cons list moves the pre-bar element out of the `{:|, …}` node so
  # it joins the others, and `rebuild` re-wraps the last element back into the cons with
  # the original tail and `:|` metadata.
  defp list_shape(node) do
    case List.last(node) do
      {:|, cons_meta, [last, tail]} ->
        elements = List.replace_at(node, length(node) - 1, last)

        rebuild = fn elems ->
          {init, [new_last]} = Enum.split(elems, length(elems) - 1)
          init ++ [{:|, cons_meta, [new_last, tail]}]
        end

        {elements, rebuild}

      _ ->
        {node, & &1}
    end
  end

  # For each unordered pair of distinct-named variable siblings, rebuild the container
  # with those two positions exchanged. A sibling is a plain variable *or* a pin
  # (`swap_name/1`).
  defp sibling_swaps(elements, rebuild) do
    vars = for {e, i} <- Enum.with_index(elements), name = swap_name(e), do: {i, name}

    for {i, ni} <- vars, {j, nj} <- vars, i < j, ni != nj do
      rebuild.(swap_at(elements, i, j))
    end
  end

  # Swap the *values* of two map pairs whose values are distinct-named variables (or
  # pins), leaving the keys in place.
  defp map_value_swaps(meta, pairs) do
    vars =
      for {pair, i} <- Enum.with_index(pairs),
          match?({_k, _v}, pair),
          name = swap_name(elem(pair, 1)),
          do: {i, name}

    for {i, ni} <- vars, {j, nj} <- vars, i < j, ni != nj do
      {ki, vi} = Enum.at(pairs, i)
      {kj, vj} = Enum.at(pairs, j)
      {:%{}, meta, pairs |> List.replace_at(i, {ki, vj}) |> List.replace_at(j, {kj, vi})}
    end
  end

  # Swap the *values* of two bitstring segments whose values are distinct-named
  # variables, leaving each type/size spec in place. A value read as a size elsewhere in
  # the binary is excluded (`swappable_segment_var/2`) — moving its binding would strand
  # the size read (Elixir requires it bound earlier in the same binary).
  defp bitstring_value_swaps(meta, segments) do
    spec_reads = spec_var_names(segments)

    vars =
      for {seg, i} <- Enum.with_index(segments),
          name = swappable_segment_var(seg, spec_reads),
          do: {i, name}

    for {i, ni} <- vars, {j, nj} <- vars, i < j, ni != nj do
      {:<<>>, meta, swap_segment_values(segments, i, j)}
    end
  end

  # The swappable name of a segment's value (a plain variable or a pin), or `nil` — also
  # `nil` for a value read as a size elsewhere in the binary (`spec_reads`), which must not
  # be relocated.
  defp swappable_segment_var(seg, spec_reads) do
    case swap_name(segment_value(seg)) do
      nil -> nil
      name -> if MapSet.member?(spec_reads, name), do: nil, else: name
    end
  end

  defp swap_segment_values(segments, i, j) do
    vi = segment_value(Enum.at(segments, i))
    vj = segment_value(Enum.at(segments, j))

    segments
    |> List.replace_at(i, put_segment_value(Enum.at(segments, i), vj))
    |> List.replace_at(j, put_segment_value(Enum.at(segments, j), vi))
  end

  # A segment is either a bare value or `value :: spec`; read/replace only its value side.
  defp segment_value({:"::", _meta, [value, _spec]}), do: value
  defp segment_value(seg), do: seg

  defp put_segment_value({:"::", meta, [_value, spec]}, value), do: {:"::", meta, [value, spec]}
  defp put_segment_value(_seg, value), do: value

  # --- child swaps: recurse, lifting each nested variant back into place ----------

  defp child_swaps({form, meta, args}) when is_list(args) do
    for {child, i} <- Enum.with_index(args), variant <- swaps_within(child) do
      {form, meta, List.replace_at(args, i, variant)}
    end
  end

  defp child_swaps(node) when is_tuple(node) and tuple_size(node) == 2 do
    [a, b] = Tuple.to_list(node)
    Enum.map(swaps_within(a), &{&1, b}) ++ Enum.map(swaps_within(b), &{a, &1})
  end

  defp child_swaps(node) when is_list(node) do
    for {child, i} <- Enum.with_index(node), variant <- swaps_within(child) do
      List.replace_at(node, i, variant)
    end
  end

  defp child_swaps(_node), do: []

  # --- helpers --------------------------------------------------------------------

  defp swap_at(list, i, j) do
    a = Enum.at(list, i)
    b = Enum.at(list, j)
    list |> List.replace_at(i, b) |> List.replace_at(j, a)
  end

  # The variable-shaped names appearing in any bitstring **spec** (the right of `::`)
  # among `segments` — the `n` in `<<n, rest::binary-size(n)>>`, plus bare type atoms
  # like `integer` (indistinguishable from a variable in the AST). A value with such a
  # name is excluded from swapping; over-collecting type atoms is the safe direction — it
  # can only decline a swap, never produce an illegal one. (Mirrors the same helper in
  # `Mutare.Mutators.PatternWildcard`.)
  defp spec_var_names(segments) do
    {_ast, names} =
      Macro.prewalk(segments, MapSet.new(), fn
        {:"::", _meta, [_value, spec]} = node, acc -> {node, collect_var_names(spec, acc)}
        node, acc -> {node, acc}
      end)

    names
  end

  defp collect_var_names(spec, acc) do
    {_ast, names} =
      Macro.prewalk(spec, acc, fn node, acc ->
        case var_name(node) do
          nil -> {node, acc}
          name -> {node, MapSet.put(acc, name)}
        end
      end)

    names
  end

  # The swap identity of a node, or `nil`. A swappable sibling is either a plain variable
  # or a **pinned** variable `^name` (`{:^, _, [var]}`); both swap as whole nodes keyed by
  # `name`, so `{^a, ^b}` → `{^b, ^a}`, and a pin can trade places with a distinct-named
  # plain binding (`{^a, b}` → `{b, ^a}`). Reordering pins is safe — a pin only
  # *references* an outer binding (it cannot bind), so the original could only have
  # compiled if that binding already exists, and a swap never unbinds it. `swap_name/1` is
  # used everywhere a swappable position is collected; `var_name/1` stays the strict
  # plain-variable notion used to read names *inside* a node (e.g. bitstring specs).
  defp swap_name({:^, _meta, [var]}), do: var_name(var)
  defp swap_name(node), do: var_name(node)

  # The name of a plain variable node, or `nil`. A plain variable is `{name, _meta, ctx}`
  # with an atom `name` and an atom `ctx` (`nil` or a module); `_`, `_`-prefixed names
  # (intentionally ignored), and pins (`^x`, whose ctx is a list) are excluded.
  defp var_name({name, _meta, ctx}) when is_atom(name) and is_atom(ctx) do
    string = Atom.to_string(name)
    if name == :_ or String.starts_with?(string, "_"), do: nil, else: name
  end

  defp var_name(_node), do: nil
end
