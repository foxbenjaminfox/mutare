defmodule Mutare.RescueRunnerTest do
  @moduledoc """
  End-to-end proof that a `rescue` exception-type-drop mutant runs through the whole loop with
  real `mix test` subprocesses: compile once, the coverage probe attributes it (the whole-`try`
  selector records when the `try` is reached), and a test that relies on each type being caught
  kills it.
  """
  use ExUnit.Case, async: false

  alias Mutare.Test.Project

  @probe [Mutare.Mutators.RescueType]

  @moduletag :runner
  @moduletag timeout: 180_000

  setup do
    Project.build(:guarded, %{
      "lib/guarded.ex" => """
      defmodule Guarded do
        def safe(f) do
          try do
            f.()
          rescue
            e in [RuntimeError, ArgumentError] -> {:rescued, e.__struct__}
          end
        end
      end
      """,
      "test/guarded_test.exs" => """
      defmodule GuardedTest do
        use ExUnit.Case

        test "safe rescues both runtime and argument errors" do
          assert Guarded.safe(fn -> raise RuntimeError end) == {:rescued, RuntimeError}
          assert Guarded.safe(fn -> raise ArgumentError end) == {:rescued, ArgumentError}
        end
      end
      """
    })
  end

  test "a rescue type-drop mutant is covered and killed end-to-end", %{
    project: project,
    sandbox: sandbox
  } do
    assert {:ok, run} = Mutare.run(project, sandbox: sandbox, mutators: @probe)

    # Two mutants: drop RuntimeError and drop ArgumentError. Each makes one of the two raised
    # errors propagate, failing the test — so both are killed, neither left :no_coverage.
    assert length(run.results) == 2
    assert Enum.all?(run.results, &(&1.status == :killed))
    assert Enum.all?(run.results, &(&1.site.mutator == :rescue_type))
  end

  test "a multi-branch rescue clause-drop mutant is covered and killed end-to-end" do
    %{project: project, sandbox: sandbox} =
      Project.build(:branched, %{
        "lib/branched.ex" => """
        defmodule Branched do
          def safe(f) do
            try do
              f.()
            rescue
              e in ArgumentError -> {:arg, e.__struct__}
              e in RuntimeError -> {:run, e.__struct__}
            end
          end
        end
        """,
        "test/branched_test.exs" => """
        defmodule BranchedTest do
          use ExUnit.Case

          test "safe rescues both branches" do
            assert Branched.safe(fn -> raise ArgumentError end) == {:arg, ArgumentError}
            assert Branched.safe(fn -> raise RuntimeError end) == {:run, RuntimeError}
          end
        end
        """
      })

    assert {:ok, run} = Mutare.run(project, sandbox: sandbox, mutators: @probe)

    # Each branch catches a single type, so there is nothing to narrow — the two mutants are
    # whole-clause drops. Dropping either branch makes its exception propagate, failing the
    # test, so both are killed and covered (not :no_coverage).
    assert length(run.results) == 2
    assert Enum.all?(run.results, &(&1.status == :killed))

    assert Enum.all?(
             run.results,
             &(&1.site.mutator == :rescue_type and &1.site.operation == :delete)
           )
  end

  test "a `def … rescue …` shorthand rescue mutant is covered and killed end-to-end" do
    %{project: project, sandbox: sandbox} =
      Project.build(:shorthand, %{
        "lib/shorthand.ex" => """
        defmodule Shorthand do
          def safe(f) do
            f.()
          rescue
            e in [RuntimeError, ArgumentError] -> {:rescued, e.__struct__}
          end
        end
        """,
        "test/shorthand_test.exs" => """
        defmodule ShorthandTest do
          use ExUnit.Case

          test "safe rescues both runtime and argument errors" do
            assert Shorthand.safe(fn -> raise RuntimeError end) == {:rescued, RuntimeError}
            assert Shorthand.safe(fn -> raise ArgumentError end) == {:rescued, ArgumentError}
          end
        end
        """
      })

    assert {:ok, run} = Mutare.run(project, sandbox: sandbox, mutators: @probe)

    # The shorthand (no explicit `try`) is hosted in a synthesized `try`, so its two-type list
    # is narrowed like any rescue. Both type-drops are covered and killed end-to-end.
    assert length(run.results) == 2
    assert Enum.all?(run.results, &(&1.status == :killed))
    assert Enum.all?(run.results, &(&1.site.mutator == :rescue_type))
  end
end
