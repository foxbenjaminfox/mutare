defmodule Mutare.Mutators.Relational do
  @moduledoc """
  Relational/equality operator swaps. Ordering operators mutate to both their
  boundary neighbour and their direction flip (the classic boundary + reversal
  pair); equality operators flip polarity, and membership (`in`) flips to `not in`
  (the polarity flip for membership, mirroring `==` → `!=`).

  In-place and compile-safe — every substitution is another boolean-valued
  expression: an operator swap, or (for `in`) a `not`-negated membership test,
  which is legal anywhere `in` is (bodies *and* `when` guards).

  The reverse direction — `not in` → `in` — is not produced here: `x not in y`
  parses as `not(x in y)`, and `Mutare.Mutators.Logical` already strips that `not`.
  To avoid duplicating it, `Mutare.Transform` (and the guard tagger) never offer an
  `in` node that is the direct operand of a `not` to a mutator, so the `in → not in`
  flip below is suppressed exactly there (re-negating it would yield `in` again).
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
