defmodule Mutare.Mutators.PatternWildcard do
  @moduledoc """
  Replaces repeated variables in a pattern with `_`, removing the equality
  constraint created by the repetition:

      def equal?(x, x), do: true  →  def equal?(_, _), do: true

  The replacement policy keeps required bindings intact:

    * If the variable is read by the guard or body, or appears at least three times
      in the head, one mutant is produced for each wildcarded occurrence.
    * If it appears exactly twice and is not read elsewhere, both occurrences are
      replaced in one mutant. Replacing only one would leave an unused binding.

  `_`, underscore-prefixed names, and pinned variables are not counted or replaced.
  On the right side of a bitstring `::`, atoms such as `binary` have the same AST
  shape as variables, so that side is not searched for pattern occurrences.

  A variable read by a bitstring specifier is also excluded. For example, the `n`
  bound and read by `<<n, rest::size(n)>>` cannot be wildcarded without leaving an
  invalid size reference.

  This family is enabled by default and uses the `pattern_wildcard` ignore name.
  """
  @behaviour Mutare.Mutator
  @behaviour Mutare.Mutator.Structural

  alias Mutare.Transform.PatternStructure

  @impl Mutare.Mutator
  def name, do: :pattern_wildcard

  @doc """
  Returns the wildcard variants for repeated variables in `head_args`.

  `used_outside` contains variable names read by the clause body or guard and
  determines whether one occurrence must remain bound. Returns `[]` when no
  variable is repeated.
  """
  @impl Mutare.Mutator.Structural
  @spec pattern_mutations([Macro.t()], MapSet.t()) :: [[Macro.t()]]
  def pattern_mutations(head_args, used_outside) when is_list(head_args) do
    # A name *read* inside a bitstring spec (the `n` in `<<n, rest::binary-size(n)>>`)
    # must be left wholly alone — even when the same name is also bound elsewhere in the
    # head. Elixir requires a size variable to be bound *earlier in the same bitstring*,
    # so wildcarding that binding strands the read (`<<_, rest::binary-size(n)>>`, a hard
    # CompileError). The walk already never *counts* a spec read (it descends only the
    # value side of `::`), but a same-named binding elsewhere — `f(<<n, r::size(n)>>, n)`
    # — still makes `n` look like a wildcardable duplicate, so spec-read names are excluded
    # outright. `used_outside` can't express this: it only keeps *some* binding alive, not
    # the specific in-binary one the size depends on.
    spec_reads = PatternStructure.spec_var_names(head_args)
    occurrences = collect_occurrences(head_args)
    counts = Enum.frequencies(Enum.map(occurrences, &elem(&1, 0)))

    counts
    |> Enum.filter(fn {name, count} -> count >= 2 and not MapSet.member?(spec_reads, name) end)
    |> Enum.flat_map(fn {name, count} ->
      indices = for {n, i} <- occurrences, n == name, do: i

      if count == 2 and not MapSet.member?(used_outside, name) do
        # orphan-fix: both occurrences → `_` (one mutant)
        [replace_occurrences(head_args, MapSet.new(indices))]
      else
        # thin: each occurrence → `_` (one mutant apiece), a binding always remains
        Enum.map(indices, &replace_occurrences(head_args, MapSet.new([&1])))
      end
    end)
  end

  # `[{name, occurrence_index}]` for every plain-variable occurrence in the args, in
  # the same deterministic pre-order the replacement walk uses, so an index identifies
  # the same node in both passes.
  defp collect_occurrences(args) do
    {_args, {_next, acc}} =
      walk_list(args, {0, []}, fn var, index, acc ->
        {var, [{PatternStructure.var_name(var), index} | acc]}
      end)

    Enum.reverse(acc)
  end

  # Replace the variable occurrences whose index is in `indices` with `_`, leaving the
  # rest untouched. The `_` reuses the replaced variable's metadata (its line/column),
  # so Sourceror renders it inline at the original position rather than reflowing the
  # surrounding call onto several lines.
  defp replace_occurrences(args, indices) do
    {args, _acc} =
      walk_list(args, {0, nil}, fn {_name, meta, _ctx} = var, index, acc ->
        if MapSet.member?(indices, index), do: {{:_, meta, nil}, acc}, else: {var, acc}
      end)

    args
  end

  # --- variable walk (shared by both passes) --------------------------------------

  # Walk `node`, calling `fun.(var_node, occurrence_index, acc)` for each plain-variable
  # occurrence (incrementing the index each time) and using its `{replacement, acc}`
  # result. Pins (`^x`) are opaque — neither counted nor descended — so a pinned
  # variable is never wildcarded.
  defp walk_vars({:^, _meta, _args} = pin, acc, _fun), do: {pin, acc}

  # A bitstring segment `value::spec` (`<<binary::binary>>`, `<<n::size(k)>>`): only
  # the *value* side is a pattern-variable position. The spec side's type atoms
  # (`binary`, `integer`, …) parse as plain vars (`{:binary, [], nil}`) but are
  # specifiers, not variables — counting one would invent a phantom "duplicate" of a
  # same-named value var, and replacing it yields an illegal `<<v::_>>` specifier (or
  # strands the real var, since the spec atom isn't a binding). Walk the value side
  # only; the spec rides through untouched and uncounted. (Mirrors the `:spec`
  # exclusion `Mutare.Transform.analyze_spec/3` applies on the in-place path.)
  defp walk_vars({:"::", meta, [value, spec]}, acc, fun) do
    {value, acc} = walk_vars(value, acc, fun)
    {{:"::", meta, [value, spec]}, acc}
  end

  defp walk_vars(node, {index, acc}, fun) do
    if PatternStructure.var_name(node) do
      {replacement, acc} = fun.(node, index, acc)
      {replacement, {index + 1, acc}}
    else
      descend(node, {index, acc}, fun)
    end
  end

  defp descend({form, meta, args}, acc, fun) when is_list(args) do
    {args, acc} = walk_list(args, acc, fun)
    {{form, meta, args}, acc}
  end

  defp descend(node, acc, fun) when is_tuple(node) and tuple_size(node) == 2 do
    {a, acc} = walk_vars(elem(node, 0), acc, fun)
    {b, acc} = walk_vars(elem(node, 1), acc, fun)
    {{a, b}, acc}
  end

  defp descend(node, acc, fun) when is_list(node), do: walk_list(node, acc, fun)

  defp descend(other, acc, _fun), do: {other, acc}

  defp walk_list(list, acc, fun),
    do: Enum.map_reduce(list, acc, fn node, acc -> walk_vars(node, acc, fun) end)
end
