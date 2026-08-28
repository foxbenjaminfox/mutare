defmodule Mutare.RunnerTest do
  @moduledoc """
  End-to-end runner coverage: generate a tiny project, run mutation testing
  against it with real `mix test` subprocesses, and prove the whole loop:
  compile once, kill/survive classification, and a survivor diff.
  """
  use ExUnit.Case, async: false

  alias Mutare.{Report, Result, Run}
  alias Mutare.Test.Project

  # Pin to the operator-swap families: this fixture is built around a precise
  # 3-mutant scenario (the missing boundary test), so the higher-volume default
  # mutators are excluded to keep the counts and score deterministic.
  @probe [Mutare.Mutators.Arithmetic, Mutare.Mutators.Relational]

  @moduletag :runner
  # Several `mix` subprocesses (compile + baseline + one per mutant).
  @moduletag timeout: 180_000

  setup do
    Project.build(:calc, %{
      "lib/calc.ex" => """
      defmodule Calc do
        def add(a, b), do: a + b
        def gte?(a, b), do: a >= b
      end
      """,
      "test/calc_test.exs" => """
      defmodule CalcTest do
        use ExUnit.Case

        test "add sums its arguments" do
          assert Calc.add(2, 3) == 5
        end

        # Note: only tests well above the threshold — no boundary case.
        test "gte? is true well above the threshold" do
          assert Calc.gte?(10, 5) == true
        end
      end
      """
    })
  end

  test "classifies mutants and finds the missing boundary test", %{
    project: project,
    sandbox: sandbox
  } do
    assert {:ok, run} = Mutare.run(project, sandbox: sandbox, mutators: @probe)

    assert %Run{} = run
    assert length(run.results) == 3
    assert Enum.count(run.results, &(&1.status == :killed)) == 2
    assert [survivor] = Enum.filter(run.results, &(&1.status == :survived))

    # The boundary test is missing for gte?/2, so `>= -> >` slips through.
    assert %Result{site: %{mutator: :relational, original_form: :>=, mutated_form: :>, line: 3}} =
             survivor

    refute File.exists?(Path.join(sandbox, ".mutare_sandbox.lock"))
  end

  test "renders the survivor as a one-line diff with a score", %{
    project: project,
    sandbox: sandbox
  } do
    assert {:ok, run} = Mutare.run(project, sandbox: sandbox, mutators: @probe)

    report = Report.render(run.results, run.schema.sources)

    assert report =~ "lib/calc.ex:3  [relational, in-place]  SURVIVED"
    assert report =~ "-  def gte?(a, b), do: a >= b"
    assert report =~ "+  def gte?(a, b), do: a > b"
    assert report =~ "mutation score: 66.7%  (2 killed, 1 survived, 3 total)"
  end

  test "compiles once: no per-mutant recompilation", %{project: project, sandbox: sandbox} do
    assert {:ok, run} = Mutare.run(project, sandbox: sandbox, mutators: @probe)

    # If the one-compile invariant holds, no mutant run rebuilds anything.
    for %Result{output: output} <- run.results do
      refute output =~ "Compiling", "a mutant run recompiled:\n#{output}"
    end
  end

  test "kill_runs demotes a one-off flaky kill to survived" do
    %{project: project, sandbox: sandbox} =
      Project.build(:kill_runs, %{
        "lib/flaky_kill.ex" => """
        defmodule FlakyKill do
          def add(a, b), do: a + b
        end
        """,
        "test/flaky_kill_test.exs" => """
        defmodule FlakyKillTest do
          use ExUnit.Case

          test "touches the mutant line but flakes only once per active mutant" do
            _ = FlakyKill.add(2, 3)

            active = System.get_env("MUTARE_ACTIVE_MUTANT")

            if active not in [nil, "0"] do
              counter = "kill_counter_\#{active}.txt"

              runs =
                case File.read(counter) do
                  {:ok, n} -> String.to_integer(n)
                  _ -> 0
                end

              File.write!(counter, Integer.to_string(runs + 1))
              assert runs >= 1
            end
          end
        end
        """
      })

    assert {:ok, run} =
             Mutare.run(project,
               sandbox: sandbox,
               mutators: [Mutare.Mutators.Arithmetic],
               kill_runs: 2
             )

    assert [%Result{status: :survived, duration_ms: ms}] = run.results
    assert ms > 0
  end

  test "removes the default throwaway sandbox when the run completes", %{project: project} do
    # No `--sandbox` and no `--keep-sandbox`: the runner materialises a throwaway
    # sandbox under the temp dir and removes it on completion, so default runs
    # don't accumulate stale dirs there.
    assert {:ok, run} = Mutare.run(project, mutators: @probe)
    on_exit(fn -> File.rm_rf(run.sandbox) end)

    refute File.exists?(run.sandbox)
  end

  test "keep_sandbox reuses the sandbox and its build across runs", %{
    project: project,
    sandbox: sandbox
  } do
    assert {:ok, first} =
             Mutare.run(project, sandbox: sandbox, mutators: @probe, keep_sandbox: true)

    assert Enum.count(first.results, &(&1.status == :killed)) == 2

    # The first run compiled the metamutant in place; that build must survive.
    build = Path.join(sandbox, "_build")
    assert File.dir?(build)
    [marker | _] = Path.wildcard(Path.join(build, "**/*.beam"))
    assert File.exists?(marker), "expected compiled .beam artifacts after the first run"

    # A second kept run against the unchanged source is still correct, and the
    # earlier build artifact is still present (it was reused, not wiped).
    assert {:ok, second} =
             Mutare.run(project, sandbox: sandbox, mutators: @probe, keep_sandbox: true)

    assert Enum.count(second.results, &(&1.status == :killed)) == 2
    assert [_] = Enum.filter(second.results, &(&1.status == :survived))
    assert File.exists?(marker)
  end

  describe "--max-survivors / --time-budget (early stop)" do
    setup do
      # Two weakly-tested comparisons (each tested only well clear of its
      # boundary), so `>=`→`>` and `<=`→`<` both slip through: two survivors, in
      # source order, with a fully-tested `add` last so killed sites remain after
      # the first survivor.
      Project.build(:calc_survivors, %{
        "lib/calc.ex" => """
        defmodule Calc do
          def gte?(a, b), do: a >= b
          def lte?(a, b), do: a <= b
          def add(a, b), do: a + b
        end
        """,
        "test/calc_test.exs" => """
        defmodule CalcTest do
          use ExUnit.Case

          test "gte? is true well above the threshold" do
            assert Calc.gte?(10, 5) == true
          end

          test "lte? is true well below the threshold" do
            assert Calc.lte?(5, 10) == true
          end

          test "add sums its arguments" do
            assert Calc.add(2, 3) == 5
          end
        end
        """
      })
    end

    test "without a cap, the fixture yields more than one survivor", %{
      project: project,
      sandbox: sandbox
    } do
      assert {:ok, run} = Mutare.run(project, sandbox: sandbox, mutators: @probe)

      assert run.stopped_early == false
      assert Enum.count(run.results, &(&1.status == :survived)) >= 2
    end

    test "stops once the survivor cap is reached, over a partial set", %{
      project: project,
      sandbox: sandbox
    } do
      assert {:ok, run} =
               Mutare.run(project, sandbox: sandbox, mutators: @probe, max_survivors: 1)

      assert run.stopped_early == true
      # Exactly the cap: the first survivor in source order triggers the stop.
      assert Enum.count(run.results, &(&1.status == :survived)) == 1
      # The run halted before testing every mutant, so the score is over a prefix.
      assert length(run.results) < Mutare.Schema.count(run.schema)
    end

    test "stops once the wall-clock budget elapses, over a partial set" do
      # A dedicated fixture whose first mutant run sleeps well past the budget, so
      # the elapsed time does not depend on how fast `mix test` starts up. With one
      # worker, the next mutant cannot launch until the current `mix test`
      # subprocess finishes; by then the 1s budget has elapsed, so the remaining
      # sites skip instead of running.
      %{project: project, sandbox: sandbox} =
        Project.build(:budget_elapsed_partial, %{
          "lib/budget_elapsed_partial.ex" => """
          defmodule BudgetElapsedPartial do
            def a(x, y), do: x + y
            def b(x, y), do: x + y
            def c(x, y), do: x + y
            def d(x, y), do: x + y
          end
          """,
          "test/budget_elapsed_partial_test.exs" => """
          defmodule BudgetElapsedPartialTest do
            use ExUnit.Case

            test "covers every arithmetic site" do
              if System.get_env("MUTARE_ACTIVE_MUTANT", "0") != "0" do
                Process.sleep(2_000)
              end

              assert BudgetElapsedPartial.a(2, 2) == 4
              assert BudgetElapsedPartial.b(2, 2) == 4
              assert BudgetElapsedPartial.c(2, 2) == 4
              assert BudgetElapsedPartial.d(2, 2) == 4
            end
          end
          """
        })

      assert {:ok, run} =
               Mutare.run(project,
                 sandbox: sandbox,
                 mutators: @probe,
                 workers: 1,
                 time_budget: "1s"
               )

      assert run.stopped_early == true
      assert length(run.results) < Mutare.Schema.count(run.schema)
    end

    test "does not launch additional real mutant runs after the budget elapses under ordered streaming" do
      %{project: project, sandbox: sandbox} =
        Project.build(:budget_launch_gate, %{
          "lib/budget_launch_gate.ex" => """
          defmodule BudgetLaunchGate do
            def slow(a, b), do: a + b
            def one(a, b), do: a + b
            def two(a, b), do: a + b
            def three(a, b), do: a + b
            def four(a, b), do: a + b
            def five(a, b), do: a + b
            def six(a, b), do: a + b
            def seven(a, b), do: a + b
          end
          """,
          "test/budget_launch_gate_test.exs" => """
          defmodule BudgetLaunchGateTest do
            use ExUnit.Case

            test "all arithmetic sites are covered" do
              case System.get_env("MUTARE_ACTIVE_MUTANT", "0") do
                "0" -> :ok
                "1" -> Process.sleep(3_000)
                _ -> Process.sleep(700)
              end

              assert BudgetLaunchGate.slow(2, 2) == 4
              assert BudgetLaunchGate.one(2, 2) == 4
              assert BudgetLaunchGate.two(2, 2) == 4
              assert BudgetLaunchGate.three(2, 2) == 4
              assert BudgetLaunchGate.four(2, 2) == 4
              assert BudgetLaunchGate.five(2, 2) == 4
              assert BudgetLaunchGate.six(2, 2) == 4
              assert BudgetLaunchGate.seven(2, 2) == 4
            end
          end
          """
        })

      {:ok, starts} = Agent.start_link(fn -> [] end)

      on_start = fn site ->
        Agent.update(starts, fn ids -> [site.id | ids] end)
      end

      assert {:ok, run} =
               Mutare.run(project,
                 sandbox: sandbox,
                 mutators: [Mutare.Mutators.Arithmetic],
                 workers: 2,
                 time_budget: "1s",
                 on_start: on_start
               )

      started = Agent.get(starts, fn ids -> Enum.reverse(ids) end)

      assert run.stopped_early == true
      assert Mutare.Schema.count(run.schema) >= 8
      assert length(started) <= 3
      assert Enum.max(started) <= 3
    end

    test "does not confirm provisional timeouts after the budget elapses" do
      marker = Project.tmp_dir(:budget_timeout_marker)
      on_exit(fn -> File.rm_rf!(marker) end)

      %{project: project, sandbox: sandbox} =
        Project.build(:budget_timeout_confirmation, %{
          "lib/budget_timeout_confirmation.ex" => """
          defmodule BudgetTimeoutConfirmation do
            def add(a, b), do: a + b
          end
          """,
          "test/budget_timeout_confirmation_test.exs" => """
          defmodule BudgetTimeoutConfirmationTest do
            use ExUnit.Case

            test "first mutant run exceeds the cap" do
              if System.get_env("MUTARE_ACTIVE_MUTANT", "0") != "0" and
                   not File.exists?(#{inspect(marker)}) do
                File.write!(#{inspect(marker)}, "started")
                Process.sleep(5_000)
              end

              assert BudgetTimeoutConfirmation.add(2, 2) == 4
            end
          end
          """
        })

      {:ok, starts} = Agent.start_link(fn -> 0 end)

      on_start = fn _site ->
        Agent.update(starts, &(&1 + 1))
      end

      assert {:ok, run} =
               Mutare.run(project,
                 sandbox: sandbox,
                 mutators: [Mutare.Mutators.Arithmetic],
                 workers: 1,
                 timeout: 2_000,
                 time_budget: "1s",
                 on_start: on_start
               )

      assert Agent.get(starts, & &1) == 1
      assert [%Result{status: :timeout}] = run.results
      assert run.stopped_early == true
    end

    test "does not mark a budgeted run partial when every mutant was evaluated" do
      %{project: project, sandbox: sandbox} =
        Project.build(:budget_complete, %{
          "lib/budget_complete.ex" => """
          defmodule BudgetComplete do
            def add(a, b), do: a + b
          end
          """,
          "test/budget_complete_test.exs" => """
          defmodule BudgetCompleteTest do
            use ExUnit.Case

            test "the only mutant run is slow but finite" do
              if System.get_env("MUTARE_ACTIVE_MUTANT", "0") != "0" do
                Process.sleep(1_300)
              end

              assert BudgetComplete.add(2, 2) == 4
            end
          end
          """
        })

      assert {:ok, run} =
               Mutare.run(project,
                 sandbox: sandbox,
                 mutators: [Mutare.Mutators.Arithmetic],
                 workers: 1,
                 timeout: 5_000,
                 time_budget: "1s"
               )

      assert Mutare.Schema.count(run.schema) == 1
      assert length(run.results) == 1
      assert run.stopped_early == false
    end

    test "never reports a result the survivor cap discarded" do
      # Mutant 1 (`a`) is slow *and* unasserted, so it survives — and while it sleeps the
      # second lane runs the fast mutants behind it to completion, parking their results in
      # the ordered stream's buffer. When mutant 1 finally lands it trips `--max-survivors 1`
      # and those buffered stragglers are discarded, so a reporter fed from the worker would
      # have already emitted live/verbose lines for mutants absent from `run.results`.
      %{project: project, sandbox: sandbox} =
        Project.build(:straggler_report, %{
          "lib/straggler_report.ex" => """
          defmodule StragglerReport do
            def a(x, y), do: x + y
            def b(x, y), do: x + y
            def c(x, y), do: x + y
            def d(x, y), do: x + y
          end
          """,
          "test/straggler_report_test.exs" => """
          defmodule StragglerReportTest do
            use ExUnit.Case

            test "covers every arithmetic site" do
              if System.get_env("MUTARE_ACTIVE_MUTANT", "0") == "1" do
                Process.sleep(2_000)
              end

              # Covered but unasserted: mutant 1 survives.
              StragglerReport.a(2, 2)
              assert StragglerReport.b(2, 2) == 4
              assert StragglerReport.c(2, 2) == 4
              assert StragglerReport.d(2, 2) == 4
            end
          end
          """
        })

      {:ok, seen} = Agent.start_link(fn -> %{started: 0, reported: []} end)

      on_start = fn _site -> Agent.update(seen, &%{&1 | started: &1.started + 1}) end

      reporter = fn %Result{site: site} ->
        Agent.update(seen, &%{&1 | reported: [site.id | &1.reported]})
      end

      assert {:ok, run} =
               Mutare.run(project,
                 sandbox: sandbox,
                 mutators: [Mutare.Mutators.Arithmetic],
                 workers: 2,
                 timeout: 15_000,
                 max_survivors: 1,
                 on_start: on_start,
                 reporter: reporter
               )

      %{started: started, reported: reported} = Agent.get(seen, & &1)

      assert run.stopped_early == true
      assert [%Result{status: :survived, site: %{id: 1}}] = run.results

      # The second lane launched alongside mutant 1, so at least one run past the cap really
      # was drained and discarded — without that the assertion below is vacuous.
      assert started > length(run.results)

      assert Enum.sort(reported) == [1],
             "reported #{inspect(Enum.sort(reported))} but kept #{inspect(Enum.map(run.results, & &1.site.id))}"
    end
  end
end
