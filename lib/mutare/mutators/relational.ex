defmodule Mutare.Mutators.Relational do
  @moduledoc """
  Relational/equality operator swaps:

      :>   → :>=, :<       :==  → :!=
      :>=  → :>,  :<=      :!=  → :==
      :<   → :<=, :>       :=== → :!==
      :<=  → :<,  :>=      :!== → :===

  Ordering operators mutate to both their boundary neighbour and their direction flip
  (the classic boundary + reversal pair); equality operators flip polarity, and
  membership (`in`) flips to `not in` (the polarity flip for membership, mirroring
  `==` → `!=`). Legal in bodies *and* `when` guards.

  Not mutated:

    * `not in` → `in` is not produced — `x not in y` parses as `not(x in y)`, which
      `Mutare.Mutators.Logical` already strips. For the same reason, an `in` node that
      is the direct operand of `not`/`!` is left to Logical.
    * An **equality** operator (`==`/`!=`/`===`/`!==`) directly under `not`/`!` is left
      to Logical — each is its own exact polarity complement, so `!(a != b)` ≡ `a == b`
      (Logical's strip). The **ordering** operators are *not* suppressed there: their
      boundary/reversal swaps are not the negation complement, so they survive a
      surrounding negation as genuinely new mutants.
  """
  @behaviour Mutare.Mutator

  @swaps %{
    :> => [:>=, :<],
    :>= => [:>, :<=],
    :< => [:<=, :>],
    :<= => [:<, :>=],
    :== => [:!=],
    :!= => [:==],
    :=== => [:!==],
    :!== => [:===]
  }

  @impl Mutare.Mutator
  def name, do: :relational

  # Membership polarity flip: `x in y` → `x not in y`. `not in` is sugar for
  # `not(x in y)`, so we wrap the original `in` node in a fresh-meta `:not` (the
  # formatter renders it back as `x not in y`). Reuses the operand AST, so it stays
  # a minimal, compile- and guard-safe mutation.
  @impl Mutare.Mutator
  def mutate({:in, meta, [left, right]}) do
    [{:not, [], [{:in, meta, [left, right]}]}]
  end

  def mutate({op, meta, [left, right]}) do
    case Map.fetch(@swaps, op) do
      {:ok, replacements} -> Enum.map(replacements, &{&1, meta, [left, right]})
      :error -> :skip
    end
  end

  def mutate(_node), do: :skip
end
