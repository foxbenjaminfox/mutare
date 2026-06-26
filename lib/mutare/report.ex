defmodule Mutare.Report do
  @moduledoc """
  Turns results into the product: a list of surviving mutants, each rendered as
  a diff at `file:line`.

  Diffs are patched against the **original** source via `Sourceror.patch_string`
  at the site's recorded range, so the rest of every line stays byte-identical
  and a survivor reads as a precise one-line change.
  """

  alias Mutare.{Result, Site}

  @doc "Apply a single mutation to the original source string."
  @spec patch(Site.t(), String.t()) :: String.t()
  def patch(%Site{} = site, source) do
    Sourceror.patch_string(source, [Sourceror.Patch.new(site.range, site.mutated_code)])
  end

  @doc """
  Header line for a surviving mutant, e.g. `lib/x.ex:42  [relational, in-place]  SURVIVED`.

  A mutation that carries a `note` (a hosting mutator's advisory, e.g. "kill may require
  NULL/boundary data") appends it as a trailing `— note`, like an ignored mutant's reason — so a
  survivor that may be legitimately hard to kill reads as honest signal, not just a test gap.
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
  A `-`/`+` diff of the line(s) the mutation touches.

  Computed by a **line-based** diff (`List.myers_difference/2`) between the
  original and patched text *within* the site's line span, so only the lines that
  actually change are shown as `-`/`+`; unchanged lines inside a multi-line
  fragment appear as ` ` context. This matters for a mutation that removes (or
  adds) a line in the middle of a multi-line fragment — e.g. an Ecto `:hosted`
  swap dropping one `where:` from a big `from` block: a naive line-by-line
  pairing would re-emit every following line as a spurious delete+insert (they
  "shift" past the removal), whereas the diff aligns the unchanged lines and
  shows just the dropped one. A single-line swap still renders as a clean
  `-old`/`+new` pair.
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
  Render the whole report from results and a `%{file => original_source}` map.
  """
  @spec render([Result.t()], %{optional(String.t()) => String.t()}) :: String.t()
  def render(results, sources) do
    survivors = Enum.filter(results, &(&1.status == :survived))

    blocks =
      Enum.map_join(survivors, "\n\n", fn %Result{site: site} ->
        survivor(site, Map.fetch!(sources, site.file))
      end)

    [survivor_section(survivors, blocks), ignored_section(results), summary(results)]
    |> Enum.reject(&(&1 == ""))
    |> Enum.join("\n\n")
  end

  @doc """
  Conform to the machine reporters' `(results, sources, opts)` signature so all
  four formats dispatch uniformly. The human report ignores `opts` — the score
  gate is applied separately by the Mix task, not rendered here.
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
  without a trailing `%`. The single home for the score/percent number format.

      iex> Mutare.Report.percent(2 / 3 * 100)
      "66.7"
  """
  @spec percent(number()) :: String.t()
  def percent(value), do: :erlang.float_to_binary(value / 1, decimals: 1)

  @doc """
  Whether `results` meet a minimum score (a percentage). A `nil` minimum always
  passes — this is the CI gate's decision, kept pure here so it is testable.

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
  Fraction (0.0..1.0) of the mutants that actually *ran* which ended in a
  `:harness_error`.

  "Ran" is `:killed`/`:survived`/`:timeout`/`:atom_exhausted`/`:harness_error` —
  the runs that reached (or tried to reach) a verdict. `:no_coverage`/`:ignored`/
  `:poisoned` never launched a `mix test`, so they are not part of this
  denominator: this rate measures how broken the *running* was, not how much was
  skipped. Returns `0.0` when nothing ran. The runner compares it to
  `:max_harness_error_rate` to decide whether to abort; kept pure here so it is
  testable (cf. `passes_gate?/2`).

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
  Whether `harness_error_rate/1` exceeds `max_rate` (a fraction in 0.0..1.0). A
  `nil` `max_rate` disables the check (always `false`).

  This is the runner's abort decision, kept pure here so it is testable — the
  mirror of `passes_gate?/2` for the harness-error guard. When it is `true` the
  score would be computed over a denominator hollowed out by infrastructure
  failures, so the run aborts rather than report it.
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
    killed = count(counts, :killed)
    timeout = count(counts, :timeout)
    atom_exhausted = count(counts, :atom_exhausted)
    survived = count(counts, :survived)
    no_coverage = count(counts, :no_coverage)
    ignored = count(counts, :ignored)
    poisoned = count(counts, :poisoned)
    harness_error = count(counts, :harness_error)
    total = total(counts)

    tally =
      [
        "#{killed} killed",
        if(timeout > 0, do: "#{timeout} timeout"),
        if(atom_exhausted > 0, do: "#{atom_exhausted} atom-table"),
        "#{survived} survived",
        if(no_coverage > 0, do: "#{no_coverage} no-coverage"),
        if(ignored > 0, do: "#{ignored} ignored"),
        if(poisoned > 0, do: "#{poisoned} poisoned"),
        if(harness_error > 0, do: "#{harness_error} harness-error"),
        "#{total} total"
      ]
      |> Enum.reject(&is_nil/1)
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

  # The `""` default of `Enum.at/3` is unreachable: callers only request lines
  # within the site's range, always in-file, so the fallback never fires and its
  # `"" -> "mutare"` mutant can't be killed. Scoped to `[string]` so the genuinely
  # tested index arithmetic (`n - 1`) on this line still runs (and is killed).
  # mutare:ignore[string] the "" fallback is unreachable; ranges are always in-file
  defp line_at(lines, n), do: Enum.at(lines, n - 1, "")

  defp tally(results), do: Enum.frequencies_by(results, & &1.status)

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

  defp total(counts), do: counts |> Map.values() |> Enum.sum()
end
