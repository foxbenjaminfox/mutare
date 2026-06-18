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
end
