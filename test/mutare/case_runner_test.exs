defmodule Mutare.CaseRunnerTest do
  @moduledoc """
  End-to-end proof that a `case` clause-pattern mutant (the tuple-the-scrutinee rewrite) runs
  through the whole loop with real `mix test` subprocesses: compile the metamutant once, the
  coverage probe attributes the per-clause mutants, and a test that distinguishes the mutated
  pattern kills it.

  Two attribution paths are exercised:

    * an **exhaustive** `case` (with a `_` catch-all) — every clause body records the full id-set,
      so a value matching *any* clause covers them all;
    * a **non-exhaustive** `case` exercised *only* with a value that matches no clause — the
      regression the tuple rewrite first introduced: the tupled subject `{active, value}` fell
      through every clause recording nothing, so a mutant that would *make* that value match was
      wrongly scored `:no_coverage`. The unmatched fallback records the ids (and re-raises the
      original `CaseClauseError`), so it is covered and killed.
  """
  use ExUnit.Case, async: false

  alias Mutare.Test.Project

  # IntegerLiteral only, so the mutant set is the small, deterministic set of integer-literal swaps.
  @probe [Mutare.Mutators.IntegerLiteral]

  @moduletag :runner
  @moduletag timeout: 180_000

  test "an exhaustive case clause-pattern mutant is covered and killed end-to-end" do
    %{project: project, sandbox: sandbox} =
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

    assert {:ok, run} = Mutare.run(project, sandbox: sandbox, mutators: @probe)

    # Both mutants target the `0` pattern (line 4) and change what clause 1 matches, so the
    # `label(0) == :zero` test kills them. None is left :no_coverage (the probe attributed
    # them via the clause-body record), and the metamutant compiled exactly once.
    assert run.results != []
    assert Enum.all?(run.results, &(&1.status == :killed))
    assert Enum.all?(run.results, &(&1.site.line == 4 and &1.site.mutator == :integer))
  end

  test "a non-exhaustive case mutant is covered via the unmatched fallback and killed" do
    %{project: project, sandbox: sandbox} =
      Project.build(:narrow, %{
        "lib/narrow.ex" => """
        defmodule Narrow do
          def classify(n) do
            case n do
              1 -> :one
              2 -> :two
            end
          end
        end
        """,
        # The suite exercises `classify` *only* with `3`, which matches no clause — so no original
        # clause body ever runs and the only attribution path is the unmatched fallback.
        "test/narrow_test.exs" => """
        defmodule NarrowTest do
          use ExUnit.Case

          test "classify raises on an unknown value" do
            assert_raise CaseClauseError, fn -> Narrow.classify(3) end
          end
        end
        """
      })

    assert {:ok, run} = Mutare.run(project, sandbox: sandbox, mutators: @probe)

    # The mutant that re-targets clause `2` to `3` (`2 -> :two` becomes `3 -> :two`) makes
    # `classify(3)` return `:two` instead of raising — failing the `assert_raise`, so it is killed.
    # Before the fallback, baseline `classify(3)` fell through the tupled subject recording
    # nothing, so every mutant here was wrongly `:no_coverage` and this one survived undetected.
    assert run.results != []
    refute Enum.any?(run.results, &(&1.status == :no_coverage))

    retarget = Enum.find(run.results, &(&1.site.mutated_code == "3"))
    assert retarget, "expected a mutant re-targeting clause 2 to the pattern 3"
    assert retarget.status == :killed
  end
end
