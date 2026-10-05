defmodule Mutare.Runner.OutcomePolicy do
  @moduledoc false
  # What the runner does with each `Mutare.Sandbox.Command.outcome()`: which `Mutare.Result`
  # status it records, which retry budget (if any) it draws on, whether it counts as a kill,
  # and whether it is worth a warning. `Mutare.Runner.MutantRun` executes these decisions;
  # this module makes them, in one table.
  #
  # The two vocabularies stay distinct on purpose. An outcome is what one `mix test` did,
  # refined as far as its exit code and output allow (`Command.outcome/2`); a status is
  # the verdict a reporter shows and the score counts. Several outcomes share a status —
  # `:boot_failure` and `:sigkilled` are harness errors by verdict, refined only so the
  # runner can retry and warn about them differently — and no reporter sees an outcome.
  #
  # Each row states two independent facts, the status and the retry budget. Everything
  # else is derived from them, so the relationships cannot drift:
  #
  #   * `kill?/1` — the status is a kill (`Mutare.Result.kill?/1`).
  #   * `warning/1` — `:no_verdict` for every outcome recorded as `:harness_error`;
  #     `:contended_kill` for a kill that draws on the boot-contention budget, whose
  #     signature a startup stampede also produces and which is believed only once that
  #     budget is spent.

  alias Mutare.Result
  alias Mutare.Sandbox.Command

  @typedoc """
  The retry budget an outcome draws on before it is recorded:

    * `:none` — recorded as is.
    * `:harness` — the general `:harness_retries` budget.
    * `:boot_contention` — the dedicated boot-contention budget, with a jittered backoff.
  """
  @type retry :: :none | :harness | :boot_contention

  @typedoc """
  What an outcome warrants telling the user once it is recorded:

    * `:none` — nothing; the status says it all.
    * `:no_verdict` — the run reached no verdict, so it is left out of the score; say why.
    * `:contended_kill` — a kill no failing test stands behind, which contention could
      also have produced; say why it was believed.
  """
  @type warning :: :none | :no_verdict | :contended_kill

  @policy %{
    # Real verdicts: never retried — a retry could only flip a verdict the suite reached.
    passed: {:survived, :none},
    failed: {:killed, :none},
    timeout: {:timeout, :none},

    # The mutation broke the test suite's own compilation: it was detected, so a kill.
    # `Command.outcome/2` separates it from an infrastructure compile failure (which stays
    # `:harness_error`), so it cannot be an infra blip and is not retried.
    suite_compile_error: {:killed, :none},

    # The mutation minted atoms until the atom table filled and the VM aborted — a
    # resource divergence like a timeout, so a kill, under its own status so the report
    # names the cause. A verdict, not a transient failure, so not retried.
    atom_exhausted: {:atom_exhausted, :none},

    # The mutation broke project evaluation, configuration, or application startup, so
    # `mix test` never loaded a test. The baseline boots the same sandbox green, so the
    # mutation is what changed: a kill. But on one attempt it is indistinguishable from
    # startup contention that reached Mix's `Could not start application` banner, so it
    # spends the boot-contention budget first — contention clears on a retry, the
    # mutation detonates every time.
    app_start_failure: {:killed, :boot_contention},

    # The suite never reached a verdict (a compile error, a missing dep, a filesystem or
    # lock race). It says nothing about the mutation, so it stays out of the score; some
    # causes are transient, so it is re-run first — a fresh `mix` boot is its own backoff.
    harness_error: {:harness_error, :harness},

    # The node died during boot with its own diagnostic erased: a known-transient
    # contention signature, so a harness error by verdict, retried on the dedicated budget.
    boot_failure: {:harness_error, :boot_contention},

    # The OS SIGKILLed the run (exit 137), almost always the kernel OOM killer reaping a
    # mutant made to allocate without bound. A harness error by verdict — but never
    # retried: that failure is deterministic, and a retry re-detonates the same
    # multi-GB blowup on the host (observed live: two consecutive ~25GB RSS spikes before
    # the budget ran out). Not retrying the rare innocent SIGKILL costs one unscored
    # harness error; retrying a real one costs the host.
    sigkilled: {:harness_error, :none}
  }

  @doc "Every outcome this policy covers."
  @spec outcomes :: [Command.outcome()]
  def outcomes, do: Map.keys(@policy)

  @doc "The status `outcome` records once its retries are spent."
  @spec status(Command.outcome()) :: Result.status()
  def status(outcome), do: @policy |> Map.fetch!(outcome) |> elem(0)

  @doc "The retry budget `outcome` draws on before it is recorded."
  @spec retry(Command.outcome()) :: retry()
  def retry(outcome), do: @policy |> Map.fetch!(outcome) |> elem(1)

  @doc """
  Whether `outcome` counts as a kill: a test failed, the cap was hit, the suite or
  application could not load, or the atom table filled. The rest — a pass, or a run that
  reached no verdict — do not.
  """
  @spec kill?(Command.outcome()) :: boolean()
  def kill?(outcome), do: Result.kill?(status(outcome))

  @doc "What `outcome` warrants telling the user once it is recorded."
  @spec warning(Command.outcome()) :: warning()
  def warning(outcome) do
    cond do
      status(outcome) == :harness_error -> :no_verdict
      kill?(outcome) and retry(outcome) == :boot_contention -> :contended_kill
      true -> :none
    end
  end
end
