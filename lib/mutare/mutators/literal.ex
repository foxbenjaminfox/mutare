defmodule Mutare.Mutators.Literal do
  @moduledoc """
  Constant mutations on integer and boolean literals:

    * integers — `n` → `n + 1`, `n - 1`, and `0` (the "off-by-one" boundary plus
      the zero sentinel), deduplicated and never equal to `n`
    * booleans — `true` ↔ `false`

  Only literals in *runtime* positions are mutated, never pattern literals.
  Mutations that would reproduce the original value are dropped (`0` is not
  re-emitted for the literal `0`; `n - 1` and `0` collapse for `n = 1`).

  Integer literals are pervasive, so this is the highest-volume built-in — the
  cost is paid in the denominator, the benefit is catching constants the suite
  never pins down.
  """
  @behaviour Mutare.Mutator

  alias Mutare.AST
  alias Mutare.Mutators.Helpers

  @impl Mutare.Mutator
  def name, do: :literal

  @impl Mutare.Mutator
  def mutate({:__block__, _meta, [n]}) when is_integer(n), do: Helpers.numeric_mutations(n, 1, 0)

  def mutate({:__block__, _meta, [b]}) when is_boolean(b), do: [AST.literal(not b)]

  def mutate(_node), do: :skip
end
