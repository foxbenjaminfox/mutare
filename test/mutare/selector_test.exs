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

  test "activate_from_env/0 reads the env var" do
    System.put_env(Selector.env_var(), "42")
    assert Selector.activate_from_env() == 42
    assert Selector.active() == 42
  end

  test "activate_from_env/0 falls back to baseline when unset or empty" do
    System.delete_env(Selector.env_var())
    assert Selector.activate_from_env() == 0

    System.put_env(Selector.env_var(), "")
    assert Selector.activate_from_env() == 0
  end
end
