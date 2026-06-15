defmodule Mutare.Mutators.Logical do
  @moduledoc """
  Logical/boolean operator mutations: `and`↔`or`, `&&`↔`||`, and negation
  stripping (`not x` → `x`, `!x` → `x`).

  Compile-safe by construction — each swap reuses the original operands and
  yields another boolean connective, and dropping a `not`/`!` leaves a
  sub-expression that already type-checked.

  ## Guard-safety

  The strict connectives `and`/`or` and `not` are legal in `when` guards, so the
  lift path can deliver them there safely. The relaxed `&&`/`||`/`!` macros are
  *forbidden* in guards by the compiler, so a source guard can never contain one
  — this mutator is therefore only ever asked to swap them in ordinary bodies.

  ## `&&`/`||` vs `and`/`or`

  We keep the two pairs distinct rather than collapsing them: `&&`/`||` accept
  any term and short-circuit on truthiness, while `and`/`or` require booleans.
  Swapping within each pair preserves that contract, so the mutant always
  compiles and only its logic changes.
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
