defmodule Mutare.Sandbox.ProjectEvaluation do
  @moduledoc """
  Preserve evidence of failures while evaluating the sandbox's `mix.exs` files.

  Selection precedes project evaluation, so required library code and `project/0`
  can fail with a mutation active, before configuration or application startup.
  Wrapping the whole project source covers both inline and externally required
  project definitions, independently of the compiler-options hook. The selector
  and watcher bootstrap stays outside this wrapper so its own failures cannot
  produce project evidence.

  Escaping errors, exits, and throws print a marker before being re-raised with
  their original class, reason, and stacktrace. Successful evaluation preserves
  the source's value and prints nothing. `Mutare.Sandbox.Command.Output` requires
  the marker and an exception header, even when deep calls lose all project frames.
  """

  @failure_marker "[mutare] project evaluation raised"

  @doc false
  @spec failure_marker() :: String.t()
  def failure_marker, do: @failure_marker

  @doc false
  @spec wrap(String.t()) :: String.t()
  def wrap(source) do
    """
    try do
    #{source}
    catch
      mutare_project_kind, mutare_project_reason ->
        Elixir.IO.puts(:stderr, #{inspect("\n" <> @failure_marker)})
        :erlang.raise(mutare_project_kind, mutare_project_reason, __STACKTRACE__)
    end
    """
  end
end
