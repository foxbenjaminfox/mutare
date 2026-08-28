defmodule Mutare.Runner.Stream do
  @moduledoc false
  # The per-mutant run loop, extracted from `Mutare.Runner`: stream every site through
  # `Mutare.Runner.MutantRun.classify/3` across `:workers` partition lanes, collect in source order,
  # and report each result the collector **accepts** — stopping early at the Nth survivor
  # (`--max-survivors`) or when the wall-clock budget (`--time-budget`) elapses, whichever fires
  # first (draining, never killing, in-flight runs). `confirm_timeouts/7` is the sequential,
  # uncontended re-run that settles a provisional streamed `:timeout` (`:confirm_timeouts`).
  # `deadline/1` reads the budget once, as the phase begins. Returns
  # `{results_in_source_order, stopped_early?}`.

  alias Mutare.{Duration, Options, Result}
  alias Mutare.Runner.{Hydrate, MutantRun, Partitions}

  # Run every site through `classify` concurrently (one partition slot per lane) and collect in
  # source order, reporting each accepted result — stopping early at the Nth survivor
  # (`--max-survivors`) or when a task launched after the wall-clock budget elapsed
  # (`--time-budget`) skips its real run, whichever comes first. Returns
  # `{results, stopped_early?}`.
  def stream_and_collect(
        schema,
        ctx,
        partitions,
        %Options{} = options,
        deadline,
        on_start,
        reporter
      ) do
    # Set once the survivor cap is reached or the launch deadline has elapsed: tasks that start
    # *after* it skip their real run, letting the collector **drain** the rest of the stream cheaply
    # rather than halting it. Draining lets the already-in-flight `mix test` runs finish instead of
    # being killed mid-write — which used to leave a dying subprocess racing the sandbox/project
    # teardown (a flaky `File.rm_rf`). No extra mutant is actually run after the cap: at most the
    # in-flight stragglers (≤ one per worker, exactly as before) complete, and every later site comes
    # back a trivial skip.
    capped = :atomics.new(1, signed: false)

    schema.sites
    |> Task.async_stream(
      fn site ->
        cond do
          :atomics.get(capped, 1) == 1 ->
            :capped

          past_deadline?(deadline) ->
            :atomics.put(capped, 1, 1)
            :capped

          true ->
            # No reporting here — that's the collector's call to make (this result may still be
            # discarded as a post-stop straggler). Hydration stays in the worker, where it
            # parallelises (NOTES "Deferred site-code hydration").
            run_and_hydrate(ctx, partitions, on_start, site)
        end
      end,
      # `max_concurrency` is driven from the pool itself so it can never drift from
      # the token count: the pool's non-blocking checkout relies on one token per
      # concurrency lane. Falls back to `options.workers` when partitioning is off
      # (no pool). See `Mutare.Runner.Partitions`.
      max_concurrency: Partitions.max_concurrency(partitions, options.workers),
      ordered: true,
      timeout: :infinity
    )
    |> collect_until_stop(options, capped, reporter)
  end

  # The monotonic instant the wall-clock budget (`--time-budget`) expires, or nil when unset. Read
  # once, here, so the clock starts as the per-mutant phase begins (compile/baseline/probe are not
  # charged against it — the budget is "how long to spend running mutants"). The string is already
  # validated by `Options`, so parsing cannot fail.
  def deadline(nil), do: nil

  def deadline(time_budget) do
    {:ok, ms} = Duration.parse(time_budget)
    System.monotonic_time(:millisecond) + ms
  end

  # Consume the ordered per-mutant result stream. With neither early-stop condition set we drain the
  # whole stream; otherwise we record results until the Nth `:survived` (`--max-survivors`) or until
  # a task reports that it skipped because the wall-clock budget had elapsed (`--time-budget`) —
  # whichever fires first — then signal `capped` (so tasks not yet started skip — see
  # `stream_and_collect/7`) and **drain the rest** rather than halting. Returns
  # `{results_in_source_order, stopped_early?}`.
  #
  # Every accepted result is reported *here*, as the collector takes it, never in the worker that
  # produced it: only the collector knows whether a result survives the cap, so a worker-side report
  # emits live/verbose lines for stragglers that never reach `run.results`. Reporting from the
  # ordered collector also fixes the reported order (source order — the order the final report
  # prints) and leaves `:reporter` single-threaded; `:on_start` still fires from every worker, so
  # the live reporter stays a `GenServer`.
  #
  # Because the stream is consumed `ordered: true`, a survivor stop is deterministic: the Nth
  # survivor *in source order*, regardless of which worker finished first, so the reported survivors
  # are exactly the first N. The deadline is observed in the task body immediately before the real
  # run starts, rather than here, because `ordered: true` may buffer later completions while still
  # launching replacement tasks as worker slots free. That makes launch gating independent of ordered
  # result delivery. A complete run whose final result lands after the deadline stays complete: no
  # task skipped, so this collector never marks it partial.
  #
  # We drain (not halt) either way, so the in-flight `mix test` runs already started before the trigger
  # finish cleanly instead of being killed mid-write; their real results are discarded, and every
  # post-trigger site comes back as a cheap `:capped` skip. Draining is what keeps the sandbox/project
  # teardown from racing a dying subprocess. See NOTES "Early stop: survivor cap and time budget".
  defp collect_until_stop(stream, %Options{} = options, capped, reporter) do
    {acc, _survivors, stopped} =
      Enum.reduce(stream, {[], 0, false}, fn
        # A task that skipped because the cap was already set — discard. If the collector has not
        # already observed the trigger, this was the time-budget task that first noticed the expired
        # launch deadline, so the reported prefix is partial.
        {:ok, :capped}, {acc, survivors, stopped} ->
          {acc, survivors, stopped or :atomics.get(capped, 1) == 1}

        # An in-flight straggler that finished its real run after the cap — drain but discard,
        # keeping the reported set to exactly the mutants evaluated before the stop.
        {:ok, _result}, {acc, survivors, true} ->
          {acc, survivors, true}

        {:ok, result}, {acc, survivors, false} ->
          report(reporter, result, options)
          survivors = survivors + survivor_count(result)
          acc = [result | acc]

          if stop_now?(survivors, options.max_survivors) do
            :atomics.put(capped, 1, 1)
            {acc, survivors, true}
          else
            {acc, survivors, false}
          end
      end)

    {Enum.reverse(acc), stopped}
  end

  # Report one accepted result. Under `:confirm_timeouts` a streamed `:timeout` is *provisional* —
  # the sequential confirmation pass (`confirm_timeouts/7`) re-runs it and reports the final
  # verdict, so no (possibly false) TIMEOUT line may land here.
  defp report(_reporter, %Result{status: :timeout}, %Options{confirm_timeouts: true}), do: :ok

  defp report(reporter, result, _options) do
    reporter.(result)
    :ok
  end

  # Stop once the survivor cap is reached. The wall-clock launch budget is enforced in the task
  # body, where it cannot be hidden by ordered stream buffering.
  defp stop_now?(survivors, limit), do: limit != nil and survivors >= limit

  defp past_deadline?(nil), do: false
  defp past_deadline?(deadline), do: System.monotonic_time(:millisecond) >= deadline

  # 1 for a survivor (`:survived`), 0 otherwise — the only status `--max-survivors`
  # counts. A timeout/atom-exhaustion is a kill, and no-coverage/ignored/poisoned/
  # harness-error reached no verdict, so none of those is an "unkilled" survivor.
  defp survivor_count(%Result{status: :survived}), do: 1
  defp survivor_count(_result), do: 0

  # A streamed `:timeout` is provisional (`:confirm_timeouts`, on by default): the cap
  # is scaled from an *uncontended* baseline, but the stream runs `:workers` mutants
  # wide — each a full BEAM — so a slow-but-finite run can overrun the cap without
  # hanging. Survivors are hit hardest: a kill exits at its first failing test
  # (`--max-failures 1`), while a survivor must run its *entire* selected set, so the
  # slowest honest runs are exactly the ones a contended cap falsely kills — and a
  # false `:timeout` is a false kill hiding a true survivor. So each timed-out mutant
  # is re-run here *sequentially* (no contention) with the same cap, and that verdict
  # recorded instead; only a repeat overrun stays `:timeout`. A genuine hang pays one
  # extra cap — cheap next to a silently wrong score. The same wall-clock deadline
  # used by the async stream gates this pass too: if the budget has elapsed, the
  # provisional timeout is reported as-is and no new `mix test` process starts. Runs
  # after the stream (and after a `--max-survivors` stop, whose drained stragglers
  # were discarded, not confirmed), so a confirmed survivor can push the reported
  # survivors past the requested cap — the honest reading of a run that was already
  # stopped early.
  def confirm_timeouts(results, ctx, partitions, on_phase, on_start, reporter, deadline) do
    case Enum.count(results, &(&1.status == :timeout)) do
      0 ->
        {results, false}

      count ->
        if past_deadline?(deadline) do
          report_unconfirmed_timeouts(results, reporter)
          {results, true}
        else
          on_phase.({:confirming_timeouts, count})

          Enum.map_reduce(results, false, fn
            %Result{status: :timeout, site: site} = provisional, stopped ->
              if stopped or past_deadline?(deadline) do
                reporter.(provisional)
                {provisional, true}
              else
                result = run_and_hydrate(ctx, partitions, on_start, site)
                reporter.(result)
                {result, false}
              end

            result, stopped ->
              {result, stopped}
          end)
        end
    end
  end

  defp report_unconfirmed_timeouts(results, reporter) do
    Enum.each(results, fn
      %Result{status: :timeout} = result -> reporter.(result)
      _result -> :ok
    end)
  end

  # Launch one mutant under a partition slot (announcing its start first) and fill in a displayed
  # survivor's deferred diff code before it reaches the reporter — the sequence shared by the async
  # stream and the sequential timeout-confirmation pass. A no-op hydrate on the eager path or a
  # killed/no-coverage result (see `Mutare.Runner.Hydrate`).
  defp run_and_hydrate(ctx, partitions, on_start, site) do
    on_start.(site)
    # Check out a distinct partition for this run (and its harness retries), check it back in when
    # done — see `Mutare.Runner.Partitions`.
    result = Partitions.with_slot(partitions, fn env -> MutantRun.classify(ctx, site, env) end)
    Hydrate.result(ctx.hydrate, result)
  end
end
