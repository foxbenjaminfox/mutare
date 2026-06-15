defmodule Mutare.Runner.Baseline do
  @moduledoc """
  Run the complete test suite once, green-checked, against the baseline mutant
  (`MUTANT_UNDER_TEST=0`).

  This is the authoritative green check *and* the source of `baseline_ms`. Two
  things hang on it being a single run of the *whole* suite:

    * **Timing.** `baseline_ms` is the wall-clock of one process boot plus the
      suite, which the runner scales into the per-mutant timeout cap. Summing
      per-file probe runs (as the old conflated probe did) folded N process boots
      into the figure and inflated every mutant's cap.
    * **Green-ness.** The suite is confirmed green *together*. A per-file probe
      never runs the suite as a whole, so a cross-file dependency could pass
      file-by-file (or fail in isolation) without the suite's real state ever
      being checked.

  Mutation testing on a red suite is meaningless — every "kill" is suspect — so a
  non-green baseline aborts the run: `{:error, :baseline_failed, output}`. No
  `--cover` here: mutant runs don't use it, so an uninstrumented baseline times
  the cap against like conditions (and the `--cover` instrumentation belongs to
  `Mutare.Runner.CoverageProbe`, which runs separately afterwards).
  """

  alias Mutare.Selector
  alias Mutare.Sandbox.Command

  @doc """
  Run the whole suite once at baseline. Returns `{:ok, baseline_ms}` when green,
  else `{:error, :baseline_failed, output}`.
  """
  @spec run(Path.t()) :: {:ok, non_neg_integer()} | {:error, :baseline_failed, String.t()}
  def run(sandbox) do
    {ms, output, status} = Command.timed_mix(sandbox, ["test"], Selector.baseline())

    if status == 0 do
      {:ok, ms}
    else
      {:error, :baseline_failed, output}
    end
  end
end
