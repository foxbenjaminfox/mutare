defmodule Mutare.SchedulersRunnerTest do
  @moduledoc """
  `:schedulers` trims the sandbox runs' BEAMs (`Invocation.emulator_flags_env/1`). Which runs
  is the contract pinned here, by having the target's suite log the scheduler count it sees:
  the baseline, the coverage probe and every per-mutant run are trimmed — the baseline is the
  mutants' yardstick, and the probe must execute what a mutant run will — while the one
  compile keeps the machine.

  Why the probe: the target below branches on `System.schedulers_online/0`, taking the
  arithmetic under test only at the trimmed count. An untrimmed probe would take the other
  branch, record no coverage for that mutant, and file a killable mutant as `:no_coverage`.
  """
  use ExUnit.Case, async: false

  alias Mutare.Test.Project

  @moduletag :runner
  @moduletag timeout: 180_000

  # A count no machine defaults to, so a trimmed run is told apart from an untrimmed one
  # wherever the suite runs (bar a 3-core box, where the trim proves nothing).
  @trim 3

  test "the baseline, the probe and the mutant runs are all trimmed" do
    %{project: project, sandbox: sandbox} =
      Project.build(:schedulers, %{
        "lib/sched.ex" => """
        defmodule Sched do
          # The mutated arithmetic runs only at the mutants' scheduler count: a probe on
          # every scheduler would never record it.
          def two do
            if System.schedulers_online() == #{@trim}, do: 1 + 1, else: Enum.sum([1, 1])
          end
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

    # `1 + 1`'s mutants are covered and killed; nothing was filed `:no_coverage`.
    statuses = Enum.map(run.results, & &1.status)
    assert :killed in statuses
    refute :no_coverage in statuses

    runs =
      sandbox
      |> Path.join("sched.log")
      |> File.read!()
      |> String.split("\n", trim: true)
      |> Enum.map(&(&1 |> Code.eval_string() |> elem(0)))

    {probes, others} = Enum.split_with(runs, fn {coverage, _mutant, _count} -> coverage end)

    {baselines, mutants} =
      Enum.split_with(others, fn {_coverage, mutant, _count} -> mutant == "0" end)

    assert [{_, _, @trim}] = probes
    assert [_ | _] = baselines
    assert [_ | _] = mutants
    assert Enum.all?(baselines ++ mutants, fn {_coverage, _mutant, count} -> count == @trim end)
  end
end
