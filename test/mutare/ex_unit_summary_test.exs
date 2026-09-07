defmodule Mutare.ExUnitSummaryTest do
  use ExUnit.Case, async: true

  import Mutare.Test.ExUnitSummary, only: [tests_run: 1]

  # One narrowed run of a two-test file, as each supported Elixir line summarises it.
  test "one test of two, across the three summary wordings" do
    assert tests_run("Finished in 0.01 seconds\n2 tests, 0 failures, 1 excluded\n") == 1
    assert tests_run("Finished in 0.01 seconds\n1 test, 0 failures (1 excluded)\n") == 1
    assert tests_run("Finished in 0.01 seconds\n\nResult: 1 passed, 1 excluded\n") == 1
  end

  test "a whole file, green" do
    assert tests_run("2 tests, 0 failures\n") == 2
    assert tests_run("Result: 2 passed\n") == 2
  end

  test "failures: the total is what ran" do
    assert tests_run("85 doctests, 12 properties, 2977 tests, 1 failure\n") == 2977

    assert tests_run("Result: 2/3 passed (1/2 tests, 1 property), 1 excluded\nFailed: 1 test\n") ==
             3
  end

  test "nothing ran, or no summary at all" do
    assert tests_run("Result: 0 tests, 2 excluded\n") == 0
    assert tests_run("0 tests, 0 failures\n") == 0
    assert tests_run("== Compilation error in file lib/x.ex ==\n") == nil
  end
end
