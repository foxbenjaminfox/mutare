defmodule Mutare.Mutators.Integer do
  @moduledoc """
  Swap complementary `Integer` calls for their opposite:

    * `Integer.mod` ↔ `Integer.floor_div` — the two halves of floored division
      (`mod` is the remainder, `floor_div` the quotient); confusing one for the
      other is a classic off-by-operation bug
    * `Integer.is_even` ↔ `Integer.is_odd` — the parity predicates

  Each pair shares its arity (`mod`/`floor_div` are `/2`, `is_even`/`is_odd` are
  `/1`), so renaming while keeping the argument list always compiles. Like the other
  call-matching families, it matches `Integer` by its **resolved** module
  (`Mutare.Transform.Calls`): a renamed `alias Integer, as: I`, and a bare imported
  `is_even` (`import Integer`), are matched (and
  mutates `I.is_even` → `I.is_odd`), while a shadowing `alias MyApp.Integer` resolves
  to the local module and is correctly left alone.

  `Integer.is_even`/`is_odd` are **guard-safe macros**, so they appear in `when`
  clauses as well as bodies. A guard swap is delivered by lifting (a selector
  `case` can't live in a guard) — the same `Integer.` source already carries the
  `require Integer` those macros need, so the `is_odd` copy compiles. `mod`/
  `floor_div` are ordinary functions (never guard-legal), so those swaps are always
  in place. On by default.
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
  def name, do: :integer

  @impl Mutare.Mutator
  def mutate(node), do: Helpers.swap_call(node, @swaps)
end
