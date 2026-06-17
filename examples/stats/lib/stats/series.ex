defmodule Stats.Series do
  @moduledoc """
  Summary statistics over a list of numbers.

  A Mutare target rich in `Enum`/`List` calls — so it shows off the
  collection-shaped mutators: Collection (swap a call for a sibling of the same
  arity, e.g. `sort` ↔ `reverse`), CollectionArity (drop a refining argument),
  and CallRemoval (delete a transparent transform). The instructive survivors
  come from *symmetric test data*, where reordering a collection can't change
  the answer, and from the empty / single-element boundaries.
  """

  @doc "Arithmetic mean. An empty series has a mean of 0.0 by convention."
  def mean([]), do: 0.0
  def mean(values), do: Enum.sum(values) / length(values)

  @doc "Middle value (the mean of the two middle values when the count is even)."
  def median([]), do: nil

  def median(values) do
    sorted = Enum.sort(values)
    count = length(values)
    mid = div(count, 2)

    if rem(count, 2) == 0 do
      (Enum.at(sorted, mid - 1) + Enum.at(sorted, mid)) / 2
    else
      Enum.at(sorted, mid)
    end
  end

  @doc "The `n` largest values, in descending order."
  def top(values, n) do
    values |> Enum.sort(:desc) |> Enum.take(n)
  end

  @doc "Restrict a value to the inclusive range `[low, high]`."
  def clamp(value, low, high) when low <= high do
    value |> max(low) |> min(high)
  end
end
