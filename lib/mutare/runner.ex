defmodule Mutare.Runner do
  @moduledoc """
  Compile once, then run the suite once per mutant in a fresh OS process.

  The flow protects the one-compile invariant: we compile the sandbox a single time, run the tests as a baseline to ensure it passes, then launch one `mix test` process per mutant with `MUTARE_ACTIVE_MUTANT` set. Sources never change between runs, so mix's incremental compiler finds nothing to rebuild — the per-mutant cost is process boot plus the suite (only up to the first failure for a kill), never recompilation.

  The compile step distinguishes Mix dependency validation from actual compile-poisoning. A dependency failure returns `:dependency_failed` immediately: dropping mutant ids cannot repair copied dependency state, so it never enters poison recovery. The Mix task then points remediation at the original project rather than the disposable sandbox. The compile also carries a wall-clock cap (`:compile_timeout`, default 30 minutes, `nil` to disable): a config-hosted sibling of the per-mutant timeout watcher self-halts a pathological compile, surfaced as `:compile_timed_out` — likewise never fed to poison recovery, since there is no error to attribute and a rebuild cannot make an oversized compile faster.

  `run/2` returns `{:ok, %Mutare.Run{}}`: the `Mutare.Schema` that was run, the list of per-mutant `Mutare.Result`s, the sandbox path, the baseline run's wall-clock in milliseconds, and whether an early-stop condition (`:max_survivors` or `:time_budget`) stopped the run early.

  ## Baseline + coverage probe

  Before the per-mutant loop we run the test suite once and ensure it passes (`Mutare.Runner.Baseline`) — then build a per-mutant test selection (`Mutare.Runner.CoverageProbe`) which picks the test files each mutant needs (or marks it `:no_coverage`). The two are split on purpose: a failing baseline test aborts, while coverage is advisory and degrades to running everything. The baseline can be run more than once (`:baseline_runs`) to catch a flaky suite: runs that disagree abort with `:baseline_flaky` rather than let a flaky test manufacture false mutant kills. A consistently red baseline attempt can also be retried (`:baseline_retries`, default 0) to survive startup/load flakes without weakening `:baseline_runs`' mixed-outcome check. See those modules for the selection modes.

  ## Unanimous kill reruns

  `:kill_runs` (`--kill-runs`, default 1) handles the narrower case where a residual flaky test appears only under one mutant's timing. Only kill outcomes are rerun, and every attempt must kill. If a later attempt passes, the mutant is recorded as `:survived`; if a later attempt persistently hits the harness, it remains `:harness_error`. Harness retries are the inner infrastructure layer; kill reruns combine settled test-suite verdicts.

  ## Parallel workers and timeouts

  The per-mutant phase runs `:workers` mutants concurrently (default: half `System.schedulers_online/0`, capped at 4 — each worker is a full `mix test` BEAM that itself uses every scheduler, so a parallel suite already scales with the machine and extra workers only fill the serial/IO gaps one run leaves), each its own OS process in the shared sandbox. Each run has a wall-clock cap: an explicit `:timeout` in ms, or `baseline × :timeout_multiplier` (default 3.0) scaled by half the concurrent lanes — the baseline is measured *uncontended*, so wall time under contention legitimately inflates with the lane count — with a floor. A mutation can turn a terminating loop infinite, so the run is capped; a capped run counts as `:timeout` — a kill, since the hang is observable misbehavior.

  Even a scaled cap can be overrun by a slow-but-finite run, and survivors are the most exposed (a kill exits at its first failing test; a survivor must run its entire selected set). A false `:timeout` is a false kill hiding a true survivor, so by default (`:confirm_timeouts`) a streamed `:timeout` is *provisional*: after the stream drains, each timed-out mutant is re-run sequentially — no contention — with the same cap, and that verdict is recorded instead. Only a repeat overrun records `:timeout`; a genuine hang pays one extra cap. `confirm_timeouts: false` (`--no-confirm-timeouts`) records the first overrun as-is. A wall-clock `:time_budget` covers this confirmation pass too: confirmations already launched are allowed to finish, but no new confirmation run starts after the deadline.

  ## Early stop: survivor cap (`:max_survivors`) or time budget (`:time_budget`)

  Two conditions can stop the per-mutant loop before every mutant runs, whichever fires first. `:max_survivors` (`--max-survivors`) stops once that many survivors (`:survived` results) have surfaced — an iterate-and-fix workflow that wants a handful of concrete test gaps rather than a full run. `:time_budget` (`--time-budget`, a duration string like `"10m"` parsed by `Mutare.Duration`) stops once that much wall-clock elapses in the per-mutant phase — a "see what I can get in ten minutes" run. The clock starts as the phase begins (compile/baseline/probe are not charged against it) and is checked just before a task announces and launches a real mutant run, so ordered result buffering cannot hide an expired budget and allow more mutants to start.

  Unlike `:max_mutants` (a `Mutare.Schema` cap on candidate *sites*), both leave every mutant compiled in — only the *run* halts early. The per-mutant stream is consumed `ordered: true`, so a survivor stop is deterministic: the Nth survivor in source order, regardless of which worker finished first, and the reported survivors are exactly the first N. (A time-budget stop is not deterministic — it depends on how far the run got.) Runs already in flight when either condition trips are *drained* (not killed), so the sandbox teardown never races a live `mix` subprocess. If the budget elapses after every mutant has already launched, the result set is still complete unless the budget also prevents a provisional timeout from being confirmed. Otherwise the returned run carries `stopped_early`; on an early stop the harness-error abort guard is skipped (the score is already budget-limited or a partial prefix — the Mix task notes it and skips the `--min-score` gate too), since aborting would discard the very survivors the user asked to find.

  ## Per-worker partitioning (DB isolation)

  Optionally (`:partition_env`, off by default), each concurrent run is handed a distinct partition id under a named env var (default `MIX_TEST_PARTITION`), so a stateful suite can point each worker at its own database — the `mix test --partitions` convention. The ids come from a bounded, recycled pool (`Mutare.Runner.Partitions`) sized to `:workers`, so two live runs never share a partition and only `:workers` databases are needed. The one compile, the baseline, and the coverage probe (all sequential, pre-pool) take a fixed partition — the compile too, since it evaluates the target's config, where a partitioned default-less `System.fetch_env!` would otherwise raise. Inert when unset.

  ## Harness errors are kept out of the score

  A mutant run that never reaches a verdict — a compile error, a missing dependency, a filesystem race — says *nothing* about the mutation, so it is recorded as `:harness_error` and kept out of the score's denominator, never silently miscounted as a kill the way a raw "non-zero ⇒ killed" rule would.

  Two knobs harden this against flakiness and systemic breakage:

    * `:harness_retries` (default 2) re-runs a harness-errored mutant before recording it, so a *transient* failure (a filesystem/lock race) gets another chance; a real verdict is never retried.
    * `:max_harness_error_rate` (default 0.5, `nil` to disable) aborts the whole run — `{:error, :too_many_harness_errors, detail}` — when persistent harness errors exceed that fraction of the mutants that *ran*. Past that, the sandbox is broken, not the mutations tested, and a score over the surviving denominator would mislead; better to fail loudly.

  ## Boot-failure: a known-transient harness error retried harder

  One harness-error *cause* is recognised by name (`Output.boot_failure?/1` → the `:boot_failure` outcome): the sandbox node dies during boot with its own diagnostic erased by a secondary `:standard_error` failure. It is almost always concurrent workers contending on shared singletons at startup (a test DB, a connection pool), so it clears on a retry that doesn't re-collide with the boot stampede. It gets its own retry budget (`@boot_failure_retries`), independent of `:harness_retries` and with a short jittered backoff, plus a *specific* warning that stops pointing at output that can't help (the real cause is unrecoverable) and names the actual contention levers — `--workers` and `--partition-db`/`--partition-env`. (Not `--harness-retries`: a `:boot_failure` draws only from its own dedicated budget, so raising that knob would not retry it more.) The verdict is unchanged (a harness error, out of the score); only the messaging and retry effort differ.

  ## SIGKILL (likely OOM): a harness error never retried, and the `:max_heap_mb` cap

  The mirror-image refinement: a run the OS killed with SIGKILL (exit 137, the `:sigkilled` outcome) is recognised so it is **never** retried — the opposite of `:boot_failure`. Its signature cause is the kernel OOM killer reaping a mutant whose mutation made it allocate without bound (a dropped guard turning a function unconditionally self-recursive can exhaust tens of GB in under a second — faster than any wall-clock watcher can react), and that failure is *deterministic*: a back-to-back retry re-detonates the same blowup on the host. The verdict stays a harness error (out of the score), with a specific warning naming the likely cause and the mitigation.

  The mitigation is `:max_heap_mb` (`--max-heap-mb`, off by default): a per-process BEAM heap cap injected into every *runtime* sandbox run — baseline, coverage probe, per-mutant — so a runaway-allocation mutant dies as an ordinary, fast test failure inside its own run instead of endangering the host. The baseline running under the same cap validates up front that the suite itself fits under it. The one metamutant compile is deliberately not capped. Mechanism and sizing guidance: `Mutare.Sandbox.Command.Invocation.heap_cap_env/1`.
  """

  alias Mutare.{
    Options,
    Project,
    Report,
    Run,
    Sandbox,
    Schema
  }

  alias Mutare.Run.Context

  alias Mutare.Runner.{
    AppGraph,
    Baseline,
    Compile,
    CoverageProbe,
    Hydrate,
    Partitions,
    RunCtx,
    Stream
  }

  alias Mutare.Sandbox.Command.Invocation

  # `sandbox` is where the run *was* materialised. For a default (throwaway) run it
  # is removed once the run completes — the path is informational, not a live dir;
  # only `--sandbox`/`--keep-sandbox` runs leave it in place. The report reads
  # `schema`/`results`, never the sandbox, so this is safe.
  @type run :: Run.t()

  @type error ::
          {:error,
           :compile_failed
           | :compile_timed_out
           | :dependency_failed
           | :baseline_failed
           | :baseline_flaky
           | :nothing_to_mutate
           | :too_many_harness_errors, String.t()}

  @doc """
  Run mutation testing against the project at `root`.

  `opts` is a `Mutare.Run.Context` (or a `Mutare.Options` / keyword list resolved
  into one). Returns `{:ok, %Mutare.Run{}}` or `{:error, reason, detail}`.
  """
  @spec run(Path.t(), Context.t() | Options.t() | keyword()) :: {:ok, run()} | error()
  def run(input_root \\ ".", opts \\ []) do
    context = Context.ensure_project(Context.new(opts), input_root)
    root = context.project.copy_root
    schema = Schema.build(root, context)
    run_with_schema(schema, root, context)
  end

  @doc """
  Run a pre-built schema (lets a caller report the mutant count before launching).

  `opts` may be a `Mutare.Run.Context`, a `Mutare.Options` struct, or a keyword
  list. The resolved context supplies the sandbox options, run options, and live
  progress hooks.

  Live progress hooks:

    * `:reporter` — called with each `Mutare.Result` the run keeps, in source order.
      Every reported result appears in the returned run's `:results` (an early stop
      discards the runs still in flight when it trips — those are never reported), and
      the calls are serialized, so the hook needs no synchronization of its own.
    * `:on_start` — called with each `Mutare.Site` just before its test run starts.
      Unlike `:reporter`, this fires concurrently from every worker, and a site whose
      run is later discarded by an early stop still announces its start.
    * `:on_phase` — called as the run enters `:compiling`, `:baseline`,
      `:coverage_probe`, and `{:running, total}`.

  `:on_phase` may also receive detail events:

    * `{:seed_app_build, summary}` — emitted during `:compiling` by `Mutare.Sandbox`
      as it materialises: what the app-build `_build` seed did
      (`Mutare.Sandbox.Seed.summary/0` — `:seeded` with reused/recompiled beam
      counts, a `:fallback` to a cold compile, or `:skipped`). `--verbose` renders
      the first two.
    * `{:poison_round, info}` — one compile-poison recovery round: the compile
      failed, the implicated mutants were dropped, and a rebuild + recompile is
      starting. `info` is `%{dropped: [%{id: id, file: file, line: line,
      mutator: family}], escalated: [t:Mutare.Run.escalation/0]}` — the mutants
      dropped individually this round, and any unknown block macro escalated
      wholesale. Fired on every round (not just verbose), since each one is a
      full recompile the user would otherwise read as a hang.
    * `{:compiled, ms}`
    * `{:baseline_done, ms}`
    * `{:coverage_done, summary}`
    * `{:run_config, cfg}`
    * `{:confirming_timeouts, count}` — the sequential re-run of provisional
      timeouts is starting (see the timeouts section above)

  Custom hooks should ignore phase or detail events they do not recognise.

  The run uses the resolved `:test_selection`, `:workers`, `:timeout`,
  `:timeout_multiplier`, `:max_heap_mb`, `:baseline_runs`, `:baseline_retries`,
  `:kill_runs`, `:confirm_timeouts`, `:harness_retries`, `:max_harness_error_rate`,
  and `:max_survivors` options. When
  `:max_survivors` stops the run early, the returned run has
  `stopped_early: true`.
  """
  @spec run_with_schema(Schema.t(), Path.t(), Context.t() | Options.t() | keyword()) ::
          {:ok, run()} | error()
  def run_with_schema(%Schema{} = schema, input_root \\ ".", opts \\ []) do
    context = Context.ensure_project(Context.new(opts), input_root)

    with_compiled_sandbox(schema, context, fn schema, sandbox, recovery ->
      run_mutants(schema, sandbox, context, recovery)
    end)
  end

  @doc """
  Compile-only preflight (`mix mutare --check`): materialise the sandbox and run the one
  compile — recovering from compile-poisoning exactly like a full run — then stop before
  the baseline and the per-mutant phase.

  Returns `{:ok, %{schema: schema, recovery: recovery}}`, where `schema` is the (possibly
  rebuilt) schema the compile succeeded against and `recovery` summarises any poison
  recovery it took (`t:Mutare.Run.recovery/0`, or `nil` when the metamutant compiled
  clean on the first attempt). Errors are the compile-stage subset of `t:error/0`. The
  `:on_phase` hook receives the same `:compiling` / `{:poison_round, info}` /
  `{:compiled, ms}` events as a full run.
  """
  @spec check_with_schema(Schema.t(), Path.t(), Context.t() | Options.t() | keyword()) ::
          {:ok, %{schema: Schema.t(), recovery: Run.recovery() | nil}} | error()
  def check_with_schema(%Schema{} = schema, input_root \\ ".", opts \\ []) do
    context = Context.ensure_project(Context.new(opts), input_root)

    with_compiled_sandbox(schema, context, fn schema, _sandbox, recovery ->
      {:ok, %{schema: schema, recovery: recovery}}
    end)
  end

  # The shared compile prelude of `run_with_schema/3` and `check_with_schema/3`: lock,
  # materialise, compile with poison recovery, then hand `fun.(schema, sandbox,
  # recovery_summary)` the compiled sandbox. `schema` may differ from the input
  # (poisoners flagged), which is what the run reports against. `prepare_compiling`
  # always hands the sandbox back, so cleanup is owned here on every exit path — the
  # terminal-failure path and the post-`fun` `after` alike.
  defp with_compiled_sandbox(%Schema{} = schema, %Context{} = context, fun) do
    options = context.options
    root = context.project.copy_root

    if Schema.count(schema) == 0 do
      {:error, :nothing_to_mutate, nothing_to_mutate_detail(options.paths, root)}
    else
      lock = Sandbox.acquire_lock(root, context)

      try do
        on_phase = Context.hook(context, :on_phase)

        on_phase.(:compiling)
        compile_started = System.monotonic_time(:millisecond)

        case Compile.run(schema, root, context) do
          {:error, reason, detail, sandbox} ->
            cleanup_sandbox(sandbox, options)
            {:error, reason, detail}

          {:ok, schema, sandbox, recovery} ->
            # The one compile is done (the `{:compiled, ms}` covers any poison-recovery
            # rebuilds it took). A verbose reporter renders the timing; non-verbose ignores it.
            on_phase.({:compiled, System.monotonic_time(:millisecond) - compile_started})

            try do
              fun.(schema, sandbox, Compile.summary(recovery, schema))
            after
              cleanup_sandbox(sandbox, options)
            end
        end
      after
        Sandbox.release_lock(lock)
      end
    end
  end

  # The zero-sites abort detail. When some configured path doesn't even exist under
  # the target, the likely cause is the cwd-relative instinct (`mix mutare ./phoenix
  # --only phoenix/lib/…` typed from one level up) — paths resolve against the target
  # project. Name that; a bare "found nothing" leaves the user staring at a path that
  # looks right from where they're standing. Existing-but-siteless paths (an empty
  # dir, an excluded glob) keep the plain message — the hint would mislead there.
  defp nothing_to_mutate_detail(paths, root) do
    base = "no mutation sites found under #{inspect(paths)}"

    if Enum.any?(paths, &(not File.exists?(Path.join(root, &1)))) do
      base <>
        " — note that paths (--only/:paths) are resolved relative to the target " <>
        "project being mutated, not the directory mix was invoked from"
    else
      base
    end
  end

  # Baseline → coverage probe → per-mutant run, against an already-compiled
  # sandbox. `recovery` is the compile's poison-recovery summary (or `nil`), recorded on
  # the returned run. Returns `{:ok, run}` or a `{:error, reason, detail}` (a red/flaky
  # baseline, or too many harness errors).
  defp run_mutants(schema, sandbox, %Context{} = context, recovery) do
    options = context.options
    on_phase = Context.hook(context, :on_phase)
    on_start = Context.hook(context, :on_start)
    reporter = Context.hook(context, :reporter)

    # Per-worker partition pool (e.g. `MIX_TEST_PARTITION`) for DB isolation across
    # the concurrent runs; `:disabled` (the default) when `:partition_env` is unset.
    # Sized to `workers` so each concurrency lane has one token. Lifecycle owned
    # here: started before the run, stopped on every exit path.
    partitions = Partitions.new(options.partition_env, options.workers)

    # The deferred-diff hydrator (`nil` for the eager path). Lifecycle owned here like the
    # partition pool: started before the run, stopped on every exit path. It re-renders a
    # displayed survivor's diff code on demand, since the scan skipped it.
    hydrate = Hydrate.maybe_new(schema, context)

    try do
      # The baseline + coverage probe are sequential (pre-pool), so they share one
      # fixed partition (`1`) — a partitioned suite still needs a valid database.
      # Both also get the `:max_heap_mb` heap cap (`[]` when off): running the
      # baseline under the same cap the mutants get validates up front that the
      # suite itself fits under it — a too-small cap fails the baseline loudly
      # instead of minting false kills mid-run. (The one metamutant compile is
      # deliberately *not* capped — see `Invocation.heap_cap_env/1`.)
      heap_env = Invocation.heap_cap_env(options.max_heap_mb)
      fixed_env = Partitions.entry(options.partition_env, 1) ++ heap_env

      with {:ok, baseline_ms} <-
             run_baseline(
               on_phase,
               sandbox,
               options.baseline_runs,
               options.baseline_retries,
               fixed_env
             ) do
        # Verbose-only detail: the baseline timing the cap is scaled from.
        on_phase.({:baseline_done, baseline_ms})
        ctx = build_run_ctx(schema, sandbox, context, baseline_ms, fixed_env, hydrate)

        # The run configuration the verbose running line reports (worker count); fired
        # just before `{:running, total}` so the reporter has it when it renders the label.
        on_phase.(
          {:run_config, %{workers: options.workers, partition_env: options.partition_env}}
        )

        on_phase.({:running, length(schema.sites)})

        deadline = Stream.deadline(options.time_budget)

        {results, stopped_early} =
          Stream.stream_and_collect(
            schema,
            ctx,
            partitions,
            options,
            deadline,
            on_start,
            reporter
          )

        {results, confirmation_stopped_early} =
          if options.confirm_timeouts do
            Stream.confirm_timeouts(
              results,
              ctx,
              partitions,
              on_phase,
              on_start,
              reporter,
              deadline
            )
          else
            {results, false}
          end

        run = %Run{
          schema: schema,
          results: results,
          sandbox: sandbox,
          baseline_ms: baseline_ms,
          stopped_early: stopped_early or confirmation_stopped_early,
          recovery: recovery
        }

        finalize_run(run, options)
      end
    after
      Partitions.stop(partitions)
      Hydrate.stop(hydrate)
    end
  end

  # The coverage probe + per-app test scopes + timeout cap, assembled into the `RunCtx` threaded
  # to every per-mutant `classify`. Runs after a green baseline, on the fixed (pre-pool) partition.
  defp build_run_ctx(schema, sandbox, %Context{} = context, baseline_ms, fixed_env, hydrate) do
    options = context.options
    on_phase = Context.hook(context, :on_phase)
    mode = options.test_selection
    on_phase.(:coverage_probe)
    cap = timeout_cap(baseline_ms, schema, options)
    selection = CoverageProbe.run(sandbox, schema, mode, fixed_env, probe_cap(cap, options))

    # Verbose-only detail: the per-mutant coverage breakdown plus the derived timeout
    # cap (the probe summary is pure; this assembles the display payload).
    on_phase.({:coverage_done, Map.put(CoverageProbe.summarize(selection), :cap_ms, cap)})

    # Per owning app, the test dirs a whole-suite run may be narrowed to (the app +
    # its declared dependents). Empty for a single project, and when nothing broad
    # will run — see `app_scopes/3` and `Mutare.Runner.MutantRun`'s broadening.
    scopes = app_scopes(context.project, sandbox, selection)

    %RunCtx{
      sandbox: sandbox,
      selection: selection,
      cap: cap,
      scopes: scopes,
      retries: options.harness_retries,
      kill_runs: options.kill_runs,
      hydrate: hydrate,
      heap_env: Invocation.heap_cap_env(options.max_heap_mb)
    }
  end

  # The umbrella narrowing map. Reading the declared inter-app graph costs one Mix
  # boot (`Mutare.Runner.AppGraph`), so it is paid only when the selection actually
  # holds a broad run to narrow. An unreadable graph means no narrowing: every
  # broad run covers the whole umbrella — never narrowed on doubt.
  defp app_scopes(%Project{umbrella?: true} = project, sandbox, selection) do
    with true <- CoverageProbe.broad_runs?(selection),
         {:ok, forward} <- AppGraph.read(project, sandbox) do
      Project.app_test_scopes(project, sandbox, forward)
    else
      _ -> %{}
    end
  end

  defp app_scopes(_project, _sandbox, _selection), do: %{}

  # A complete run applies the harness-error abort guard; an early stop
  # (`--max-survivors`) skips it. Aborting on an early stop would discard the very
  # survivors the user asked us to find — and the run is already flagged
  # `stopped_early` (the Mix task notes it and skips the `--min-score` gate).
  defp finalize_run(%Run{stopped_early: true} = run, _options), do: {:ok, run}

  defp finalize_run(%Run{stopped_early: false} = run, %Options{} = options) do
    case harness_error_guard(run.results, options) do
      :ok -> {:ok, run}
      {:error, _reason, _detail} = error -> error
    end
  end

  # Announce the baseline phase, then run it. A thin wrapper so the `:baseline`
  # notification fires immediately before `Baseline.run/4` inside the `with`
  # chain (where a bare side effect between `<-` clauses can't live). `env` carries
  # the fixed partition entry (or `[]`).
  defp run_baseline(on_phase, sandbox, baseline_runs, baseline_retries, env) do
    on_phase.(:baseline)
    Baseline.run(sandbox, baseline_runs, baseline_retries, env)
  end

  # Per-mutant wall-clock cap. An explicit `:timeout` (ms) wins; otherwise
  # baseline × `:timeout_multiplier` (default 3.0), scaled by the concurrent lanes
  # (below), with a floor so tiny suites don't get an absurdly small cap. A mutation
  # can turn a terminating loop infinite, so without a cap a single mutant could
  # hang the whole run.
  defp timeout_cap(_baseline_ms, _schema, %Options{timeout: ms}) when is_integer(ms) and ms > 0,
    do: ms

  defp timeout_cap(baseline_ms, schema, %Options{} = options) do
    # The baseline is measured uncontended, but up to `lanes` runs — each a full
    # BEAM — execute at once, so an honest run's wall time inflates with the lane
    # count (~2.4× at 4 workers, >4× at 16 — NOTES "Timeouts"). Scale the cap by
    # half the lanes so slow-but-finite runs rarely reach the confirmation pass;
    # over-generosity only delays catching a genuine hang, which the confirmation
    # re-run bounds anyway. `lanes` is capped by the site count (a `--line` rerun
    # of two mutants has next to no contention), and the generous floor keeps tiny
    # suites honest. A true infinite loop runs far past any cap, so we still catch it.
    lanes = min(options.workers, length(schema.sites))
    contention = max(1.0, lanes / 2)
    max(round(baseline_ms * options.timeout_multiplier * contention), 10_000)
  end

  # The coverage probe's wall-clock cap. An explicit `:probe_timeout` (ms) wins —
  # the same explicit-beats-derived shape as `timeout_cap/2`; otherwise a generous
  # multiple of the per-mutant cap, since the instrumented run legitimately pays
  # coverage-capture overhead a plain baseline doesn't. It exists only so a
  # pathological capture slowdown degrades to run-all selection (logged by
  # `Mutare.Runner.CoverageProbe`) instead of hanging the whole run at the probe
  # stage; a probe anywhere near the derived bound is already far outside normal
  # overhead.
  defp probe_cap(_mutant_cap, %Options{probe_timeout: ms}) when is_integer(ms) and ms > 0,
    do: ms

  defp probe_cap(mutant_cap, %Options{}), do: mutant_cap * 10

  # Remove an auto-generated fresh sandbox once the run is done with it, so the
  # default throwaway dirs don't accumulate in the temp dir across runs. A pinned
  # `--sandbox` is the user's chosen path (left for inspection and their own reuse)
  # and `--keep-sandbox` deliberately persists for `_build` caching, so neither is
  # touched. Best-effort (`rm_rf`, not `rm_rf!`): a cleanup failure must never mask
  # the run's actual result.
  defp cleanup_sandbox(sandbox, %Options{sandbox: nil, keep_sandbox: false}) do
    File.rm_rf(sandbox)
    :ok
  end

  defp cleanup_sandbox(_sandbox, _options), do: :ok

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

    base =
      "#{errors} mutant run(s) failed at the harness level — #{pct(rate)} of the mutants that " <>
        "ran, above the --max-harness-error-rate limit of #{pct(max_rate)}. A harness error " <>
        "means the suite never reached a verdict (a compile error, a missing dependency, or a " <>
        "filesystem/lock problem), so the score would be computed over a denominator hollowed " <>
        "out by infrastructure failures. Fix the sandbox, or raise --max-harness-error-rate " <>
        "to proceed anyway."

    case harness_error_examples(results) do
      "" -> base
      examples -> base <> "\n\nExamples:\n" <> examples
    end
  end

  defp harness_error_examples(results) do
    results
    |> Enum.filter(&(&1.status == :harness_error))
    |> Enum.take(3)
    |> Enum.map_join("\n", &("  " <> Report.HarnessDiagnostic.line(&1)))
  end

  defp pct(rate), do: "#{Report.percent(rate * 100)}%"
end
