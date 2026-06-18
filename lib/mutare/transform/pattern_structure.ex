defmodule Mutare.Transform.PatternStructure do
  @moduledoc false

  # Shared helpers for the structural pattern mutators (`Mutare.Mutators.PatternSwap` /
  # `Mutare.Mutators.PatternWildcard`), which restructure a *whole pattern* rather than a
  # single node. Two delivery paths use them, so the discovery primitives live here once:
  #
  #   * `def`/`defp` *head* patterns — lifted (`Mutare.Transform.FunctionPlan`).
  #   * `case` *clause* patterns — wrapped in an in-place selector (`Mutare.Transform`).
  #
  # The two differ only in *delivery*; "which mutators participate", "which names are read
  # outside the pattern", and "run a mutator over a single pattern node" are identical.

  @doc "The enabled mutator specs that implement the structural `pattern_mutations/2` hook."
  @spec mutators([Mutare.Mutator.Spec.t()]) :: [Mutare.Mutator.Spec.t()]
  def mutators(enabled) do
    Enum.filter(enabled, fn %{module: module} ->
      Code.ensure_loaded?(module) and function_exported?(module, :pattern_mutations, 2)
    end)
  end

  @doc """
  The variable names read in `ast` (a node or a list of nodes) — the `used_outside` set a
  structural mutator needs so it never strands a binding. **Over-collects** (any
  `{name, _, ctx}` with an atom `ctx`, including a mere rebinding), which is the safe
  direction: it can only make a mutator keep a binding it didn't need, never remove one a
  body reads (which would be an unbound-variable hard error).
  """
  @spec used_names(Macro.t() | [Macro.t()]) :: MapSet.t()
  def used_names(ast) do
    {_ast, names} =
      Macro.prewalk(ast, MapSet.new(), fn
        {name, _meta, ctx} = node, acc when is_atom(name) and is_atom(ctx) ->
          {node, MapSet.put(acc, name)}

        node, acc ->
          {node, acc}
      end)

    names
  end

  @doc """
  Structural mutations of a *single* pattern node, as `{mutator, mutated_pattern}` pairs.

  The `pattern_mutations/2` contract takes the argument *list* of a head and never changes
  its length, so a lone pattern is wrapped as a one-element list and the single mutated
  element unwrapped — letting the `case` path reuse the exact same mutators as the def-head
  path, which works on the full arg list directly.
  """
  @spec node_mutations(Macro.t(), MapSet.t(), [Mutare.Mutator.Spec.t()]) ::
          [{Mutare.Mutator.Spec.t(), Macro.t()}]
  def node_mutations(pattern, used_outside, structural_mutators) do
    Enum.flat_map(structural_mutators, fn mutator ->
      [pattern]
      |> mutator.module.pattern_mutations(used_outside)
      |> Enum.flat_map(fn
        [mutated] -> [{mutator, mutated}]
        _other -> []
      end)
    end)
  end

  @doc """
  The name of a plain variable node, or `nil`. A plain variable is `{name, _meta, ctx}`
  with an atom `name` and an atom `ctx` (`nil` or a module); `_`, `_`-prefixed names
  (intentionally ignored), and pins (`^x`, whose ctx is a list) are excluded. The strict
  "is this a swappable / wildcardable variable" notion both structural families share.
  """
  @spec var_name(Macro.t()) :: atom() | nil
  def var_name({name, _meta, ctx}) when is_atom(name) and is_atom(ctx) do
    string = Atom.to_string(name)
    if name == :_ or String.starts_with?(string, "_"), do: nil, else: name
  end

  def var_name(_node), do: nil

  @doc """
  The variable-shaped names appearing in any bitstring **spec** (the right of `::`)
  within `ast` — the `n` in `<<n, rest::binary-size(n)>>`, plus bare type atoms like
  `integer` (indistinguishable from a variable in the AST). The structural families
  exclude a value with such a name from swapping / wildcarding; over-collecting type
  atoms is the safe direction — it can only decline a mutation, never produce an illegal
  one (an `<<v::_>>` specifier) or strand a binding.
  """
  @spec spec_var_names(Macro.t()) :: MapSet.t()
  def spec_var_names(ast) do
    {_ast, names} =
      Macro.prewalk(ast, MapSet.new(), fn
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
end
