defmodule Mutare.Sandbox.DependencyDiagnostic do
  @moduledoc """
  Render actionable guidance for a sandbox dependency-check failure.

  The sandbox compile already runs Mix's authoritative dependency validation, so
  no speculative preflight is needed. `Mutare.Sandbox.Command.Output` classifies
  that captured output; this module turns the category into a command to run in
  the **original** project. Mutare deliberately does not execute dependency
  commands itself: they may use the network or credentials, modify `mix.lock`,
  and would write fetched sources into a disposable default sandbox.
  """

  alias Mutare.Sandbox.Command.Output

  @doc "Render a dependency failure, its remediation, and Mix's original diagnostic."
  @spec format(String.t(), Path.t()) :: String.t()
  def format(detail, root) when is_binary(detail) and is_binary(root) do
    issue = Output.dependency_issue(detail)

    "sandbox dependency validation failed before the metamutant could compile.\n\n" <>
      guidance(issue, root) <>
      "\n\nMutare does not run dependency commands automatically: they may access the " <>
      "network, require credentials, or modify mix.lock, and a default sandbox is " <>
      "disposable. Repair the original project, then rerun Mutare.\n\n" <>
      "Original Mix dependency diagnostic:\n\n" <> String.trim(detail)
  end

  defp guidance(:fetch, root) do
    "Mix reports that dependency sources or the lock state are not ready.\n" <>
      original_project_command(root, "MIX_ENV=test mix deps.get")
  end

  defp guidance(:compile, root) do
    "Mix reports that fetched dependency sources need compiling.\n" <>
      original_project_command(root, "MIX_ENV=test mix deps.compile")
  end

  defp guidance(:diverged, root) do
    "Dependency declarations diverge; `deps.get` cannot resolve conflicting specs.\n" <>
      original_project_command(root, "MIX_ENV=test mix deps") <>
      "\nResolve the reported requirements/options in mix.exs."
  end

  defp guidance(:unavailable, root) do
    "A non-fetchable dependency is unavailable from the sandbox copy. This usually " <>
      "means a local/path dependency points outside the copied project or umbrella root; " <>
      "running `deps.get` will not relocate it. Keep the dependency under the copied root " <>
      "or use a dependency source that remains resolvable after copying.\n\n" <>
      "Original project root: #{root}"
  end

  defp guidance(_invalid, root) do
    "Mix reports an invalid dependency state.\n" <>
      original_project_command(root, "MIX_ENV=test mix deps") <>
      "\nApply the remedy shown for each dependency below."
  end

  defp original_project_command(root, command) do
    "From the original project root:\n  #{root}\nrun:\n  #{command}"
  end
end
