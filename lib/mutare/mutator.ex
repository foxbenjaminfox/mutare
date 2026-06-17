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

  @typedoc """
  Context threaded to the optional `mutate/2` at each runtime call site. Currently
  carries only `:piped` — whether the node is the right-hand side of a `|>` (so its
  effective first argument is the pipe's left side, *not* present in the node's own
  args). A mutator computes effective arity as `length(args) + if(piped, do: 1, else: 0)`.
  """
  @type context :: %{piped: boolean()}

  @doc """
  Return `:skip` when the mutator does not apply to `node`, otherwise a list of
  mutated nodes (one per mutant).
  """
  @callback mutate(Macro.t()) :: :skip | [Macro.t()]

  @doc "Short family name, shown in reports (e.g. `:arithmetic`)."
  @callback name() :: atom()

  @doc """
  Optional **pipe-aware** variant of `mutate/1`, for mutations whose legality
  depends on a call's *effective arity* — which is ambiguous from the node alone,
  because Elixir expands `|>` only after this transform runs, so a pipe stage's
  node carries one fewer argument than the source reads.

  `Mutare.Transform` invokes it at every runtime call position with a `context`
  (`%{piped: boolean}`); a mutator uses `context.piped` to recover the effective
  arity. Used for arity-*changing* call mutations (dropping a refining argument,
  collapsing to a coarser call) that `mutate/1` cannot express safely — see
  `Mutare.Mutators.CollectionArity`. A mutator that implements this typically
  returns `:skip` from `mutate/1` (it never fires node-locally). Discovered by
  `function_exported?(mod, :mutate, 2)`; a mutator without it takes no part.
  """
  @callback mutate(Macro.t(), context()) :: :skip | [Macro.t()]

  @doc """
  Optional structural hook for mutating a `def`/`defp` clause **head pattern** as a
  whole — restructurings that `mutate/1` can't express because they span sibling
  positions or repeated variables (variable swaps, duplicate-variable wildcarding).

  Given a clause's head argument patterns and `used_outside` (the set of variable names
  read in the clause body/guard), it returns a list of mutated argument lists, one per
  mutant. `Mutare.Transform.FunctionPlan` discovers implementers by
  `function_exported?(mod, :pattern_mutations, 2)` and delivers each by lifting (a
  selector `case` is illegal in a pattern), so an implementer must return only
  *pattern-legal*, compile-safe argument lists. See `Mutare.Mutators.PatternSwap` and
  `Mutare.Mutators.PatternWildcard`. A mutator without this callback simply takes no
  part in head-pattern restructuring.
  """
  @callback pattern_mutations(head_args :: [Macro.t()], used_outside :: MapSet.t()) ::
              [[Macro.t()]]

  @doc """
  Optional hook by which a mutator claims **exclusive ownership** of one or more of a
  call's *argument positions*, so the transform does not also offer those leaves to
  *other* mutators in place.

  Given a runtime call node and the same `context` as `mutate/2` (`%{piped: boolean}`),
  it returns the **visible** argument indices (into the node's own arg list, the piped
  value excluded) that this mutator already covers via the *whole call* — positions
  where another mutator firing in place would only add a redundant, often nonsensical
  mutant. `Mutare.Mutators.ModeSwap` is the built-in user: it swaps a unit/mode atom
  (`DateTime.truncate(dt, :second)` → `:millisecond`) by rewriting the call, so it owns
  that atom's position and `Mutare.Mutators.AtomLiteral` no longer turns the same
  `:second` into the sentinel `:mutare` (a mutant that would just raise).

  A mutator should claim a position **only when it actually mutates it** (so a position
  it leaves untouched — an unrecognised atom, a variable — stays available to others).
  `Mutare.Transform` discovers implementers by `function_exported?(mod, :owned_args, 2)`
  and routes owned positions through a non-mutating context; a mutator without this
  callback claims nothing.
  """
  @callback owned_args(Macro.t(), context()) :: [non_neg_integer()]

  @optional_callbacks pattern_mutations: 2, mutate: 2, owned_args: 2

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

  Each mutator's `mutate/1` is always run; its optional `mutate/2` is *also* run
  (with `context`) when implemented, so pipe-aware/arity-changing mutators
  participate at runtime call positions. `context` defaults to a non-piped node;
  the transform passes `%{piped: true}` for a `|>` right-hand side.
  """
  @spec mutations(Macro.t(), [module()], context()) :: [{module(), Macro.t()}]
  def mutations(node, mutators, context \\ %{piped: false}) do
    Enum.flat_map(mutators, fn mutator ->
      tag(mutator, mutator.mutate(node)) ++ contextual(mutator, node, context)
    end)
  end

  defp contextual(mutator, node, context) do
    if function_exported?(mutator, :mutate, 2),
      do: tag(mutator, mutator.mutate(node, context)),
      else: []
  end

  defp tag(_mutator, :skip), do: []
  defp tag(mutator, nodes) when is_list(nodes), do: Enum.map(nodes, &{mutator, &1})
end
