defmodule Mutare.Mutators.IntegerCall do
  @moduledoc """
  Swap complementary `Integer` calls for their opposite:

    * `Integer.mod` ↔ `Integer.floor_div` — the two halves of floored division (`mod` is the remainder, `floor_div` the quotient); confusing one for the other is a classic off-by-operation bug
    * `Integer.is_even` ↔ `Integer.is_odd` — the parity predicates

  The integer-call sibling of `Mutare.Mutators.Numeric`/`Math` (and named like `Mutare.Mutators.StringCall` beside the `Mutare.Mutators.IntegerLiteral` value family, to keep "calls to `Integer`" distinct from "integer literals").

  `Integer.is_even`/`is_odd` are guard-safe macros, so a swap in a `when` clause is mutated too. On by default. Matches aliased and bare-imported calls (`alias Integer, as: I; I.is_even` → `I.is_odd`), while a shadowing `alias MyApp.Integer` is left alone.
  """
  @behaviour Mutare.Mutator

  alias Mutare.Mutators.Helpers

  # {alias_path, function} => new_function. Each pair shares its arity, so the rename
  # keeping the argument list always compiles; `Helpers.swap_call/2` keeps the written
  # module, so an aliased `I.is_even` mutates to `I.is_odd`, not `Integer.is_odd`.
  @swaps %{
    {[:Integer], :mod} => :floor_div,
    {[:Integer], :floor_div} => :mod,
    {[:Integer], :is_even} => :is_odd,
    {[:Integer], :is_odd} => :is_even
  }

  @impl Mutare.Mutator
  def name, do: :integer_call

  @impl Mutare.Mutator
  def mutate(node), do: Helpers.swap_call(node, @swaps)
end
