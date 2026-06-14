defmodule Mutare.Changes do
  @moduledoc """
  Source files changed versus a git ref — the basis for `mix mutare --since`,
  the CI mode that mutation-tests only what a branch touched.
  """

  @doc """
  Files changed under `root` versus `ref`, as a set of paths relative to `root`.

  Uses `git diff --name-only --relative`, run with `root` as the working dir, so
  it reports working-tree changes (committed and uncommitted) since `ref`, scoped
  to and relative to `root`. Returns `{:error, detail}` if git fails (no repo,
  bad ref, git missing).
  """
  @spec since(Path.t(), String.t()) :: {:ok, MapSet.t()} | {:error, String.t()}
  def since(root, ref) do
    case System.cmd("git", ["-C", root, "diff", "--name-only", "--relative", ref],
           stderr_to_stdout: true
         ) do
      {output, 0} ->
        {:ok, output |> String.split("\n", trim: true) |> MapSet.new()}

      {output, _status} ->
        {:error, String.trim(output)}
    end
  rescue
    error -> {:error, Exception.message(error)}
  end
end
