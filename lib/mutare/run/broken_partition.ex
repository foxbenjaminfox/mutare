defmodule Mutare.Run.BrokenPartition do
  @moduledoc """
  A partition (`:partition_env`) whose environment failed the run's tests with no mutant
  active, while the same tests passed on partition `1` — one of `Mutare.Run`'s
  `:broken_partitions`.

    * `:partition` — the partition.
    * `:mutant` — the report id of the kill on `:partition` whose tests were rerun there.
    * `:failure` — how the rerun failed (`t:failure/0`).
    * `:reason` — the output line that best explains the failure, or `nil`.
  """

  alias Mutare.Result

  @typedoc """
  How the rerun failed: its tests failed (`:tests_failed`), ran past the per-mutant cap
  (`:timeout`), or the application would not start (`:app_start`).
  """
  @type failure :: :tests_failed | :timeout | :app_start

  @type t :: %__MODULE__{
          partition: pos_integer(),
          mutant: pos_integer(),
          failure: failure(),
          reason: String.t() | nil
        }

  @enforce_keys [:partition, :mutant, :failure, :reason]
  defstruct @enforce_keys

  @doc """
  How the rerun failed, as a clause, naming the kill whose tests were rerun as `mutant`
  (`"mutant 12"`, or with its location where the caller has the site), e.g.
  `the tests that killed mutant 12 failed`.
  """
  @spec what_failed(t(), String.t()) :: String.t()
  def what_failed(%__MODULE__{failure: :app_start}, _mutant),
    do: "the application would not start"

  def what_failed(%__MODULE__{failure: :timeout}, mutant),
    do: "the tests that killed #{mutant} ran past the per-mutant cap"

  def what_failed(%__MODULE__{failure: :tests_failed}, mutant),
    do: "the tests that killed #{mutant} failed"

  @doc """
  How the rerun failed, as a clause naming the kill by its id (`what_failed/2`), then the
  explaining output line if any, e.g.
  `the tests that killed mutant 12 failed: ** (RuntimeError) no database`.
  """
  @spec rerun_failure(t()) :: String.t()
  def rerun_failure(%__MODULE__{mutant: mutant, reason: reason} = broken) do
    what = what_failed(broken, "mutant #{mutant}")
    if reason, do: "#{what}: #{reason}", else: what
  end

  @doc """
  How many of `results` are kills on `broken`'s partition: the kills that may be false.
  """
  @spec kills(t(), [Result.t()]) :: non_neg_integer()
  def kills(%__MODULE__{partition: partition}, results),
    do: Enum.count(results, &(&1.partition == partition and Result.kill?(&1.status)))
end
