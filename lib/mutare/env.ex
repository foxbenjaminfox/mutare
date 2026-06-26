defmodule Mutare.Env do
  @moduledoc false

  # Tiny shared helpers for reading the process environment.

  @doc """
  Read `var` as an atom: `default` when the var is unset or empty (`""`), else
  `String.to_atom/1` of its value.

  Backs the self-hosting *override* env vars — `Mutare.Selector`'s selection key and
  `Mutare.Coverage.Recorder`'s fixture module — each of which names an atom that defaults
  to a harness constant unless a sandbox run sets a private one. `String.to_atom/1` is
  sound here because the value is a harness-controlled identifier, not arbitrary user input.
  """
  @spec atom(String.t(), atom()) :: atom()
  def atom(var, default) do
    case System.get_env(var) do
      nil -> default
      "" -> default
      name -> String.to_atom(name)
    end
  end
end
