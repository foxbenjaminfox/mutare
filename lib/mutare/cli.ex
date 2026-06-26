defmodule Mutare.CLI do
  @moduledoc false
  # Shared CLI presentation helpers used by both `Mix.Tasks.Mutare` (the run path)
  # and `Mutare.CLI.Info` (the inspect-and-exit commands).

  alias Mutare.Project

  @doc ~S(`"s"` unless the count is exactly 1 — for human-readable labels/notes.)
  @spec plural(non_neg_integer()) :: String.t()
  def plural(1), do: ""
  def plural(_n), do: "s"

  @doc "A short ` in <root>` / ` (umbrella: …)` suffix naming the mutation scope."
  @spec scope_label(Project.t()) :: String.t()
  def scope_label(%Project{umbrella?: true, mutate_scope: scope}) do
    " (umbrella: #{Enum.map_join(scope, ", ", & &1.app)})"
  end

  def scope_label(%Project{copy_root: "."}), do: ""
  def scope_label(%Project{copy_root: root}), do: " in #{root}"
end
