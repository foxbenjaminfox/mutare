defmodule Mutare.CLI.Outcome do
  @moduledoc false
  # The run-outcome presentation of `mix mutare`, extracted from `Mix.Tasks.Mutare`: `report/3`
  # emits every configured reporter and applies the post-report CI gates (or notes an early stop);
  # `checkpoint/3` and `report_interrupted/5` write the partial reports of a run still in
  # progress (`Mutare.CLI.PartialReport`);
  # `warn_poison_recovery/1` prints the durable `:call_routes` fix after a poison-recovered run; and
  # `format_error/3` renders each terminal `{:error, reason, detail}` into the message the task
  # `Mix.raise`s; `scope/2` names the flags a scoped run's score is over. All output is the
  # task's (stdout report, stderr notes) — this only builds it.

  alias Mutare.{CLI, Options, Run, Schema, Score}
  alias Mutare.Poison.Hint
  alias Mutare.Sandbox.Command.Output
  alias Mutare.Sandbox.DependencyDiagnostic

  # After a run that recovered from compile-poisoning by escalating (skipping wholesale)
  # one or more unknown block macros, print the durable `:call_routes` fix — the extra
  # rebuilds are in-memory only and paid again every run, so pinning the routes saves them.
  # Onto **stderr** (like the ineffective-ignore warnings), so a machine report on stdout
  # stays clean. Only escalations earn a note: an id-specific poison drop is a one-off (a
  # custom mutator emitting bad code), not a stable per-macro fact worth pinning.
  def warn_poison_recovery(%Run{recovery: nil}), do: :ok

  def warn_poison_recovery(%Run{recovery: recovery}) do
    [
      Hint.escalation_note(Map.get(recovery, :escalated, [])),
      Hint.macro_skip_note(Map.get(recovery, :macro_skipped, []))
    ]
    |> Enum.reject(&is_nil/1)
    |> Enum.each(fn note -> IO.puts(:stderr, "\n" <> note) end)
  end

  # The flags that chose which of the project's mutants a run tests, as the user wrote them, for
  # the human report to set beside its score — a scoped run's score is over those mutants alone.
  # `nil` for a run over the whole project. `--max-mutants` is read from `options`, since
  # `.mutare.exs` may set it too; a repeatable flag lists its first values, then counts the rest.
  @doc false
  @spec scope(keyword(), Options.t()) :: String.t() | nil
  def scope(flags, %Options{} = options) do
    [
      Enum.map(List.wrap(flags[:since]), &"--since #{&1}"),
      repeated(flags, :only),
      repeated(flags, :exclude),
      repeated(flags, :line),
      Enum.map(List.wrap(options.max_mutants), &"--max-mutants #{&1}")
    ]
    |> List.flatten()
    |> case do
      [] -> nil
      parts -> Enum.join(parts, " ")
    end
  end

  @listed_values 3

  defp repeated(flags, key) do
    flag = "--#{key}"

    case Keyword.get_values(flags, key) do
      values when length(values) <= @listed_values ->
        Enum.map(values, &"#{flag} #{&1}")

      values ->
        {listed, rest} = Enum.split(values, @listed_values)
        Enum.map(listed, &"#{flag} #{&1}") ++ ["(+#{length(rest)} more #{flag})"]
    end
  end

  def report(run, %Options{} = options, scope) do
    # The runner checks partitions after the stream, so every run it returns has
    # `broken_partitions`, one stopped early included (whose reports list them, though
    # `finish_run/2` skips its gate). Checkpoints and an interrupted run's reports are
    # written before that check, so they have none.
    emit_all(run.results, run.schema, options,
      scope: scope,
      broken_partitions: run.broken_partitions
    )

    finish_run(run, options)
  end

  # A `--since` run whose changed lines hold no mutation site. The reporters still
  # write — empty — so a CI step that uploads a report file finds one, and the gates
  # still apply: over no results they pass (`Mutare.Score` scores an empty denominator
  # at 100), as they would for a run whose every mutant went uncovered.
  def report_unchanged(%Schema{} = schema, since, %Options{} = options, scope) do
    Mix.shell().info(unchanged_note(since))
    emit_all([], schema, options, scope: scope)
    gate([], options)
  end

  def unchanged_note(since),
    do: "no mutation sites on lines changed since #{since}; nothing to test"

  # `report_opts` are renderer options beyond the ones `render_for/5` derives: the scope
  # note, and a finished run's broken partitions.
  defp emit_all(results, %Schema{} = schema, %Options{} = options, report_opts) do
    Enum.each(options.reporters, fn {format, path} ->
      emit(format, path, results, schema, options, report_opts)
    end)
  end

  # The formats a report of an unfinished run is written in. JSON (and the HTML page embedding
  # it) marks each untested mutant `Pending`, so a partial one reads as partial; SARIF has no such
  # mark, and a partial upload would close the code-scanning alerts of every mutant not yet tested.
  @partial_formats [:human, :json, :html]

  # The formats worth rewriting on disk as a run progresses: those that mark untested mutants.
  @checkpoint_formats [:json, :html]

  @doc false
  # Whether `options` configure any report a checkpoint would write.
  def checkpoints?(%Options{} = options), do: checkpoint_targets(options) != []

  @doc false
  # Rewrite each JSON/HTML report bound for a file with the results so far, untested mutants
  # `Pending`. Silent: the live progress already says how far the run has got. Neither format
  # carries the scope note, so none is passed.
  def checkpoint(results, %Schema{} = schema, %Options{} = options) do
    Enum.each(checkpoint_targets(options), fn {format, path} ->
      write_report!(path, render_for(format, results, schema, options))
    end)
  end

  defp checkpoint_targets(%Options{reporters: reporters}),
    do: Enum.filter(reporters, fn {format, path} -> format in @checkpoint_formats and path end)

  @doc false
  # The reports of a run stopped by a signal: every report but SARIF, from the results the run
  # had accepted, then a note on stderr of how far it got. With no result yet — the signal came
  # before the first mutant finished, and `schema` is `nil` if it came during the scan — no
  # report is written, so a previous run's reports stay as they were.
  def report_interrupted(results, schema, %Options{} = options, scope, signal) do
    if results != [] do
      options.reporters
      |> Enum.filter(fn {format, _path} -> format in @partial_formats end)
      |> Enum.each(fn {format, path} ->
        emit(format, path, results, schema, options, scope: scope)
      end)
    end

    IO.puts(:stderr, interrupted_note(results, schema, options, signal))
  end

  defp interrupted_note(results, schema, options, signal) do
    [headline(results, schema, options, signal) | partial_notes(results, options)]
    |> Enum.join(" ")
  end

  defp headline([], _schema, _options, signal),
    do: "stopped on #{signal} before any mutant was tested; no report was written."

  defp headline(results, %Schema{} = schema, options, signal) do
    total = Schema.count(schema)

    "stopped on #{signal}; evaluated #{length(results)} of #{total} mutant#{CLI.plural(total)}. " <>
      "The mutation score above is over this partial set" <> gate_skipped_note(options)
  end

  defp partial_notes(results, %Options{reporters: reporters}) do
    formats = Enum.map(reporters, &elem(&1, 0))
    marking = Enum.filter(@checkpoint_formats, &(&1 in formats))

    [
      (results != [] and marking != []) &&
        "The #{Enum.map_join(marking, " and ", &String.upcase(to_string(&1)))} " <>
          "report#{CLI.plural(length(marking))} mark#{if length(marking) == 1, do: "s"} " <>
          "the untested mutants Pending.",
      :sarif in formats &&
        "The SARIF report was not written: a partial one would close the code-scanning " <>
          "alerts of the untested mutants."
    ]
    |> Enum.filter(&is_binary/1)
  end

  # On a complete run, apply the post-report CI gates. On an early stop
  # (`--max-survivors`), the result set is only a partial prefix of the mutants,
  # so a gate would be misleading — instead note what happened (on stderr, so a
  # machine report on stdout stays clean, like `warn_ineffective_ignores/1`) and
  # skip it.
  defp finish_run(%Run{stopped_early: false} = run, %Options{} = options),
    do: gate(run.results, options, run.broken_partitions)

  defp finish_run(%Run{stopped_early: true} = run, %Options{} = options) do
    IO.puts(:stderr, early_stop_note(run, options))
  end

  # The partial-run note for an early stop: why it stopped, how much of the candidate
  # set was evaluated, and — only when a CI gate was configured — that gates were
  # skipped because the result set is partial.
  defp early_stop_note(run, %Options{} = options) do
    survivors = Enum.count(run.results, &(&1.status == :survived))
    evaluated = length(run.results)
    total = Schema.count(run.schema)

    "stopped #{stop_cause(options, survivors)}; evaluated #{evaluated} of #{total} " <>
      "mutant#{CLI.plural(total)}. " <> score_scope_note(evaluated, total, options)
  end

  defp score_scope_note(evaluated, total, %Options{} = options) when evaluated < total do
    "The mutation score above is over this partial set" <> gate_skipped_note(options)
  end

  defp score_scope_note(_evaluated, _total, %Options{time_budget: budget} = options)
       when is_binary(budget) do
    "The mutation score above may include unconfirmed timeouts because the time budget " <>
      "was reached during timeout confirmation" <> gate_skipped_note(options)
  end

  defp score_scope_note(_evaluated, _total, %Options{} = options) do
    "The mutation score above is over this stopped run" <> gate_skipped_note(options)
  end

  # Which early-stop condition fired. The survivor cap stops the loop the instant the count reaches
  # the limit and discards later stragglers, so `survivors == max_survivors` *exactly* on a survivor
  # stop — when both caps are set and the count is short of the limit, the wall-clock budget must
  # have fired. (The final clause is unreachable given `stopped_early`, but keeps the note total.)
  defp stop_cause(%Options{max_survivors: n}, survivors) when is_integer(n) and survivors >= n,
    do: "after finding #{survivors} survivor#{CLI.plural(survivors)} (--max-survivors #{n})"

  defp stop_cause(%Options{time_budget: budget}, _survivors) when is_binary(budget),
    do: "on reaching the time budget (--time-budget #{budget})"

  defp stop_cause(%Options{max_survivors: n}, survivors),
    do: "after finding #{survivors} survivor#{CLI.plural(survivors)} (--max-survivors #{n})"

  defp gate_skipped_note(%Options{} = options) do
    if ci_gates_configured?(options) do
      ", so CI gates were not applied."
    else
      "."
    end
  end

  # A `nil` path means stdout (the console); a path means write the rendered
  # report to that file and note where it went.
  defp emit(format, nil, results, schema, options, report_opts) do
    Mix.shell().info(render_for(format, results, schema, options, report_opts))
  end

  defp emit(format, path, results, schema, options, report_opts) do
    write_report!(path, render_for(format, results, schema, options, report_opts))
    Mix.shell().info("wrote #{format} report to #{path}")
  end

  # Every site with no result is `pending:` — none after a complete run; after an early stop,
  # an interruption, or at a checkpoint, the mutants not yet tested.
  defp render_for(format, results, %Schema{} = schema, options, report_opts \\ []) do
    tested = MapSet.new(results, & &1.site.id)
    pending = Enum.reject(schema.sites, &MapSet.member?(tested, &1.id))

    Options.renderer(format).render(
      results,
      schema.sources,
      [min_score: options.min_score, pending: pending] ++ report_opts
    )
  end

  # Write beside `path`, then rename over it: a kill mid-write leaves the previous report (a
  # checkpoint's, or an earlier run's) whole, plus a stray temporary file, never a truncated one.
  defp write_report!(path, content) do
    temp =
      Path.join(
        Path.dirname(path),
        ".#{Path.basename(path)}.#{System.unique_integer([:positive])}.tmp"
      )

    try do
      File.write!(temp, content)
      File.rename!(temp, path)
    after
      File.rm(temp)
    end
  end

  defp gate(results, %Options{} = options, broken_partitions \\ []) do
    case Score.gate_failures(results, options, broken_partitions) do
      [] ->
        :ok

      failures ->
        Mix.raise("CI gate failed:\n" <> Enum.map_join(failures, "\n", &"  * #{&1}"))
    end
  end

  defp ci_gates_configured?(%Options{} = options) do
    options.min_score != nil or options.max_no_coverage != nil or options.fail_on_poisoned or
      options.fail_on_harness_error
  end

  def format_error(:nothing_to_mutate, detail, _root), do: detail

  def format_error(:too_many_harness_errors, detail, _root), do: detail

  # A poisoned compile that recovery couldn't isolate. Lead with a remediation
  # hint when we recognise the cause (a macro requiring a literal argument — see
  # `Mutare.Poison.Hint`), then the raw compiler error for the full detail. The
  # raw error can be long, so a footer points back up to the hint (the fix is at
  # the top, but the user reads the error dump last).
  def format_error(:compile_failed, detail, _root) do
    intro = "the metamutant failed to compile (compile-poisoning).\n\n"
    tail = Output.output_tail(detail, 25)

    case Hint.for_compile_failure(detail) do
      nil ->
        intro <> tail

      hint ->
        footer =
          "\n\n↑ Scroll up for how to fix this — the remediation hint is above the original error."

        intro <> hint <> "\n\nOriginal compile error:\n\n" <> tail <> footer
    end
  end

  def format_error(:compile_timed_out, detail, _root) do
    "the metamutant compile exceeded its wall-clock cap (:compile_timeout, " <>
      "default 30 minutes) and halted itself.\n\n" <>
      "A legitimate compile rarely gets near the cap — this usually means a " <>
      "compiler pass is pathological on the generated code (see NOTES \"Type " <>
      "inference and verification off for the metamutant compile\" for a known " <>
      "class) or a compile-time hook is hanging. Raise the cap with " <>
      "--compile-timeout <ms> (or `compile_timeout: nil` in .mutare.exs to " <>
      "disable) if the compile is genuinely that slow.\n\n" <>
      Output.output_tail(detail, 25)
  end

  def format_error(:dependency_failed, detail, root) do
    DependencyDiagnostic.format(detail, root)
  end

  def format_error(:baseline_failed, detail, _root) do
    "baseline suite is not green; mutation testing needs a passing suite. " <>
      "If `mix test` is green in the project itself, the kept sandbox may have gone bad " <>
      "(a stale or corrupted build artifact): rerun with --no-keep-sandbox to rebuild it " <>
      "cold.\n\n" <>
      Output.output_tail(detail, 25)
  end

  def format_error(:baseline_flaky, detail, _root) do
    "baseline suite is flaky (passed on some runs, failed on others); mutation " <>
      "testing needs a deterministically green suite — a flaky test manufactures " <>
      "false kills. Fix or quarantine the test(s), then re-run.\n\n" <> detail
  end
end
