defmodule Mutare.Runner.BaselineTest do
  @moduledoc """
  The baseline is the authoritative green check and the source of `baseline_ms`.
  With `:baseline_runs` > 1 it also catches a flaky suite: runs that disagree with
  themselves abort with `:baseline_flaky` rather than let a flaky test manufacture
  false kills.

  The decision (and the flaky message) is the pure `classify/1` — exercised here
  without spawning `mix`. One `:runner`-tagged test then drives a deterministically
  flaky suite through the whole `Mutare.run/2` pipeline.
  """
  use ExUnit.Case, async: false

  alias Mutare.Runner.Baseline
  alias Mutare.Test.Project

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
  end

  describe "run/2 (flaky baseline, end to end)" do
    @tag :runner
    @tag timeout: 180_000
    test "a suite that passes one run and fails another aborts :baseline_flaky" do
      # The test reads a counter file (persisted in the reused sandbox cwd across
      # the two baseline runs): red on the first run, green on the second → mixed
      # → flaky. `lib/flaky.ex` gives Schema something to mutate (so the run
      # reaches the baseline rather than aborting :nothing_to_mutate first).
      %{project: project, sandbox: sandbox} =
        Project.build(:flaky_baseline, %{
          "lib/flaky.ex" => "defmodule Flaky do\n  def add(a, b), do: a + b\nend\n",
          "test/flaky_test.exs" => """
          defmodule FlakyTest do
            use ExUnit.Case

            test "passes only after the first run" do
              counter = "flaky_counter.txt"

              runs =
                case File.read(counter) do
                  {:ok, n} -> String.to_integer(n)
                  _ -> 0
                end

              File.write!(counter, Integer.to_string(runs + 1))
              assert runs >= 1
            end
          end
          """
        })

      assert {:error, :baseline_flaky, detail} =
               Mutare.run(project, sandbox: sandbox, baseline_runs: 2, mutators: [:arithmetic])

      assert detail =~ "flaky_test.exs"
    end
  end
end
