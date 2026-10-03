defmodule Mutare.PartitionCheckRunnerTest do
  @moduledoc """
  End-to-end check of `Mutare.Runner.PartitionCheck`: a run whose partition 2 is broken
  warns about it, after rerunning one of its kills there with no mutant active.

  A partition is reported only if the rerun fails on every `:kill_runs` attempt and the
  same tests pass on partition 1. Timeouts must also repeat without competing checks
  when timeout confirmation is enabled.

  The fixture's suite checks `Calc`'s answers, so most mutants are killed honestly
  wherever they run, and a mutant killed on partition 2 would most likely be killed on
  partition 1 too: rerunning it there could not tell the broken partition apart.
  Partition 2 stands in for a worker whose database is missing, either by failing the
  test there or by refusing to start the application there.
  """
  # Subprocess-bound: runs beside the in-process tests, one module at a time within its
  # group (`test_helper.exs` says why there are three).
  use ExUnit.Case, async: true, group: :subprocess_1

  import ExUnit.CaptureLog

  alias Mutare.{Options, Result, Site}
  alias Mutare.Runner.{PartitionCheck, RunCtx}
  alias Mutare.Sandbox.Command.Exit
  alias Mutare.Test.Project

  @moduletag :runner
  # compile + baseline + probe + one subprocess per mutant, each app-start failure retried
  @moduletag timeout: 300_000

  @slot_var "MUTARE_TEST_DB_SLOT"

  @bodies ~w(x+y x-y x*y x>y x<y x>=y)
  @names Enum.map(1..length(@bodies), &:"f#{&1}")
  @calc """
  defmodule Calc do
  #{Enum.map_join(Enum.zip(@names, @bodies), "\n", fn {name, body} -> "  def #{name}(x, y), do: #{body}" end)}
  end
  """

  defp test_file(check) do
    """
    defmodule CalcTest do
      use ExUnit.Case

      test "Calc answers for 3 and 2" do
        #{check}
        assert Enum.map(#{inspect(@names)}, &apply(Calc, &1, [3, 2])) ==
                 [5, 1, 6, true, false, true]
      end
    end
    """
  end

  defp run(project, sandbox, opts \\ []) do
    with_log(fn ->
      Mutare.run(
        project,
        [
          sandbox: sandbox,
          mutators: [Mutare.Mutators.Arithmetic, Mutare.Mutators.Relational],
          partition_env: @slot_var,
          workers: 2
        ] ++ opts
      )
    end)
  end

  test "warns about a partition where the tests fail" do
    %{project: project, sandbox: sandbox} =
      Project.build(:partition_check, %{
        "lib/calc.ex" => @calc,
        "test/calc_test.exs" =>
          test_file(~s|if System.get_env("#{@slot_var}") == "2", do: raise("no database")|)
      })

    assert {{:ok, run}, log} = run(project, sandbox)

    assert Enum.any?(run.results, &(&1.partition == 2 and &1.status == :killed))
    assert log =~ "partition 2's kills may be false. With no mutant active, the tests that killed"
    assert log =~ "The rerun ended with: ** (RuntimeError) no database"

    assert [
             %{
               partition: 2,
               failure: :tests_failed,
               reason: "** (RuntimeError) no database",
               mutant: mutant
             }
           ] = run.broken_partitions

    assert %{partition: 2, status: :killed} = Enum.find(run.results, &(&1.site.id == mutant))
    refute log =~ "partition 1's kills"
  end

  test "warns about a partition where the application fails to start" do
    %{project: project, sandbox: sandbox} =
      Project.build(:partition_check_app, %{
        "mix.exs" => """
        defmodule PartitionCheckApp.MixProject do
          use Mix.Project
          def project, do: [app: :partition_check_app, version: "0.1.0", elixir: "~> 1.15"]
          def application, do: [mod: {CalcApp, []}]
        end
        """,
        "lib/calc_app.ex" => """
        # mutare:ignore-file the stand-in for a database connection, not code under test
        defmodule CalcApp do
          use Application

          def start(_type, _args) do
            case System.get_env("#{@slot_var}") do
              "2" -> {:error, :no_database}
              _ -> Supervisor.start_link([], strategy: :one_for_one)
            end
          end
        end
        """,
        "lib/calc.ex" => @calc,
        "test/calc_test.exs" => test_file("")
      })

    assert {{:ok, run}, log} = run(project, sandbox)

    assert Enum.any?(run.results, &(&1.partition == 2 and &1.status == :killed))

    assert log =~
             "partition 2's kills may be false. With no mutant active, " <>
               "the application would not start on partition 2"

    assert [%{partition: 2, failure: :app_start, reason: reason}] = run.broken_partitions
    assert reason =~ "Could not start application partition_check_app"
  end

  @tag :tmp_dir
  test "a failure that does not repeat across --kill-runs reports nothing", %{tmp_dir: tmp_dir} do
    # Partition 2 fails its first run with no mutant active, then works: a flaky test.
    marker = Path.join(tmp_dir, "flaked")

    flake = """
    if System.get_env("#{@slot_var}") == "2" and
         System.get_env("#{Mutare.Selector.env_var()}") == "0" and
         not File.exists?(#{inspect(marker)}) do
      File.write!(#{inspect(marker)}, "")
      raise "flaked"
    end
    """

    %{project: project, sandbox: sandbox} =
      Project.build(:partition_check_flaky, %{
        "lib/calc.ex" => @calc,
        "test/calc_test.exs" => test_file(flake)
      })

    assert {{:ok, run}, _log} = run(project, sandbox, kill_runs: 2)

    assert Enum.any?(run.results, &(&1.partition == 2 and &1.status == :killed))
    assert File.exists?(marker), "the rerun on partition 2 never flaked"
    assert run.broken_partitions == []
  end

  test "tests that fail on their own fail the control, and no partition is blamed" do
    # `mix test` loads only the files a run selects: run alone, the Calc test cannot find
    # the module the other test file defines, and fails on every partition.
    %{project: project, sandbox: sandbox} =
      Project.build(:partition_check_alone, %{
        "lib/calc.ex" => @calc,
        "test/helper_test.exs" => """
        defmodule HelperTest do
          use ExUnit.Case
          test "is loaded", do: assert(true)
        end
        """,
        "test/calc_test.exs" => test_file("assert Code.ensure_loaded?(HelperTest)")
      })

    assert {{:ok, run}, log} = run(project, sandbox)

    assert Enum.any?(run.results, &(&1.partition == 2 and &1.status == :killed))
    assert run.broken_partitions == []
    assert log =~ "on partition 2 fail there and on partition 1 too"
  end

  for {outcome, confirm?, kill_runs, failure} <- [
        {:passed, true, 1, nil},
        {:passed, true, 2, nil},
        {:timeout, true, 1, :timeout},
        {:failed, true, 1, :tests_failed},
        {:harness_error, true, 1, nil},
        {:passed, false, 1, :timeout}
      ] do
    @tag outcome: outcome, confirm?: confirm?, kill_runs: kill_runs, failure: failure
    test "partition timeout confirmation: #{outcome}, confirm=#{confirm?}, kill_runs=#{kill_runs}",
         %{outcome: outcome, confirm?: confirm?, kill_runs: kill_runs, failure: failure} do
      # Model contention deterministically: the first attempts on partitions 2 and 3
      # exit with the watcher's timeout code; later attempts reach the chosen verdict.
      # A barrier makes both initial checks start before either can time out. Each
      # confirmation verifies that every concurrent attempt has finished first.
      exit_status =
        case outcome do
          :passed -> 0
          :timeout -> Exit.timeout()
          :failed -> Exit.failure()
          :harness_error -> 1
        end

      %{project: project} =
        Project.build(:partition_check_timeout, %{
          "test/test_helper.exs" => """
          spawn(fn -> Process.sleep(30_000); System.halt(1) end)
          slot = System.fetch_env!(#{inspect(@slot_var)})
          "0" = System.fetch_env!(#{inspect(Mutare.Selector.env_var())})
          marker = "attempts-" <> slot
          attempt = if File.exists?(marker), do: String.to_integer(File.read!(marker)) + 1, else: 1
          File.write!(marker, Integer.to_string(attempt))

          cond do
            slot == "1" ->
              System.halt(0)

            attempt <= #{kill_runs} ->
              File.write!("started-" <> slot, "")
              wait = fn wait ->
                if Enum.all?(["2", "3"], &File.exists?("started-" <> &1)) do
                  :ok
                else
                  Process.sleep(10)
                  wait.(wait)
                end
              end
              wait.(wait)
              if attempt == #{kill_runs}, do: File.write!("finished-" <> slot, "")
              System.halt(#{Exit.timeout()})

            true ->
              unless Enum.all?(["2", "3"], &File.exists?("finished-" <> &1)) do
                File.write!("overlapping-confirmation", "")
              end
              IO.puts("confirmed verdict")
              System.halt(#{exit_status})
          end
          """
        })

      assert {_output, 0} = Project.compile(project)

      ctx = %RunCtx{
        options:
          Options.new(
            partition_env: @slot_var,
            workers: 3,
            confirm_timeouts: confirm?,
            kill_runs: kill_runs,
            harness_retries: 0
          ),
        sandbox: project,
        project_root: project,
        selection: {:run_all, nil},
        cap: 60_000,
        scopes: %{},
        partitions: :disabled,
        # Partition checks, including confirmation, must still run after the budget.
        deadline: System.monotonic_time(:millisecond) - 1,
        on_start: fn _ -> :ok end,
        reporter: fn _ -> :ok end,
        on_phase: fn _ -> :ok end
      }

      kills =
        for partition <- [2, 3] do
          %Result{
            site: %Site{id: partition, file: "lib/calc.ex", line: 1},
            status: :killed,
            partition: partition,
            duration_ms: 1
          }
        end

      {broken, log} = with_log(fn -> PartitionCheck.run(ctx, kills) end)

      refute File.exists?(Path.join(project, "overlapping-confirmation"))

      for partition <- [2, 3] do
        attempts = File.read!(Path.join(project, "attempts-#{partition}"))
        assert String.to_integer(attempts) == kill_runs + if(confirm?, do: 1, else: 0)
      end

      if failure do
        assert Enum.map(broken, &{&1.partition, &1.failure}) == [{2, failure}, {3, failure}]
        assert File.read!(Path.join(project, "attempts-1")) == "2"
        if confirm?, do: assert(Enum.all?(broken, &(&1.reason == "confirmed verdict")))
      else
        assert broken == []
        refute log =~ "kills may be false"
        refute File.exists?(Path.join(project, "attempts-1"))
      end
    end
  end
end
