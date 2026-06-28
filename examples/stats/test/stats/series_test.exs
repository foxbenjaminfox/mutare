defmodule Stats.SeriesTest do
  use ExUnit.Case

  alias Stats.Series

  test "mean averages the values" do
    assert Series.mean([2, 4, 6]) == 4.0
  end

  # Pins the empty branch: drop the clause and `Enum.sum([]) / length([])` is
  # 0 / 0, which raises — so the clause_drop dies, and shifting the 0.0 literal
  # changes the result. median/1, by contrast, has *no* empty-list test below.
  test "mean of an empty series is zero" do
    assert Series.mean([]) == 0.0
  end

  # Both fixtures are *symmetric* — reading them back-to-front gives the same
  # multiset — so a mutant that sorts the other way (or reverses instead of
  # sorting) lands on the same median and survives. Asymmetric data would kill it.
  test "median of an odd-length series" do
    assert Series.median([5, 1, 3]) == 3
  end

  test "median of an even-length series averages the two middles" do
    assert Series.median([1, 2, 3, 4]) == 2.5
  end

  # top/2 is pinned hard: the fixture is unsorted with duplicates, so dropping
  # the sort, reversing it, or flipping :desc all change the result and are killed.
  test "top returns the n largest values, descending" do
    assert Series.top([3, 1, 4, 1, 5, 9, 2], 3) == [9, 5, 4]
  end

  # midrange/1 destructures `{low, high}` then averages with a commutative `+`, so
  # PatternSwap's `{high, low}` lands on the same value and survives — the destructuring
  # twin of the symmetric-median survivor above.
  test "midrange averages the smallest and largest" do
    assert Series.midrange([3, 1, 4, 1, 5]) == 3.0
  end

  # spread/1 destructures the same `{low, high}` but subtracts, so the `{high, low}` swap
  # negates the answer — this asymmetric fixture kills it.
  test "spread is the distance between largest and smallest" do
    assert Series.spread([3, 1, 4, 1, 5]) == 4
  end

  # midrange/1 and spread/1 each declare an empty-list base clause; covering
  # them here (drop the clause and the fallthrough call to Enum.min_max([])
  # raises) leaves median([]) as the *one* untested empty branch — the lone
  # clause_drop survivor, on purpose.
  test "midrange and spread handle an empty series" do
    assert Series.midrange([]) == nil
    assert Series.spread([]) == 0
  end

  # clamp/3 is exercised inside the range and past each end, but never with
  # low == high — so the guard boundary `low <= high` → `low < high` survives.
  test "clamp restricts a value to the range" do
    assert Series.clamp(5, 0, 10) == 5
    assert Series.clamp(15, 0, 10) == 10
    assert Series.clamp(-3, 0, 10) == 0
  end
end
