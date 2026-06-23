defmodule Mutare.Mutators.Logical do
  @moduledoc """
  Logical/boolean operator mutations: `and`↔`or`, `&&`↔`||`, and negation
  stripping (`not x` → `x`, `!x` → `x`).

  The strict connectives `and`/`or` and `not` are legal in `when` guards, so a swap
  there is mutated too; the relaxed `&&`/`||`/`!` are forbidden in guards by the
  compiler, so they only ever appear in ordinary bodies.

  The two pairs are kept distinct rather than collapsed: `&&`/`||` accept any term and
  short-circuit on truthiness, while `and`/`or` require booleans. Swapping within each
  pair preserves that contract.

  Not mutated: in a double negation with the **same** operator (`not not x` / `!!x`) the
  inner strip is identical to the outer's, so only the outer is offered. A *mixed*
  `not !x` is kept — its two strips can diverge on a non-boolean operand (`not x` raises
  where `!x` coerces).
  """
  @behaviour Mutare.Mutator

  @swaps %{
    :and => :or,
    :or => :and,
    :&& => :||,
    :|| => :&&
  }

  @impl Mutare.Mutator
  def name, do: :logical

  @impl Mutare.Mutator
  def mutate({op, meta, [left, right]}) when is_map_key(@swaps, op) do
    [{Map.fetch!(@swaps, op), meta, [left, right]}]
  end

  # Strip a negation: `not x` / `!x` → `x`. The operand already type-checked in
  # its position, so the result always compiles (and stays guard-safe for `not`).
  def mutate({op, _meta, [operand]}) when op in [:not, :!], do: [operand]

  def mutate(_node), do: :skip
end
