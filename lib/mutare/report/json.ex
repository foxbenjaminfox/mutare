defmodule Mutare.Report.Json do
  @moduledoc """
  Renders a mutation run as a **mutation-testing-elements** report-schema JSON
  document (the schema Stryker and its viewer/dashboard speak).

  This is the lossless machine format: every mutant (not just survivors) is
  emitted, keyed by file, with its location and status. Mutare's
  `Mutare.Result` statuses map exactly onto the schema's `MutantStatus`
  vocabulary (see `status/1`), so the report drops straight into the existing
  ecosystem — `Mutare.Report.Html` embeds this same document into the report
  web component, and it can be uploaded to the Stryker dashboard unchanged.

  Emitted by `mix mutare --format json`.
  """

  alias Mutare.Result
  alias Mutare.Result.Status

  # The report schema is versioned `^([1-2])(\.([1-9]\d*|0)){0,2}$`. We depend on
  # no v2-only feature, so we emit the conservative `"1.0"`.
  @schema_version "1.0"

  # Score thresholds drive the viewer's red/yellow/green colouring. We have a
  # single gate (`:min_score`), not a band, so a set gate collapses both bounds
  # onto it; absent, we fall back to Stryker's conventional defaults.
  @default_high 80
  @default_low 60

  # Mutare status -> schema MutantStatus is the `:json` field of each
  # `Mutare.Result.Status` descriptor — the single place the two vocabularies meet,
  # total over `Mutare.Result.status/0` by construction (a status with no row makes
  # `Status.fetch!/1` raise, exactly as the old `Map.fetch!` did). `:atom_exhausted`
  # has no dedicated schema status; its descriptor maps it to "Timeout" (the schema's
  # other "detected by non-completion" status) — score-consistent with Stryker.

  @doc """
  Render `results` and their original `sources` as a report-schema JSON string.

  `opts[:min_score]` (when set) becomes the report's score thresholds.
  """
  @spec render([Result.t()], %{optional(String.t()) => String.t()}, keyword()) :: String.t()
  def render(results, sources, opts \\ []) do
    %{
      schemaVersion: @schema_version,
      thresholds: thresholds(opts[:min_score]),
      files: files(results, sources)
    }
    |> JSON.encode!()
  end

  defp thresholds(nil), do: %{high: @default_high, low: @default_low}

  defp thresholds(min_score) do
    n = round(min_score)
    %{high: n, low: n}
  end

  defp files(results, sources) do
    results
    |> Enum.group_by(& &1.site.file)
    |> Map.new(fn {file, file_results} ->
      {file,
       %{
         language: "elixir",
         source: Map.get(sources, file, ""),
         mutants: Enum.map(file_results, &mutant/1)
       }}
    end)
  end

  defp mutant(%Result{site: site} = result) do
    %{
      id: to_string(site.id),
      mutatorName: to_string(site.mutator),
      replacement: site.mutated_code || "",
      location: location(site.range),
      status: Status.fetch!(result.status).json
    }
    |> put_present(:statusReason, site.ignore_reason)
    |> put_present(:description, site.note)
    |> put_present(:duration, result.duration_ms)
  end

  # Every real `Site` carries a range; this default only guards the typespec's
  # `range: nil` corner so a malformed site can't crash the whole report.
  defp location(nil), do: %{start: %{line: 1, column: 1}, end: %{line: 1, column: 1}}

  defp location(range) do
    %{
      start: %{line: range.start[:line], column: range.start[:column]},
      end: %{line: range.end[:line], column: range.end[:column]}
    }
  end

  defp put_present(map, _key, nil), do: map
  defp put_present(map, key, value), do: Map.put(map, key, value)
end
