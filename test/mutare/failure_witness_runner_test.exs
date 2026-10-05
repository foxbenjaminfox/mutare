defmodule Mutare.FailureWitnessRunnerTest do
  @moduledoc """
  End-to-end proof that a run which crashes after a test failed is a kill: the target's own
  formatter raises at ExUnit's teardown once it has seen a failure, so `mix test` exits `1`
  instead of the failure code, and only the injected failure witness
  (`Mutare.Sandbox.Command.FailureWitness`) knows a test failed.
  """
  # Subprocess-bound: runs beside the in-process tests, one module at a time within its
  # group (`test_helper.exs` says why there are three).
  use ExUnit.Case, async: true, group: :subprocess_3

  import ExUnit.CaptureLog

  alias Mutare.Sandbox.Command
  alias Mutare.Test.Project

  @moduletag :runner
  @moduletag timeout: 180_000

  # Raising from `terminate/2` crashes `ExUnit.EventManager.stop/1` deterministically, the
  # way ExUnit's CLI formatter does when it is still printing a failure it cannot print
  # (a message that is not valid UTF-8) as the suite ends.
  @helper """
  defmodule TeardownCrash do
    use GenServer

    @impl true
    def init(_opts), do: {:ok, :clean}

    @impl true
    def handle_cast({:test_finished, %{state: {:failed, _}}}, _state), do: {:noreply, :failed}
    def handle_cast(_event, state), do: {:noreply, state}

    @impl true
    def terminate(_reason, :failed), do: raise("cannot print this failure")
    def terminate(_reason, :clean), do: :ok
  end

  ExUnit.start(formatters: [ExUnit.CLIFormatter, TeardownCrash])
  """

  setup do
    Project.build(:calc, %{
      "lib/calc.ex" => """
      defmodule Calc do
        def add(a, b), do: a + b
      end
      """,
      "test/calc_test.exs" => """
      defmodule CalcTest do
        use ExUnit.Case

        test "add" do
          assert Calc.add(2, 1) == 3
        end
      end
      """,
      "test/test_helper.exs" => @helper
    })
  end

  test "a test failure followed by a crash is killed, with a warning naming the crash", %{
    project: project,
    sandbox: sandbox
  } do
    {result, log} =
      with_log(fn ->
        Mutare.run(project, sandbox: sandbox, mutators: [Mutare.Mutators.Arithmetic])
      end)

    assert {:ok, run} = result
    assert [_ | _] = run.results

    for result <- run.results do
      assert result.status == :killed
      assert result.exit_status == 1
      assert result.output =~ "cannot print this failure"
    end

    assert log =~ "a test failed with this mutation active, then the run crashed"
  end

  test "the witness reports a failure the exit code lost, and nothing on a pass", %{
    project: project
  } do
    assert {_, 0} = Project.compile(project)

    # The fixture's own helper is not wrapped here, so install the witness by hand, after it.
    helper = Path.join(project, "test/test_helper.exs")
    File.write!(helper, @helper <> Macro.to_string(Command.FailureWitness.install_ast()))

    assert Command.timed_test(project, :suite, Mutare.Selector.baseline()).outcome == :passed

    File.write!(Path.join(project, "lib/calc.ex"), """
    defmodule Calc do
      def add(_a, _b), do: 0
    end
    """)

    assert {_, 0} = Project.compile(project)

    crashed = Command.timed_test(project, :suite, Mutare.Selector.baseline())
    assert crashed.exit_status == 1
    assert crashed.outcome == :failed_then_crashed
  end
end
