defmodule Mutare.Report.Json do
  @moduledoc """
  Renders a mutation run as a mutation-testing-elements report-schema JSON document (the schema used by Stryker and its viewer/dashboard).

  This is the lossless machine format: every mutant (not just survivors) is emitted, keyed by file, with its location and status. A mutant the run has no result for — a report written before the run finished, or after it stopped early — is emitted as `Pending`, so a partial report never reads as a complete one. Mutare's `Mutare.Result` statuses map exactly onto the schema's `MutantStatus` vocabulary (see `status/1`), so the report drops straight into the existing ecosystem — `Mutare.Report.Html` embeds this same document into the report web component, and it can be uploaded to the Stryker dashboard unchanged.

  Two fields locate a mutant. The schema's `location` is the source span its `replacement` text replaces. Mutare adds `position`, a `{line, column}` point: where the mutant *is*, the location the human report prints and `--line` selects by. Its line is the one `# mutare:ignore` reads. Usually `position` is where `location` starts. A mutant whose replacement must cover more text than it changes is the exception: removing a pipe stage, for instance, rewrites the whole pipe but is positioned at the stage.

  Under `--partition-db`, Mutare also adds each mutant's `partition`, the one its run used. A kill on a partition whose environment failed the tests with no mutant active (`Mutare.Run`'s `:broken_partitions`) carries a `statusReason` saying the kill may be false.

  Emitted by `mix mutare --report json` or `mix mutare --report json:path.json`.
  """

  alias Mutare.{Report, Result, Site}
  alias Mutare.Report.HarnessDiagnostic
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

  `opts[:min_score]` (when set) becomes the report's score thresholds,
  `opts[:pending]` lists the sites with no result yet, emitted as `Pending`, and
  `opts[:broken_partitions]` (`Mutare.Run`'s) gives each kill on one of those
  partitions a `statusReason` saying the kill may be false.
  """
  @spec render([Result.t()], %{optional(String.t()) => String.t()}, keyword()) :: String.t()
  def render(results, sources, opts \\ []) do
    %{
      schemaVersion: @schema_version,
      thresholds: thresholds(opts[:min_score]),
      files:
        files(
          results ++ Keyword.get(opts, :pending, []),
          sources,
          Map.new(Keyword.get(opts, :broken_partitions, []), &{&1.partition, &1})
        )
    }
    |> JSON.encode!()
  end

  defp thresholds(nil), do: %{high: @default_high, low: @default_low}

  defp thresholds(min_score) do
    n = round(min_score)
    %{high: n, low: n}
  end

  # `entries` are results and pending sites together, each file's in id order.
  defp files(entries, sources, broken) do
    entries
    |> Enum.group_by(&site(&1).file)
    |> Map.new(fn {file, file_entries} ->
      {file,
       %{
         language: "elixir",
         source: Map.get(sources, file, ""),
         mutants: file_entries |> Enum.sort_by(&site(&1).id) |> Enum.map(&mutant(&1, broken))
       }}
    end)
  end

  defp site(%Result{site: site}), do: site
  defp site(%Site{} = site), do: site

  defp mutant(%Site{} = site, _broken) do
    site
    |> base_mutant()
    |> Map.put(:status, "Pending")
    |> put_present(:description, site.note)
  end

  defp mutant(%Result{site: site} = result, broken) do
    site
    |> base_mutant()
    |> Map.put(:status, Status.fetch!(result.status).json)
    |> put_present(:statusReason, status_reason(result, broken))
    |> put_present(:description, site.note)
    |> put_present(:duration, result.duration_ms)
    |> put_present(:testSelection, selection(result.selection))
    # Mutare's addition, like `testSelection`: the partition (`--partition-db`) the
    # mutant's run used, absent when partitioning was off or no run launched.
    |> put_present(:partition, result.partition)
  end

  defp base_mutant(%Site{} = site) do
    %{
      id: to_string(site.id),
      mutatorName: to_string(site.mutator),
      replacement: site.mutated_code || "",
      location: location(site.range)
    }
    |> put_present(:position, position(site))
  end

  # Mutare's addition to the schema's `MutantResult`, beside `testSelection`: the Site's own
  # `line:column` (`Mutare.Site.position/1`), not the start of the patched span `location`
  # holds — see the moduledoc.
  defp position(%Site{line: nil}), do: nil
  defp position(%Site{line: line, column: nil}), do: %{line: line}
  defp position(%Site{line: line, column: column}), do: %{line: line, column: column}

  # Mutare's addition to the schema's `MutantResult` (the schema permits extra
  # properties; the report web component ignores them): which tests the mutant's run
  # covered — `Mutare.Result.selection/0` by name — so a tool over the report can find
  # the mutants that ran the whole suite. Absent for a mutant that launched no run.
  defp selection(nil), do: nil
  defp selection(shape) when is_atom(shape), do: Atom.to_string(shape)

  defp status_reason(%Result{status: :harness_error} = result, _broken),
    do: HarnessDiagnostic.summary(result)

  defp status_reason(%Result{status: status, partition: partition} = result, broken) do
    case Result.kill?(status) && Map.get(broken, partition) do
      %{} = broken_partition -> false_kill_reason(broken_partition)
      _not_a_false_kill -> result.site.ignore_reason
    end
  end

  defp false_kill_reason(%{partition: partition} = broken) do
    "This kill may be false: on partition #{partition}, where it ran, with no mutant " <>
      "active, #{Report.rerun_failure(broken)}"
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
