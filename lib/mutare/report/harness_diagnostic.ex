defmodule Mutare.Report.HarnessDiagnostic do
  @moduledoc """
  Compact diagnostics for mutants that ended as `:harness_error`.

  The runner already captures the raw `mix test` output, but the final reports
  need a short, stable summary rather than an entire suite log. This module is the
  shared presentation layer for human, JSON, live, and abort messages.

  It only formats. Picking the output line to show and recognising the known boot
  crash both read mix's output format, which `Mutare.Sandbox.Command.Output` owns
  (`salient_line/1`, `boot_failure?/1`).
  """

  alias Mutare.Result
  alias Mutare.Sandbox.Command.Output
  alias Mutare.Site

  @max_line_chars 200

  @doc """
  Return a one-line diagnostic for a harness-errored result.

  Includes the exit status when known plus the output's salient line
  (`Mutare.Sandbox.Command.Output.salient_line/1`), truncated. The known
  self-erasing boot crash gets a cause-specific summary because its output is
  explicitly not useful for recovering the original exception.
  """
  @spec summary(Result.t()) :: String.t()
  def summary(%Result{} = result) do
    [exit_status(result.exit_status), output_clue(result.output)]
    |> Enum.reject(&(&1 == ""))
    |> Enum.join("; ")
  end

  @doc """
  Return a site-prefixed diagnostic line suitable for multi-error summaries.
  """
  @spec line(Result.t()) :: String.t()
  def line(%Result{site: %Site{} = site} = result) do
    "#{site.file}:#{site.line}: mutant #{site.id} — #{summary(result)}"
  end

  defp exit_status(status) when is_integer(status), do: "exit #{status}"
  defp exit_status(_status), do: "exit unknown"

  defp output_clue(output) when is_binary(output) do
    cond do
      Output.boot_failure?(output) ->
        "sandbox node died during boot; likely startup contention"

      line = Output.salient_line(output) ->
        truncate(line)

      true ->
        "no output captured"
    end
  end

  defp output_clue(_output), do: "no output captured"

  defp truncate(line) do
    if String.length(line) <= @max_line_chars do
      line
    else
      String.slice(line, 0, @max_line_chars) <> "…"
    end
  end
end
