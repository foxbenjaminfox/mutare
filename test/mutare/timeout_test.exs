defmodule Mutare.TimeoutTest do
  @moduledoc """
  A mutation can turn a terminating loop infinite. The per-mutant wall-clock cap
  catches it — and does so portably: the mutant run halts itself (no external
  process-killing).
  """
  use ExUnit.Case, async: false

  alias Mutare.Result

  @moduletag :runner
  @moduletag timeout: 180_000

  test "an infinite-loop mutation is capped and counts as a timeout (a kill)" do
    base = Path.join(System.tmp_dir!(), "mutare_to_#{System.unique_integer([:positive])}")
    project = Path.join(base, "loop")
    sandbox = Path.join(base, "sandbox")
    write_project(project)
    on_exit(fn -> File.rm_rf!(base) end)

    # Small explicit cap so the hang is caught quickly.
    assert {:ok, run} = Mutare.run(project, sandbox: sandbox, timeout: 2_000)

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

  defp write_project(project) do
    write(project, "mix.exs", """
    defmodule Loop.MixProject do
      use Mix.Project
      def project, do: [app: :loop, version: "0.1.0", elixir: "~> 1.15"]
      def application, do: []
    end
    """)

    write(project, "lib/loop.ex", """
    defmodule Loop do
      def count_down(0), do: :done
      def count_down(n), do: count_down(n - 1)
    end
    """)

    write(project, "test/test_helper.exs", "ExUnit.start()\n")

    write(project, "test/loop_test.exs", """
    defmodule LoopTest do
      use ExUnit.Case
      test "counts down to done", do: assert(Loop.count_down(5) == :done)
    end
    """)
  end

  defp write(project, rel, contents) do
    path = Path.join(project, rel)
    File.mkdir_p!(Path.dirname(path))
    File.write!(path, contents)
  end
end
