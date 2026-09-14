defmodule Mutare.Sandbox.RuntimeConfig do
  @moduledoc """
  Preserve evidence of errors, exits, and throws during runtime configuration.

  Mix evaluates `runtime.exs` beside the effective `config_path`. That path can
  be computed by project code, so sandbox materialisation wraps regular files
  named `runtime.exs` throughout the project, without evaluating `mix.exs` or
  following symlinks. Dependencies and excluded build/VCS trees are left alone.

  The wrapper prints a marker only when a failure escapes evaluation, then
  re-raises it with its original class, reason, and stacktrace. This covers imported
  configuration and deep library calls even when the stacktrace has lost every Config frame.
  Successful configuration prints nothing; an unreadable entry file never enters
  the wrapper. `Mutare.Sandbox.Command.Output` reads the marker alongside the
  exception header.
  """

  alias Mutare.Sandbox.Mirror

  @failure_marker "[mutare] runtime configuration raised"

  @doc false
  @spec failure_marker() :: String.t()
  def failure_marker, do: @failure_marker

  @doc false
  @spec files(Path.t(), [String.t()]) :: %{Path.t() => String.t()}
  def files(root, excluded) do
    for {rel, {:regular, _mode}} <- Mirror.source_entries(root, ["deps" | excluded]),
        Path.basename(rel) == "runtime.exs",
        {:ok, source} <- [File.read(Path.join(root, rel))],
        into: %{} do
      {rel, wrap(source)}
    end
  end

  defp wrap(source) do
    """
    try do
    #{source}
    catch
      mutare_config_kind, mutare_config_reason ->
        Elixir.IO.puts(:stderr, #{inspect("\n" <> @failure_marker)})
        :erlang.raise(mutare_config_kind, mutare_config_reason, __STACKTRACE__)
    end
    """
  end
end
