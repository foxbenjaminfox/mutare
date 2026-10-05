defmodule Mutare.Runner.MutantRun do
  @moduledoc false
  # One mutant's test run, extracted from `Mutare.Runner`: `run/2` announces the site, checks out
  # a partition slot, and `classify/3` dispatches the `Mutare.Site` to the right outcome (a
  # poisoned/ignored short-circuit, a no-coverage skip, or a real run narrowed to its selected
  # tests), then `run_mutant/*` executes it with the retry/rerun policy — the general
  # `:harness_retries` budget, the dedicated boot-failure budget, the `:kill_runs` unanimous-kill
  # reruns — taking every per-outcome decision (which budget a retry draws on, what counts as a
  # kill, what to warn about, which `Mutare.Result` status to record) from
  # `Mutare.Runner.OutcomePolicy`.
  # Returns a `%Mutare.Result{}`; the streaming pass (`Mutare.Runner.Stream`) calls `run/2`.

  alias Mutare.{Result, Selector, Site, TestSelection}
  alias Mutare.Runner.{Hydrate, OutcomePolicy, Partitions, RunCtx}
  alias Mutare.Sandbox.Command

  require Logger

  @doc """
  Run one mutant: announce its start (`on_start`), check out a partition slot for the run and
  its harness retries (`Mutare.Runner.Partitions`), classify + run it, and fill in a displayed
  survivor's deferred diff code before it reaches the reporter (a no-op hydrate on the eager
  path or a killed/no-coverage result — see `Mutare.Runner.Hydrate`). The one sequence both the
  async stream and the sequential timeout-confirmation pass share.
  """
  @spec run(RunCtx.t(), Site.t()) :: Result.t()
  def run(%RunCtx{} = ctx, %Site{} = site) do
    ctx.on_start.(site)

    result =
      Partitions.with_slot(ctx.partitions, fn partition -> classify(ctx, site, partition) end)

    Hydrate.result(ctx.hydrate, result)
  end

  @doc """
  The tests `site`'s run selects, narrowed to its umbrella app — or `:no_coverage`, when
  the coverage probe found none that reach it. Every attempt and retry runs this one
  selection; the result records its shape.
  """
  @spec selection(RunCtx.t(), Site.t()) :: TestSelection.t()
  def selection(%RunCtx{selection: {:run_all, _degrade}} = ctx, site),
    do: TestSelection.narrow_to_app(:suite, site.file, ctx.scopes)

  def selection(%RunCtx{selection: {:selective, outcomes}} = ctx, site) do
    case Map.fetch(outcomes, site.id) do
      {:ok, selection} ->
        TestSelection.narrow_to_app(selection, site.file, ctx.scopes)

      # A failed probe has the explicit :run_all variant. A selective result is total;
      # a missing id contradicts that internal contract rather than expressing uncertainty.
      :error ->
        raise "selective coverage missed mutant ##{site.id} (#{Site.location(site)})"
    end
  end

  # `partition` is the run's partition slot (`nil` when partitioning is off), handed to every
  # attempt as its `:partition` run option and recorded on the result.
  defp classify(_ctx, %Site{poisoned: true} = site, _partition) do
    %Result{site: site, status: :poisoned, duration_ms: 0, output: nil}
  end

  defp classify(_ctx, %Site{ignored: true} = site, _partition) do
    %Result{site: site, status: :ignored, duration_ms: 0, output: nil}
  end

  defp classify(%RunCtx{} = ctx, site, partition) do
    case selection(ctx, site) do
      :no_coverage -> %Result{site: site, status: :no_coverage, duration_ms: 0, output: nil}
      selection -> run_mutant(ctx, site, selection, partition)
    end
  end

  # The dedicated boot-contention budget (`OutcomePolicy` says which outcomes draw on it),
  # with a short jittered backoff so a retry doesn't re-collide with the same boot
  # stampede. Sized to the field-proven figure: 4 extra attempts (total 5) cleared it
  # across repeated runs of a contended target.
  @boot_failure_retries 4
  @boot_retry_base_ms 150
  @boot_retry_jitter_ms 350

  defp run_mutant(%RunCtx{} = ctx, site, selection, partition) do
    id = Mutare.RuntimeId.of(site)

    result =
      ctx
      |> run_attempt(id, selection, partition)
      |> require_unanimous_kill(ctx, id, selection, partition, ctx.options.kill_runs - 1)

    case OutcomePolicy.warning(result.outcome) do
      :no_verdict -> warn_no_verdict(site, result)
      :contended_kill -> warn_contended_kill(site, result)
      :none -> :ok
    end

    record(site, result, selection, partition)
  end

  # One run of `selection` with mutant `id` active (`Selector.baseline()` for none), its
  # infrastructure retries settled, each with a full budget.
  defp run_attempt(%RunCtx{} = ctx, id, selection, partition),
    do:
      run_attempt(
        ctx,
        id,
        selection,
        partition,
        ctx.options.harness_retries,
        @boot_failure_retries
      )

  # `retries` is the general `:harness_retries` budget; `boot_retries` the dedicated
  # boot-contention budget. The two are decremented independently by the *current* run's
  # outcome, so a boot failure that later degrades to a plain harness error still draws
  # its general retries, and vice versa.
  defp run_attempt(%RunCtx{} = ctx, id, selection, partition, retries, boot_retries) do
    result =
      Command.timed_test(ctx.sandbox, selection, id,
        cap: ctx.cap,
        max_heap_mb: ctx.options.max_heap_mb,
        schedulers: ctx.options.schedulers,
        project_root: ctx.project_root,
        partition: Partitions.slot_entry(ctx.partitions, partition)
      )

    case OutcomePolicy.retry(result.outcome) do
      :boot_contention when boot_retries > 0 ->
        Process.sleep(boot_backoff_ms())
        run_attempt(ctx, id, selection, partition, retries, boot_retries - 1)

      :harness when retries > 0 ->
        run_attempt(ctx, id, selection, partition, retries - 1, boot_retries)

      _exhausted_or_none ->
        result
    end
  end

  # The kill-rerun layer sits outside harness retries. Each attempt first settles
  # its own infrastructure retries above; only kill outcomes are repeated, and all
  # attempts must kill. A passing rerun is the conservative verdict, while a
  # persistent harness error stays an infrastructure failure.
  defp require_unanimous_kill(result, _ctx, _id, _selection, _partition, remaining)
       when remaining <= 0,
       do: result

  defp require_unanimous_kill(result, ctx, id, selection, partition, remaining) do
    if OutcomePolicy.kill?(result.outcome) do
      next = run_attempt(ctx, id, selection, partition)

      combined = combine_attempts(result, next)

      if OutcomePolicy.kill?(next.outcome) do
        require_unanimous_kill(combined, ctx, id, selection, partition, remaining - 1)
      else
        combined
      end
    else
      result
    end
  end

  defp combine_attempts(previous, next) do
    %{next | duration_ms: previous.duration_ms + next.duration_ms}
  end

  @doc """
  Run `selection` with no mutant active on partition `slot`, outside the pool, announcing
  and recording nothing. It runs as a mutant does — under the mutants' cap, with the same
  boot and harness retries — and a failure, like a kill, must repeat on every one of the
  `:kill_runs` attempts, so a suite the user has called flaky is not believed broken on
  one failure. It asks whether partition `slot` itself works
  (`Mutare.Runner.PartitionCheck`), so it may run only while no pooled run holds `slot`,
  which is after the stream.
  """
  @spec unmutated(RunCtx.t(), TestSelection.runnable(), pos_integer()) :: Command.Result.t()
  def unmutated(%RunCtx{} = ctx, selection, slot) do
    id = Selector.baseline()

    ctx
    |> run_attempt(id, selection, slot)
    |> require_unanimous_kill(ctx, id, selection, slot, ctx.options.kill_runs - 1)
  end

  defp record(%Site{} = site, result, selection, partition) do
    %Result{
      partition: partition,
      site: site,
      status: OutcomePolicy.status(result.outcome),
      duration_ms: result.duration_ms,
      output: result.output,
      exit_status: result.exit_status,
      selection: TestSelection.shape(selection)
    }
  end

  # Short jittered backoff before a boot-failure retry, so the concurrent workers
  # don't re-stampede shared services in lockstep on the same instant.
  defp boot_backoff_ms, do: @boot_retry_base_ms + :rand.uniform(@boot_retry_jitter_ms)

  # A run that reached no verdict (retries exhausted) is recorded out of the score —
  # but silence would hide infrastructure breakage behind a count buried in the
  # summary. Warn once, naming the mutant and its exit code, so it's actionable;
  # the full `mix` output stays on the `Mutare.Result` for inspection.
  #
  # A `:boot_failure` gets a *specific* message: its real cause is unrecoverable
  # from output (the boot crash erased its own diagnostic), so rather than send the
  # user to output that can't help, we name the actual fix — it is almost always
  # startup contention across concurrent workers.
  defp warn_no_verdict(%Site{} = site, %{outcome: :boot_failure} = result) do
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

  # A `:sigkilled` run also gets a *specific* message: exit 137 is the OS's, not
  # the suite's, and its signature cause is the kernel OOM killer reaping a mutant
  # made to allocate unboundedly. Deliberately not retried (see `OutcomePolicy`),
  # and the actionable mitigation — a per-process heap cap on the sandbox runs —
  # is named here.
  defp warn_no_verdict(%Site{} = site, %{outcome: :sigkilled} = result) do
    Logger.warning(
      "#{site_ref(site)} — the OS killed the run with SIGKILL " <>
        "(exit #{result.exit_status}). This is usually the kernel OOM killer: a mutation can " <>
        "make code allocate without bound (e.g. a dropped guard turning a function " <>
        "unconditionally self-recursive), exhausting memory in well under a second. Not " <>
        "retried — a deterministic blowup would just re-detonate on this machine — and not " <>
        "counted as killed or survived. To contain such mutants, cap the sandbox runs' " <>
        "per-process heap with --max-heap-mb <mb> (a runaway then dies as an ordinary, fast " <>
        "test failure instead of endangering the host)."
    )
  end

  defp warn_no_verdict(%Site{} = site, result) do
    Logger.warning(
      "#{site_ref(site)} failed at the harness level " <>
        "(exit #{result.exit_status}) — the suite never reached a verdict (a compile error, " <>
        "a missing dependency, or a filesystem/lock race). Not counted as killed or survived; " <>
        "see the mutant's output to diagnose the sandbox."
    )
  end

  # Not a harness error — a kill — but a *silent* one: no test failed, so the
  # survivor diff a user would normally read has no failing test behind it. Say what
  # happened, once, so a startup kill is never mistaken for a mis-scored infra blip.
  # `:app_start_failure` is the one contended kill; another would need its own message.
  defp warn_contended_kill(%Site{} = site, %{outcome: :app_start_failure} = result) do
    Logger.warning(
      "#{site_ref(site)} — the target's application would not start with this " <>
        "mutation active (exit #{result.exit_status}), and kept refusing across the " <>
        "boot-contention retries. `mix test` boots the app before it loads a single test, " <>
        "so a mutation reachable from project evaluation, runtime configuration, or " <>
        "Application.start/2 stops the " <>
        "run there. The baseline boots the same sandbox green, so this counts as killed, " <>
        "not as a harness error."
    )
  end

  # The `file:line:column: mutant id` prefix shared by the warnings above.
  defp site_ref(%Site{} = site), do: "#{Site.location(site)}: mutant #{site.id}"
end
