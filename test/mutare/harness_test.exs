defmodule Mutare.HarnessTest do
  @moduledoc """
  Infrastructure failures must not count as killed mutants.

  `Mutare.Sandbox.Command.timed_test/4` runs a real `mix test` and decodes its
  exit code against the contract `Mutare.Sandbox.Command` owns. The first tests
  pin the three outcomes that share the "non-zero exit" space against actual
  `mix` subprocesses: a passing suite (survived), a *failing* suite (a clean
  kill, via the forced `--exit-status`), and a suite that can't even compile (a
  harness error — explicitly **not** a kill, which the old "non-zero ⇒ killed"
  rule got wrong).

  Each first-block test compiles its project up front (`Project.compile/1`) before
  calling `timed_test/4`, mirroring production: `Mutare.Runner` compiles the sandbox
  **once**, and every per-mutant `mix test` then runs with `--no-compile` (the sources
  never change between runs). Driving `timed_test/4` against an *uncompiled* project
  would just measure a missing-`.app` boot failure, not the exit-code contract.

  The `through the runner` tests then drive a harness error through the *whole*
  `Mutare.run/2` pipeline. A post-baseline harness error can't be produced by a
  broken sandbox (that fails the baseline first), so a target test simulates one
  deterministically: it reads the public `:mutare_active` selection key and
  `System.halt`s with an off-contract code for exactly one mutant — baseline
  (id 0) stays green. That exercises the runner's harness path end to end: the
  per-mutant warning, and the abort guard (`:max_harness_error_rate`).
  """
  use ExUnit.Case, async: false

  import ExUnit.CaptureLog

  alias Mutare.Report
  alias Mutare.Sandbox.Command
  alias Mutare.Sandbox.Command.Result
  alias Mutare.Test.Project

  @moduletag :runner
  @moduletag timeout: 180_000

  test "a passing suite is a pass (the mutation would survive)" do
    %{project: project} =
      Project.build(:harness_pass, %{
        "lib/m.ex" => "defmodule M do\n  def add(a, b), do: a + b\nend\n",
        "test/m_test.exs" => """
        defmodule MTest do
          use ExUnit.Case
          test "adds", do: assert M.add(1, 2) == 3
        end
        """
      })

    # Production compiles the sandbox once, then per-mutant runs go `--no-compile`.
    assert {_out, 0} = Project.compile(project)

    assert %Result{outcome: :passed, exit_status: 0, duration_ms: ms} =
             Command.timed_test(project, [], 0)

    assert is_integer(ms) and ms >= 0
  end

  test "a failing suite is a clean kill, not a harness error" do
    %{project: project} =
      Project.build(:harness_fail, %{
        "lib/m.ex" => "defmodule M do\n  def add(a, b), do: a + b\nend\n",
        "test/m_test.exs" => """
        defmodule MTest do
          use ExUnit.Case
          test "wrong on purpose", do: assert M.add(1, 2) == 99
        end
        """
      })

    assert {_out, 0} = Project.compile(project)

    # The forced `--exit-status` is what makes this a `:failed` (kill) rather than
    # an ambiguous non-zero exit indistinguishable from infrastructure failure.
    assert %Result{outcome: :failed, exit_status: status} = Command.timed_test(project, [], 0)
    assert status == Command.failure_exit()
  end

  test "a lib that can't compile is a harness error, NOT a kill" do
    %{project: project} =
      Project.build(:harness_broken, %{
        # Syntax error: the lib never compiles.
        "lib/m.ex" => "defmodule M do\n  def add(a, b), do: a +\nend\n",
        "test/m_test.exs" => """
        defmodule MTest do
          use ExUnit.Case
          test "unreachable", do: assert M.add(1, 2) == 3
        end
        """
      })

    # In production a non-compiling lib is caught at the one-compile step (poison
    # recovery), never reaching per-mutant runs — so the compile genuinely fails here.
    assert {_out, status} = Project.compile(project)
    refute status == 0

    # And the per-mutant path itself fails safe: with no `.app`/beams the `--no-compile`
    # run can't start the app, exits non-zero, and is read as a harness error — never a
    # clean test failure, so never charged as a kill.
    assert %Result{outcome: :harness_error, exit_status: status} =
             Command.timed_test(project, [], 0)

    refute status in [0, Command.failure_exit()]
  end

  test "a test SUITE that can't compile is a kill, not a harness error" do
    # The lib is fine; the *test script* fails to compile. In a real run that is
    # a mutation breaking code that runs at the test modules' compile time (a
    # `Plug.Router` route macro calling a mutated helper, say) — the suite can't
    # build with the mutant, so it was detected: a kill. `outcome/2` tells this
    # apart from the lib/infra compile error above via the test-script banner.
    %{project: project} =
      Project.build(:harness_test_compile, %{
        "lib/m.ex" => "defmodule M do\n  def add(a, b), do: a + b\nend\n",
        # Syntax error in the test script ⇒ exit 1 with a test-file compile banner.
        "test/m_test.exs" => "defmodule MTest do\n  use ExUnit.Case\n  def broken(, do: :x\nend\n"
      })

    # The lib is valid, so the up-front compile succeeds; the `.exs` test script is only
    # evaluated at `mix test` time, where `--no-compile` still re-reads it and trips the
    # test-file compile banner that `outcome/2` reads as a kill.
    assert {_out, 0} = Project.compile(project)

    assert %Result{outcome: :suite_compile_error, exit_status: status} =
             Command.timed_test(project, [], 0)

    # Still exit 1 (a compile error), but the output refinement makes it a kill,
    # not the infra `:harness_error` a bare exit-code read would give.
    refute status in [0, Command.failure_exit()]
  end

  describe "through the runner" do
    # Pinned to `:arithmetic` so `def f(a, b), do: a + b` yields exactly one mutant
    # (`+`→`-`, id 1) — the default set would also add a return-value mutant
    # (`a + b → 0`), which these tests (about the harness-error mechanism, not the
    # mutator set) don't want. The test halts with 99 (off-contract: not 0/pass, not
    # the failure or timeout codes) only when that mutant is active, so the baseline
    # (id 0) stays green and the one mutant always lands as a harness error.
    @arithmetic_only [mutators: [Mutare.Mutators.Arithmetic]]

    defp halting_project(tag) do
      Project.build(tag, %{
        "lib/h.ex" => "defmodule H do\n  def f(a, b), do: a + b\nend\n",
        "test/h_test.exs" => """
        defmodule HTest do
          use ExUnit.Case

          test "f" do
            # Simulate a harness-level failure for this one mutant only.
            if :persistent_term.get(:mutare_active, 0) == 1, do: System.halt(99)
            assert H.f(1, 2) == 3
          end
        end
        """
      })
    end

    test "a persistent harness error is warned and (over the threshold) aborts the run" do
      %{project: project, sandbox: sandbox} = halting_project(:harness_runner_abort)

      {result, log} =
        with_log(fn ->
          # No retry (the failure is deterministic, not transient) keeps it quick.
          Mutare.run(project, [sandbox: sandbox, harness_retries: 0] ++ @arithmetic_only)
        end)

      # The lone mutant harness-errors → 100% of the mutants that ran → abort,
      # rather than report a score over an empty denominator.
      assert {:error, :too_many_harness_errors, detail} = result
      assert detail =~ "harness level"
      assert detail =~ "--max-harness-error-rate"
      assert detail =~ "Examples:"
      assert detail =~ "mutant 1 — exit 99; no output captured"

      # ...and it was surfaced loudly per-mutant, not just tallied.
      assert log =~ "mutant 1 failed at the harness level (exit 99)"
    end

    test "a harness error is kept out of the score, and retries warn only once" do
      %{project: project, sandbox: sandbox} = halting_project(:harness_runner_keep)

      {result, log} =
        with_log(fn ->
          # Disable the abort to inspect the recorded result; one retry exercises
          # the retry path (the halt repeats, so it stays a harness error).
          Mutare.run(
            project,
            [sandbox: sandbox, harness_retries: 1, max_harness_error_rate: nil] ++
              @arithmetic_only
          )
        end)

      assert {:ok, run} = result
      assert [%{status: :harness_error, exit_status: 99, output: output}] = run.results
      assert is_binary(output)

      # Excluded from the denominator: nothing was actually measured (100% over 0).
      assert Report.summary(run.results) =~ "1 harness-error"
      assert Report.score(run.results) == 100.0

      # Retried once, but recorded — and warned — exactly once.
      assert log |> String.split("failed at the harness level") |> length() == 2
    end

    # A node that dies during boot with its diagnostic self-erased (the
    # `:standard_error` recursion) is a *named* harness error: still out of the
    # score, but recognised so the runner gives a specific, actionable warning
    # instead of pointing at output that can't help. Simulated by emitting the
    # boot-crash banner to stderr (merged into the captured output) and halting
    # off-contract for the one mutant, leaving the baseline (id 0) green.
    defp boot_crashing_project(tag) do
      Project.build(tag, %{
        "lib/h.ex" => "defmodule H do\n  def f(a, b), do: a + b\nend\n",
        "test/h_test.exs" => """
        defmodule HTest do
          use ExUnit.Case

          test "f" do
            if :persistent_term.get(:mutare_active, 0) == 1 do
              IO.puts(:stderr, "Runtime terminating during boot " <>
                "({badarg,[{io,put_chars,[standard_error,...]}]})")
              System.halt(158)
            end

            assert H.f(1, 2) == 3
          end
        end
        """
      })
    end

    test "a self-erasing boot crash is named, retried harder, and warned specifically" do
      %{project: project, sandbox: sandbox} = boot_crashing_project(:harness_runner_boot)

      {result, log} =
        with_log(fn ->
          # `harness_retries: 0` proves the boot-failure budget is *independent* — the
          # mutant still retries (and so survives a single transient) off its own pool.
          Mutare.run(
            project,
            [sandbox: sandbox, harness_retries: 0, max_harness_error_rate: nil] ++
              @arithmetic_only
          )
        end)

      assert {:ok, run} = result
      # The verdict is unchanged — a harness error kept out of the score.
      assert [%{status: :harness_error}] = run.results
      assert Report.score(run.results) == 100.0

      # ...but the warning is the *specific* one: it names the cause and the levers,
      # and does not send the user to output that can't help.
      assert log =~ "died during boot"
      assert log =~ "--partition-db"
      refute log =~ "see the mutant's output to diagnose the sandbox"

      # Warned exactly once (at recording), not per retry attempt.
      assert log |> String.split("died during boot") |> length() == 2
    end

    # An OS SIGKILL (exit 137 = 128 + 9) — the kernel OOM killer's signature. The
    # fixture *counts* each attempt into a file before dying, so the test can prove
    # the mutant ran exactly once: retrying a deterministic memory detonation
    # re-detonates it on the host, so `:sigkilled` must ignore the retry budget.
    defp sigkilled_project(tag) do
      Project.build(tag, %{
        "lib/h.ex" => "defmodule H do\n  def f(a, b), do: a + b\nend\n",
        "test/h_test.exs" => """
        defmodule HTest do
          use ExUnit.Case

          test "f" do
            if :persistent_term.get(:mutare_active, 0) == 1 do
              # Count this attempt (cwd is the sandbox root), then die as the
              # OOM killer's victim would.
              File.write!("sigkill_attempts.log", ".", [:append])
              System.halt(137)
            end

            assert H.f(1, 2) == 3
          end
        end
        """
      })
    end

    test "an OS SIGKILL (exit 137) is never retried, and warned as likely OOM" do
      %{project: project, sandbox: sandbox} = sigkilled_project(:harness_runner_sigkill)

      {result, log} =
        with_log(fn ->
          # A generous general budget proves `:sigkilled` ignores it entirely —
          # unlike a plain harness error, which would burn all three retries here.
          Mutare.run(
            project,
            [sandbox: sandbox, harness_retries: 3, max_harness_error_rate: nil] ++
              @arithmetic_only
          )
        end)

      assert {:ok, run} = result
      # The verdict is unchanged — a harness error kept out of the score.
      assert [%{status: :harness_error}] = run.results
      assert Report.score(run.results) == 100.0

      # The load-bearing assertion: exactly one attempt, despite harness_retries: 3.
      assert File.read!(Path.join(sandbox, "sigkill_attempts.log")) == "."

      # ...and the warning is the *specific* one: it names the likely cause and
      # the mitigation, and does not send the user to truncated output.
      assert log =~ "SIGKILL"
      assert log =~ "OOM killer"
      assert log =~ "--max-heap-mb"
      refute log =~ "see the mutant's output to diagnose the sandbox"
    end
  end
end
