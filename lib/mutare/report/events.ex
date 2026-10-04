defmodule Mutare.Report.Events do
  @version 1

  @moduledoc """
  The events of `mix mutare --events FILE`: one JSON object per line, appended as the run goes,
  so a consumer can follow a run with `tail -f` and filter it a line at a time
  (`jq -c 'select(.status == "survived")'`). The JSON report is the complete record of a
  finished run; this is the record of one in progress.

  Every event has an `event` name and `elapsed_ms`, the milliseconds since the run started.
  In order:

    * `start` — the run has started, and its scan with it. `version` is this format's version
      (#{@version}), `mutare` the Mutare version.
    * `scanned` — the scan is done: `mutants` will be tested, from `files` files.
    * `phase` — the run entered `phase`: `compiling`, `baseline`, `coverage_probe`, `running`
      (with `mutants`, the number it will test), `confirming_timeouts` (with `mutants`, the
      number of provisional timeouts to re-run one at a time), and, under `--partition-env`,
      `checking_partitions` (with `partitions`, the number whose environment it re-runs one
      kill's tests in with no mutant active).
    * `mutant` — one mutant's verdict, written once the run accepts it. The run tests several
      mutants at once but accepts their verdicts in source order, so a slow mutant holds back
      the lines of mutants after it that have already finished: a quiet file does not mean no
      mutant has finished. A provisional timeout is re-run alone after the others
      (`confirming_timeouts`), so its line comes at the end. Fields:
      * `evaluated` — how many `mutant` lines the file holds, this one included: against the
        `scanned` count, how far the run has got;
      * `id` — the report id, an integer: the JSON report's `id`, which that report writes as
        a string;
      * `file`, `line`, `column` — where the mutant is: the location the human report prints,
        `--line` selects by, and `# mutare:ignore` reads;
      * `mutator`, `variant` — the family, and the variant labels its
        `# mutare:ignore[family:label]` filters match (a list, empty when the family declares
        none);
      * `status` — one of #{Mutare.Result.Status.names() |> Enum.map_join(", ", &"`#{&1}`")};
      * `range`, `original`, `replacement` — the patch: `original` is the source text between
        `range.start` and `range.end` (1-based, `end` exclusive), and `replacement` the text that
        takes its place, exactly as the human report's diff applies it. A replacement may cover
        more than it changes: removing a pipe stage rewrites the whole pipe, while `line` and
        `column` point at the stage. A column, here and in `column`, counts graphemes, as
        Elixir's columns do — not bytes, code points or UTF-16 units — so on a line with
        non-ASCII text, slice by graphemes or find `original` on the line;
      * `duration_ms`, `selection` — how long the mutant's test run took, and which tests it ran
        (`tests`, `files`, `app` or `suite`); absent for a mutant that launched no run (one
        `no_coverage`, `ignored` or `poisoned`);
      * `note`, `reason` — an advisory note from the mutator, and why a mutant was ignored or why
        its run reached no verdict; each absent when there is none.
    * `finish` — the last line, written once the reports are. `stopped` says why: `complete`,
      `max_survivors`, `time_budget`, `sigterm`, or `error`. All but `error` carry `mutants`
      (the number the run set out to test; `null` if a SIGTERM stopped the scan),
      `evaluated`, `counts` (every status, zeros included) and `score`, over the mutants
      evaluated. An `error` carries `error`, the reason's name (`baseline_failed`,
      `compile_failed`, …, and `aborted` for an abort with no reason of its own, such as a bad
      `# mutare:ignore` qualifier or `--strict-ignores`), and
      `message`, the text `mix mutare` prints. An `error` writes no final report, so a report
      file holds what it held before: an earlier run's report, or, when the error came after
      mutants had run (`too_many_harness_errors`), possibly this run's last checkpoint, with
      the mutants it had not tested `Pending`. A SIGTERM that arrives while the final reports
      are being written stops the writes: each report is then either its final version or the
      last checkpoint, which may hold fewer verdicts than the `finish` counts.

  A file that ends without a `finish` belongs to a run that is still going or died without
  stopping cleanly — a SIGKILL or a crash; its stderr says which.

  Object keys are not in a fixed order, and a later version may add fields and events: a
  consumer ignores the ones it does not know. A change that would mislead such a consumer
  bumps `version`.
  """

  alias Mutare.{Result, Schema, Score, Site}
  alias Mutare.Report.HarnessDiagnostic
  alias Mutare.Result.Status

  @typedoc "Why a run stopped, as a `finish` event names it."
  @type stopped :: :complete | :max_survivors | :time_budget | :sigterm

  # The `start` event.
  @doc false
  @spec start() :: map()
  def start do
    %{event: "start", version: @version, mutare: mutare_version()}
  end

  defp mutare_version do
    case Application.spec(:mutare, :vsn) do
      nil -> nil
      vsn -> to_string(vsn)
    end
  end

  # The `scanned` event for `schema`.
  @doc false
  @spec scanned(Schema.t()) :: map()
  def scanned(%Schema{} = schema) do
    %{event: "scanned", mutants: Schema.count(schema), files: map_size(schema.metamutants)}
  end

  # The event for a runner `:on_phase` notification, or `nil` for one this format does not
  # record (the detail events `--verbose` renders).
  @doc false
  @spec phase(term()) :: map() | nil
  def phase(phase) when phase in [:compiling, :baseline, :coverage_probe],
    do: %{event: "phase", phase: Atom.to_string(phase)}

  def phase({:running, total}), do: %{event: "phase", phase: "running", mutants: total}

  def phase({:confirming_timeouts, count}),
    do: %{event: "phase", phase: "confirming_timeouts", mutants: count}

  def phase({:checking_partitions, count}),
    do: %{event: "phase", phase: "checking_partitions", partitions: count}

  def phase(_detail), do: nil

  # The `mutant` event for `result`, whose file's source is `source`, the `evaluated`th such
  # event of the run.
  @doc false
  @spec mutant(Result.t(), String.t(), pos_integer()) :: map()
  def mutant(%Result{site: %Site{} = site} = result, source, evaluated)
      when is_binary(source) and is_integer(evaluated) and evaluated > 0 do
    {original, replacement} = patch(site, source)

    %{
      event: "mutant",
      evaluated: evaluated,
      id: site.id,
      file: site.file,
      line: site.line,
      column: site.column,
      mutator: Atom.to_string(site.mutator),
      variant: site.variant,
      status: Atom.to_string(result.status),
      range: %{start: point(site.range.start), end: point(site.range.end)},
      original: original,
      replacement: replacement
    }
    |> Map.merge(test_run(result))
    |> put_present(:note, site.note)
    |> put_present(:reason, reason(result))
  end

  # A run's duration and selection, or nothing for a mutant that launched no run: the runner
  # records those with a `duration_ms` of 0 and no selection.
  defp test_run(%Result{selection: nil}), do: %{}

  defp test_run(%Result{selection: selection, duration_ms: duration_ms}),
    do: %{duration_ms: duration_ms, selection: Atom.to_string(selection)}

  defp point(position), do: %{line: position[:line], column: position[:column]}

  # The source text in the site's range, and the text the patch puts there. Both are read off
  # `Mutare.Report.patch/2`, the patch the human report diffs, so the event cannot disagree with
  # it: `Sourceror.patch_string/2` re-indents a multi-line replacement to its first line, which
  # makes the spliced text differ from `mutated_code`. The source on either side of the range is
  # what a patch at that range leaves alone, found by patching a marker over it.
  @marker "\0mutare-range\0"

  defp patch(%Site{} = site, source) do
    [before, after_range] =
      source
      |> Sourceror.patch_string([Sourceror.Patch.new(site.range, @marker)])
      |> String.split(@marker)

    {between(source, before, after_range),
     between(Mutare.Report.patch(site, source), before, after_range)}
  end

  defp between(text, before, after_range) do
    binary_part(
      text,
      byte_size(before),
      byte_size(text) - byte_size(before) - byte_size(after_range)
    )
  end

  # The JSON report's `statusReason`: a harness error's diagnosis, else an ignore's reason.
  defp reason(%Result{status: :harness_error} = result), do: HarnessDiagnostic.summary(result)
  defp reason(%Result{site: site}), do: site.ignore_reason

  # The `finish` event of a run that stopped for `stopped`, having set out to test `mutants`
  # mutants (`nil` if the scan had not counted them yet) and evaluated mutants whose statuses
  # tally to `counts` (as `Enum.frequencies_by(results, & &1.status)` gives it).
  @doc false
  @spec finish(stopped(), non_neg_integer() | nil, %{optional(Result.status()) => pos_integer()}) ::
          map()
  def finish(stopped, mutants, counts)
      when stopped in [:complete, :max_survivors, :time_budget, :sigterm] and is_map(counts) do
    %{
      event: "finish",
      stopped: Atom.to_string(stopped),
      mutants: mutants,
      evaluated: counts |> Map.values() |> Enum.sum(),
      counts: Map.new(Status.names(), &{Atom.to_string(&1), Map.get(counts, &1, 0)}),
      score: Float.round(Score.score_counts(counts), 1)
    }
  end

  # The `finish` event of a run that ended in the error `reason`, explained by `message`.
  @doc false
  @spec error(atom(), String.t()) :: map()
  def error(reason, message) when is_atom(reason) and is_binary(message) do
    %{event: "finish", stopped: "error", error: Atom.to_string(reason), message: message}
  end

  # `event` as one line of the file, stamped with `elapsed_ms`.
  @doc false
  @spec encode(map(), non_neg_integer()) :: String.t()
  def encode(%{event: _} = event, elapsed_ms) do
    JSON.encode!(Map.put(event, :elapsed_ms, elapsed_ms)) <> "\n"
  end

  defp put_present(map, _key, nil), do: map
  defp put_present(map, key, value), do: Map.put(map, key, value)
end
