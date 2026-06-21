defmodule Mutare.Mutators.MapSet do
  @moduledoc """
  Swap a `MapSet` set-combination call for its complement:

    * `MapSet.union` ↔ `MapSet.intersection`

  The two opposite ways to combine two sets — keep-everything-from-either vs
  keep-only-the-shared — so swapping asks: does the suite actually pin down *which*
  combination this code performs, or would the union pass for the intersection (and
  vice versa)? Classic untested-edge territory when a test only exercises overlapping
  or disjoint inputs.

  Both are `/2` and return a `MapSet`, so renaming the function while keeping the
  argument list always compiles — an arity-blind rename like `Mutare.Mutators.Collection`,
  correct in a pipe for free. These are remote calls, never legal in a guard, so
  guard-safety is automatic.

  Only the **commutative** combinators live here (order doesn't matter, so the swap is a
  pure name change). The *non-commutative* `MapSet` calls — `difference` and `subset?`,
  where the argument *order* carries the meaning — are operand-order swaps, so they belong
  to `Mutare.Mutators.OperandSwap` (which transposes their two arguments), not here.

  On by default. Recognises `MapSet` by its resolved module (`Mutare.Transform.Calls`),
  so an aliased (`alias MapSet, as: MS; MS.union(a, b)`) or bare-imported call is matched
  while a shadowing `alias MyApp.MapSet` is left alone. The family atom is `:map_set`.
  """
  @behaviour Mutare.Mutator

  alias Mutare.Mutators.Helpers

  # {alias_path, function} => new_function. Both exist in `MapSet` at the same arity
  # (`/2`), so the swap keeps the argument list and `Helpers.swap_call/2` keeps the
  # written module (an aliased `MS.union` mutates to `MS.intersection`).
  @swaps %{
    {[:MapSet], :union} => :intersection,
    {[:MapSet], :intersection} => :union
  }

  @impl Mutare.Mutator
  def name, do: :map_set

  @impl Mutare.Mutator
  def mutate(node), do: Helpers.swap_call(node, @swaps)
end
