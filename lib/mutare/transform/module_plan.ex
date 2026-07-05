defmodule Mutare.Transform.ModulePlan do
  @moduledoc false

  # The plan for one statement sequence (a module body, or any block that defines
  # functions): each statement classified into how emission should handle it.
  #
  # This is the "module planning" stage, split out of the emission loop. It is
  # pure and id-free: it groups consecutive same-signature clauses into runs,
  # decides per run whether to lift (delegating to `FunctionPlan.plan/3`), and
  # leaves everything else for `Mutare.Transform`'s module-statement classifier.
  # `Mutare.Transform` then walks `items` in order, threading ids and rendering each.
  #
  # An item is one of:
  #
  #   * `{:lift, %FunctionPlan{}}` — a clause group to duplicate behind a dispatcher;
  #   * `{:in_place, [clause]}`    — a clause group whose clauses stay put (bodies
  #     still mutate); used for groups that can't or needn't lift, and for
  #     non-consecutive clauses (see below);
  #   * `{:statement, node}`       — any other statement, classified by
  #     `Mutare.Transform` as a nested scope, a statement block, a macro block, or
  #     compile-time scaffold.

  require Logger

  alias Mutare.Transform.FunctionPlan

  @type item ::
          {:lift, FunctionPlan.t()}
          | {:in_place, [Macro.t()]}
          | {:statement, Macro.t()}

  @type t :: %__MODULE__{items: [item()]}

  defstruct items: []

  @doc """
  Plan a statement sequence into classified `items`.

  `file` is used only to attribute the non-consecutive-clause warning.
  """
  @spec build([Macro.t()], [Mutare.Mutator.Spec.t()], String.t()) :: t()
  def build(statements, mutators, file) do
    chunks = chunk_clause_runs(statements)
    non_consecutive = non_consecutive_signatures(chunks)
    metaprogrammed = metaprogrammed_def_names(chunks)
    delegated = delegated_name_arities(chunks)
    # Each blocked signature gets exactly one warning, for its binding reason.
    # Delegation wins the diagnosis when it applies: it is keyed by exact
    # {name, arity}, so it is never a false positive, and neither of the other
    # two remedies (grouping clauses, nothing) would restore lifting while the
    # defdelegate exists. Metaprogramming wins over non-consecutive: grouping
    # the clauses can't enable lifting (the generated clauses still force
    # in-place), so the non-consecutive advice ("group the clauses") would
    # mislead.
    warn_delegated(delegated_signatures(chunks, delegated), file)

    warn_metaprogrammed(
      metaprogrammed_signatures(chunks, metaprogrammed, delegated),
      file
    )

    warn_non_consecutive(
      non_consecutive_only(non_consecutive, metaprogrammed, delegated),
      file
    )

    items =
      Enum.map(chunks, fn
        {:other, statement} ->
          {:statement, statement}

        {:clauses, clauses} ->
          plan_clause_group(clauses, non_consecutive, metaprogrammed, delegated, mutators)
      end)

    %__MODULE__{items: items}
  end

  @doc """
  The `{visibility, name, arity}` of a `def`/`defp` clause, or `nil` for anything
  else. Public so `Mutare.Transform` can tell a clause-bearing block apart from a
  plain one without re-deriving the shape.
  """
  @spec clause_signature(Macro.t()) :: FunctionPlan.signature() | nil
  def clause_signature({vis, _meta, [head | _rest]}) when vis in [:def, :defp] do
    case name_arity(head) do
      {name, arity} -> {vis, name, arity}
      :error -> nil
    end
  end

  def clause_signature(_), do: nil

  # --- clause-group classification ------------------------------------------

  defp plan_clause_group(clauses, non_consecutive, metaprogrammed, delegated, mutators) do
    signature = clause_signature(hd(clauses))
    {_vis, name, arity} = signature

    # Non-consecutive heads can't be lifted (for now). A dispatcher is a catch-all
    # for the whole signature, so lifting one run would shadow the others; and
    # lifting every run as one unit relocates each clause's body to the
    # dispatcher's position — which silently changes semantics when a compile-time
    # `@attr` read between the heads resolves differently there
    # (`@a 1; def f(0), do: @a; @a 2; def f(1), do: @a`). Fall back to in-place;
    # guard/clause-drop mutants are simply not offered for such functions.
    #
    # Same hazard, different source: a function whose clause set is *augmented by
    # compile-time metaprogramming* — a module-level `for`/macro that `def`s the
    # same name (`def code(integer) when …` beside `for … do def code(atom) …`).
    # Those generated clauses are invisible here (they live inside an `{:other}`
    # statement), so the run looks complete and consecutive; lifting it installs a
    # dispatcher that shadows every metaprogrammed clause and forwards to a lifted
    # group missing them — a guaranteed `FunctionClauseError`. Refuse to lift any
    # name that is also defined inside a non-`def` statement.
    #
    # A `defdelegate` sharing the name/arity is the same shadowing hazard in its
    # most idiomatic form ("one explicit clause for the special case, delegate the
    # rest" — hit for real on `Phoenix.Controller.assign/2`): the delegate expands
    # to a sibling `def` clause invisible to this grouping, so the lifted run's
    # unconditional public wrapper would shadow it and the delegate's inputs would
    # crash *at baseline*, no mutant active. Delegates carry an exact, statically
    # visible arity, so this check is keyed by {name, arity}, not bare name.
    if signature in non_consecutive or name in metaprogrammed or
         {name, arity} in delegated do
      {:in_place, clauses}
    else
      case FunctionPlan.plan(signature, clauses, mutators) do
        {:lift, plan} -> {:lift, plan}
        :in_place -> {:in_place, clauses}
      end
    end
  end

  defp name_arity({:when, _, [call | _guards]}), do: name_arity(call)
  defp name_arity({name, _, args}) when is_atom(name) and is_list(args), do: {name, length(args)}
  defp name_arity({name, _, context}) when is_atom(name) and is_atom(context), do: {name, 0}
  defp name_arity(_), do: :error

  # --- clause-run chunking ---------------------------------------------------

  # Group maximal runs of consecutive clauses that share {visibility, name, arity}.
  # A signature appearing in more than one run is "non-consecutive" (see
  # non_consecutive_signatures/1) and is never lifted.
  defp chunk_clause_runs(statements) do
    statements
    |> Enum.reduce([], fn statement, acc ->
      case {clause_signature(statement), acc} do
        {nil, acc} ->
          [{:other, statement} | acc]

        {sig, [{:clauses, sig, clauses} | rest]} ->
          [{:clauses, sig, [statement | clauses]} | rest]

        {sig, acc} ->
          [{:clauses, sig, [statement]} | acc]
      end
    end)
    |> Enum.map(fn
      {:clauses, _sig, clauses} -> {:clauses, Enum.reverse(clauses)}
      other -> other
    end)
    |> Enum.reverse()
  end

  # The deduplicated signatures of all top-level clause groups.
  defp clause_group_signatures(chunks) do
    chunks
    |> Enum.flat_map(fn
      {:clauses, clauses} -> [clause_signature(hd(clauses))]
      {:other, _statement} -> []
    end)
    |> Enum.uniq()
  end

  # Signatures whose clauses are split across more than one consecutive run —
  # something (another definition, a module attribute) appears between them.
  # These are the functions Transform refuses to lift.
  defp non_consecutive_signatures(chunks) do
    chunks
    |> Enum.flat_map(fn
      {:clauses, clauses} -> [clause_signature(hd(clauses))]
      {:other, _statement} -> []
    end)
    |> Enum.frequencies()
    |> Enum.flat_map(fn
      {signature, count} when count > 1 -> [signature]
      {_signature, _count} -> []
    end)
    |> MapSet.new()
  end

  # The non-consecutive signatures whose binding reason really *is* being
  # non-consecutive — i.e. not also metaprogrammed (which is keyed by name only,
  # and refuses lifting at the name level regardless of consecutiveness, so its
  # warning is the accurate one) or delegated. Dropping those here avoids a
  # misleading "group the clauses" suggestion that grouping wouldn't honour.
  defp non_consecutive_only(non_consecutive, metaprogrammed, delegated) do
    Enum.reject(non_consecutive, fn {_vis, name, arity} ->
      name in metaprogrammed or {name, arity} in delegated
    end)
  end

  # Lifting is silently disabled for non-consecutive clauses, which costs that
  # function its guard and clause-drop mutants. Warn once per signature so the
  # gap is visible (and actionable — grouping the clauses restores lifting).
  defp warn_non_consecutive(signatures, file) do
    Enum.each(signatures, fn {_vis, name, arity} ->
      Logger.warning(
        "#{file}: clauses of #{name}/#{arity} are non-consecutive — not lifting " <>
          "(no guard or clause-drop mutants for it); group the clauses to enable lifting"
      )
    end)
  end

  # --- metaprogramming-augmented signatures ----------------------------------

  # Names `def`/`defp`'d *inside* a non-clause statement (a module-level `for`,
  # `if`, `Enum.each`, macro body, …). A function with such a name may gain
  # clauses at compile time that aren't visible as top-level `def` statements, so
  # its top-level run is not the whole function and must not be lifted (the
  # dispatcher would shadow the generated clauses). Nested module/protocol bodies
  # are a different scope — their defs can't add clauses here — so the walk is
  # pruned at those boundaries.
  defp metaprogrammed_def_names(chunks) do
    chunks
    |> Enum.flat_map(fn
      {:other, statement} -> nested_def_names(statement)
      {:clauses, _clauses} -> []
    end)
    |> MapSet.new()
  end

  defp nested_def_names(statement) do
    {_ast, names} =
      Macro.prewalk(statement, [], fn
        {form, _meta, _args}, acc when form in [:defmodule, :defimpl, :defprotocol] ->
          # Prune: return a leaf so prewalk does not descend into the nested scope.
          {:__mutare_pruned__, acc}

        {form, _meta, [head | _rest]} = node, acc when form in [:def, :defp] ->
          case name_arity(head) do
            {name, _arity} -> {node, [name | acc]}
            :error -> {node, acc}
          end

        node, acc ->
          {node, acc}
      end)

    names
  end

  # The top-level clause-group signatures blocked from lifting by metaprogramming,
  # for the warning. Deduplicated by signature. Metaprogramming outranks
  # non-consecutiveness as the diagnosis (it refuses lifting at the name level),
  # but yields to delegation, whose exact {name, arity} keying makes it the more
  # precise reason — see the precedence note in `build/3`.
  defp metaprogrammed_signatures(chunks, metaprogrammed, delegated) do
    chunks
    |> clause_group_signatures()
    |> Enum.filter(fn {_vis, name, arity} ->
      name in metaprogrammed and {name, arity} not in delegated
    end)
  end

  # Mirror of warn_non_consecutive/2 for the metaprogramming case. Not user-fixable
  # (the generated clauses are intentional), but the coverage gap should still be
  # visible.
  defp warn_metaprogrammed(signatures, file) do
    Enum.each(signatures, fn {_vis, name, arity} ->
      Logger.warning(
        "#{file}: clauses of #{name}/#{arity} are augmented by compile-time " <>
          "metaprogramming — not lifting (no guard or clause-drop mutants for it)"
      )
    end)
  end

  # --- defdelegate siblings ---------------------------------------------------

  # {name, arity} pairs defined by a `defdelegate` anywhere in this statement
  # sequence (top level, or nested inside a non-clause statement — the same
  # territory metaprogrammed_def_names/1 covers). A delegate expands to a plain
  # `def` clause of that exact name/arity, but its AST form is `:defdelegate`,
  # invisible to clause_signature/1 — so a sibling top-level run of the same
  # signature looks complete and would lift, installing an unconditional public
  # wrapper that shadows the delegate clause and crashes the delegate's inputs
  # at *baseline*, no mutant active. Unlike metaprogrammed defs, a delegate head
  # is statically visible, so the exact arity is known — this set is keyed by
  # {name, arity}, never blocking same-named functions of other arities.
  #
  # Default arguments (`defdelegate f(a, b \\ [])`) contribute only the full
  # arity: an explicit def at one of the implied lower arities cannot legally
  # coexist with the defaults anyway ("def f/1 conflicts with defaults from
  # f/2" is a compile error), so no compilable module needs them blocked.
  defp delegated_name_arities(chunks) do
    chunks
    |> Enum.flat_map(fn
      {:other, statement} -> nested_delegated_name_arities(statement)
      {:clauses, _clauses} -> []
    end)
    |> MapSet.new()
  end

  defp nested_delegated_name_arities(statement) do
    {_ast, name_arities} =
      Macro.prewalk(statement, [], fn
        {form, _meta, _args}, acc when form in [:defmodule, :defimpl, :defprotocol] ->
          # Prune: return a leaf so prewalk does not descend into the nested scope.
          {:__mutare_pruned__, acc}

        {:defdelegate, _meta, [funs | _opts]} = node, acc ->
          {node, delegate_name_arities(funs) ++ acc}

        node, acc ->
          {node, acc}
      end)

    name_arities
  end

  # `defdelegate` historically accepted a list of heads; List.wrap/1 keeps the
  # extraction total over both the single-head and list shapes.
  defp delegate_name_arities(funs) do
    funs
    |> List.wrap()
    |> Enum.flat_map(fn head ->
      case name_arity(head) do
        {name, arity} -> [{name, arity}]
        :error -> []
      end
    end)
  end

  # The top-level clause-group signatures blocked from lifting by a defdelegate
  # sibling, for the warning. Delegation is the binding diagnosis whenever it
  # applies — see the precedence note in `build/3`.
  defp delegated_signatures(chunks, delegated) do
    chunks
    |> clause_group_signatures()
    |> Enum.filter(fn {_vis, name, arity} -> {name, arity} in delegated end)
  end

  # Mirror of warn_metaprogrammed/2 for the defdelegate case: the delegate is an
  # invisible sibling clause, so lifting is refused and the mutant gap should be
  # visible.
  defp warn_delegated(signatures, file) do
    Enum.each(signatures, fn {_vis, name, arity} ->
      Logger.warning(
        "#{file}: #{name}/#{arity} is also defined by a defdelegate — not lifting " <>
          "(no guard or clause-drop mutants for it)"
      )
    end)
  end
end
