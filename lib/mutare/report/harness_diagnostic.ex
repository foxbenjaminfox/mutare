defmodule Mutare.Report.HarnessDiagnostic do
  @moduledoc """
  Compact diagnostics for mutants that ended as `:harness_error`.

  The runner already captures the raw `mix test` output, but the final reports
  need a short, stable summary rather than an entire suite log. This module is the
  shared presentation layer for human, JSON, live, and abort messages.
  """

  alias Mutare.Result
  alias Mutare.Sandbox.Command.Output
  alias Mutare.Site

  @max_line_chars 200

  @doc """
  Return a one-line diagnostic for a harness-errored result.

  Includes the exit status when known plus the first useful output line. The
  known self-erasing boot crash gets a cause-specific summary because its output
  is explicitly not useful for recovering the original exception.
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

      line = useful_line(output) ->
        truncate(line)

      true ->
        "no output captured"
    end
  end

  defp output_clue(_output), do: "no output captured"

  defp useful_line(output) do
    lines =
      output
      |> String.split("\n")
      |> Enum.map(&String.trim/1)
      |> Enum.reject(&(&1 == "" or routine_line?(&1)))

    Enum.find(lines, &interesting?/1) || List.first(lines)
  end

  defp routine_line?(line) do
    String.starts_with?(line, "Compiling ") or
      String.starts_with?(line, "Generated ") or
      String.starts_with?(line, "Running ExUnit with seed:") or
      String.starts_with?(line, "Excluding tags:") or
      String.starts_with?(line, "Including tags:") or
      String.starts_with?(line, "Finished in ") or
      Regex.match?(~r/^\.*$/, line)
  end

  defp interesting?(line) do
    String.starts_with?(line, "** (") or
      String.starts_with?(line, "error:") or
      String.starts_with?(line, "Unchecked dependencies") or
      String.starts_with?(line, "Dependencies have diverged") or
      String.starts_with?(line, "Could not start application") or
      String.contains?(line, "Runtime terminating during boot")
  end

  defp truncate(line) do
    if String.length(line) <= @max_line_chars do
      line
    else
      String.slice(line, 0, @max_line_chars) <> "…"
    end
  end
end
