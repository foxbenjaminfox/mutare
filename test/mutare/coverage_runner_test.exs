defmodule Mutare.CoverageRunnerTest do
  @moduledoc """
  Coverage end to end: the probe's recording drives `:no_coverage` and test selection in real
  `mix` runs. The in-process recorder and helper tests are in `coverage_test.exs`.
  """
  # Subprocess-bound: runs beside the in-process tests, one module at a time within its
  # group (`test_helper.exs` says why there are three).
  use ExUnit.Case, async: true, group: :subprocess_3

  import Mutare.Test.ExUnitSummary, only: [tests_run: 1]

  import ExUnit.CaptureLog, only: [capture_log: 1]

  alias Mutare.{Coverage, Result}
  alias Mutare.Coverage.Recorder
  alias Mutare.Test.Project

  @moduletag :runner
  @moduletag timeout: 180_000

  # Pin the end-to-end runs to the operator-swap families: these tests assert
  # coverage classification and test-file selection, not mutant volume, so the
  # higher-volume default mutators (literals) are excluded for determinism/speed.
  @probe [Mutare.Mutators.Arithmetic, Mutare.Mutators.Relational]

  describe "no-coverage skipping (end to end)" do
    test "selecting only uncovered code skips it even when the probe records no hits" do
      %{project: project, sandbox: sandbox} =
        Project.build(:focused_cov, %{
          "lib/nc.ex" => """
          defmodule NC do
            def covered(x), do: x + 1
            def dead(x), do: x - 1
          end
          """,
          "test/nc_test.exs" => """
          defmodule NCTest do
            use ExUnit.Case
            test "covered", do: assert(NC.covered(2) == 3)
          end
          """
        })

      for lines <- [[3], nil, [2, 3]] do
        only_lines = if lines, do: MapSet.new(lines, &{"lib/nc.ex", &1})

        assert {:ok, run} =
                 Mutare.run(project,
                   sandbox: sandbox,
                   mutators: [Mutare.Mutators.Arithmetic],
                   only_lines: only_lines
                 )

        assert %Result{status: :no_coverage, duration_ms: 0, output: nil, exit_status: nil} =
                 Enum.find(run.results, &(&1.site.line == 3))

        if lines == [3] do
          assert length(run.results) == 1

          assert {:ok, %{aggregate: aggregate}} =
                   Coverage.read_dump(Path.join(sandbox, Recorder.dump_file()))

          assert MapSet.size(aggregate) == 0
        else
          assert [%Result{status: :killed}, %Result{status: :no_coverage}] = run.results
        end

        assert Mutare.Score.score(run.results) == 100.0
      end
    end

    test "a mutant on an unexecuted line is :no_coverage and is not run" do
      %{project: project, sandbox: sandbox} =
        Project.build(:cov, %{
          "lib/cov.ex" => """
          defmodule Cov do
            def classify(x) do
              if x > 0 do
                x + 1
              else
                x - 1
              end
            end
          end
          """,
          "test/cov_test.exs" => """
          defmodule CovTest do
            use ExUnit.Case

            # Only the positive branch is ever exercised.
            test "classify positive" do
              assert Cov.classify(5) == 6
            end
          end
          """
        })

      assert {:ok, run} = Mutare.run(project, sandbox: sandbox, mutators: @probe)

      by_op = Map.new(run.results, &{&1.site.original_form, &1})

      # `x - 1` lives in the else branch, which no test executes → skipped.
      assert %Result{status: :no_coverage, duration_ms: 0, output: nil} = by_op[:-]

      # `x + 1` is in the executed then-branch → actually run (and killed here).
      assert by_op[:+].status == :killed

      # no-coverage mutants are excluded from the denominator
      assert Enum.count(run.results, &(&1.status == :no_coverage)) == 1
    end

    test "a covered mutant in a relative nested module is run" do
      %{project: project, sandbox: sandbox} =
        Project.build(:nested, %{
          "lib/outer.ex" => """
          defmodule Outer do
            defmodule Inner do
              def add(a, b), do: a + b
            end
          end
          """,
          "test/outer_test.exs" => """
          defmodule OuterTest do
            use ExUnit.Case
            test "nested add", do: assert(Outer.Inner.add(2, 3) == 5)
          end
          """
        })

      assert {:ok, run} = Mutare.run(project, sandbox: sandbox, mutators: @probe)
      assert [%Result{status: :killed}] = run.results
    end

    test "coverage tracking includes code reached from test_helper setup" do
      %{project: project, sandbox: sandbox} =
        Project.build(:helper_cov, %{
          "lib/startup.ex" => """
          defmodule Startup do
            def touch, do: 1 + 1
          end
          """,
          "test/test_helper.exs" => """
          Startup.touch()
          ExUnit.start()
          """,
          "test/startup_test.exs" => """
          defmodule StartupTest do
            use ExUnit.Case
            test "unrelated green test", do: assert(true)
          end
          """
        })

      assert {:ok, run} =
               Mutare.run(project, sandbox: sandbox, mutators: [Mutare.Mutators.Arithmetic])

      # The only execution of Startup.touch/0 happens in test_helper.exs before
      # any test process is labeled. That is covered-but-unattributed, so it must
      # run the whole suite rather than being skipped as :no_coverage.
      assert [%Result{status: :survived, duration_ms: ms, output: output}] = run.results
      assert ms > 0
      # The whole (1-test) suite ran rather than being skipped as :no_coverage.
      assert tests_run(output) == 1
    end

    test "a target lib/mutare_cov.ex is preserved and can still host mutants" do
      %{project: project, sandbox: sandbox} =
        Project.build(:cov_name_collision, %{
          "lib/mutare_cov.ex" => """
          defmodule MutareCov do
            def value, do: 40 + 2
          end
          """,
          "test/mutare_cov_test.exs" => """
          defmodule MutareCovTest do
            use ExUnit.Case
            test "value", do: assert(MutareCov.value() == 42)
          end
          """
        })

      assert {:ok, run} =
               Mutare.run(project, sandbox: sandbox, mutators: [Mutare.Mutators.Arithmetic])

      assert [%Result{status: :killed}] = run.results
      assert File.read!(Path.join(sandbox, "lib/mutare_cov.ex")) =~ "def value"
      assert File.regular?(Path.join(sandbox, "lib/__mutare__/coverage_helper.ex"))
    end
  end

  # A single file with TWO tests, only one of which touches the mutated line. This is the case that
  # distinguishes `:tests` (narrow to the covering test) from `:coverage` (run the whole file): the
  # file-granular tests can't, since each of their files holds a single test. The lone mutant
  # *survives* (the covering test asserts only that the result stays an integer), so the run always
  # executes its full selected set — no `--max-failures 1` early abort — making the test count in
  # the output deterministic (a killing mutant's count would be order-dependent; see the setup_all
  # test below).
  defp two_test_project(name) do
    Project.build(name, %{
      "lib/calc.ex" => "defmodule Calc do\n  def add(a, b), do: a + b\nend\n",
      "test/calc_test.exs" => """
      defmodule CalcTest do
        use ExUnit.Case
        test "covers add loosely", do: assert(is_integer(Calc.add(2, 3)))
        test "unrelated", do: assert(1 == 1)
      end
      """
    })
  end

  describe "test-case selection (:tests default, end to end)" do
    test "the default narrows to the covering test case within a multi-test file" do
      %{project: project, sandbox: sandbox} = two_test_project(:tests_narrow)

      # No :test_selection given ⇒ the :tests default.
      assert {:ok, run} = Mutare.run(project, sandbox: sandbox, mutators: @probe)

      assert [%Result{status: :survived} = result] = run.results
      # Narrowed to `--only test:"test covers add loosely"` → ExUnit runs 1 test, not the 2-test
      # file.
      assert tests_run(result.output) == 1
      assert result.selection == :tests
    end

    test "--per-file (:coverage) opts out, running the whole covering file" do
      %{project: project, sandbox: sandbox} = two_test_project(:tests_optout)

      assert {:ok, run} =
               Mutare.run(project,
                 sandbox: sandbox,
                 mutators: @probe,
                 test_selection: :coverage
               )

      assert [%Result{status: :survived} = result] = run.results
      # The whole covering file runs — both tests, no per-test narrowing.
      assert tests_run(result.output) == 2
      assert result.selection == :files
    end
  end

  describe "test-file selection (end to end)" do
    test "a mutant runs only the test files that cover it" do
      %{project: project, sandbox: sandbox} =
        Project.build(:sel, %{
          "lib/calc.ex" => "defmodule Calc do\n  def add(a, b), do: a + b\nend\n",
          "lib/greeter.ex" => "defmodule Greeter do\n  def shout(n), do: n * 2\nend\n",
          "test/calc_test.exs" => """
          defmodule CalcTest do
            use ExUnit.Case
            test "add", do: assert(Calc.add(2, 3) == 5)
          end
          """,
          "test/greeter_test.exs" => """
          defmodule GreeterTest do
            use ExUnit.Case
            test "shout", do: assert(Greeter.shout(3) == 6)
          end
          """
        })

      assert {:ok, run} = Mutare.run(project, sandbox: sandbox, mutators: @probe)

      by_op = Map.new(run.results, &{&1.site.original_form, &1})

      # Calc.add's `+` mutant is covered only by calc_test.exs → that file alone
      # runs (1 test), not the whole 2-test suite — and it's killed.
      calc = by_op[:+]
      assert calc.status == :killed
      assert tests_run(calc.output) == 1

      # Greeter.shout's `*` mutant likewise runs only greeter_test.exs, killed.
      greeter = by_op[:*]
      assert greeter.status == :killed
      assert tests_run(greeter.output) == 1
    end

    test "a mutant covered only via a test body's on_exit is attributed to that file (not the whole suite)" do
      %{project: project, sandbox: sandbox} =
        Project.build(:on_exit_cov, %{
          "lib/cleanup.ex" => "defmodule Cleanup do\n  def verify(x), do: x + 1\nend\n",
          # Cleanup.verify runs *only* inside an `on_exit` registered in the test body. The
          # callback runs in ExUnit's per-test runner process (no label, caller already dead) —
          # attributed via its `:"-test …"` closure frame. An `on_exit` failure fails the owning
          # test, so this file alone kills the mutant.
          "test/on_exit_test.exs" => """
          defmodule OnExitTest do
            use ExUnit.Case
            test "verifies in cleanup" do
              on_exit(fn -> assert Cleanup.verify(1) == 2 end)
              assert true
            end
          end
          """,
          "test/other_test.exs" => """
          defmodule OtherTest do
            use ExUnit.Case
            test "unrelated", do: assert(1 == 1)
          end
          """
        })

      assert {:ok, run} = Mutare.run(project, sandbox: sandbox, mutators: @probe)

      # Killed by on_exit_test.exs *alone* (1 test, not the 2-test whole suite): the closure-frame
      # recovery attributed the id instead of dropping it to the unlabeled (run-everything) bucket.
      assert [result] = run.results
      assert result.status == :killed
      assert tests_run(result.output) == 1
    end

    test "a mutant covered via another file's setup_all is attributed to both files (no false survivor)" do
      %{project: project, sandbox: sandbox} =
        Project.build(:setup_all_cov, %{
          "lib/shared.ex" => "defmodule Shared do\n  def calc(x), do: x + 1\nend\n",
          # This file *touches the line* in its test body, so the id is attributed
          # here — but the test asserts nothing about the value, so it can never kill
          # the mutant. Under the old "attributed file wins" rule this masked the
          # killing file below and produced a false survivor.
          "test/touch_test.exs" => """
          defmodule TouchTest do
            use ExUnit.Case
            test "touches Shared.calc without asserting its value" do
              _ = Shared.calc(5)
              assert true
            end
          end
          """,
          # The killing test reaches Shared.calc only through `setup_all`. That runs
          # in an unlabeled process, but inside this module's `__ex_unit__/2`
          # dispatch, so the id is attributed to setup_all_test.exs via the
          # stacktrace recovery — the only test that distinguishes the mutation.
          "test/setup_all_test.exs" => """
          defmodule SetupAllTest do
            use ExUnit.Case
            setup_all do
              %{value: Shared.calc(5)}
            end
            test "asserts the exact value", %{value: value} do
              assert value == 6
            end
          end
          """
        })

      assert {:ok, run} = Mutare.run(project, sandbox: sandbox, mutators: @probe)

      # Every `+` mutant is killed (not a false survivor). Both files attribute the
      # id — touch_test.exs via its body, setup_all_test.exs via the `__ex_unit__/2`
      # stacktrace recovery — so the run includes the killing file. Here the two
      # covering files happen to be the whole 2-file suite.
      assert run.results != []
      assert Enum.all?(run.results, &(&1.status == :killed))

      # The kill is driven by setup_all_test's `assert value == 6` (touch_test asserts
      # nothing it could fail on), so a killed mutant proves the recovery-attributed
      # killing file was selected and run — touch_test's body attribution did not mask
      # it. We do *not* assert the subprocess test *count* ("2 tests"): the runner forces
      # `--max-failures 1` (`Mutare.Sandbox.Command`), so when ExUnit happens to run the
      # failing setup_all_test before touch_test the suite aborts after one test, making
      # the count order-dependent. The kill (and its source below) is not.
      assert Enum.all?(run.results, &(&1.output =~ "value == 6"))
    end

    test "a mutant covered only via setup_all is attributed to its own file (not the whole suite)" do
      %{project: project, sandbox: sandbox} =
        Project.build(:setup_all_only_cov, %{
          "lib/shared.ex" => "defmodule Shared do\n  def calc(x), do: x + 1\nend\n",
          # The mutated line runs only through this module's `setup_all`. The
          # `__ex_unit__/2` stacktrace recovery attributes it to setup_all_test.exs,
          # so selection runs *only* this file — not the whole suite — and its own
          # test (which asserts the setup_all value) still kills the mutant.
          "test/setup_all_test.exs" => """
          defmodule SetupAllOnlyTest do
            use ExUnit.Case
            setup_all do
              %{value: Shared.calc(5)}
            end
            test "asserts the exact value", %{value: value} do
              assert value == 6
            end
          end
          """,
          # An unrelated file that never touches the line. Before the recovery the id
          # was unlabeled → whole suite, so this file would have run too (2 tests).
          "test/idle_test.exs" => """
          defmodule IdleTest do
            use ExUnit.Case
            test "unrelated", do: assert(true)
          end
          """
        })

      assert {:ok, run} = Mutare.run(project, sandbox: sandbox, mutators: @probe)

      assert run.results != []
      assert Enum.all?(run.results, &(&1.status == :killed))
      # Tight selection: only setup_all_test.exs runs (1 test), not the idle file.
      assert Enum.all?(run.results, &(tests_run(&1.output) == 1))
    end

    test "a mutant covered only via a spawned Task is attributed to the spawning test's file" do
      %{project: project, sandbox: sandbox} =
        Project.build(:task_cov, %{
          "lib/worker.ex" => "defmodule Worker do\n  def work(x), do: x + 1\nend\n",
          # The line runs only inside a Task spawned by this test. Option 2 recovers
          # the test label via the Task's `$callers` chain, so the id is attributed
          # to worker_test.exs and selection stays tight (1 test, not whole suite).
          "test/worker_test.exs" => """
          defmodule WorkerTest do
            use ExUnit.Case
            test "work via a spawned task" do
              task = Task.async(fn -> Worker.work(5) end)
              assert Task.await(task) == 6
            end
          end
          """,
          "test/idle_test.exs" => """
          defmodule IdleTest do
            use ExUnit.Case
            test "unrelated", do: assert(true)
          end
          """
        })

      assert {:ok, run} = Mutare.run(project, sandbox: sandbox, mutators: @probe)

      assert run.results != []
      assert Enum.all?(run.results, &(&1.status == :killed))
      # Attributed to worker_test.exs (via the Task caller chain), so only that file
      # runs — not the whole suite.
      assert Enum.all?(run.results, &(tests_run(&1.output) == 1))
    end

    test "a late hit after a caller-attributing process exits forces whole-suite selection" do
      %{project: project, sandbox: sandbox} =
        Project.build(:late_dead_caller_cov, %{
          "lib/shared.ex" => "defmodule Shared do\n  def calc(x), do: x + 1\nend\n",
          "test/spawner_test.exs" => """
          defmodule SpawnerTest do
            use ExUnit.Case, async: true

            test "covers through a long-lived caller-attributed worker" do
              parent = self()

              holder =
                spawn(fn ->
                  Process.set_label({__MODULE__, :spawning_test})
                  send(parent, :holder_ready)

                  receive do
                    :stop -> :ok
                  end
                end)

              assert_receive :holder_ready
              holder_ref = Process.monitor(holder)

              worker =
                spawn(fn ->
                  Process.put(:"$callers", [holder])
                  Shared.calc(5)
                  send(parent, :first_done)

                  receive do
                    :late -> :ok
                  end

                  :persistent_term.put(:late_dead_caller_value, Shared.calc(5))
                  send(parent, :late_done)
                end)

              assert_receive :first_done
              send(holder, :stop)
              assert_receive {:DOWN, ^holder_ref, :process, ^holder, _}

              send(worker, :late)
              assert_receive :late_done
            end
          end
          """,
          "test/killer_test.exs" => """
          defmodule KillerTest do
            use ExUnit.Case, async: true

            test "kills through the late side effect without covering the source line" do
              assert wait_value(200) == 6
            end

            defp wait_value(0), do: flunk("late worker did not publish")

            defp wait_value(attempts) do
              case :persistent_term.get(:late_dead_caller_value, :missing) do
                :missing ->
                  Process.sleep(10)
                  wait_value(attempts - 1)

                value ->
                  value
              end
            end
          end
          """
        })

      assert {:ok, run} =
               Mutare.run(project, sandbox: sandbox, mutators: [Mutare.Mutators.Arithmetic])

      assert [%{status: :killed, output: output}] = run.results
      # Whole-suite selection ran both files (the kill aborts at `--max-failures 1`, so the
      # summary counts one failure among the two).
      assert tests_run(output) == 2
    end

    test "a probe-only flake is retried, preserving coverage selection" do
      # The baseline is green, but the first probe attempt hits a flake (simulated with a
      # marker file: fail once under MUTARE_COVERAGE, pass ever after). Without the retry
      # this degrades to run-all — under which `uncovered/0`'s mutant would run the whole
      # suite and *survive*; with the retry the probe succeeds and classifies it
      # `:no_coverage`, proving selection quality survived the flake.
      %{project: project, sandbox: sandbox} =
        Project.build(:probe_retry, %{
          "lib/probe_retry.ex" => """
          defmodule ProbeRetry do
            def covered, do: 1 + 1
            def uncovered, do: 3 + 4
          end
          """,
          "test/probe_retry_test.exs" => """
          defmodule ProbeRetryTest do
            use ExUnit.Case

            test "covers only covered/0, flaking on the first probe attempt" do
              if System.get_env("MUTARE_COVERAGE") && !File.exists?("probe_retry_marker") do
                File.write!("probe_retry_marker", "")
                flunk("first probe attempt")
              end

              assert ProbeRetry.covered() == 2
            end
          end
          """
        })

      assert {:ok, run} =
               Mutare.run(project, sandbox: sandbox, mutators: [Mutare.Mutators.Arithmetic])

      by_status = Enum.group_by(run.results, & &1.status)
      assert [%{site: killed_site}] = by_status[:killed]
      assert [%{site: skipped_site}] = by_status[:no_coverage]
      assert killed_site.line != skipped_site.line
      refute Map.has_key?(by_status, :survived)
    end

    test "a non-zero coverage probe falls back to running every mutant" do
      %{project: project, sandbox: sandbox} =
        Project.build(:probe_failure, %{
          "lib/probe_failure.ex" => """
          defmodule ProbeFailure do
            def first, do: 1 + 1
            def second, do: 3 + 4
          end
          """,
          "test/test_helper.exs" => "ExUnit.start(seed: 0, max_failures: 1)\n",
          "test/probe_failure_test.exs" => """
          defmodule ProbeFailureTest do
            use ExUnit.Case

            test "first then probe-only failure" do
              assert ProbeFailure.first() == 2

              if System.get_env("MUTARE_COVERAGE") do
                flunk("probe-only failure")
              end
            end

            test "second" do
              assert ProbeFailure.second() == 7
            end
          end
          """
        })

      assert {:ok, run} =
               Mutare.run(project, sandbox: sandbox, mutators: [Mutare.Mutators.Arithmetic])

      assert length(run.results) == 2
      assert Enum.all?(run.results, &(&1.status == :killed))
      refute Enum.any?(run.results, &(&1.status == :no_coverage))
    end

    test "a green probe with a missing capture table falls back to running every mutant" do
      %{project: project, sandbox: sandbox} =
        Project.build(:missing_capture, %{
          "lib/calc.ex" => "defmodule Calc do\n  def add(x), do: x + 1\nend\n",
          "test/test_helper.exs" => """
          ExUnit.start()
          if System.get_env("MUTARE_COVERAGE"), do: :ets.delete(:mutare_cov_agg)
          """,
          "test/calc_test.exs" => """
          defmodule CalcTest do
            use ExUnit.Case
            test "add", do: assert(Calc.add(2) == 3)
          end
          """
        })

      assert capture_log(fn ->
               assert {:ok, run} =
                        Mutare.run(project,
                          sandbox: sandbox,
                          mutators: [Mutare.Mutators.Arithmetic]
                        )

               assert [%Result{status: :killed}] = run.results
             end) =~ "missing_coverage_table"
    end
  end
end
