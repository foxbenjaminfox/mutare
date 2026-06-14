defmodule Mutare.SelectorTest do
  # Not async: :persistent_term and the env var are process-global.
  use ExUnit.Case, async: false

  alias Mutare.Selector

  setup do
    on_exit(fn ->
      System.delete_env(Selector.env_var())
      Selector.put(Selector.baseline())
    end)
  end

  test "defaults" do
    assert Selector.key() == :mutare_active
    assert Selector.env_var() == "MUTANT_UNDER_TEST"
    assert Selector.baseline() == 0
  end

  test "put/1 and active/0 round-trip" do
    Selector.put(7)
    assert Selector.active() == 7
    assert :persistent_term.get(Selector.key()) == 7
  end

  test "bootstrap AST reads the env var" do
    System.put_env(Selector.env_var(), "42")
    Code.eval_quoted(Selector.bootstrap_ast())
    assert Selector.active() == 42
  end

  test "bootstrap AST falls back to baseline when unset or empty" do
    System.delete_env(Selector.env_var())
    Selector.put(7)
    Code.eval_quoted(Selector.bootstrap_ast())
    assert Selector.active() == 0

    System.put_env(Selector.env_var(), "")
    Selector.put(7)
    Code.eval_quoted(Selector.bootstrap_ast())
    assert Selector.active() == 0
  end

  test "sandbox renders the canonical bootstrap AST" do
    rendered = Macro.to_string(Selector.bootstrap_ast())

    assert Mutare.Sandbox.bootstrap() =~ rendered
  end
end
