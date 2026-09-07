defmodule Mutare.Test.ExUnitSummary do
  @moduledoc """
  Reads how many tests a captured `mix test` run executed, whatever ExUnit's summary
  wording — which the `:runner` tests must not hard-code, because it has changed in every
  Elixir line Mutare supports:

    * **1.18** — `2 tests, 0 failures, 1 excluded`: the test count *includes* the excluded
      tests, appended `, N excluded`.
    * **1.19** — `1 test, 0 failures (1 excluded)`: the count excludes them, appended in
      parentheses.
    * **1.20** — `Result: 1 passed, 1 excluded`, or `Result: 2/3 passed` when some failed
      (the total is the tests that ran); a per-type breakdown in parentheses appears only
      when more than one type (doctest/property/test) ran. `Result: 0 tests` when none did.

  A test that asserts "only the covering test ran" asks `tests_run/1` for the number and
  compares, instead of matching a phrase.
  """

  # 1.20+: `Result: <passed>[/<ran>] passed…` or `Result: 0 tests`.
  @result ~r/^Result: (?:(?<passed>\d+)(?:\/(?<ran>\d+))? passed|(?<none>0 tests))/m

  # ≤1.19: `[N doctests, ][N properties, ]<count> test(s), F failure(s)<tail>`. In 1.18 the
  # count includes excluded tests, reported in the tail as `, E excluded`; in 1.19 it does not,
  # and the tail reads `(E excluded)`.
  @counts ~r/^(?:\d+ doctests?, )?(?:\d+ propert(?:y|ies), )?(?<count>\d+) tests?, \d+ failures?(?<tail>[^\n]*)/m
  @excluded_in_count ~r/, (?<excluded>\d+) excluded/

  @doc "The number of tests the captured run executed, or `nil` when no summary is found."
  @spec tests_run(String.t()) :: non_neg_integer() | nil
  def tests_run(output) when is_binary(output) do
    cond do
      caps = Regex.named_captures(@result, output) -> from_result(caps)
      caps = Regex.named_captures(@counts, output) -> from_counts(caps)
      true -> nil
    end
  end

  defp from_result(%{"none" => "0 tests"}), do: 0
  defp from_result(%{"ran" => "", "passed" => passed}), do: String.to_integer(passed)
  defp from_result(%{"ran" => ran}), do: String.to_integer(ran)

  defp from_counts(%{"count" => count, "tail" => tail}) do
    case Regex.named_captures(@excluded_in_count, tail) do
      %{"excluded" => excluded} -> String.to_integer(count) - String.to_integer(excluded)
      nil -> String.to_integer(count)
    end
  end
end
