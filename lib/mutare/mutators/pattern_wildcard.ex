defmodule Mutare.Mutators.PatternWildcard do
  @moduledoc """
  Where a variable appears **more than once** in a pattern, replace an occurrence with
  `_` — dropping the (non-linear) equality constraint the repetition encodes.

  `def equal?(x, x), do: true` matches only when its two arguments are equal; mutating
  it to `def equal?(_, x), do: true` makes it match *any* two arguments. This asks: *is
  the case where the values differ actually tested?* If only equal inputs are exercised,
  the mutant survives — a precisely located gap.

  ## Why this is structural, not a node-level `mutate/1`

  Detecting a repeated variable needs the whole pattern (the duplicate often spans
  separate arguments, as in `f(x, x)`), so it is not a rewrite of one node a `mutate/1`
  could match. Like `Mutare.Mutators.ReturnValue` and `Mutare.Mutators.PatternSwap`, the
  real entry point is `pattern_mutations/2`, called by `Mutare.Transform.FunctionPlan`
  per `def`/`defp` clause head; `mutate/1` is `:skip`. Registry membership gives it the
  usual: on by default, named in reports, toggleable via `:mutators`, filterable by
  `# mutare:ignore[pattern_wildcard]`. Delivery is **lifting** (a selector `case` is
  illegal in a pattern), exactly like guards and head literals.

  ## Compile-safety: thin vs orphan-fix

  Wildcarding must never strand the variable. Two cases, decided from `used_outside`
  (the names read in the clause body/guard — see `Mutare.Transform.FunctionPlan`):

    * The variable is read in the body/guard, **or** it appears ≥ 3 times in the head:
      replacing *one* occurrence with `_` always leaves a binding behind. Emit one
      mutant per occurrence (e.g. `def f(x, x), do: x` → `f(_, x)` and `f(x, _)`).
    * The variable appears exactly twice in the head and is **not** read elsewhere:
      thinning to one occurrence would leave a lone, unread binding (an unused-variable
      warning → poison under `--warnings-as-errors`). Instead replace *both* occurrences
      with `_` (`def equal?(x, x), do: true` → `def equal?(_, _), do: true`) — the honest
      form of "the equality no longer matters", and always clean.

  Over-collecting `used_outside` is the safe direction here: treating a name as used can
  only make us keep a binding we didn't need, never strand one. The only residual
  compile concern is *shadowing* — broadening a non-final clause to an irrefutable
  pattern makes later same-arity clauses unreachable, a warning that fails only under
  `--warnings-as-errors` and is then dropped by poison-recovery (single-clause functions
  are always clean). No mutation ever emits a hard compile error.

  `_`, `_`-prefixed names, and pinned variables (`^x`) are never counted or replaced.
  Nor is the **specifier side of a bitstring segment** (`<<v::binary>>`, `<<v::size(k)>>`):
  a type atom like `binary` parses identically to a variable, so counting it would
  invent a phantom duplicate of a same-named value/arg, and replacing it yields an
  illegal `<<v::_>>`. The walk descends only the *value* side of a `::` segment. A name
  *read* in a spec (a `size(k)` reference) is excluded from wildcarding entirely, even
  when it is also bound elsewhere in the head (`f(<<n, r::size(n)>>, n)`): a size variable
  must be bound earlier in the same bitstring, so wildcarding that binding strands the read.
  """
  @behaviour Mutare.Mutator

  @impl Mutare.Mutator
  def name, do: :pattern_wildcard

  # Structural, not node-level: a duplicate spans the whole head, invisible to a node
  # mutator. `pattern_mutations/2` is the real entry point. See the moduledoc.
  @impl Mutare.Mutator
  def mutate(_node), do: :skip

  @doc """
  For each variable that appears more than once in `head_args`, the mutant argument
  list(s) that replace an occurrence with `_`.

  `used_outside` is the set of variable names read in the clause body/guard; it decides
  whether thinning a duplicate to a single occurrence is safe (see the moduledoc).
  Returns `[]` when no variable is duplicated.
  """
  @impl Mutare.Mutator
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
    spec_reads = spec_var_names(head_args)
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
      walk_list(args, {0, []}, fn var, index, acc -> {var, [{var_name(var), index} | acc]} end)

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

  # The variable-shaped names appearing in any bitstring **spec** (the right of `::`) in
  # the head — the `n` in `<<n, rest::binary-size(n)>>`, plus bare type atoms like
  # `integer` (indistinguishable from a variable in the AST). Excluded from wildcarding
  # (see `pattern_mutations/2`); over-collecting type atoms is the safe direction — it can
  # only decline to mutate a name, never strand a binding.
  defp spec_var_names(head_args) do
    {_ast, names} =
      Macro.prewalk(head_args, MapSet.new(), fn
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
    if var_name(node) do
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

  # The name of a countable/replaceable variable, or `nil`. Same rule as
  # `Mutare.Mutators.PatternSwap`: a plain `{name, _meta, ctx}` with atom `name`/`ctx`,
  # excluding `_` and `_`-prefixed (already-ignored) names.
  defp var_name({name, _meta, ctx}) when is_atom(name) and is_atom(ctx) do
    string = Atom.to_string(name)
    if name == :_ or String.starts_with?(string, "_"), do: nil, else: name
  end

  defp var_name(_node), do: nil
end
