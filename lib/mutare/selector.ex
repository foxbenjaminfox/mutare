defmodule Mutare.Selector do
  @moduledoc """
  Runtime selection of the active mutant.

  The active mutant is constant for an entire suite run, so it is read once from
  the environment at boot and stashed in `:persistent_term` (O(1) reads, built
  for write-once/read-many). Every selector site in the metamutant reads this
  key on each execution.

  The metamutant bakes in the literal key (`#{inspect(:mutare_active)}`) and a
  default of `0`, so this module and `Mutare.Transform` must agree on both.
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
  Read `MUTANT_UNDER_TEST` and stash it. Returns the activated id.
  Called once from the target project's test bootstrap.
  """
  @spec activate_from_env() :: non_neg_integer()
  def activate_from_env do
    id =
      case System.get_env(@env_var) do
        nil -> @baseline
        "" -> @baseline
        raw -> String.to_integer(raw)
      end

    put(id)
    id
  end

  @doc "Set the active mutant id directly (used by tests and in-process runs)."
  @spec put(non_neg_integer()) :: :ok
  def put(id) when is_integer(id) and id >= 0, do: :persistent_term.put(@key, id)

  @doc "The currently active mutant id (`0` if unset)."
  @spec active() :: non_neg_integer()
  def active, do: :persistent_term.get(@key, @baseline)
end
