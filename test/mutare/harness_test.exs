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

    # The forced `--exit-status` is what makes this a `:failed` (kill) rather than
    # an ambiguous non-zero exit indistinguishable from infrastructure failure.
    assert %Result{outcome: :failed, exit_status: status} = Command.timed_test(project, [], 0)
    assert status == Command.failure_exit()
  end

  test "a suite that can't compile is a harness error, NOT a kill" do
    %{project: project} =
      Project.build(:harness_broken, %{
        # Syntax error: never compiles, so `mix test` exits 1 before any verdict.
        "lib/m.ex" => "defmodule M do\n  def add(a, b), do: a +\nend\n",
        "test/m_test.exs" => """
        defmodule MTest do
          use ExUnit.Case
          test "unreachable", do: assert M.add(1, 2) == 3
        end
        """
      })

    assert %Result{outcome: :harness_error, exit_status: status} =
             Command.timed_test(project, [], 0)

    # Whatever mix exits with, it is neither success nor a clean test failure, so
    # it is never charged as a kill.
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
      assert [%{status: :harness_error}] = run.results

      # Excluded from the denominator: nothing was actually measured (100% over 0).
      assert Report.summary(run.results) =~ "1 harness-error"
      assert Report.score(run.results) == 100.0

      # Retried once, but recorded — and warned — exactly once.
      assert log |> String.split("failed at the harness level") |> length() == 2
    end
  end
end
