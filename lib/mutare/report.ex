defmodule Mutare.Report do
  @moduledoc """
  Renders mutation results for the human report.

  Diffs are patched against the original source via `Sourceror.patch_string` at the site's recorded range, so untouched source stays byte-identical and a survivor reads as a precise source-range change.
  """

  alias Mutare.{Result, Site}
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
  Mutation score as a percentage:
  `killed / (total − no_coverage − ignored − poisoned − harness_error)`.
  Returns `100.0` when the denominator is zero (nothing to test).

      iex> results = [
      ...>   %Mutare.Result{status: :killed},
      ...>   %Mutare.Result{status: :survived},
      ...>   %Mutare.Result{status: :no_coverage}
      ...> ]
      iex> Mutare.Report.score(results)
      50.0
  """
  @spec score([Result.t()]) :: float()
  def score(results) do
    results
    |> tally()
    |> score_from_tally()
  end

  @doc """
  Format a percentage value (already on a 0..100 scale) to one decimal place,
  without a trailing `%`.

      iex> Mutare.Report.percent(2 / 3 * 100)
      "66.7"
  """
  @spec percent(number()) :: String.t()
  def percent(value), do: :erlang.float_to_binary(value / 1, decimals: 1)

  @doc """
  Returns whether `results` meet a minimum score percentage.

  A `nil` minimum always passes.

      iex> results = [%Mutare.Result{status: :killed}, %Mutare.Result{status: :survived}]
      iex> Mutare.Report.passes_gate?(results, 60)
      false
      iex> Mutare.Report.passes_gate?(results, nil)
      true
  """
  @spec passes_gate?([Result.t()], number() | nil) :: boolean()
  def passes_gate?(_results, nil), do: true
  def passes_gate?(results, min_score), do: score(results) >= min_score

  @doc """
  Human-readable failures for complete-run CI gates.

  These gates are separate from score semantics: `:no_coverage`, `:poisoned`,
  and `:harness_error` stay out of the mutation-score denominator, but a caller
  can still make them fatal for CI. `opts` may be a keyword list or an options
  map carrying:

    * `:min_score` — minimum mutation score percentage, or `nil`
    * `:max_no_coverage` — maximum allowed `:no_coverage` count, or `nil`
    * `:fail_on_poisoned` — fail if any mutant is `:poisoned`
    * `:fail_on_harness_error` — fail if any mutant is `:harness_error`
  """
  @spec gate_failures([Result.t()], keyword() | map()) :: [String.t()]
  def gate_failures(results, opts \\ []) do
    counts = tally(results)

    [
      score_gate_failure(results, gate_opt(opts, :min_score)),
      max_count_gate_failure(count(counts, :no_coverage), gate_opt(opts, :max_no_coverage)),
      fail_on_status_failure(
        count(counts, :poisoned),
        gate_opt(opts, :fail_on_poisoned, false),
        "poisoned",
        "--fail-on-poisoned"
      ),
      fail_on_status_failure(
        count(counts, :harness_error),
        gate_opt(opts, :fail_on_harness_error, false),
        "harness-error",
        "--fail-on-harness-error"
      )
    ]
    |> Enum.reject(&is_nil/1)
  end

  @doc """
  Fraction of launched mutant runs that ended in `:harness_error`.

  The denominator includes `:killed`, `:survived`, `:timeout`,
  `:atom_exhausted`, and `:harness_error`. It excludes `:no_coverage`,
  `:ignored`, and `:poisoned`, which never launch a test run. Returns `0.0`
  when nothing ran.

      iex> results = [
      ...>   %Mutare.Result{status: :killed},
      ...>   %Mutare.Result{status: :harness_error},
      ...>   %Mutare.Result{status: :no_coverage}
      ...> ]
      iex> Mutare.Report.harness_error_rate(results)
      0.5
  """
  @spec harness_error_rate([Result.t()]) :: float()
  def harness_error_rate(results) do
    counts = tally(results)
    errors = count(counts, :harness_error)
    ran = count_where(counts, &Result.ran?/1)

    if ran == 0, do: 0.0, else: errors / ran
  end

  @doc """
  Returns whether `harness_error_rate/1` exceeds `max_rate`.

  `max_rate` is a fraction from `0.0` to `1.0`. A `nil` value disables the
  check and returns `false`.
  """
  @spec harness_errors_exceed?([Result.t()], number() | nil) :: boolean()
  # Equivalent mutant: dropping this clause changes nothing. The fallback clause
  # would then compute `harness_error_rate(results) > nil`, and a number always
  # sorts before `nil` in Erlang term order, so the result is `false` for a nil
  # `max_rate` either way. Unkillable — scoped to the clause-drop so the
  # `false -> true` literal sibling (killed by the nil test) still counts.
  # mutare:ignore[clause_drop] falls through to the same false for a nil max_rate
  def harness_errors_exceed?(_results, nil), do: false
  def harness_errors_exceed?(results, max_rate), do: harness_error_rate(results) > max_rate

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
    counts = tally(results)

    # One labelled count per status, in the registry's render order; the unusual
    # statuses (everything but `:killed`/`:survived`, which are `always_in_summary?`)
    # appear only when nonzero. Driven by `Mutare.Result.Status` so a new status is
    # tallied without editing this list (CLAUDE.md "Result statuses").
    tally =
      Status.all()
      |> Enum.flat_map(fn descriptor ->
        n = count(counts, descriptor.name)

        if descriptor.always_in_summary? or n > 0,
          do: ["#{n} #{descriptor.summary_label}"],
          else: []
      end)
      |> Kernel.++(["#{total(counts)} total"])
      |> Enum.join(", ")

    score = score_from_tally(counts)
    "mutation score: #{percent(score)}%  (#{tally})"
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

  defp tally(results), do: Enum.frequencies_by(results, & &1.status)

  defp gate_opt(opts, key, default \\ nil)
  defp gate_opt(opts, key, default) when is_list(opts), do: Keyword.get(opts, key, default)
  # Equivalent mutant: `opts` is always a keyword list or a map (per `gate_failures/2`'s
  # spec), and the `is_list` clause above already claimed every list — so this last clause
  # only ever runs for maps, whether or not its `is_map` guard remains. Scoped to
  # `[guard_drop]` so the `default` drop (a real map-default path) stays killable.
  # mutare:ignore[guard_drop] opts is always keyword|map; the is_list clause owns lists
  defp gate_opt(opts, key, default) when is_map(opts), do: Map.get(opts, key, default)

  # Equivalent mutant: dropping this clause changes nothing. A nil `min_score` then
  # reaches the general clause, where `passes_gate?(results, nil)` is true (a nil minimum
  # always passes), so `unless true` yields nil either way. Scoped to the clause-drop so
  # the `unless` condition mutant on the general clause stays killable.
  # mutare:ignore[clause_drop] passes_gate?(_, nil) is true, so the general clause also returns nil
  defp score_gate_failure(_results, nil), do: nil

  defp score_gate_failure(results, min_score) do
    unless passes_gate?(results, min_score) do
      "mutation score #{percent(score(results))}% is below the required minimum of #{percent(min_score)}%"
    end
  end

  # Equivalent mutant: dropping this clause changes nothing. A nil `max` then reaches the
  # `n <= max` clause, and a number always sorts before an atom in Erlang term order, so
  # `n <= nil` is true and it returns nil either way. Scoped to the clause-drop so the
  # `n <= max` boundary guard stays killable.
  # mutare:ignore[clause_drop] n <= nil is always true, so the guarded clause also returns nil
  defp max_count_gate_failure(_n, nil), do: nil
  defp max_count_gate_failure(n, max) when n <= max, do: nil

  defp max_count_gate_failure(n, max) do
    "#{n} no-coverage mutant#{plural(n)} #{exceed(n)} the allowed maximum of #{max}"
  end

  defp fail_on_status_failure(0, _enabled, _label, _flag), do: nil
  defp fail_on_status_failure(_n, false, _label, _flag), do: nil

  defp fail_on_status_failure(n, true, label, flag) do
    "#{n} #{label} mutant#{plural(n)} #{present(n)} and #{flag} is set"
  end

  defp score_from_tally(counts) do
    # Kills (numerator) and the scored set (denominator) are classified by `Mutare.Result`:
    # a timeout/atom-exhaustion is a kill, while no-coverage/ignored/poisoned/harness-error
    # reach no verdict and are excluded from the denominator.
    killed = count_where(counts, &Result.kill?/1)
    denominator = count_where(counts, &Result.scored?/1)

    if denominator <= 0, do: 100.0, else: killed / denominator * 100
  end

  defp count(counts, status), do: Map.get(counts, status, 0)

  # Sum a frequency map's values over the statuses a predicate admits.
  defp count_where(counts, pred) do
    for {status, n} <- counts, pred.(status), reduce: 0, do: (acc -> acc + n)
  end

  defp plural(1), do: ""
  defp plural(_), do: "s"

  defp exceed(1), do: "exceeds"
  defp exceed(_), do: "exceed"

  defp present(1), do: "is present"
  defp present(_), do: "are present"

  defp total(counts), do: counts |> Map.values() |> Enum.sum()
end
