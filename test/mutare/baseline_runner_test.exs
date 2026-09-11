defmodule Mutare.Runner.BaselineRunnerTest do
  @moduledoc """
  `Mutare.run/2` against a deterministically flaky suite: the baseline decision
  (`Mutare.Runner.Baseline.classify/1`, unit-tested in baseline_test.exs) driven end to end
  through a real `mix test` in a sandbox.
  """
  use ExUnit.Case, async: false

  alias Mutare.Test.Project

  describe "run/2 (flaky baseline, end to end)" do
    @tag :runner
    @tag timeout: 180_000
    test "a suite that passes one run and fails another aborts :baseline_flaky even with retries" do
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
               Mutare.run(
                 project,
                 sandbox: sandbox,
                 baseline_runs: 2,
                 baseline_retries: 3,
                 mutators: [:arithmetic]
               )

      assert detail =~ "flaky_test.exs"
    end

    @tag :runner
    @tag timeout: 180_000
    test "baseline_retries retries an all-red attempt and proceeds after a later green run" do
      # Default baseline_runs: 1: the first baseline attempt is red, then the retry
      # is green. Later coverage/mutant runs stay green at baseline and exercise the
      # arithmetic mutant normally.
      %{project: project, sandbox: sandbox} =
        Project.build(:retry_baseline, %{
          "lib/flaky.ex" => "defmodule Flaky do\n  def add(a, b), do: a + b\nend\n",
          "test/flaky_test.exs" => """
          defmodule FlakyTest do
            use ExUnit.Case

            test "passes after the first run" do
              counter = "retry_counter.txt"

              runs =
                case File.read(counter) do
                  {:ok, n} -> String.to_integer(n)
                  _ -> 0
                end

              File.write!(counter, Integer.to_string(runs + 1))
              assert runs >= 1
              assert Flaky.add(1, 2) == 3
            end
          end
          """
        })

      assert {:ok, run} =
               Mutare.run(
                 project,
                 sandbox: sandbox,
                 baseline_retries: 1,
                 mutators: [:arithmetic]
               )

      assert Enum.map(run.results, & &1.status) == [:killed]
    end
  end
end
