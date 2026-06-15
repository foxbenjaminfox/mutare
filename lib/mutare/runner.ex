defmodule Mutare.Runner do
  @moduledoc """
  Compile once, then run the suite once per mutant in a fresh OS process.

  The flow protects the one-compile invariant: we compile the sandbox a single
  time, run the baseline green, then launch one `mix test` process per mutant
  with `MUTANT_UNDER_TEST` set. Sources never change between runs, so mix's
  incremental compiler finds nothing to rebuild — the per-mutant cost is process
  boot plus the suite, never recompilation.

  ## Baseline + coverage probe

  Before the per-mutant loop we run the suite green once (`Mutare.Runner.Baseline`)
  — the authoritative green check, and the timing the per-mutant timeout cap is
  scaled from — then build a per-mutant test selection
  (`Mutare.Runner.CoverageProbe`), which picks the test files each mutant needs (or
  marks it `:no_coverage`). The two are split on purpose: a red baseline aborts,
  while coverage is advisory and degrades to running everything. See those modules
  for the selection modes.

  ## Parallel workers and timeouts

  The per-mutant phase runs `:workers` mutants concurrently (default
  `System.schedulers_online/0`), each its own `mix test` OS process in the shared
  sandbox. Each run has a wall-clock cap (`baseline × :timeout_multiplier`,
  default 3.0, with a floor; or an explicit `:timeout` in ms): a mutation can
  turn a terminating loop infinite, so the run is capped.

  The cap is enforced *portably* by the mutant run **halting itself** — the
  injected watcher (see `Mutare.Sandbox`) calls `System.halt/1` after the
  deadline — rather than the runner killing an OS process tree (which needs
  platform-specific signals). A capped run exits with
  `Mutare.Sandbox.Command.timeout_exit/0`, which we count as `:timeout` (a kill —
  the hang is observable misbehavior).

  ## Outcomes vs. exit codes

  `Mutare.Sandbox.Command` owns the exit-code contract and decodes each mutant
  run into a typed outcome; the runner only maps that onto a `Mutare.Result`
  status. The point of the typing is the `:harness_error` case — a run that never
  reached a verdict (a compile error, a missing dependency, a filesystem race).
  Such a run says *nothing* about the mutation, so it is recorded as
  `:harness_error` and kept out of the score's denominator, never silently
  miscounted as a kill the way a raw "non-zero ⇒ killed" rule would.

  Two knobs harden this against flakiness and systemic breakage:

    * `:harness_retries` (default 1) re-runs a harness-errored mutant before
      recording it, so a *transient* failure (a filesystem/lock race) gets
      another chance; a real verdict is never retried.
    * `:max_harness_error_rate` (default 0.5, `nil` to disable) aborts the whole
      run — `{:error, :too_many_harness_errors, detail}` — when persistent
      harness errors exceed that fraction of the mutants that *ran*. Past that,
      the sandbox is broken, not the mutations tested, and a score over the
      surviving denominator would mislead; better to fail loudly.
  """

  alias Mutare.{Options, Poison, Report, Result, Sandbox, Schema, Selector, Site}
  alias Mutare.Runner.{Baseline, CoverageProbe}
  alias Mutare.Sandbox.Command

  require Logger

  @type run :: %{
          schema: Schema.t(),
          results: [Result.t()],
          sandbox: Path.t(),
          baseline_ms: non_neg_integer()
        }

  @type error ::
          {:error,
           :compile_failed
           | :baseline_failed
           | :nothing_to_mutate
           | :too_many_harness_errors, String.t()}

  @doc """
  Run mutation testing against the project at `root`.

  `opts` is a `Mutare.Options` (or a keyword list resolved into one). Returns
  `{:ok, run}` or `{:error, reason, detail}`.
  """
  @spec run(Path.t(), Options.t() | keyword()) :: {:ok, run()} | error()
  def run(root \\ ".", opts \\ []) do
    options = Options.new(opts)
    schema = Schema.build(root, options)
    run_with_schema(schema, root, options)
  end

  @doc """
  Run a pre-built schema (lets a caller report the mutant count before launching).

  `opts` is a `Mutare.Options` (or a keyword list resolved into one). Beyond the
  schema/sandbox fields, it uses `:reporter` — a 1-arity function called with each
  `Mutare.Result` as it completes, for live progress — and `:test_selection`,
  `:workers`, `:timeout`, `:timeout_multiplier`, `:harness_retries` (re-run a
  harness-errored mutant before recording it), and `:max_harness_error_rate`
  (abort if too many runs fail at the harness level).
  """
  @spec run_with_schema(Schema.t(), Path.t(), Options.t() | keyword()) ::
          {:ok, run()} | error()
  def run_with_schema(%Schema{} = schema, root \\ ".", opts \\ []) do
    options = Options.new(opts)

    if Schema.count(schema) == 0 do
      {:error, :nothing_to_mutate, "no mutation sites found under #{inspect(options.paths)}"}
    else
      reporter = options.reporter || fn _result -> :ok end
      mode = options.test_selection

      # Prepare + compile, recovering from compile-poisoning by dropping the
      # offending mutants and rebuilding. `schema` here may differ from the input
      # (poisoners flagged), which is what the run reports against.
      with {:ok, schema, sandbox} <- prepare_compiling(schema, root, options),
           {:ok, baseline_ms} <- Baseline.run(sandbox) do
        selection = CoverageProbe.run(sandbox, schema, mode)
        cap = timeout_cap(baseline_ms, options)
        workers = options.workers

        retries = options.harness_retries

        results =
          schema.sites
          |> Task.async_stream(
            fn site ->
              result = classify(sandbox, site, selection, cap, retries)
              reporter.(result)
              result
            end,
            max_concurrency: workers,
            ordered: true,
            timeout: :infinity
          )
          |> Enum.map(fn {:ok, result} -> result end)

        run = %{schema: schema, results: results, sandbox: sandbox, baseline_ms: baseline_ms}

        case harness_error_guard(results, options) do
          :ok -> {:ok, run}
          {:error, _reason, _detail} = error -> error
        end
      end
    end
  end

  # Per-mutant wall-clock cap. An explicit `:timeout` (ms) wins; otherwise
  # baseline × `:timeout_multiplier` (default 3.0), with a floor so tiny suites
  # don't get an absurdly small cap. A mutation can turn a terminating loop
  # infinite, so without a cap a single mutant could hang the whole run.
  defp timeout_cap(_baseline_ms, %Options{timeout: ms}) when is_integer(ms) and ms > 0, do: ms

  defp timeout_cap(baseline_ms, %Options{timeout_multiplier: multiplier}) do
    # A generous floor: under parallel workers the baseline (measured
    # uncontended) underestimates a mutant's wall time, so a tight cap would
    # false-timeout a slow-but-finite mutant. A true infinite loop runs far
    # past any floor, so we still catch it.
    max(round(baseline_ms * multiplier), 10_000)
  end

  # Materialise the schema and compile it once, recovering from compile-poisoning.
  @poison_attempts 25

  defp prepare_compiling(
         schema,
         root,
         %Options{} = options,
         skip_ids \\ MapSet.new(),
         attempts \\ @poison_attempts
       ) do
    sandbox = Sandbox.prepare(root, schema, options)

    case compile(sandbox) do
      :ok ->
        {:ok, schema, sandbox}

      {:error, :compile_failed, output} = failure ->
        poison = Poison.ids(output, schema.manifests)

        if attempts > 0 and not MapSet.subset?(poison, skip_ids) do
          # Drop the poisoning mutants and rebuild. Ids are stable across rebuilds
          # (the transform advances its counter for skipped ids), so accumulated
          # `skip_ids` keep referring to the same mutations.
          skip_ids = MapSet.union(skip_ids, poison)
          # Rebuild against the *same* files this schema covers (not a fresh
          # discovery), so a restricted schema (`from_files/4`, `:only_files`,
          # `:exclude`) can't silently expand. Forward the original options so
          # `:mutators` survive; ids stay stable across rebuilds.
          schema = Schema.rebuild(schema, root, options, skip_ids)
          prepare_compiling(schema, root, options, skip_ids, attempts - 1)
        else
          # Couldn't identify (or keep making progress on) the poison → give up.
          failure
        end
    end
  end

  # The one compilation.
  defp compile(sandbox) do
    case Command.mix(sandbox, ["compile"], Selector.baseline()) do
      {_output, 0} -> :ok
      {output, _status} -> {:error, :compile_failed, output}
    end
  end

  # === per-mutant runs =======================================================

  defp classify(_sandbox, %Site{poisoned: true} = site, _selection, _cap, _retries) do
    %Result{site: site, status: :poisoned, duration_ms: 0, output: nil}
  end

  defp classify(_sandbox, %Site{ignored: true} = site, _selection, _cap, _retries) do
    %Result{site: site, status: :ignored, duration_ms: 0, output: nil}
  end

  defp classify(sandbox, site, :run_all, cap, retries),
    do: run_mutant(sandbox, site, [], cap, retries)

  defp classify(sandbox, site, {:selective, outcomes}, cap, retries) do
    case Map.fetch(outcomes, site.id) do
      {:ok, {:run, test_args}} ->
        run_mutant(sandbox, site, test_args, cap, retries)

      {:ok, :no_coverage} ->
        %Result{site: site, status: :no_coverage, duration_ms: 0, output: nil}

      # `outcomes` is total over every mutant id, so this is unreachable in
      # practice; a missing id is a bug, not a no-coverage signal — run it rather
      # than silently drop a mutant from the score.
      :error ->
        run_mutant(sandbox, site, [], cap, retries)
    end
  end

  # A `:harness_error` means the suite never reached a verdict (a compile error,
  # a missing dep, a filesystem/lock race). Some of those are *transient*, so we
  # re-run before recording — a fresh `mix` boot is its own natural backoff. A
  # real verdict (passed/failed/timeout) is never retried. `retries` exhausting
  # records the harness error as-is; the run-level guard decides if too many
  # persisted.
  defp run_mutant(sandbox, site, test_args, cap, retries) do
    result = Command.timed_test(sandbox, test_args, site.id, cap)

    if result.outcome == :harness_error and retries > 0 do
      run_mutant(sandbox, site, test_args, cap, retries - 1)
    else
      if result.outcome == :harness_error, do: warn_harness_error(site, result)

      %Result{
        site: site,
        status: status_for(result.outcome),
        duration_ms: result.duration_ms,
        output: result.output
      }
    end
  end

  # A persistent harness error (retries exhausted) is recorded out of the score —
  # but silence would hide infrastructure breakage behind a count buried in the
  # summary. Warn once, naming the mutant and its exit code, so it's actionable;
  # the full `mix` output stays on the `Mutare.Result` for inspection.
  defp warn_harness_error(%Site{} = site, result) do
    Logger.warning(
      "#{site.file}:#{site.line}: mutant #{site.id} failed at the harness level " <>
        "(exit #{result.exit_status}) — the suite never reached a verdict (a compile error, " <>
        "a missing dependency, or a filesystem/lock race). Not counted as killed or survived; " <>
        "see the mutant's output to diagnose the sandbox."
    )
  end

  # Map a run's typed outcome (decoded by `Mutare.Sandbox.Command`, which owns the
  # exit-code contract) onto a result status. A `:harness_error` — the suite never
  # reached a verdict (compile error, missing dep, filesystem race) — is *not* a
  # kill: it says nothing about the mutation, so it's recorded separately and kept
  # out of the score's denominator rather than inflating the kill count.
  defp status_for(:passed), do: :survived
  defp status_for(:failed), do: :killed
  defp status_for(:timeout), do: :timeout
  defp status_for(:harness_error), do: :harness_error

  # Persistent harness errors (after per-mutant retries) hollow out the score's
  # denominator — many mutants measured nothing. Past `:max_harness_error_rate`
  # (a fraction of the mutants that *ran*; `nil` disables) we abort rather than
  # report a score the broken sandbox makes meaningless. The decision is
  # `Report`'s (pure, tested, mirroring `passes_gate?`); the message is here.
  defp harness_error_guard(results, %Options{max_harness_error_rate: max_rate}) do
    if Report.harness_errors_exceed?(results, max_rate) do
      {:error, :too_many_harness_errors, harness_error_detail(results, max_rate)}
    else
      :ok
    end
  end

  defp harness_error_detail(results, max_rate) do
    errors = Enum.count(results, &(&1.status == :harness_error))
    rate = Report.harness_error_rate(results)

    "#{errors} mutant run(s) failed at the harness level — #{pct(rate)} of the mutants that " <>
      "ran, above the --max-harness-error-rate limit of #{pct(max_rate)}. A harness error " <>
      "means the suite never reached a verdict (a compile error, a missing dependency, or a " <>
      "filesystem/lock problem), so the score would be computed over a denominator hollowed " <>
      "out by infrastructure failures. Inspect a harness-errored mutant's output and fix the " <>
      "sandbox, or raise --max-harness-error-rate to proceed anyway."
  end

  defp pct(rate), do: "#{:erlang.float_to_binary(rate * 100 / 1, decimals: 1)}%"
end
