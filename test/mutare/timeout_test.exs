defmodule Mutare.TimeoutTest do
  @moduledoc """
  A mutation can turn a terminating loop infinite. The per-mutant wall-clock cap
  catches it — and does so portably: the mutant run halts itself (no external
  process-killing).
  """
  use ExUnit.Case, async: false

  alias Mutare.Result
  alias Mutare.Test.Project

  @moduletag :runner
  @moduletag timeout: 180_000

  test "an infinite-loop mutation is capped and counts as a timeout (a kill)" do
    %{project: project, sandbox: sandbox} =
      Project.build(:loop, %{
        "lib/loop.ex" => """
        defmodule Loop do
          def count_down(0), do: :done
          def count_down(n), do: count_down(n - 1)
        end
        """,
        "test/loop_test.exs" => """
        defmodule LoopTest do
          use ExUnit.Case
          test "counts down to done", do: assert(Loop.count_down(5) == :done)
        end
        """
      })

    # Small explicit cap so the hang is caught quickly. Pin to the arithmetic
    # family so the run is the one `n - 1 → n + 1` site this test is about (the
    # default literal mutator would add more infinite-loop mutants to wait on).
    assert {:ok, run} =
             Mutare.run(project,
               sandbox: sandbox,
               timeout: 2_000,
               mutators: [Mutare.Mutators.Arithmetic]
             )

    # `count_down(n - 1)` mutated to `n + 1` never reaches 0 → infinite recursion.
    hang =
      Enum.find(run.results, fn %Result{site: s} ->
        s.mutator == :arithmetic and s.original_form == :- and s.mutated_form == :+
      end)

    assert hang.status == :timeout
    # It ran roughly up to the cap, then self-halted (not a fast test failure).
    assert hang.duration_ms >= 1_500

    # A timeout is a kill: it isn't a survivor.
    refute Enum.any?(run.results, &(&1.status == :survived and &1.site.original_form == :-))
  end

  # The false-timeout side of the contract: the cap is scaled from an *uncontended*
  # baseline but mutants run under worker contention, so a slow-but-finite run can
  # overrun the cap without hanging. The fixture manufactures that deterministically:
  # the *first* mutant run drops a marker file and sleeps past the cap (a provisional
  # timeout); the sequential confirmation re-run sees the marker, finishes fast, and
  # reaches the real verdict. The baseline and coverage probe (mutant 0) never enter
  # the slow branch, so the cap they derive is honest.
  defp slow_first_run_project(app, marker) do
    Project.build(app, %{
      "lib/adder.ex" => """
      defmodule Adder do
        def add(a, b), do: a + b
      end
      """,
      "test/adder_test.exs" => """
      defmodule AdderTest do
        use ExUnit.Case

        test "adds" do
          if System.get_env("MUTARE_ACTIVE_MUTANT", "0") != "0" and
               not File.exists?(#{inspect(marker)}) do
            File.write!(#{inspect(marker)}, "ran")
            Process.sleep(5_000)
          end

          assert Adder.add(2, 2) == 4
        end
      end
      """
    })
  end

  test "a spurious timeout is confirmed without contention and records the real verdict" do
    marker = Project.tmp_dir(:confirm_marker)
    on_exit(fn -> File.rm_rf!(marker) end)

    %{project: project, sandbox: sandbox} = slow_first_run_project(:confirm, marker)

    assert {:ok, run} =
             Mutare.run(project,
               sandbox: sandbox,
               timeout: 2_000,
               workers: 1,
               mutators: [Mutare.Mutators.Arithmetic]
             )

    # Exactly one mutant (`a + b → a - b`). Its first run overran the cap — a
    # provisional timeout — and the confirmation re-run reached the real verdict:
    # `add(2, 2) == 0`, a failing assertion, i.e. a kill. Nothing records `:timeout`.
    assert [%Result{status: :killed}] = run.results
  end

  test "confirm_timeouts: false records the first overrun as a timeout" do
    marker = Project.tmp_dir(:noconfirm_marker)
    on_exit(fn -> File.rm_rf!(marker) end)

    %{project: project, sandbox: sandbox} = slow_first_run_project(:noconfirm, marker)

    assert {:ok, run} =
             Mutare.run(project,
               sandbox: sandbox,
               timeout: 2_000,
               workers: 1,
               confirm_timeouts: false,
               mutators: [Mutare.Mutators.Arithmetic]
             )

    # Opted out: the provisional timeout is recorded as-is, no re-run.
    assert [%Result{status: :timeout}] = run.results
  end
end
