defmodule Mutare.CLI.Outcome do
  @moduledoc false
  # The run-outcome presentation of `mix mutare`, extracted from `Mix.Tasks.Mutare`: `report/2`
  # emits every configured reporter and applies the post-report CI gates (or notes an early stop);
  # `warn_poison_recovery/1` prints the durable `:macro_routes` fix after a poison-recovered run; and
  # `format_error/3` renders each terminal `{:error, reason, detail}` into the message the task
  # `Mix.raise`s. All output is the task's (stdout report, stderr notes) — this only builds it.

  alias Mutare.{CLI, Options, Report, Run, Schema}
  alias Mutare.Poison.Hint
  alias Mutare.Sandbox.Command.Output
  alias Mutare.Sandbox.DependencyDiagnostic

  # After a run that recovered from compile-poisoning by escalating (skipping wholesale)
  # one or more unknown block macros, print the durable `:macro_routes` fix — the extra
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

  def report(run, %Options{} = options) do
    Enum.each(options.reporters, fn {format, path} -> emit(format, path, run, options) end)
    finish_run(run, options)
  end

  # On a complete run, apply the post-report CI gates. On an early stop
  # (`--max-survivors`), the result set is only a partial prefix of the mutants,
  # so a gate would be misleading — instead note what happened (on stderr, so a
  # machine report on stdout stays clean, like `warn_ineffective_ignores/1`) and
  # skip it.
  defp finish_run(%Run{stopped_early: false} = run, %Options{} = options),
    do: gate(run.results, options)

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
  defp emit(format, nil, run, options) do
    Mix.shell().info(render_for(format, run, options))
  end

  defp emit(format, path, run, options) do
    File.write!(path, render_for(format, run, options))
    Mix.shell().info("wrote #{format} report to #{path}")
  end

  defp render_for(format, run, options) do
    Options.renderer(format).render(run.results, run.schema.sources, min_score: options.min_score)
  end

  defp gate(results, %Options{} = options) do
    case Report.gate_failures(results, options) do
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
    "baseline suite is not green; mutation testing needs a passing suite.\n\n" <>
      Output.output_tail(detail, 25)
  end

  def format_error(:baseline_flaky, detail, _root) do
    "baseline suite is flaky (passed on some runs, failed on others); mutation " <>
      "testing needs a deterministically green suite — a flaky test manufactures " <>
      "false kills. Fix or quarantine the test(s), then re-run.\n\n" <> detail
  end
end
