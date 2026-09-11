defmodule Mutare.Runner.BaselineTest do
  @moduledoc """
  The baseline is the authoritative green check and the source of `baseline_ms`.
  With `:baseline_runs` > 1 it also catches a flaky suite: runs that disagree with
  themselves abort with `:baseline_flaky` rather than let a flaky test manufacture
  false kills.

  The decision (and the flaky message) is the pure `classify/1` — exercised here
  without spawning `mix`; baseline_runner_test.exs drives a deterministically flaky
  suite through the whole `Mutare.run/2` pipeline.
  """
  use ExUnit.Case, async: true

  alias Mutare.Runner.Baseline

  describe "classify/1" do
    test "all green → {:ok, the slowest green run} (a conservative cap)" do
      assert Baseline.classify([{:pass, 100}, {:pass, 250}, {:pass, 80}]) == {:ok, 250}
    end

    test "a single green run → {:ok, that run's ms} (the default N=1 path)" do
      assert Baseline.classify([{:pass, 120}]) == {:ok, 120}
    end

    test "all red → {:error, :baseline_failed, output}" do
      assert {:error, :baseline_failed, "boom"} = Baseline.classify([{:fail, "boom"}])
      assert {:error, :baseline_failed, _} = Baseline.classify([{:fail, "a"}, {:fail, "b"}])
    end

    test "a mix of pass and fail → {:error, :baseline_flaky, detail} naming the test" do
      output =
        "  1) test wobbles (FlakyTest)\n     test/flaky_test.exs:7\n     Assertion failed"

      assert {:error, :baseline_flaky, detail} =
               Baseline.classify([{:pass, 90}, {:fail, output}])

      assert detail =~ "passed on some baseline runs and failed on others"
      assert detail =~ "test/flaky_test.exs:7"
    end

    test "flaky detail falls back to the output tail when no test location parses" do
      assert {:error, :baseline_flaky, detail} =
               Baseline.classify([{:pass, 10}, {:fail, "opaque failure, no test path here"}])

      assert detail =~ "Could not pin the flaky test"
      assert detail =~ "opaque failure, no test path here"
    end

    test "the fallback tail keeps only the last lines, newline-joined" do
      # No `_test.exs:NN` location parses, so flaky_detail falls back to tail/1:
      # the *last* 20 lines, joined by newlines. A 25-line run drops the first 5.
      output = Enum.map_join(1..25, "\n", &"line #{&1}")

      assert {:error, :baseline_flaky, detail} =
               Baseline.classify([{:pass, 10}, {:fail, output}])

      # Last 20 lines are present and newline-joined (not first-20, not run together).
      assert detail =~ "line 25"
      assert detail =~ "line 6\nline 7"
      # The first 5 lines are dropped by take(-20) (not take(20) / the whole output).
      refute detail =~ "line 5\n"
      refute detail =~ "line 1\n"
    end
  end
end
