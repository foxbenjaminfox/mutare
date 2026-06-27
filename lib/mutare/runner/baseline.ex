defmodule Mutare.Runner.Baseline do
  @moduledoc """
  Run the complete test suite green-checked against the baseline mutant
  (`MUTANT_UNDER_TEST=0`) — once, or several times to catch a flaky suite.

  This is the authoritative green check *and* the source of `baseline_ms`. Two
  things hang on it being a run of the *whole* suite:

    * **Timing.** `baseline_ms` is the wall-clock of one process boot plus the
      suite, which the runner scales into the per-mutant timeout cap. Summing
      per-file probe runs (as the old conflated probe did) folded N process boots
      into the figure and inflated every mutant's cap. When the suite runs more
      than once (see flakiness, below) we take the **slowest** green run, so the
      cap stays conservative.
    * **Green-ness.** The suite is confirmed green *together*. A per-file probe
      never runs the suite as a whole, so a cross-file dependency could pass
      file-by-file (or fail in isolation) without the suite's real state ever
      being checked.

  Mutation testing on a red suite is meaningless — every "kill" is suspect — so a
  non-green baseline aborts the run: `{:error, :baseline_failed, output}`. No
  `--cover` here: mutant runs don't use it, so an uninstrumented baseline times
  the cap against like conditions (and the `--cover` instrumentation belongs to
  `Mutare.Runner.CoverageProbe`, which runs separately afterwards).

  ## Flakiness (`:baseline_runs`)

  A flaky test — one that passes/fails nondeterministically *regardless of the
  mutant* — is corrosive here: when it goes red during a mutant's run it marks
  that mutant killed, a **false kill** that hides a real survivor. Flakiness is a
  property of the suite, not of any one mutant, so the cheapest place to catch it
  is right here: run the baseline up to `:baseline_runs` times (default 1) and
  classify the outcomes (`classify/1`):

    * **all green** → proceed (`{:ok, slowest_green_ms}`);
    * **all red** → `{:error, :baseline_failed, output}` (a deterministically
      broken suite — unchanged from a single run);
    * **mixed** → a test disagreed with itself → `{:error, :baseline_flaky,
      detail}`, aborting loudly with the flaky tests named, rather than scoring
      against a suite that manufactures false kills.

  Collection short-circuits the moment outcomes disagree — flakiness is already
  proven, so there's no point running the rest. With `:baseline_runs` at its
  default of 1 this is exactly the old single-run behavior: one run, green or red.
  """

  alias Mutare.Selector
  alias Mutare.Sandbox.Command
  alias Mutare.Sandbox.Command.{Invocation, Output}

  @type outcome :: {:pass, non_neg_integer()} | {:fail, String.t()}
  @type result ::
          {:ok, non_neg_integer()}
          | {:error, :baseline_failed, String.t()}
          | {:error, :baseline_flaky, String.t()}

  @doc """
  Run the whole suite up to `runs` times at baseline, then classify (`classify/1`).
  Returns `{:ok, baseline_ms}` when consistently green, `{:error, :baseline_failed,
  output}` when consistently red, or `{:error, :baseline_flaky, detail}` when the
  runs disagree.

  `env` is extra environment for each run — a fixed partition entry (e.g.
  `MIX_TEST_PARTITION=1`) when `:partition_env` is on, so a partitioned suite finds
  a valid database; `[]` (the default) adds none. The baseline is sequential, so
  one fixed partition suffices (`Mutare.Runner.Partitions`).
  """
  @spec run(Path.t(), pos_integer(), [{String.t(), String.t()}]) :: result()
  def run(sandbox, runs \\ 1, env \\ []) when is_integer(runs) and runs >= 1 do
    sandbox |> collect(runs, env) |> classify()
  end

  @doc """
  Classify a non-empty list of baseline run outcomes into a run result.

  Pure: the I/O lives in `run/2`, the decision (and the flaky message) here, so it
  is unit-testable without spawning `mix`. All green → `{:ok, slowest_ms}`; all red
  → `{:error, :baseline_failed, _}`; a mix of both → `{:error, :baseline_flaky, _}`.
  """
  @spec classify([outcome()]) :: result()
  def classify(outcomes) do
    passes = for {:pass, ms} <- outcomes, do: ms
    fails = for {:fail, output} <- outcomes, do: output

    cond do
      # Slowest green run: under N runs a tight cap would false-timeout a
      # slow-but-finite mutant, so we keep the most generous green timing.
      fails == [] -> {:ok, Enum.max(passes)}
      passes == [] -> {:error, :baseline_failed, List.last(fails)}
      true -> {:error, :baseline_flaky, flaky_detail(fails)}
    end
  end

  # Run the suite up to `runs` times, stopping as soon as the outcomes disagree
  # (a pass and a fail both seen → flakiness proven, the rest would be wasted).
  @spec collect(Path.t(), pos_integer(), [{String.t(), String.t()}]) :: [outcome()]
  defp collect(sandbox, runs, env) do
    Enum.reduce_while(1..runs, [], fn _i, acc ->
      {ms, output, status} =
        Invocation.timed_mix(sandbox, ["test"], Selector.baseline(), nil, env)

      acc = [run_outcome(status, ms, output) | acc]
      if disagree?(acc), do: {:halt, acc}, else: {:cont, acc}
    end)
  end

  # `Command.success?/1` owns the "0 means success" reading of the exit code.
  defp run_outcome(status, ms, output) do
    if Command.success?(status), do: {:pass, ms}, else: {:fail, output}
  end

  defp disagree?(outcomes) do
    Enum.any?(outcomes, &match?({:pass, _}, &1)) and
      Enum.any?(outcomes, &match?({:fail, _}, &1))
  end

  # Name the tests that disagreed with themselves so the abort is actionable.
  # Best-effort: extract test-file locations from a failing run's output (a
  # `mix test` failure block prints `test/…_test.exs:NN`); fall back to the raw
  # output tail when nothing parses (we abort regardless, so this only shapes the
  # message).
  defp flaky_detail(fails) do
    output = List.last(fails)
    tests = failing_tests(output)

    named =
      case tests do
        [] ->
          "Could not pin the flaky test(s); failing run output (tail):\n\n#{Output.output_tail(output)}"

        locations ->
          "Tests that disagreed with themselves:\n" <> Enum.map_join(locations, "\n", &"  #{&1}")
      end

    "the suite passed on some baseline runs and failed on others.\n\n" <> named
  end

  # The `test_file:line` pattern is owned by `Mutare.Sandbox.Command.Output` (the
  # home of everything that parses mix's output), so a mix output-format change is
  # one fix.
  defp failing_tests(output) do
    Output.test_location_regex()
    |> Regex.scan(output)
    |> Enum.map(fn [_match, file, line] -> "#{file}:#{line}" end)
    |> Enum.uniq()
  end
end
