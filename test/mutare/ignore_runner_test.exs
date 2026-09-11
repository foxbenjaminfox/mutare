defmodule Mutare.IgnoreRunnerTest do
  @moduledoc "`# mutare:ignore` end to end: the ignored mutant is never run and stays out of the score."
  use ExUnit.Case, async: false

  alias Mutare.Result
  alias Mutare.Test.Project

  describe "end to end" do
    @tag :runner
    @tag timeout: 180_000
    test "an ignored mutant is :ignored (not run) and kept out of the score" do
      %{project: project, sandbox: sandbox} =
        Project.build(:ig, %{
          "lib/ig.ex" => """
          defmodule Ig do
            def keep(x), do: x + 1
            def skip(x), do: x + 1 # mutare:ignore
          end
          """,
          "test/ig_test.exs" => """
          defmodule IgTest do
            use ExUnit.Case
            test "keep", do: assert(Ig.keep(1) == 2)
          end
          """
        })

      # Pin to a single operator-swap family so `skip/1` has exactly one mutant
      # (the test asserts a single ignored result); the default integer-literal mutator
      # would add more, off-topic for what this checks.
      assert {:ok, run} =
               Mutare.run(project, sandbox: sandbox, mutators: [Mutare.Mutators.Arithmetic])

      ignored = Enum.filter(run.results, &(&1.status == :ignored))

      # `skip/1`'s mutant is suppressed — and ignore wins over no-coverage
      # (it's never run), so it's :ignored, not :no_coverage.
      assert [%Result{site: %{ignored: true}, duration_ms: 0}] = ignored
      assert Enum.all?(ignored, &(&1.site.line == skip_line()))

      # keep/1's mutant is covered and killed; with the other ignored, score is 100%.
      assert Mutare.Score.score(run.results) == 100.0
    end
  end

  defp skip_line, do: 3
end
