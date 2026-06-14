defmodule Mutare.Mutators.Relational do
  @moduledoc """
  Relational/equality operator swaps. Ordering operators mutate to both their
  boundary neighbour and their direction flip (the classic boundary + reversal
  pair); equality operators flip polarity.

  In-place and compile-safe — every substitution is another boolean-valued
  binary operator.
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

  @impl Mutare.Mutator
  def kind, do: :in_place

  @impl Mutare.Mutator
  def mutate({op, meta, [left, right]}) do
    case Map.fetch(@swaps, op) do
      {:ok, replacements} -> Enum.map(replacements, &{&1, meta, [left, right]})
      :error -> :skip
    end
  end

  def mutate(_node), do: :skip
end
