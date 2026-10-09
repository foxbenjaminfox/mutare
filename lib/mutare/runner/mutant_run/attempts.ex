defmodule Mutare.Runner.MutantRun.Attempts do
  @moduledoc false
  # Pure transitions for one mutant's attempts. OutcomePolicy owns what an outcome means;
  # this module owns how outcomes consume independent retry budgets and how settled kills
  # earn another confirmation. MutantRun executes the returned decisions and owns backoff.
  #
  # Every confirmation starts with fresh infrastructure budgets. Only settled attempts
  # contribute duration, preserving the runner's accounting: infrastructure retries and
  # backoff were never included. The final attempt supplies the output and outcome.

  alias Mutare.Runner.OutcomePolicy
  alias Mutare.Sandbox.Command.Result

  # Four extra attempts cleared field-observed startup contention (five runs in all).
  @boot_failure_retries 4

  @enforce_keys [:harness_budget, :harness_left, :boot_left, :confirmations_left, :duration_ms]
  defstruct @enforce_keys

  @opaque t :: %__MODULE__{
            harness_budget: non_neg_integer(),
            harness_left: non_neg_integer(),
            boot_left: non_neg_integer(),
            confirmations_left: non_neg_integer(),
            duration_ms: non_neg_integer()
          }

  @type decision :: {:retry, :immediate | :backoff, t()} | {:confirm, t()} | {:done, Result.t()}

  @spec new(non_neg_integer(), pos_integer()) :: t()
  def new(harness_retries, kill_runs)
      when is_integer(harness_retries) and harness_retries >= 0 and is_integer(kill_runs) and
             kill_runs > 0 do
    %__MODULE__{
      harness_budget: harness_retries,
      harness_left: harness_retries,
      boot_left: @boot_failure_retries,
      confirmations_left: kill_runs - 1,
      duration_ms: 0
    }
  end

  @spec next(t(), Result.t()) :: decision()
  def next(%__MODULE__{} = state, %Result{} = result) do
    case OutcomePolicy.retry(result.outcome) do
      :boot_contention when state.boot_left > 0 ->
        {:retry, :backoff, %{state | boot_left: state.boot_left - 1}}

      :harness when state.harness_left > 0 ->
        {:retry, :immediate, %{state | harness_left: state.harness_left - 1}}

      _exhausted_or_none ->
        settle(state, result)
    end
  end

  defp settle(state, result) do
    duration = state.duration_ms + result.duration_ms

    if state.confirmations_left > 0 and OutcomePolicy.kill?(result.outcome) do
      {:confirm,
       %{
         state
         | confirmations_left: state.confirmations_left - 1,
           harness_left: state.harness_budget,
           boot_left: @boot_failure_retries,
           duration_ms: duration
       }}
    else
      {:done, %{result | duration_ms: duration}}
    end
  end
end
