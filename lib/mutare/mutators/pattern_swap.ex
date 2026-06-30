defmodule Mutare.Mutators.PatternSwap do
  @moduledoc """
  Exchanges two variables within a container in a function-head pattern:

    * `{x, y}` → `{y, x}`
    * `[x, y]` → `[y, x]`
    * `%{left: x, right: y}` → `%{left: y, right: x}`
    * `[left: x, right: y]` → `[left: y, right: x]`
    * `<<x::8, y::16>>` → `<<y::8, x::16>>`

  Only `def` and `defp` heads are considered. Swaps occur within tuples, lists, map
  and keyword values, and bitstring segment values. Map and keyword keys and
  bitstring specifiers remain in place. The top-level function argument list is not
  a swap site.

  The two variables must have distinct names. `_` and underscore-prefixed names are
  excluded. Pinned variables may be swapped with another pin or with a binding.
  Repeated same-name variables are handled by
  `Mutare.Mutators.PatternWildcard` instead.

  A bitstring value used by another segment as a size is not moved. For example,
  `n` in `<<n, rest::binary-size(n)>>` remains in place.

  This family is enabled by default and uses the `pattern_swap` ignore name.
  """
  @behaviour Mutare.Mutator
  @behaviour Mutare.Mutator.Structural

  alias Mutare.AST
  alias Mutare.Transform.PatternStructure

  @impl Mutare.Mutator
  def name, do: :pattern_swap

  @doc """
  Returns every single-swap variant of the function-head arguments.

  Each variant exchanges two distinct variables within the same container.
  `used_outside` does not affect swaps because variable usage is unchanged.
  Returns `[]` when no eligible pair exists.
  """
  @impl Mutare.Mutator.Structural
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
    sibling_swaps(elements, rebuild) ++ keyword_value_swaps(elements, rebuild)
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
  # pins), leaving the keys in place. Every `key => value` pair qualifies.
  defp map_value_swaps(meta, pairs),
    do: pair_value_swaps(pairs, fn _pair -> true end, &{:%{}, meta, &1})

  # The keyword-list analogue: swap the *values* of two entries (`[a: x, b: y]` →
  # `[a: y, b: x]`), labels fixed. Only entries with a real keyword label
  # (`keyword_pair?/1`) qualify, so a plain 2-tuple list element keeps its ordinary
  # element-swap behaviour and is never treated as a key/value pair. `rebuild` is
  # `list_shape/1`'s, so a keyword cons tail (rare) is preserved.
  defp keyword_value_swaps(elements, rebuild),
    do: pair_value_swaps(elements, &keyword_pair?/1, rebuild)

  # Swap the values of two `{key, value}` pairs (distinct-named variables/pins) among
  # `pairs`, keeping keys fixed; `eligible?` selects which pairs may participate and
  # `rebuild` reassembles the container from the updated pair list. Shared by the map and
  # keyword-list value swaps.
  defp pair_value_swaps(pairs, eligible?, rebuild) do
    vars =
      for {pair, i} <- Enum.with_index(pairs),
          eligible?.(pair),
          name = swap_name(elem(pair, 1)),
          do: {i, name}

    for {i, ni} <- vars, {j, nj} <- vars, i < j, ni != nj do
      {ki, vi} = Enum.at(pairs, i)
      {kj, vj} = Enum.at(pairs, j)
      rebuild.(pairs |> List.replace_at(i, {ki, vj}) |> List.replace_at(j, {kj, vi}))
    end
  end

  # A keyword-list entry: a 2-tuple whose key is an inline keyword label (`a:`), carrying
  # Sourceror's `format: :keyword` marker. Distinguishes `[a: x]` from a plain tuple
  # element `[{x, y}]` (which Sourceror wraps in a `:__block__`, not a bare 2-tuple).
  defp keyword_pair?({key, _value}), do: AST.keyword_label?(key)
  defp keyword_pair?(_), do: false

  # Swap the *values* of two bitstring segments whose values are distinct-named
  # variables, leaving each type/size spec in place. A value read as a size elsewhere in
  # the binary is excluded (`swappable_segment_var/2`) — moving its binding would strand
  # the size read (Elixir requires it bound earlier in the same binary).
  defp bitstring_value_swaps(meta, segments) do
    spec_reads = PatternStructure.spec_var_names(segments)

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

  # A map/struct field map's children are its `{key, value}` pairs — but a pair is
  # **not** a swappable 2-tuple container, so we descend only into each pair's *value*
  # (keys stay fixed, exactly as `own_swaps`' `map_value_swaps` does). Treating the pair
  # as a tuple (the generic clause below would, via the literal-2-tuple `own_swaps`) puts
  # a bound variable in key position: `%{^k => v}` → `%{v => ^k}`, an illegal pattern key
  # ("cannot use variable v as map key"). Pinned-key maps with a bound value occur in
  # `case`/`fn`/`receive` clause patterns, where this path delivers swaps. Mirrors
  # `Mutare.Transform.PatternStructure.collect_bound/2`'s map handling.
  defp child_swaps({:%{}, meta, pairs}) when is_list(pairs) do
    for {{key, value}, i} <- Enum.with_index(pairs), variant <- swaps_within(value) do
      {:%{}, meta, List.replace_at(pairs, i, {key, variant})}
    end
  end

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

  # The swap identity of a node, or `nil`. A swappable sibling is either a plain variable
  # or a **pinned** variable `^name` (`{:^, _, [var]}`); both swap as whole nodes keyed by
  # `name`, so `{^a, ^b}` → `{^b, ^a}`, and a pin can trade places with a distinct-named
  # plain binding (`{^a, b}` → `{b, ^a}`). Reordering pins is safe — a pin only
  # *references* an outer binding (it cannot bind), so the original could only have
  # compiled if that binding already exists, and a swap never unbinds it. `swap_name/1` is
  # used everywhere a swappable position is collected; `PatternStructure.var_name/1` is
  # the strict plain-variable notion used to read names *inside* a node (e.g. specs).
  defp swap_name({:^, _meta, [var]}), do: PatternStructure.var_name(var)
  defp swap_name(node), do: PatternStructure.var_name(node)
end
