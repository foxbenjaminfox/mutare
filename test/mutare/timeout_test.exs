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
        s.mutator == :arithmetic and s.original_op == :- and s.mutated_op == :+
      end)

    assert hang.status == :timeout
    # It ran roughly up to the cap, then self-halted (not a fast test failure).
    assert hang.duration_ms >= 1_500

    # A timeout is a kill: it isn't a survivor.
    refute Enum.any?(run.results, &(&1.status == :survived and &1.site.original_op == :-))
  end
end
