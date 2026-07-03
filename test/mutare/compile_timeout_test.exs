defmodule Mutare.CompileTimeoutTest do
  @moduledoc """
  The one metamutant compile can hang — a compiler pass pathological on
  metamutant-shaped code (see NOTES), a compile-time hook gone wrong. The
  wall-clock cap catches it the same way the per-mutant cap catches an
  infinite-loop mutant: the compile halts *itself* (no external
  process-killing), and the runner surfaces a dedicated error instead of
  blocking the run indefinitely or feeding the non-error to poison recovery.
  """
  use ExUnit.Case, async: false

  alias Mutare.Test.Project

  @moduletag :runner
  @moduletag timeout: 180_000

  test "a hanging metamutant compile is capped and surfaces :compile_timed_out" do
    %{project: project, sandbox: sandbox} =
      Project.build(:slowcomp, %{
        "lib/slow.ex" => """
        defmodule Slow do
          # A module body executes at compile time: this sleep models a compile
          # that will not finish inside any reasonable cap. It is baseline code
          # (untouched by the arithmetic-only run below), so the hang is the
          # compile itself, not a mutant.
          Process.sleep(600_000)
          def dec(n), do: n - 1
        end
        """,
        "test/slow_test.exs" => """
        defmodule SlowTest do
          use ExUnit.Case
          test "decrements", do: assert(Slow.dec(1) == 0)
        end
        """
      })

    # Small explicit cap so the hang is caught quickly; arithmetic pinned so the
    # schema has exactly the one `n - 1` site (a run must have something to
    # mutate to reach the compile at all).
    assert {:error, :compile_timed_out, _detail} =
             Mutare.run(project,
               sandbox: sandbox,
               compile_timeout: 2_000,
               mutators: [Mutare.Mutators.Arithmetic]
             )
  end
end
