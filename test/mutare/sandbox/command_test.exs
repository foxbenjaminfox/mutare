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
