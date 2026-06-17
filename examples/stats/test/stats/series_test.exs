defmodule Stats.SeriesTest do
  use ExUnit.Case

  alias Stats.Series

  test "mean averages the values" do
    assert Series.mean([2, 4, 6]) == 4.0
  end

  # This pins the empty branch — but loosely. `assert == 0.0` uses value
  # equality, and `0 == 0.0` is true in Elixir, so a mutant returning the
  # integer 0 survives. (Using `===` would kill it.)
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

  # clamp/3 is exercised inside the range and past each end, but never with
  # low == high — so the guard boundary `low <= high` → `low < high` survives.
  test "clamp restricts a value to the range" do
    assert Series.clamp(5, 0, 10) == 5
    assert Series.clamp(15, 0, 10) == 10
    assert Series.clamp(-3, 0, 10) == 0
  end
end
