defmodule Mutare.Sandbox.CommandTest do
  # Not async: the inert-watcher check touches the process-global timeout env var.
  use ExUnit.Case, async: false

  alias Mutare.Sandbox
  alias Mutare.Sandbox.Command

  setup do
    on_exit(fn -> System.delete_env(Command.timeout_env()) end)
  end

  test "timeout contract constants" do
    assert Command.timeout_env() == "MUTARE_TIMEOUT"
    assert Command.timeout_exit() == 124
  end

  test "failure exit is distinct from the codes a harness failure can produce" do
    assert Command.failure_exit() == 101
    # 0 = success, 1 = mix/compile failure, 2 = ExUnit default, 124 = timeout.
    refute Command.failure_exit() in [0, 1, 2, Command.timeout_exit()]
  end

  describe "outcome/1 decodes the exit-code contract" do
    test "0 is a pass (the mutation survived)" do
      assert Command.outcome(0) == :passed
    end

    test "the forced failure exit is a clean test failure (a kill)" do
      assert Command.outcome(Command.failure_exit()) == :failed
    end

    test "the watcher's exit code is a timeout" do
      assert Command.outcome(Command.timeout_exit()) == :timeout
    end

    test "every other exit code is a harness error, never a kill" do
      # 1 = compile error / missing dep / broken helper; 2 = ExUnit default were
      # --exit-status ever dropped; 137 = 128 + SIGKILL (e.g. OOM). None is a kill.
      for status <- [1, 2, 3, 127, 137, 255] do
        assert Command.outcome(status) == :harness_error,
               "exit #{status} must not be miscounted as a kill"
      end
    end
  end

  describe "test_argv/1 builds the kill-detection mix test argv" do
    # A flag and its value are passed as two adjacent argv elements.
    defp flag_value(argv, flag) do
      case Enum.find_index(argv, &(&1 == flag)) do
        nil -> nil
        i -> Enum.at(argv, i + 1)
      end
    end

    test "forces the failure exit status so a kill is distinct from a harness error" do
      assert flag_value(Command.test_argv([]), "--exit-status") ==
               Integer.to_string(Command.failure_exit())
    end

    test "forces --max-failures 1, since one failure is enough to declare a kill" do
      assert flag_value(Command.test_argv([]), "--max-failures") == "1"
    end

    test "appends the caller's test args (file-granular selection) after the flags" do
      argv = Command.test_argv(["test/foo_test.exs", "test/bar_test.exs"])
      # The forced flags come first; the selection is appended verbatim at the tail.
      assert List.starts_with?(argv, ["test", "--exit-status", "101", "--max-failures", "1"])
      assert Enum.take(argv, -2) == ["test/foo_test.exs", "test/bar_test.exs"]
    end

    test "a whole-suite run ([] args) carries only the forced flags" do
      assert Command.test_argv([]) == ["test", "--exit-status", "101", "--max-failures", "1"]
    end
  end

  test "watcher AST carries the timeout env var and exit code" do
    rendered = Macro.to_string(Command.watcher_ast())

    assert rendered =~ ~s|System.get_env("#{Command.timeout_env()}")|
    assert rendered =~ "System.halt(#{Command.timeout_exit()})"
  end

  test "watcher AST is inert when no cap is set" do
    System.delete_env(Command.timeout_env())
    # nil branch returns :ok and spawns nothing — safe to evaluate in-process.
    assert {:ok, _binding} = Code.eval_quoted(Command.watcher_ast())
  end

  test "sandbox renders the canonical watcher AST" do
    assert Sandbox.bootstrap() =~ Macro.to_string(Command.watcher_ast())
  end
end
