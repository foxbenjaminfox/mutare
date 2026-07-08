defmodule Mutare.Runner.MutantRun do
  @moduledoc false
  # One mutant's test run, extracted from `Mutare.Runner`: `classify/3` dispatches a `Mutare.Site`
  # to the right outcome (a poisoned/ignored short-circuit, a no-coverage skip, or a real run
  # narrowed to its selected tests), then `run_mutant/*` executes it with the retry/rerun policy —
  # the general `:harness_retries` budget, the dedicated boot-failure budget, the `:kill_runs`
  # unanimous-kill reruns, and the never-retried `:sigkilled` case — and maps the typed outcome
  # (`Mutare.Sandbox.Command`, which owns the exit-code contract) onto a `Mutare.Result` status.
  # Returns a `%Mutare.Result{}`; the streaming pass (`Mutare.Runner.Stream`) calls `classify/3`.

  alias Mutare.{Result, Site}
  alias Mutare.Runner.RunCtx
  alias Mutare.Sandbox.Command

  require Logger

  def classify(_ctx, %Site{poisoned: true} = site, _env) do
    %Result{site: site, status: :poisoned, duration_ms: 0, output: nil}
  end

  def classify(_ctx, %Site{ignored: true} = site, _env) do
    %Result{site: site, status: :ignored, duration_ms: 0, output: nil}
  end

  def classify(%RunCtx{selection: :run_all} = ctx, site, env),
    do: run_mutant(ctx, site, broaden([], site, ctx.scopes), env)

  def classify(%RunCtx{selection: {:selective, outcomes}} = ctx, site, env) do
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
  #
  # `:sigkilled` (the OS SIGKILLed the run — exit 137) is the refinement that must
  # NOT be retried, ever: its signature cause is the kernel OOM killer reaping a
  # mutant whose mutation made it allocate without bound, and that failure mode is
  # *deterministic* — a back-to-back retry re-detonates the same multi-GB blowup
  # on the host (observed live: two consecutive ~25GB RSS spikes before the retry
  # budget ran out). The cost of not retrying the rare transient SIGKILL (an
  # innocent run reaped under someone else's memory pressure, an external kill) is
  # one excluded-from-score harness error; the cost of retrying a real one is the
  # host. Fail toward the host's safety.
  defp run_mutant(%RunCtx{} = ctx, site, test_args, env) do
    result =
      ctx
      |> run_mutant_attempt(site, test_args, env, ctx.retries, @boot_failure_retries)
      |> require_unanimous_kill(ctx, site, test_args, env, ctx.kill_runs - 1)

    if result.outcome in [:harness_error, :boot_failure, :sigkilled],
      do: warn_harness_error(site, result)

    record(site, result)
  end

  # `retries` is the general `:harness_retries` budget; `boot_retries` the dedicated
  # boot-failure budget. The two are decremented independently by the *current* run's
  # outcome, so a boot failure that later degrades to a plain harness error still draws
  # its general retries, and vice versa. Only the two retryable outcomes recurse; every
  # real verdict (and the recovered kills) falls through unretried — as does
  # `:sigkilled`, deliberately (see `run_mutant/4`: retrying a likely-OOM-killed
  # mutant re-detonates it on the host).
  defp run_mutant_attempt(%RunCtx{} = ctx, site, test_args, env, retries, boot_retries) do
    result = Command.timed_test(ctx.sandbox, test_args, site.id, ctx.cap, env ++ ctx.heap_env)

    case result.outcome do
      :boot_failure when boot_retries > 0 ->
        Process.sleep(boot_backoff_ms())
        run_mutant_attempt(ctx, site, test_args, env, retries, boot_retries - 1)

      :harness_error when retries > 0 ->
        run_mutant_attempt(ctx, site, test_args, env, retries - 1, boot_retries)

      _ ->
        result
    end
  end

  # The kill-rerun layer sits outside harness retries. Each attempt first settles
  # its own infrastructure retries above; only kill outcomes are repeated, and all
  # attempts must kill. A passing rerun is the conservative verdict, while a
  # persistent harness error stays an infrastructure failure.
  defp require_unanimous_kill(result, _ctx, _site, _test_args, _env, remaining)
       when remaining <= 0,
       do: result

  defp require_unanimous_kill(result, ctx, site, test_args, env, remaining) do
    if kill_outcome?(result.outcome) do
      next = run_mutant_attempt(ctx, site, test_args, env, ctx.retries, @boot_failure_retries)
      combined = combine_attempts(result, next)

      if kill_outcome?(next.outcome) do
        require_unanimous_kill(combined, ctx, site, test_args, env, remaining - 1)
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

  defp kill_outcome?(outcome),
    do: outcome in [:failed, :timeout, :suite_compile_error, :atom_exhausted]

  defp record(%Site{} = site, result) do
    %Result{
      site: site,
      status: status_for(result.outcome),
      duration_ms: result.duration_ms,
      output: result.output,
      exit_status: result.exit_status
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

  # A `:sigkilled` run also gets a *specific* message: exit 137 is the OS's, not
  # the suite's, and its signature cause is the kernel OOM killer reaping a mutant
  # made to allocate unboundedly. Deliberately not retried (see `run_mutant/4`),
  # and the actionable mitigation — a per-process heap cap on the sandbox runs —
  # is named here.
  defp warn_harness_error(%Site{} = site, %{outcome: :sigkilled} = result) do
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
  # An OS SIGKILL (almost always the kernel OOM killer reaping a runaway-allocation
  # mutant) is likewise a harness error by *verdict* — the suite never reached one.
  # The `:sigkilled` outcome is an internal refinement like `:boot_failure`, but
  # driving the opposite retry behavior (none — see `run_mutant/4`) and its own
  # warning; reporters never see it as a status.
  defp status_for(:sigkilled), do: :harness_error
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
end
