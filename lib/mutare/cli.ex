defmodule Mutare.CLI do
  @moduledoc false
  # Shared CLI presentation helpers used by both `Mix.Tasks.Mutare` (the run path)
  # and `Mutare.CLI.Info` (the inspect-and-exit commands).

  alias Mutare.Project

  @doc ~S(`"s"` unless the count is exactly 1 — for human-readable labels/notes.)
  @spec plural(non_neg_integer()) :: String.t()
  def plural(1), do: ""
  def plural(_n), do: "s"

  @doc "Clamp `str` to `max` display columns, marking truncation with an ellipsis."
  @spec truncate(String.t(), pos_integer()) :: String.t()
  def truncate(str, max) when max > 1 do
    if String.length(str) > max, do: String.slice(str, 0, max - 1) <> "…", else: str
  end

  def truncate(str, _max), do: str

  @doc "A short ` in <root>` / ` (umbrella: …)` suffix naming the mutation scope."
  @spec scope_label(Project.t()) :: String.t()
  def scope_label(%Project{umbrella?: true, mutate_scope: scope}) do
    " (umbrella: #{umbrella_apps(scope)})"
  end

  def scope_label(%Project{copy_root: "."}), do: ""
  def scope_label(%Project{copy_root: root}), do: " in #{root}"

  @doc "The comma-joined app names of an umbrella mutation scope."
  @spec umbrella_apps([%{app: atom()}]) :: String.t()
  def umbrella_apps(scope), do: Enum.map_join(scope, ", ", & &1.app)
end
