defmodule Mutare.Mutators.RescueType do
  @moduledoc """
  Narrows the exceptions handled by a `rescue`.

  For a clause with two or more exception types, the mutator removes each type in
  turn:

      rescue e in [ArgumentError, RuntimeError] -> handle(e)

  produces clauses that rescue only `ArgumentError` or only `RuntimeError`. Both
  bound `var in [A, B]` and bare `[A, B]` forms are supported. A one-element list,
  a single type, and a bare variable are unchanged because they cannot be narrowed
  this way without removing the rescue entirely.

  A rescue with two or more clauses also produces one mutant per removed clause.
  This covers the common form where each clause handles one exception type. At least
  one clause is always retained, and the removed clause may have any valid head,
  including a catch-all variable.

  Both explicit `try` expressions and the `def ... rescue ...` shorthand are
  supported. Type-list narrowing and clause removal are reported under the
  `rescue_type` family.
  """

  # A **transform-managed** family (`Mutare.Mutators.transform_managed/0`): discovery and
  # delivery live in `Mutare.Transform` (`Analyze`/`ClausePatterns.rescue_type_candidates/3`),
  # which calls `drops/1` for the list-narrowing and owns the whole-clause drop directly.
  # `drops/1` is a plain helper, *not* a `Mutare.Mutator` producing callback (the clause-drop
  # half doesn't fit a `node -> [mutation]` shape), so — like `GuardDrop` — this module is
  # registered for naming/toggling but does **not** implement `Mutare.Mutator`.
  def name, do: :rescue_type

  @doc """
  The narrowed exception-type lists for a rescue clause's `in [t1, ..., tn]` list:
  each list with one type removed, **only** when ≥2 types are present (so the result
  is always non-empty — dropping the last would leave `in []`, which rescues
  nothing). Returns `[]` for a single type / bare alias / bare variable.
  """
  @spec drops([Macro.t()]) :: [[Macro.t()]]
  def drops(types) when is_list(types) and length(types) >= 2 do
    Enum.map(0..(length(types) - 1), &List.delete_at(types, &1))
  end

  def drops(_types), do: []
end
