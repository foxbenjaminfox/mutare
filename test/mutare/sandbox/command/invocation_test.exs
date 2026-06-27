defmodule Mutare.Sandbox.Command.InvocationTest do
  # Not async: the inert-watcher check touches the process-global timeout env var.
  use ExUnit.Case, async: false

  alias Mutare.Sandbox
  alias Mutare.Sandbox.Command
  alias Mutare.Sandbox.Command.Invocation

  setup do
    on_exit(fn -> System.delete_env(Invocation.timeout_env()) end)
  end

  test "the sandbox environment constants" do
    assert Invocation.mix_env() == "test"
    assert Invocation.timeout_env() == "MUTARE_TIMEOUT"
  end

  test "reserved_env_names/0 lists the variables Mutare sets on every sandbox mix" do
    names = Invocation.reserved_env_names()
    # The base env and the cap var are always reserved (a `:partition_env` colliding
    # with one of these is rejected by `Mutare.Options`).
    assert "MIX_ENV" in names
    assert Invocation.timeout_env() in names
    # Sourced from the accessors that build the env, so no duplicates can creep in.
    assert names == Enum.uniq(names)
  end

  test "watcher AST carries the timeout env var and exit code" do
    rendered = Macro.to_string(Invocation.watcher_ast())

    assert rendered =~ ~s|System.get_env("#{Invocation.timeout_env()}")|
    # The watcher signals the timeout via the exit code the Command contract decodes.
    assert rendered =~ "System.halt(#{Command.timeout_exit()})"
  end

  test "watcher AST is inert when no cap is set" do
    System.delete_env(Invocation.timeout_env())
    # nil branch returns :ok and spawns nothing — safe to evaluate in-process.
    assert {:ok, _binding} = Code.eval_quoted(Invocation.watcher_ast())
  end

  test "sandbox renders the canonical watcher AST" do
    assert Sandbox.bootstrap() =~ Macro.to_string(Invocation.watcher_ast())
  end
end
