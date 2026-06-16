defmodule Mutare.Selector do
  @moduledoc """
  Runtime selection of the active mutant.

  The active mutant is constant for an entire suite run, so it is read once from
  the environment at boot and stashed in `:persistent_term` (O(1) reads, built
  for write-once/read-many). Every selector site in the metamutant reads this
  key on each execution.

  This module owns both sides of that contract: `Mutare.Metamutant` uses its key
  and baseline when building selectors, while `Mutare.Sandbox` renders
  `bootstrap_ast/0` into the target project's dependency-free test bootstrap.
  """

  @key :mutare_active
  @env_var "MUTANT_UNDER_TEST"
  @baseline 0

  @doc "The `:persistent_term` key the metamutant reads."
  @spec key() :: atom()
  def key, do: @key

  @doc "The environment variable a runner sets to pick the active mutant."
  @spec env_var() :: String.t()
  def env_var, do: @env_var

  @doc "The baseline id (no mutant active)."
  @spec baseline() :: non_neg_integer()
  def baseline, do: @baseline

  @doc """
  Dependency-free code that reads the selector environment variable and stores
  the active mutant id.

  `Mutare.Sandbox` renders this AST directly into the target project's test
  bootstrap, so the target does not need Mutare as a dependency.
  """
  @spec bootstrap_ast() :: Macro.t()
  def bootstrap_ast do
    key = @key
    env_var = @env_var
    baseline = @baseline

    quote do
      :persistent_term.put(
        unquote(key),
        case System.get_env(unquote(env_var)) do
          nil -> unquote(baseline)
          "" -> unquote(baseline)
          raw -> String.to_integer(raw)
        end
      )
    end
  end

  @doc "Set the active mutant id directly for in-process execution."
  @spec put(non_neg_integer()) :: :ok
  # Self-hosting artifact: every mutant here lives in the active-mutant guard, and
  # exercising `put/1` *overwrites* `:mutare_active` — the very key the harness
  # flips to select the mutant under test. So when Mutare mutation-tests itself,
  # these mutants either deactivate themselves (the call resets the active id →
  # false survivor) or crash a test's setup/teardown `put` (false kill); neither
  # says anything about the mutation. Excluded only under dogfooding; on a normal
  # target this guard is killable by a `put(<invalid>)` test.
  # mutare:ignore self-hosting: exercising put/1 overwrites the :mutare_active selector key
  def put(id) when is_integer(id) and id >= 0, do: :persistent_term.put(@key, id)

  @doc "The active mutant id for in-process execution (`0` if unset)."
  @spec active() :: non_neg_integer()
  def active, do: :persistent_term.get(@key, @baseline)
end
