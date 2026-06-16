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

  @doc "The enabled mutators that implement the structural `pattern_mutations/2` hook."
  @spec mutators([module()]) :: [module()]
  def mutators(enabled) do
    Enum.filter(enabled, fn mutator ->
      Code.ensure_loaded?(mutator) and function_exported?(mutator, :pattern_mutations, 2)
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
  @spec node_mutations(Macro.t(), MapSet.t(), [module()]) :: [{module(), Macro.t()}]
  def node_mutations(pattern, used_outside, structural_mutators) do
    Enum.flat_map(structural_mutators, fn mutator ->
      [pattern]
      |> mutator.pattern_mutations(used_outside)
      |> Enum.flat_map(fn
        [mutated] -> [{mutator, mutated}]
        _other -> []
      end)
    end)
  end
end
