defmodule Mutare.Mutators.Integer do
  @moduledoc """
  Swap complementary `Integer` calls for their opposite:

    * `Integer.mod` ↔ `Integer.floor_div` — the two halves of floored division
      (`mod` is the remainder, `floor_div` the quotient); confusing one for the
      other is a classic off-by-operation bug
    * `Integer.is_even` ↔ `Integer.is_odd` — the parity predicates

  Each pair shares its arity (`mod`/`floor_div` are `/2`, `is_even`/`is_odd` are
  `/1`), so renaming while keeping the argument list always compiles. The sibling
  of `Mutare.Mutators.Collection`/`StringCall`; it recognises only **unaliased**
  `Integer.` calls by name, so a shadowing alias simply isn't matched (no false
  mutation).

  `Integer.is_even`/`is_odd` are **guard-safe macros**, so they appear in `when`
  clauses as well as bodies. A guard swap is delivered by lifting (a selector
  `case` can't live in a guard) — the same `Integer.` source already carries the
  `require Integer` those macros need, so the `is_odd` copy compiles. `mod`/
  `floor_div` are ordinary functions (never guard-legal), so those swaps are always
  in place. On by default.
  """
  @behaviour Mutare.Mutator

  # {alias_path, function} => {alias_path, function}. Each pair shares its arity, so
  # the rename keeping the argument list always compiles.
  @swaps %{
    {[:Integer], :mod} => {[:Integer], :floor_div},
    {[:Integer], :floor_div} => {[:Integer], :mod},
    {[:Integer], :is_even} => {[:Integer], :is_odd},
    {[:Integer], :is_odd} => {[:Integer], :is_even}
  }

  @impl Mutare.Mutator
  def name, do: :integer

  @impl Mutare.Mutator
  def mutate({{:., dot_meta, [{:__aliases__, alias_meta, mod}, fun]}, call_meta, args})
      when is_list(args) do
    case Map.fetch(@swaps, {mod, fun}) do
      {:ok, {new_mod, new_fun}} ->
        [{{:., dot_meta, [{:__aliases__, alias_meta, new_mod}, new_fun]}, call_meta, args}]

      :error ->
        :skip
    end
  end

  def mutate(_node), do: :skip
end
