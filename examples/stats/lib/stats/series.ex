defmodule Stats.Series do
  @moduledoc """
  Summary statistics over a list of numbers.

  A Mutare target rich in `Enum`/`List` calls — so it shows off the
  collection-shaped mutators: Collection (swap a call for a sibling of the same
  arity, e.g. `sort` ↔ `reverse`), CollectionArity (drop a refining argument),
  and CallRemoval (delete a transparent transform). It also destructures a
  `{low, high}` pair (`midrange/1`, `spread/1`), so PatternSwap exchanges the two
  bindings — a survivor when they feed a commutative `+`, a kill when they feed a
  `-`. The instructive survivors come from *symmetric test data*, where reordering
  a collection (or a destructured pair) can't change the answer, and from the
  empty / single-element boundaries.
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

  @doc "The midrange: the mean of the smallest and largest values."
  def midrange([]), do: nil

  def midrange(values) do
    # A statement-position destructure, so PatternSwap rewrites `{low, high}` →
    # `{high, low}`. The result feeds a *commutative* `+`, so the swap can't change
    # the midrange — a textbook surviving mutant, the same symmetry the median tests hit.
    {low, high} = Enum.min_max(values)
    (low + high) / 2
  end

  @doc "The spread: the distance between the largest and smallest values."
  def spread([]), do: 0

  def spread(values) do
    # The same `{low, high}` destructure, but feeding a *non-commutative* `-`: swapping
    # to `{high, low}` negates the result, so an asymmetric fixture kills that mutant —
    # the contrast with `midrange/1` is the lesson.
    {low, high} = Enum.min_max(values)
    high - low
  end

  @doc "Restrict a value to the inclusive range `[low, high]`."
  def clamp(value, low, high) when low <= high do
    value |> max(low) |> min(high)
  end
end
