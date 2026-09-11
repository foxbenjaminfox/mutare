defmodule Mutare.Report do
  @moduledoc """
  Renders mutation results for the human report.

  Diffs are patched against the original source via `Sourceror.patch_string` at the site's recorded range, so untouched source stays byte-identical and a survivor reads as a precise source-range change.

  The numbers the report prints — the mutation score and its tallies — come from `Mutare.Score`, which also owns the CI gates; this module only renders.
  """

  alias Mutare.{Result, Score, Site}
  alias Mutare.Report.HarnessDiagnostic
  alias Mutare.Result.Status

  @doc "Apply a single mutation to the original source string."
  @spec patch(Site.t(), String.t()) :: String.t()
  def patch(%Site{} = site, source) do
    Sourceror.patch_string(source, [Sourceror.Patch.new(site.range, site.mutated_code)])
  end

  @doc """
  Header line for a surviving mutant, e.g.
  `lib/x.ex:42  [relational, in-place]  SURVIVED`.

  A mutation with a note appends it as a trailing `— note`, matching the ignored
  mutant reason format.
  """
  @spec header(Site.t()) :: String.t()
  def header(%Site{} = site) do
    "#{site.file}:#{site.line}  [#{site.mutator}, #{kind(site.kind)}]  SURVIVED#{optional_suffix(site.note)}"
  end

  # The trailing "  — <text>" appended to a SURVIVED/IGNORED line for a Site's note or ignore
  # reason; empty when the field is absent.
  defp optional_suffix(nil), do: ""
  defp optional_suffix(text), do: "  — #{text}"

  defp kind(:in_place), do: "in-place"
  defp kind(:lifted), do: "lifted"

  @doc """
  A `-`/`+` diff of the lines touched by the mutation.

  The diff is line-based within the site's source range. Changed lines are shown
  as deletions and insertions; unchanged lines inside a multi-line fragment are
  shown as context. This keeps multi-line replacements aligned when a mutation adds
  or removes a line in the middle of the fragment.
  """
  @spec diff(Site.t(), String.t()) :: String.t()
  def diff(%Site{operation: :delete} = site, source) do
    # Clause-drop: the whole clause is removed, so show its lines as deletions.
    lines = String.split(source, "\n")

    site.range.start[:line]..site.range.end[:line]
    |> Enum.map_join("\n", &("-" <> line_at(lines, &1)))
  end

  def diff(%Site{} = site, source) do
    original_lines = String.split(source, "\n")
    patched_lines = String.split(patch(site, source), "\n")

    first = site.range.start[:line]
    last = site.range.end[:line]
    # The patch replaces only the bytes within the site range, so every line after
    # `last` shifts by the change in total line count: the patched fragment occupies
    # the same first line through `last + delta`. Diffing the two windows against each
    # other (rather than pairing line `n` with line `n`) keeps the unchanged tail aligned.
    patched_last = last + (length(patched_lines) - length(original_lines))

    window(original_lines, first, last)
    |> List.myers_difference(window(patched_lines, first, patched_last))
    |> Enum.flat_map(&diff_lines/1)
    |> Enum.join("\n")
  end

  # The lines `first..last` (1-based, inclusive) of an already-split source.
  defp window(lines, first, last), do: Enum.slice(lines, (first - 1)..(last - 1)//1)

  # Render one Myers edit chunk: kept lines as ` ` context, removed as `-`, added as `+`.
  defp diff_lines({:eq, lines}), do: Enum.map(lines, &(" " <> &1))
  defp diff_lines({:del, lines}), do: Enum.map(lines, &("-" <> &1))
  defp diff_lines({:ins, lines}), do: Enum.map(lines, &("+" <> &1))

  @doc "Full diff block (header + diff) for one survivor."
  @spec survivor(Site.t(), String.t()) :: String.t()
  def survivor(%Site{} = site, source) do
    header(site) <> "\n" <> diff(site, source)
  end

  @doc """
  One line for an ignored mutant, e.g.
  `lib/x.ex:42  [arithmetic]  IGNORED  — off-by-one is intentional`.

  The trailing `— reason` is present only when the directive carried one, so a
  bare `# mutare:ignore` reads as `… IGNORED` with nothing after it.
  """
  @spec ignored(Site.t()) :: String.t()
  def ignored(%Site{} = site) do
    "#{site.file}:#{site.line}  [#{site.mutator}]  IGNORED#{optional_suffix(site.ignore_reason)}"
  end

  @doc """
  One line for a harness-errored mutant, including a compact diagnostic.
  """
  @spec harness_error(Result.t()) :: String.t()
  def harness_error(%Result{site: %Site{} = site} = result) do
    "#{site.file}:#{site.line}  [#{site.mutator}]  HARNESS_ERROR  — " <>
      HarnessDiagnostic.summary(result)
  end

  @doc """
  Render the whole report from results and a `%{file => original_source}` map.
  """
  @spec render([Result.t()], %{optional(String.t()) => String.t()}) :: String.t()
  def render(results, sources) do
    survivors = Enum.filter(results, &(&1.status == :survived))

    blocks =
      Enum.map_join(survivors, "\n\n", fn %Result{site: site} ->
        survivor(site, Map.fetch!(sources, site.file))
      end)

    [
      survivor_section(survivors, blocks),
      ignored_section(results),
      harness_error_section(results),
      summary(results)
    ]
    |> Enum.reject(&(&1 == ""))
    |> Enum.join("\n\n")
  end

  @doc """
  Renders the human report with the same arity as machine reporters.

  `opts` is ignored; score gating is handled by the caller.
  """
  @spec render([Result.t()], %{optional(String.t()) => String.t()}, keyword()) :: String.t()
  def render(results, sources, _opts), do: render(results, sources)

  @doc """
  One-line tally, e.g. `mutation score: 66.7%  (2 killed, 1 survived, 3 total)`.

      iex> Mutare.Report.summary([
      ...>   %Mutare.Result{status: :killed},
      ...>   %Mutare.Result{status: :survived}
      ...> ])
      "mutation score: 50.0%  (1 killed, 1 survived, 2 total)"
  """
  @spec summary([Result.t()]) :: String.t()
  def summary(results) do
    counts = Enum.frequencies_by(results, & &1.status)

    # One labelled count per status, in the registry's render order; the unusual
    # statuses (everything but `:killed`/`:survived`, which are `always_in_summary?`)
    # appear only when nonzero. Driven by `Mutare.Result.Status` so a new status is
    # tallied without editing this list (CLAUDE.md "Result statuses").
    tally =
      Status.all()
      |> Enum.flat_map(fn descriptor ->
        n = Map.get(counts, descriptor.name, 0)

        if descriptor.always_in_summary? or n > 0,
          do: ["#{n} #{descriptor.summary_label}"],
          else: []
      end)
      |> Kernel.++(["#{length(results)} total"])
      |> Enum.join(", ")

    "mutation score: #{Score.percent(Score.score(results))}%  (#{tally})"
  end

  # --- internals -----------------------------------------------------------

  # Equivalent mutant: dropping this clause changes nothing. With no survivors,
  # `blocks` is already "" (an empty `Enum.map_join`), so the general clause
  # returns "" too. Unkillable — scoped to the clause-drop so the `"" -> "mutare"`
  # string sibling (killed by the no-survivors render test) still counts.
  # mutare:ignore[clause_drop] the general clause already returns "" for no survivors
  defp survivor_section([], _blocks), do: ""
  defp survivor_section(_survivors, blocks), do: blocks

  # The `# mutare:ignore` roll-call: one line per ignored mutant, each carrying
  # its reason (when given), so an exclusion documents itself in the output. Empty
  # when nothing was ignored — `render/2` then drops the blank section.
  defp ignored_section(results) do
    results
    |> Enum.filter(&(&1.status == :ignored))
    |> Enum.map_join("\n", fn %Result{site: site} -> ignored(site) end)
  end

  # Harness errors are infrastructure failures, not survivor diffs. List them so
  # the final report carries the same triage clue the live warning did.
  defp harness_error_section(results) do
    results
    |> Enum.filter(&(&1.status == :harness_error))
    |> Enum.map_join("\n", &harness_error/1)
  end

  # The `""` default of `Enum.at/3` is unreachable: callers only request lines
  # within the site's range, always in-file, so the fallback never fires. Neither
  # swapping it (`"" -> "mutare"`) nor dropping it (`Enum.at/2`, which returns `nil`)
  # is observable. Scoped to `[string, default_drop]` so the genuinely tested index
  # arithmetic (`n - 1`) on this line still runs (and is killed).
  # mutare:ignore[string, default_drop] the "" fallback is unreachable; ranges are always in-file
  defp line_at(lines, n), do: Enum.at(lines, n - 1, "")
end
