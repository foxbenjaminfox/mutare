defmodule Mutare.Transform.ModulePlan do
  @moduledoc false

  # The plan for one statement sequence (a module body, or any block that defines
  # functions): each statement classified into how emission should handle it.
  #
  # This is the "module planning" stage, split out of the emission loop. It is
  # pure and id-free: it groups consecutive same-signature clauses into runs,
  # decides per run whether to lift (delegating to `FunctionPlan.plan/3`), and
  # leaves everything else to be transformed in place. `Mutare.Transform` then
  # walks `items` in order, threading ids and rendering each.
  #
  # An item is one of:
  #
  #   * `{:lift, %FunctionPlan{}}` — a clause group to duplicate behind a dispatcher;
  #   * `{:in_place, [clause]}`    — a clause group whose clauses stay put (bodies
  #     still mutate); used for groups that can't or needn't lift, and for
  #     non-consecutive clauses (see below);
  #   * `{:statement, node}`       — any other statement, transformed in place
  #     (a nested module recurses, a bare expression gets body selectors).

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
  @spec build([Macro.t()], [module()], String.t()) :: t()
  def build(statements, mutators, file) do
    chunks = chunk_clause_runs(statements)
    non_consecutive = non_consecutive_signatures(chunks)
    warn_non_consecutive(non_consecutive, file)

    items =
      Enum.map(chunks, fn
        {:other, statement} ->
          {:statement, statement}

        {:clauses, clauses} ->
          plan_clause_group(clauses, non_consecutive, mutators)
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

  defp plan_clause_group(clauses, non_consecutive, mutators) do
    signature = clause_signature(hd(clauses))

    # Non-consecutive heads can't be lifted (for now). A dispatcher is a catch-all
    # for the whole signature, so lifting one run would shadow the others; and
    # lifting every run as one unit relocates each clause's body to the
    # dispatcher's position — which silently changes semantics when a compile-time
    # `@attr` read between the heads resolves differently there
    # (`@a 1; def f(0), do: @a; @a 2; def f(1), do: @a`). Fall back to in-place;
    # guard/clause-drop mutants are simply not offered for such functions.
    if signature in non_consecutive do
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
end
