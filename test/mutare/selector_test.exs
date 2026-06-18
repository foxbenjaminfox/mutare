defmodule Mutare.SelectorTest do
  # Not async: :persistent_term and the env var are process-global.
  use ExUnit.Case, async: false

  alias Mutare.Selector

  # This suite necessarily pokes the *harness* key directly (it tests the bootstrap
  # and `default_key/0`), so it must leave that slot — and the env vars — exactly as
  # it found them. Otherwise, when this very suite runs under dogfooding, it would
  # clobber the real mutant-under-test and manufacture false survivors (the bug
  # Option A exists to kill). Save and restore, never blindly reset.
  setup do
    saved_override = System.get_env(Selector.override_env())
    saved_selector = System.get_env(Selector.env_var())
    saved_active = :persistent_term.get(Selector.default_key(), Selector.baseline())

    on_exit(fn ->
      restore_env(Selector.override_env(), saved_override)
      restore_env(Selector.env_var(), saved_selector)
      :persistent_term.put(Selector.default_key(), saved_active)
    end)
  end

  defp restore_env(var, nil), do: System.delete_env(var)
  defp restore_env(var, value), do: System.put_env(var, value)

  test "defaults" do
    # `default_key/0` is the env-independent harness key; `key/0` equals it unless
    # the override is set (which it is when this suite runs under dogfooding).
    assert Selector.default_key() == :mutare_active
    assert Selector.env_var() == "MUTANT_UNDER_TEST"
    assert Selector.baseline() == 0
  end

  test "key/0 is the default key unless MUTARE_SELECTOR_KEY overrides it" do
    System.delete_env(Selector.override_env())
    assert Selector.key() == Selector.default_key()

    System.put_env(Selector.override_env(), "mutare_active__suite")
    assert Selector.key() == :mutare_active__suite

    # Blank is treated as unset (the bootstrap's own empty-string rule).
    System.put_env(Selector.override_env(), "")
    assert Selector.key() == Selector.default_key()
  end

  test "put/1 and active/0 round-trip on the runtime key" do
    Selector.put(7)
    assert Selector.active() == 7
    assert :persistent_term.get(Selector.key()) == 7
  end

  test "put/1 rejects a negative id (guard floor is 0, not -1)" do
    # A mutant relaxing `id >= 0` to `id >= -1`, forcing the guard to `true`, or
    # weakening `and` to `or` would accept a negative id — a mutant id is never
    # negative, so the guard is a real precondition.
    assert_raise FunctionClauseError, fn -> Selector.put(-1) end
  end

  test "put/1 rejects a non-integer id (the is_integer half of the guard)" do
    # Kills a mutant weakening `is_integer(id) and id >= 0` to an `or` (a float is
    # >= 0 so `or` would admit it) or forcing the whole guard to `true`.
    assert_raise FunctionClauseError, fn -> Selector.put(1.5) end
    assert_raise FunctionClauseError, fn -> Selector.put(:not_an_id) end
  end

  test "under a suite-key override, put/1 leaves the harness key untouched (self-hosting)" do
    # The Option-A invariant: when the suite-under-test runs in a sandbox (the
    # override names a private key), its own `put/1` lands there — never on the
    # harness's `default_key/0`, the slot holding the mutant under test. Without
    # this, a test calling `put/1` would deactivate the active mutant mid-run and
    # register a false survivor (see `Mutare.Selector`'s moduledoc / NOTES).
    harness_before = :persistent_term.get(Selector.default_key(), :unset)
    System.put_env(Selector.override_env(), Selector.suite_key())

    Selector.put(7)

    assert Selector.active() == 7
    assert :persistent_term.get(String.to_existing_atom(Selector.suite_key())) == 7
    # The harness slot is exactly as it was — no clobber.
    assert :persistent_term.get(Selector.default_key(), :unset) == harness_before
  end

  test "bootstrap AST reads the env var into the harness (default) key slot" do
    System.put_env(Selector.env_var(), "42")
    Code.eval_quoted(Selector.bootstrap_ast())
    # The bootstrap always targets the harness key — that's the slot the real
    # metamutant reads — regardless of any suite-key override.
    assert :persistent_term.get(Selector.default_key()) == 42
  end

  test "bootstrap AST falls back to baseline when unset or empty" do
    System.delete_env(Selector.env_var())
    :persistent_term.put(Selector.default_key(), 7)
    Code.eval_quoted(Selector.bootstrap_ast())
    assert :persistent_term.get(Selector.default_key()) == 0

    System.put_env(Selector.env_var(), "")
    :persistent_term.put(Selector.default_key(), 7)
    Code.eval_quoted(Selector.bootstrap_ast())
    assert :persistent_term.get(Selector.default_key()) == 0
  end

  test "sandbox renders the canonical bootstrap AST" do
    rendered = Macro.to_string(Selector.bootstrap_ast())

    assert Mutare.Sandbox.bootstrap() =~ rendered
  end
end
