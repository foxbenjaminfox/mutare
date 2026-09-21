defmodule Mutare.SchedulersRunnerTest do
  @moduledoc """
  `:schedulers` trims the sandbox runs' BEAMs (`Invocation.emulator_flags_env/1`). Which runs
  is the contract pinned here, by having the target's suite log the scheduler count it sees:
  the baseline and every per-mutant run are trimmed — the baseline is the mutants' yardstick —
  while the coverage probe, alone on the machine, keeps every scheduler.
  """
  use ExUnit.Case, async: false

  alias Mutare.Test.Project

  @moduletag :runner
  @moduletag timeout: 180_000

  # A count no machine defaults to, so a trimmed run is told apart from an untrimmed one
  # wherever the suite runs (bar a 3-core box, where the probe's line proves nothing).
  @trim 3

  test "the baseline and the mutant runs are trimmed; the probe is not" do
    %{project: project, sandbox: sandbox} =
      Project.build(:schedulers, %{
        "lib/sched.ex" => """
        defmodule Sched do
          def two, do: 1 + 1
        end
        """,
        "test/sched_test.exs" => """
        defmodule SchedTest do
          use ExUnit.Case

          test "two" do
            run = {
              System.get_env("#{Mutare.Coverage.Recorder.env_var()}"),
              System.get_env("#{Mutare.Selector.env_var()}"),
              System.schedulers_online()
            }

            File.write!("sched.log", inspect(run) <> "\\n", [:append])
            assert Sched.two() == 2
          end
        end
        """
      })

    assert {:ok, run} =
             Mutare.run(project,
               sandbox: sandbox,
               workers: 2,
               schedulers: @trim,
               mutators: [Mutare.Mutators.Arithmetic]
             )

    assert Enum.any?(run.results, &(&1.status == :killed))

    runs =
      sandbox
      |> Path.join("sched.log")
      |> File.read!()
      |> String.split("\n", trim: true)
      |> Enum.map(&(&1 |> Code.eval_string() |> elem(0)))

    {probes, others} = Enum.split_with(runs, fn {coverage, _mutant, _count} -> coverage end)

    {baselines, mutants} =
      Enum.split_with(others, fn {_coverage, mutant, _count} -> mutant == "0" end)

    assert [{_, _, probe_count}] = probes
    assert probe_count == System.schedulers_online()

    assert [_ | _] = baselines
    assert [_ | _] = mutants
    assert Enum.all?(baselines ++ mutants, fn {_coverage, _mutant, count} -> count == @trim end)
  end
end
