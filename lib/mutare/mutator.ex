defmodule Mutare.Mutator do
  @moduledoc """
  Behaviour for mutators — pure functions over AST nodes.

  A mutator inspects a single AST node and returns either `:skip` (it does not
  apply here) or a list of mutated nodes, one per mutant to generate at that
  site. Mutators **never touch source text**; the transform locates the node,
  records its range, and splices the mutation in (a clean one-line diff).

  ## Writing one

  Match the node shapes you care about and rebuild them with the change,
  **reusing the original operand AST** so the mutation stays minimal:

      defmodule MyApp.Mutators.Boolean do
        @behaviour Mutare.Mutator

        @impl true
        def name, do: :boolean

        @impl true
        def mutate({:and, meta, [left, right]}), do: [{:or, meta, [left, right]}]
        def mutate({:or, meta, [left, right]}), do: [{:and, meta, [left, right]}]
        def mutate(_node), do: :skip
      end

  Two rules:

    * **Be compile-safe.** Every mutation lives in the *one* metamutant build, so
      a single mutation that won't compile sinks the whole run. Swapping one
      operator for another of the same kind always compiles; emitting an unbound
      variable does not.
    * **You don't choose placement.** Whether a mutation is delivered in place
      (a body expression) or by lifting (inside a `when` guard) is decided by
      *where the node sits*, not by the mutator. The same operator swap is used
      both ways.

  ## Registering one

  List it under `:mutators` in `.mutare.exs` alongside (or instead of) the
  built-in family atoms — the value may be a built-in family atom or any module
  implementing this behaviour:

      [mutators: [:arithmetic, :relational, MyApp.Mutators.Boolean]]
  """

  @doc """
  Return `:skip` when the mutator does not apply to `node`, otherwise a list of
  mutated nodes (one per mutant).
  """
  @callback mutate(Macro.t()) :: :skip | [Macro.t()]

  @doc "Short family name, shown in reports (e.g. `:arithmetic`)."
  @callback name() :: atom()

  @doc "Whether `term` is a module that implements this behaviour."
  @spec implemented_by?(term()) :: boolean()
  def implemented_by?(module) when is_atom(module) do
    Code.ensure_loaded?(module) and
      function_exported?(module, :mutate, 1) and
      function_exported?(module, :name, 0)
  end

  # Total over any term: a non-atom (e.g. a string in `.mutare.exs`) is simply
  # not a mutator, so resolution reports it rather than crashing on the guard.
  def implemented_by?(_term), do: false

  @doc """
  Run every mutator over `node`, flattening to `{mutator, mutated_node}` pairs.

  The single place a node meets the mutator set. Both the in-place analyzer
  (`Mutare.Transform`) and the lifted-guard planner (`Mutare.Transform.FunctionPlan`)
  call this, so "which mutations does this node admit" has one answer regardless of
  where the node sits — placement is decided afterwards, positionally.
  """
  @spec mutations(Macro.t(), [module()]) :: [{module(), Macro.t()}]
  def mutations(node, mutators) do
    Enum.flat_map(mutators, fn mutator ->
      case mutator.mutate(node) do
        :skip -> []
        nodes when is_list(nodes) -> Enum.map(nodes, &{mutator, &1})
      end
    end)
  end
end
