defmodule Mutare.Runner do
  @moduledoc """
  Compile once, then run the suite once per mutant in a fresh OS process.

  The flow protects the one-compile invariant: we compile the sandbox a single
  time, run the baseline green, then launch one `mix test` process per mutant
  with `MUTANT_UNDER_TEST` set. Sources never change between runs, so mix's
  incremental compiler finds nothing to rebuild — the per-mutant cost is process
  boot plus the suite (only up to the first failure for a kill), never
  recompilation.

  `run/2` returns `%{schema, results, sandbox, baseline_ms}`: the `Mutare.Schema`
  that was run, the list of per-mutant `Mutare.Result`s, the sandbox path, and the
  baseline run's wall-clock in milliseconds.

  ## Baseline + coverage probe

  Before the per-mutant loop we run the suite green once (`Mutare.Runner.Baseline`)
  — the authoritative green check, and the timing the per-mutant timeout cap is
  scaled from — then build a per-mutant test selection
  (`Mutare.Runner.CoverageProbe`), which picks the test files each mutant needs (or
  marks it `:no_coverage`). The two are split on purpose: a red baseline aborts,
  while coverage is advisory and degrades to running everything. The baseline can
  be run more than once (`:baseline_runs`) to catch a flaky suite: runs that
  disagree abort with `:baseline_flaky` rather than let a flaky test manufacture
  false kills. See those modules for the selection modes.

  ## Parallel workers and timeouts

  The per-mutant phase runs `:workers` mutants concurrently (default
  `System.schedulers_online/0`), each its own `mix test` OS process in the shared
  sandbox. Each run has a wall-clock cap (`baseline × :timeout_multiplier`,
  default 3.0, with a floor; or an explicit `:timeout` in ms): a mutation can
  turn a terminating loop infinite, so the run is capped. A capped run counts as
  `:timeout` — a kill, since the hang is observable misbehavior.

  ## Early stop after N survivors (`:max_survivors`)

  `:max_survivors` (`--max-survivors`) stops the per-mutant loop once that many
  **survivors** (`:survived` results) have surfaced, for an iterate-and-fix
  workflow that wants a handful of concrete test gaps rather than a full run.
  Unlike `:max_mutants` (a `Mutare.Schema` cap on candidate *sites*), every mutant
  is still compiled in — only the *run* halts early. The per-mutant stream is
  consumed `ordered: true`, so the stop is deterministic: the Nth survivor in
  source order, regardless of which worker finished first, and the reported
  survivors are exactly the first N. The returned run carries `stopped_early`; on
  an early stop the harness-error abort guard is skipped (the score is already a
  partial prefix — the Mix task notes it and skips the `--min-score` gate too),
  since aborting would discard the very survivors the user asked to find.

  ## Per-worker partitioning (DB isolation)

  Optionally (`:partition_env`, off by default), each concurrent run is handed a
  **distinct** partition id under a named env var (default `MIX_TEST_PARTITION`),
  so a stateful suite can point each worker at its own database — the `mix test
  --partitions` convention. The ids come from a bounded, recycled pool
  (`Mutare.Runner.Partitions`) sized to `:workers`, so two live runs never share a
  partition and only `:workers` databases are needed. The one compile, the
  baseline, and the coverage probe (all sequential, pre-pool) take a fixed
  partition — the compile too, since it evaluates the target's config, where a
  partitioned default-less `System.fetch_env!` would otherwise raise. Inert when
  unset.

  ## Harness errors are kept out of the score

  A mutant run that never reaches a verdict — a compile error, a missing
  dependency, a filesystem race — says *nothing* about the mutation, so it is
  recorded as `:harness_error` and kept out of the score's denominator, never
  silently miscounted as a kill the way a raw "non-zero ⇒ killed" rule would.

  Two knobs harden this against flakiness and systemic breakage:

    * `:harness_retries` (default 2) re-runs a harness-errored mutant before
      recording it, so a *transient* failure (a filesystem/lock race) gets
      another chance; a real verdict is never retried.
    * `:max_harness_error_rate` (default 0.5, `nil` to disable) aborts the whole
      run — `{:error, :too_many_harness_errors, detail}` — when persistent
      harness errors exceed that fraction of the mutants that *ran*. Past that,
      the sandbox is broken, not the mutations tested, and a score over the
      surviving denominator would mislead; better to fail loudly.

  ## Boot-failure: a known-transient harness error retried harder

  One harness-error *cause* is recognised by name (`Output.boot_failure?/1` →
  the `:boot_failure` outcome): the sandbox node dies **during boot** with its own
  diagnostic erased by a secondary `:standard_error` failure. It is almost always
  concurrent workers contending on shared singletons at startup (a test DB, a
  connection pool), so it clears on a retry that doesn't re-collide with the boot
  stampede. It gets its **own** retry budget (`@boot_failure_retries`), independent
  of `:harness_retries` and with a short jittered backoff, plus a *specific*
  warning that stops pointing at output that can't help (the real cause is
  unrecoverable) and names the actual contention levers — `--workers` and
  `--partition-db`/`--partition-env`. (Not `--harness-retries`: a `:boot_failure`
  draws only from its own dedicated budget, so raising that knob would not retry it
  more.) The verdict is unchanged (a harness error, out of the score); only the
  messaging and retry effort differ.
  """

  alias Mutare.{Options, Poison, Project, Report, Result, Sandbox, Schema, Selector, Site}
  alias Mutare.Run.Context
  alias Mutare.Runner.{Baseline, CoverageProbe, Partitions}
  alias Mutare.Sandbox.{Command, CompilerOptions}
  alias Mutare.Sandbox.Command.Invocation

  require Logger

  # The per-run invariants threaded to every mutant's `classify/3` and `run_mutant/*`: the one
  # `sandbox`, the coverage `selection`, the timeout `cap`, the umbrella `scopes`, and the
  # initial `retries` budget. Bundled so those functions take this plus the per-task `site`/`env`
  # rather than a long positional list — and so the general `retries` budget rides a *named*
  # field where the public `run_mutant/4` first supplies the two budgets (`ctx.retries` and
  # `@boot_failure_retries`), which can't then be confused. (The private `run_mutant/6` recursion
  # does still thread both positionally, but its two recursive calls are local and obvious.)
  defmodule RunCtx do
    @moduledoc false
    @enforce_keys [:sandbox, :selection, :cap, :scopes, :retries]
    defstruct @enforce_keys
  end

  # `sandbox` is where the run *was* materialised. For a default (throwaway) run it
  # is removed once the run completes — the path is informational, not a live dir;
  # only `--sandbox`/`--keep-sandbox` runs leave it in place. The report reads
  # `schema`/`results`, never the sandbox, so this is safe.
  @type run :: %{
          schema: Schema.t(),
          results: [Result.t()],
          sandbox: Path.t(),
          baseline_ms: non_neg_integer(),
          stopped_early: boolean()
        }

  @type error ::
          {:error,
           :compile_failed
           | :baseline_failed
           | :baseline_flaky
           | :nothing_to_mutate
           | :too_many_harness_errors, String.t()}

  @doc """
  Run mutation testing against the project at `root`.

  `opts` is a `Mutare.Run.Context` (or a `Mutare.Options` / keyword list resolved
  into one). Returns `{:ok, run}` or `{:error, reason, detail}`.
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

  `opts` is a `Mutare.Run.Context` (or a `Mutare.Options` / keyword list resolved
  into one). Beyond the schema/sandbox fields, it uses three live-progress hooks —
  carried on the context — `:reporter` (a
  1-arity function called with each `Mutare.Result` as it completes), `:on_phase`
  (called with the phase as the run moves through `:compiling` → `:baseline` →
  `:coverage_probe` → `{:running, total}`), and `:on_start` (called with each
  `Mutare.Site` just before its run begins) — and `:test_selection`,
  `:workers`, `:timeout`, `:timeout_multiplier`, `:baseline_runs` (re-run the
  baseline to catch a flaky suite), `:harness_retries` (re-run a harness-errored
  mutant before recording it), `:max_harness_error_rate` (abort if too many runs
  fail at the harness level), and `:max_survivors` (stop the run once that many
  survivors are found, flagging the returned run `stopped_early`).
  """
  @spec run_with_schema(Schema.t(), Path.t(), Context.t() | Options.t() | keyword()) ::
          {:ok, run()} | error()
  def run_with_schema(%Schema{} = schema, input_root \\ ".", opts \\ []) do
    context = Context.ensure_project(Context.new(opts), input_root)
    options = context.options
    root = context.project.copy_root

    if Schema.count(schema) == 0 do
      {:error, :nothing_to_mutate, "no mutation sites found under #{inspect(options.paths)}"}
    else
      reporter = Context.hook(context, :reporter)
      on_phase = Context.hook(context, :on_phase)
      on_start = Context.hook(context, :on_start)
      mode = options.test_selection

      on_phase.(:compiling)

      # Prepare + compile, recovering from compile-poisoning by dropping the
      # offending mutants and rebuilding. `schema` here may differ from the input
      # (poisoners flagged), which is what the run reports against. `prepare_compiling`
      # always hands the sandbox back, so cleanup is owned here on every exit path —
      # the terminal-failure path and the post-run `after` alike.
      case prepare_compiling(schema, root, context) do
        {:error, reason, detail, sandbox} ->
          cleanup_sandbox(sandbox, options)
          {:error, reason, detail}

        {:ok, schema, sandbox} ->
          try do
            run_mutants(schema, sandbox, context, on_phase, on_start, reporter, mode)
          after
            cleanup_sandbox(sandbox, options)
          end
      end
    end
  end

  # Baseline → coverage probe → per-mutant run, against an already-compiled
  # sandbox. Returns `{:ok, run}` or a `{:error, reason, detail}` (a red/flaky
  # baseline, or too many harness errors).
  defp run_mutants(schema, sandbox, %Context{} = context, on_phase, on_start, reporter, mode) do
    options = context.options

    # Per-worker partition pool (e.g. `MIX_TEST_PARTITION`) for DB isolation across
    # the concurrent runs; `:disabled` (the default) when `:partition_env` is unset.
    # Sized to `workers` so each concurrency lane has one token. Lifecycle owned
    # here: started before the run, stopped on every exit path.
    partitions = Partitions.new(options.partition_env, options.workers)

    try do
      # The baseline + coverage probe are sequential (pre-pool), so they share one
      # fixed partition (`1`) — a partitioned suite still needs a valid database.
      fixed_env = Partitions.entry(options.partition_env, 1)

      with {:ok, baseline_ms} <- run_baseline(on_phase, sandbox, options.baseline_runs, fixed_env) do
        ctx = build_run_ctx(schema, sandbox, context, mode, baseline_ms, fixed_env, on_phase)

        on_phase.({:running, length(schema.sites)})

        {results, stopped_early} =
          stream_and_collect(schema, ctx, partitions, options, on_start, reporter)

        run = %{
          schema: schema,
          results: results,
          sandbox: sandbox,
          baseline_ms: baseline_ms,
          stopped_early: stopped_early
        }

        finalize_run(run, options)
      end
    after
      Partitions.stop(partitions)
    end
  end

  # The coverage probe + per-app test scopes + timeout cap, assembled into the `RunCtx` threaded
  # to every per-mutant `classify`. Runs after a green baseline, on the fixed (pre-pool) partition.
  defp build_run_ctx(
         schema,
         sandbox,
         %Context{} = context,
         mode,
         baseline_ms,
         fixed_env,
         on_phase
       ) do
    options = context.options
    on_phase.(:coverage_probe)
    selection = CoverageProbe.run(sandbox, schema, mode, fixed_env)

    # Per owning app, the test dirs a whole-suite run may be narrowed to (the app +
    # its dependents). Empty for a single project — see `broaden/3`.
    scopes =
      Project.app_test_scopes(context.project, sandbox, Path.join(sandbox, "_build/test/lib"))

    %RunCtx{
      sandbox: sandbox,
      selection: selection,
      cap: timeout_cap(baseline_ms, options),
      scopes: scopes,
      retries: options.harness_retries
    }
  end

  # Run every site through `classify` concurrently (one partition slot per lane), reporting each
  # result as it lands, and collect in source order — stopping early at the Nth survivor when
  # `--max-survivors` is set. Returns `{results, stopped_early?}`.
  defp stream_and_collect(schema, ctx, partitions, %Options{} = options, on_start, reporter) do
    schema.sites
    |> Task.async_stream(
      fn site ->
        on_start.(site)
        # Check out a distinct partition for this run (and its harness retries),
        # check it back in when done — see `Mutare.Runner.Partitions`.
        result = Partitions.with_slot(partitions, fn env -> classify(ctx, site, env) end)
        reporter.(result)
        result
      end,
      # INVARIANT: `max_concurrency` must equal the pool size (`workers`, the arg to
      # `Partitions.new/2` in `run_mutants/7`) — the pool's non-blocking checkout
      # relies on one token per concurrency lane. See `Mutare.Runner.Partitions`.
      max_concurrency: options.workers,
      ordered: true,
      timeout: :infinity
    )
    |> collect_until_survivors(options.max_survivors)
  end

  # A complete run applies the harness-error abort guard; an early stop
  # (`--max-survivors`) skips it. Aborting on an early stop would discard the very
  # survivors the user asked us to find — and the run is already flagged
  # `stopped_early` (the Mix task notes it and skips the `--min-score` gate).
  defp finalize_run(%{stopped_early: true} = run, _options), do: {:ok, run}

  defp finalize_run(%{stopped_early: false} = run, %Options{} = options) do
    case harness_error_guard(run.results, options) do
      :ok -> {:ok, run}
      {:error, _reason, _detail} = error -> error
    end
  end

  # Announce the baseline phase, then run it. A thin wrapper so the `:baseline`
  # notification fires immediately before `Baseline.run/3` inside the `with`
  # chain (where a bare side effect between `<-` clauses can't live). `env` carries
  # the fixed partition entry (or `[]`).
  defp run_baseline(on_phase, sandbox, baseline_runs, env) do
    on_phase.(:baseline)
    Baseline.run(sandbox, baseline_runs, env)
  end

  # Consume the ordered per-mutant result stream. With no `:max_survivors` cap we
  # drain the whole stream (today's behaviour); with a cap we stop once that many
  # `:survived` results have been seen. Returns `{results_in_source_order,
  # stopped_early?}`.
  #
  # Because the stream is consumed `ordered: true`, the stop point is the Nth
  # survivor *in source order* — deterministic regardless of which worker finished
  # first — so the reported survivors are exactly the first N. Halting a
  # `Task.async_stream` shuts down its in-flight tasks; a handful of mutants past
  # the trigger may have already run concurrently, but their results are discarded
  # (and any orphaned `mix` process is bounded by the timeout watcher and the
  # throwaway sandbox). See NOTES "Early stop after N survivors".
  defp collect_until_survivors(stream, nil) do
    {Enum.map(stream, fn {:ok, result} -> result end), false}
  end

  defp collect_until_survivors(stream, limit) do
    reduction =
      Enum.reduce_while(stream, {[], 0}, fn {:ok, result}, {acc, survivors} ->
        survivors = survivors + survivor_count(result)
        acc = [result | acc]

        if survivors >= limit do
          {:halt, {:stopped, Enum.reverse(acc)}}
        else
          {:cont, {acc, survivors}}
        end
      end)

    case reduction do
      {:stopped, results} -> {results, true}
      {acc, _survivors} -> {Enum.reverse(acc), false}
    end
  end

  # 1 for a survivor (`:survived`), 0 otherwise — the only status `--max-survivors`
  # counts. A timeout/atom-exhaustion is a kill, and no-coverage/ignored/poisoned/
  # harness-error reached no verdict, so none of those is an "unkilled" survivor.
  defp survivor_count(%Result{status: :survived}), do: 1
  defp survivor_count(_result), do: 0

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

  # Materialise (and **claim**) the sandbox once, then hand off to the poison-recovery
  # loop. The sandbox path is fixed here for the whole run — a poison retry re-renders the
  # rebuilt schema into this *same* dir — so there are no orphaned dirs and ownership is
  # claimed exactly once. Returns `{:ok, schema, sandbox}` or `{:error, reason, detail,
  # sandbox}`; either way the sandbox is handed back so `run_with_schema/3` owns cleanup
  # uniformly (this function never cleans up itself).
  defp prepare_compiling(schema, root, %Context{} = context) do
    sandbox = Sandbox.prepare(root, schema, context)
    deps = %{root: root, options: context.options, sandbox: sandbox}
    compile_with_recovery(deps, schema, MapSet.new(), MapSet.new(), @poison_attempts)
  end

  # Compile the materialised sandbox; on a poisoned compile, drop the implicated mutants,
  # rebuild + rematerialise into the same sandbox, and retry — bounded by `attempts`. `deps`
  # (`root`/`options`/`sandbox`) is fixed for the whole loop; the rest is per-round state — the
  # `schema` rebuilt each round, accumulating `skip_ids`/`struck`, and the remaining `attempts`.
  defp compile_with_recovery(%{sandbox: sandbox} = deps, schema, skip_ids, struck, attempts) do
    # The compile evaluates the target's config under `MIX_ENV=test`, so a
    # partitioned config that reads the var without a default (e.g.
    # `System.fetch_env!("MIX_TEST_PARTITION")`) must see it *here* too — before
    # the baseline/probe that also set it — or the compile fails. Sequential like
    # those, so the fixed partition (`1`) suffices.
    case compile(sandbox, Partitions.entry(deps.options.partition_env, 1)) do
      :ok ->
        {:ok, schema, sandbox}

      {:error, :compile_failed, output} ->
        # The implicated mutant ids this round, then evidence-based escalation for an
        # unknown module-level block macro: a block is dropped *wholesale* only once a
        # *second, distinct* poison lands in it after a targeted single-id drop — the
        # only signal that distinguishes a DSL rejecting the injected selector wholesale
        # (recurs under a single drop) from one mutant's broken replacement (does not).
        # See `escalate_block_poison/3`.
        raw = Poison.ids(output, schema.metamutants)
        {poison, struck} = escalate_block_poison(raw, schema.sites, struck)

        if attempts > 0 and not MapSet.subset?(poison, skip_ids) do
          # Drop the poisoning mutants and rebuild. Ids are stable across rebuilds
          # (the transform advances its counter for skipped ids), so accumulated
          # `skip_ids` keep referring to the same mutations. Rebuild against the *same*
          # files this schema covers (not a fresh discovery), so a restricted schema
          # (`from_files/4`, `:only_files`, `:exclude`) can't silently expand. Forward
          # the original options so `:mutators` survive.
          skip_ids = MapSet.union(skip_ids, poison)
          schema = Schema.rebuild(schema, deps.root, deps.options, skip_ids)
          Sandbox.rematerialize(sandbox, schema)
          compile_with_recovery(deps, schema, skip_ids, struck, attempts - 1)
        else
          # Couldn't identify (or keep making progress on) the poison → give up. Hand the
          # sandbox back for the caller to clean up.
          {:error, :compile_failed, output, sandbox}
        end
    end
  end

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

  # Evidence-based escalation for a poison inside an *unknown* module-level block macro
  # (a DSL whose `do` body the transform mutates on the guess it is unquoted into a
  # function). Two distinct failure modes both surface here, and they need opposite
  # responses:
  #
  #   * **Wholesale** — the DSL rejects the injected selector `case` itself (it splices the
  #     body into a guard/pattern/compile-time position). *Every* selector in the block will
  #     fail, so the whole block must be dropped at once — otherwise we'd hit the next
  #     selector round after round and could exhaust the attempt budget.
  #   * **Id-specific** — one mutant's *replacement* is illegal (classically a custom mutator
  #     emitting uncompilable code). Only that mutant must be dropped; its innocent
  #     (compile-safe-by-construction) siblings in the same block should still run.
  #
  # The build can't tell them apart — whether an unknown DSL rejects a given selector is
  # information that only exists at compile time. But the two modes differ in **recurrence
  # under a single drop**: wholesale recurs (drop one selector, the next fails), id-specific
  # does not (drop the bad mutant, the rest compile). So we escalate a block only on its
  # **second** strike: the first poison in a block drops just the implicated id(s) and *marks
  # the block struck* (`struck`); a later poison in an already-struck block drops *every*
  # mutant in it — the runtime-stable equivalent of marking the macro `:skip` (the body
  # renders raw, its mutants recorded `:poisoned`), while ids stay stable across rebuilds
  # (unlike a true `:skip`, which would stop analyzing the body and shift later ids).
  #
  # Cost of the precision: a genuinely-wholesale block pays **one extra rebuild** (drop one,
  # see it recur, escalate). Limit: two *independent* id-specific failures in one block also
  # escalate it on the second — indistinguishable from wholesale recurrence without trying
  # each id individually, which is exactly the budget blow-up escalation exists to prevent.
  #
  # Identity is **per-invocation** — `{file, {macro_name, nid}}`, tagged on each `Site` by the
  # transform — so a poison in one `custom_dsl do … end` only ever escalates that block, never
  # a sibling invocation of the same macro that expands differently. A poison touching no block
  # macro returns `{poison, struck}` with both unchanged (the common path).
  defp escalate_block_poison(poison, sites, struck) do
    by_id = Map.new(sites, &{&1.id, &1})

    hit =
      poison
      |> Enum.map(&block_macro_key(by_id[&1]))
      |> Enum.reject(&is_nil/1)
      |> MapSet.new()

    # Escalate only blocks hit this round that were *already* struck on a prior round;
    # newly-hit blocks are merely recorded (struck for next time) and dropped per-id.
    escalate = MapSet.intersection(hit, struck)

    siblings =
      for site <- sites,
          key = block_macro_key(site),
          not is_nil(key),
          MapSet.member?(escalate, key),
          do: site.id

    {MapSet.union(poison, MapSet.new(siblings)), MapSet.union(struck, hit)}
  end

  # The `{file, {macro_name, nid}}` invocation a site belongs to when it lives in an
  # unknown block macro, else `nil` (an untagged site, or a missing id). The `nid` in
  # the tag scopes it to the one invocation; pairing with `file` disambiguates the
  # per-file nid counter across files.
  defp block_macro_key(%Site{block_macro: tag, file: file}) when not is_nil(tag),
    do: {file, tag}

  defp block_macro_key(_), do: nil

  # The one compilation. `Command.success?/1` owns the "0 means success" reading;
  # `CompilerOptions.compiler_env/0` carries the SSA-alias-pass-off speed option (a
  # free compile win, applied only here — per-mutant runs never recompile the lib).
  # `partition_env` is the fixed partition entry (or `[]`), so a config read at
  # compile time finds a valid partition — see `compile_with_recovery/5`.
  defp compile(sandbox, partition_env) do
    {output, status} =
      Invocation.mix(sandbox, ["compile"], Selector.baseline(),
        env: CompilerOptions.compiler_env() ++ partition_env
      )

    if Command.success?(status), do: :ok, else: {:error, :compile_failed, output}
  end

  # === per-mutant runs =======================================================

  defp classify(_ctx, %Site{poisoned: true} = site, _env) do
    %Result{site: site, status: :poisoned, duration_ms: 0, output: nil}
  end

  defp classify(_ctx, %Site{ignored: true} = site, _env) do
    %Result{site: site, status: :ignored, duration_ms: 0, output: nil}
  end

  defp classify(%RunCtx{selection: :run_all} = ctx, site, env),
    do: run_mutant(ctx, site, broaden([], site, ctx.scopes), env)

  defp classify(%RunCtx{selection: {:selective, outcomes}} = ctx, site, env) do
    case Map.fetch(outcomes, site.id) do
      {:ok, {:run, test_args}} ->
        run_mutant(ctx, site, broaden(test_args, site, ctx.scopes), env)

      {:ok, :no_coverage} ->
        %Result{site: site, status: :no_coverage, duration_ms: 0, output: nil}

      # `outcomes` is total over every mutant id, so this is unreachable in
      # practice; a missing id is a bug, not a no-coverage signal — run it rather
      # than silently drop a mutant from the score.
      :error ->
        run_mutant(ctx, site, broaden([], site, ctx.scopes), env)
    end
  end

  # A whole-suite run (`[]` args) in an umbrella would run *every* app. Narrow it to
  # the mutant's owning app + its dependents (`scopes`, the safe superset of
  # possible killers; see `Mutare.Project.app_test_scopes/3`). A non-empty selection
  # (coverage already attributed it to specific files) is left untouched, and an
  # empty scope (single project, unknown app, or an unreadable graph) means run
  # everything — never narrow on doubt.
  defp broaden([], %Site{file: file}, scopes) when map_size(scopes) > 0 do
    Map.get(scopes, owning_app(file, scopes), [])
  end

  defp broaden(test_args, _site, _scopes), do: test_args

  # Resolve an `apps/<app>/…` sandbox path to its owning app by matching the path
  # segment against the *known* `scopes` keys — never `String.to_atom/1` on a path
  # segment. The segment is input-derived (a discovered file path), so minting an
  # atom from it is unbounded-atom-table risk; matching the existing keys instead
  # removes that risk and is exactly the lookup we want (a segment naming no scope
  # app yields `nil` ⇒ `Map.get` default `[]` ⇒ run everything — never narrow on
  # doubt).
  defp owning_app(file, scopes) do
    case Path.split(file) do
      ["apps", app | _] -> Enum.find(Map.keys(scopes), &(to_string(&1) == app))
      _ -> nil
    end
  end

  # A boot-time node crash (`:boot_failure`) is a known-transient contention
  # signature, so it gets its **own** retry budget on top of `:harness_retries`,
  # with a short jittered backoff so the retry doesn't re-collide with the same
  # boot stampede. Sized to the field-proven figure: 4 extra attempts (total 5)
  # cleared it across repeated runs of a contended target.
  @boot_failure_retries 4
  @boot_retry_base_ms 150
  @boot_retry_jitter_ms 350

  # A `:harness_error` means the suite never reached a verdict (a compile error,
  # a missing dep, a filesystem/lock race). Some of those are *transient*, so we
  # re-run before recording — a fresh `mix` boot is its own natural backoff. A
  # real verdict (passed/failed/timeout) is never retried. Exhausting the budget
  # records the harness error as-is; the run-level guard decides if too many
  # persisted.
  #
  # The two **kill** outcomes `Command.outcome/2` recovers from an otherwise-
  # `:harness_error` exit (`:suite_compile_error`, `:atom_exhausted`) are already
  # distinct outcomes here, so they record as kills and are never retried. The
  # third refinement, `:boot_failure`, *is* retried — harder than a generic
  # harness error, from its own dedicated budget — since it is a known-transient
  # startup-contention crash; see `@boot_failure_retries`.
  defp run_mutant(%RunCtx{retries: retries} = ctx, site, test_args, env),
    do: run_mutant(ctx, site, test_args, env, retries, @boot_failure_retries)

  # `retries` is the general `:harness_retries` budget; `boot_retries` the dedicated
  # boot-failure budget. The two are decremented independently by the *current* run's
  # outcome, so a boot failure that later degrades to a plain harness error still draws
  # its general retries, and vice versa. Only the two retryable outcomes recurse; every
  # real verdict (and the recovered kills) falls through to `record/2` unretried.
  defp run_mutant(%RunCtx{} = ctx, site, test_args, env, retries, boot_retries) do
    result = Command.timed_test(ctx.sandbox, test_args, site.id, ctx.cap, env)

    case result.outcome do
      :boot_failure when boot_retries > 0 ->
        Process.sleep(boot_backoff_ms())
        run_mutant(ctx, site, test_args, env, retries, boot_retries - 1)

      :harness_error when retries > 0 ->
        run_mutant(ctx, site, test_args, env, retries - 1, boot_retries)

      outcome when outcome in [:harness_error, :boot_failure] ->
        warn_harness_error(site, result)
        record(site, result)

      _ ->
        record(site, result)
    end
  end

  defp record(%Site{} = site, result) do
    %Result{
      site: site,
      status: status_for(result.outcome),
      duration_ms: result.duration_ms,
      output: result.output
    }
  end

  # Short jittered backoff before a boot-failure retry, so the concurrent workers
  # don't re-stampede shared services in lockstep on the same instant.
  defp boot_backoff_ms, do: @boot_retry_base_ms + :rand.uniform(@boot_retry_jitter_ms)

  # A persistent harness error (retries exhausted) is recorded out of the score —
  # but silence would hide infrastructure breakage behind a count buried in the
  # summary. Warn once, naming the mutant and its exit code, so it's actionable;
  # the full `mix` output stays on the `Mutare.Result` for inspection.
  #
  # A `:boot_failure` gets a *specific* message: its real cause is unrecoverable
  # from output (the boot crash erased its own diagnostic), so rather than send the
  # user to output that can't help, we name the actual fix — it is almost always
  # startup contention across concurrent workers.
  defp warn_harness_error(%Site{} = site, %{outcome: :boot_failure} = result) do
    Logger.warning(
      "#{site_ref(site)} — the sandbox node died during boot " <>
        "(exit #{result.exit_status}). Its underlying error couldn't reach a torn-down " <>
        ":standard_error, so the cause is unrecoverable from the mutant's output. This is " <>
        "almost always resource/connection contention across concurrent workers at startup, " <>
        "which the engine already retries harder on its own — if it persists, lower --workers " <>
        "or partition shared services (--partition-db / --partition-env). Not counted as " <>
        "killed or survived."
    )
  end

  defp warn_harness_error(%Site{} = site, result) do
    Logger.warning(
      "#{site_ref(site)} failed at the harness level " <>
        "(exit #{result.exit_status}) — the suite never reached a verdict (a compile error, " <>
        "a missing dependency, or a filesystem/lock race). Not counted as killed or survived; " <>
        "see the mutant's output to diagnose the sandbox."
    )
  end

  # The `file:line: mutant id` prefix shared by both harness-error warnings.
  defp site_ref(%Site{} = site), do: "#{site.file}:#{site.line}: mutant #{site.id}"

  # Map a run's typed outcome (decoded by `Mutare.Sandbox.Command`, which owns the
  # exit-code contract) onto a result status. A `:harness_error` — the suite never
  # reached a verdict (compile error, missing dep, filesystem race) — is *not* a
  # kill: it says nothing about the mutation, so it's recorded separately and kept
  # out of the score's denominator rather than inflating the kill count.
  defp status_for(:passed), do: :survived
  defp status_for(:failed), do: :killed
  defp status_for(:timeout), do: :timeout
  defp status_for(:harness_error), do: :harness_error
  # A boot-time node crash is a harness error by *verdict* (it says nothing about
  # the mutation — it's startup contention), so it records under the same status
  # and stays out of the score. The `:boot_failure` outcome is purely an internal
  # refinement (`Command.outcome/2`) driving the harder retry and the specific
  # warning; it never reaches the reporters' `Result.status` vocabulary.
  defp status_for(:boot_failure), do: :harness_error
  # The mutation broke the test suite's own compilation — it can't even build
  # with the mutant active, so it was detected: a kill. `Command.outcome/2`
  # separates this from a genuine harness/infra compile failure (which stays
  # `:harness_error`); only a per-mutant *test-script* compile error lands here.
  defp status_for(:suite_compile_error), do: :killed
  # The mutation minted unbounded atoms and crashed the BEAM (atom table full) —
  # a resource-divergence like a timeout, so a kill, recorded under its own status
  # so the report can name the cause. `Command.outcome/2` recovers it from the
  # otherwise-`:harness_error` exit via the VM-abort banner (`Output.atom_exhausted?/1`).
  # Not retried (it is a verdict, not a transient infra blip): only `:harness_error`
  # and `:boot_failure` re-run (see `run_mutant/7`).
  defp status_for(:atom_exhausted), do: :atom_exhausted

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

  defp pct(rate), do: "#{Report.percent(rate * 100)}%"
end
