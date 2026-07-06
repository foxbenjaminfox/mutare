defmodule Mutare.HeapCapTest do
  @moduledoc """
  A mutation can make code allocate without bound — faster than the wall-clock
  watcher can react. The motivating incident (dogfooding on Phoenix, see
  MUTARE-ON-PHOENIX.md): a `guard_drop` on a "normalize the shorthand, recurse"
  helper made the clause unconditionally self-recursive, each iteration wrapping
  the previous value in one more list — ~25GB RSS in under a second, OOM-killed
  by the kernel. `:max_heap_mb` (`Invocation.heap_cap_env/1`) contains that shape:
  a per-process BEAM heap cap under which the runaway *process* is killed, so the
  mutant dies as an ordinary, fast test failure inside its own run.

  The fixture reproduces the incident's growth shape (on-heap list doubling) with
  a belt-and-braces emergency bound: an absolute-size clause above the cap-kill
  threshold keeps every mutation of the module intrinsically bounded (~a couple
  hundred MB peak), so this test never endangers the host even if the cap under
  test were broken — a broken cap surfaces as the `refute`s below failing, not as
  a machine-wide OOM.
  """
  use ExUnit.Case, async: false

  alias Mutare.Test.Project

  @moduletag :runner
  @moduletag timeout: 180_000

  test "a runaway-allocation mutant dies under --max-heap-mb as a fast, ordinary kill" do
    %{project: project, sandbox: sandbox} =
      Project.build(:heap_cap, %{
        # Line numbers are load-bearing (the assertions select mutants by line):
        #   line 6 — the emergency absolute bound (test-safety, see moduledoc)
        #   line 7 — the incident shape: drop `length(acc) < target` and the
        #            recursive clause matches every call, doubling forever
        "lib/mem.ex" => """
        defmodule Mem do
          def grow_to(target) when is_integer(target) and target > 0 do
            do_grow([0], target)
          end

          defp do_grow(acc, _target) when length(acc) > 8_388_608, do: :overflow
          defp do_grow(acc, target) when length(acc) < target, do: do_grow(acc ++ acc, target)
          defp do_grow(acc, _target), do: acc
        end
        """,
        "test/mem_test.exs" => """
        defmodule MemTest do
          use ExUnit.Case
          test "grows to the target", do: assert(length(Mem.grow_to(64)) == 64)
        end
        """
      })

    # 50MB ≈ 6.5M heap words: the cap kills the doubling list at ~3M elements,
    # well before the emergency bound (8.4M) — so a *working* cap always fires
    # first, and only a broken one falls through to the bound. The generous
    # explicit timeout proves the kill is the cap's, not the wall clock's.
    assert {:ok, run} =
             Mutare.run(project,
               sandbox: sandbox,
               max_heap_mb: 50,
               timeout: 60_000,
               mutators: [Mutare.Mutators.GuardDrop]
             )

    runaway = Enum.find(run.results, &(&1.site.mutator == :guard_drop and &1.site.line == 7))
    assert runaway, "expected a guard_drop mutant on the recursive clause"

    # Killed — as a clean test failure (the capped process dies with reason
    # `:killed`, failing the test), never a timeout and never a harness error.
    assert runaway.status == :killed
    assert runaway.output =~ "killed"
    # ...by the heap cap, not the emergency bound (that path fails the test's
    # assertion with `:overflow` instead of killing the process).
    refute runaway.output =~ "overflow"
    # ...and fast: containment, not a wall-clock rescue.
    assert runaway.duration_ms < 60_000

    # The emergency clause's own guard_drop returns `:overflow` immediately — an
    # ordinary assertion failure. Both mutants die; neither touches the host.
    emergency = Enum.find(run.results, &(&1.site.mutator == :guard_drop and &1.site.line == 6))
    assert emergency, "expected a guard_drop mutant on the emergency-bound clause"
    assert emergency.status == :killed
  end
end
