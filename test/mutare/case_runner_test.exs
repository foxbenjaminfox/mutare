defmodule Mutare.CaseRunnerTest do
  @moduledoc """
  End-to-end proof that a `case` clause-pattern mutant (the tuple-the-scrutinee rewrite) runs
  through the whole loop with real `mix test` subprocesses: compile the metamutant once, the
  coverage probe attributes the per-clause mutants (recorded in the clause bodies at baseline),
  and a test that distinguishes the mutated pattern kills it.
  """
  use ExUnit.Case, async: false

  alias Mutare.Test.Project

  # Literal only: the sole mutants are the two pattern-literal swaps of the `0` clause pattern
  # (`0 -> 1`, `0 -> -1`), so the scenario is deterministic.
  @probe [Mutare.Mutators.Literal]

  @moduletag :runner
  @moduletag timeout: 180_000

  setup do
    Project.build(:sign, %{
      "lib/sign.ex" => """
      defmodule Sign do
        def label(n) do
          case n do
            0 -> :zero
            _ -> :other
          end
        end
      end
      """,
      "test/sign_test.exs" => """
      defmodule SignTest do
        use ExUnit.Case

        test "label distinguishes zero" do
          assert Sign.label(0) == :zero
          assert Sign.label(7) == :other
        end
      end
      """
    })
  end

  test "a case clause-pattern mutant is covered and killed end-to-end", %{
    project: project,
    sandbox: sandbox
  } do
    assert {:ok, run} = Mutare.run(project, sandbox: sandbox, mutators: @probe)

    # Both mutants target the `0` pattern (line 4) and change what clause 1 matches, so the
    # `label(0) == :zero` test kills them. None is left :no_coverage (the probe attributed
    # them via the clause-body record), and the metamutant compiled exactly once.
    assert run.results != []
    assert Enum.all?(run.results, &(&1.status == :killed))
    assert Enum.all?(run.results, &(&1.site.line == 4 and &1.site.mutator == :literal))
  end
end
