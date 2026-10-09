defmodule Mutare.Runner.MutantRun.AttemptsTest do
  use ExUnit.Case, async: true
  use PropCheck

  alias Mutare.Runner.MutantRun.Attempts
  alias Mutare.Runner.OutcomePolicy
  alias Mutare.Sandbox.Command.Result

  test "boot and harness retries spend independent budgets in either order" do
    for outcomes <- [
          [
            :boot_failure,
            :harness_error,
            :app_start_failure,
            :harness_error,
            :boot_failure,
            :app_start_failure,
            :passed
          ],
          [
            :harness_error,
            :boot_failure,
            :harness_error,
            :app_start_failure,
            :boot_failure,
            :app_start_failure,
            :passed
          ]
        ] do
      {result, trace} = run(outcomes, 2, 1)
      assert result.outcome == :passed
      assert length(trace) == 7
      assert Enum.count(trace, &match?({_, {:retry, :backoff}}, &1)) == 4
      assert Enum.count(trace, &match?({_, {:retry, :immediate}}, &1)) == 2
    end
  end

  test "each confirmation gets fresh budgets, and only settled durations accumulate" do
    outcomes = List.duplicate([:harness_error, :app_start_failure, :failed], 3) |> List.flatten()
    {result, trace} = run(outcomes, 1, 3)
    assert result.outcome == :failed
    assert result.output == "attempt 9"
    assert result.duration_ms == 3 + 6 + 9
    assert length(trace) == 9
    assert Enum.count(trace, &match?({_, :confirm}, &1)) == 2
  end

  test "a persistent startup kill spends its budget again for each confirmation" do
    {result, trace} = run(List.duplicate(:app_start_failure, 10), 0, 2)
    assert result.outcome == :app_start_failure
    assert result.duration_ms == 5 + 10
    assert Enum.count(trace, &match?({_, {:retry, :backoff}}, &1)) == 8
  end

  test "a passing confirmation stops immediately and keeps its own output" do
    {result, trace} = run([:failed, :harness_error, :passed, :failed], 1, 4)
    assert result.outcome == :passed
    assert result.output == "attempt 3"
    assert result.duration_ms == 1 + 3
    assert length(trace) == 3
  end

  test "an exhausted infrastructure failure ends confirmation without a verdict" do
    {result, trace} = run([:failed, :harness_error, :harness_error, :failed], 1, 3)
    assert result.outcome == :harness_error
    assert result.duration_ms == 1 + 3
    assert length(trace) == 3
  end

  test "SIGKILL ends immediately even during confirmation with unspent budgets" do
    {result, trace} = run([:failed, :sigkilled, :failed], 100, 100)
    assert result.outcome == :sigkilled
    assert result.duration_ms == 3
    assert length(trace) == 2
  end

  property "outcome sequences terminate within their budgets and require unanimous settled kills" do
    forall {outcomes, harness, kills} <-
             {list(elements(OutcomePolicy.outcomes())), integer(0, 5), integer(1, 5)} do
      {result, trace} = run(outcomes ++ [:passed], harness, kills)
      settled = for {attempt, action} <- trace, action in [:confirm, :done], do: attempt
      confirmations = Enum.count(trace, &match?({_, :confirm}, &1))
      last = List.last(settled)

      length(trace) <= kills * (1 + harness + 4) and
        confirmations < kills and
        Enum.all?(Enum.drop(settled, -1), &OutcomePolicy.kill?(&1.outcome)) and
        (not OutcomePolicy.kill?(result.outcome) or length(settled) == kills) and
        result == %{last | duration_ms: Enum.sum(Enum.map(settled, & &1.duration_ms))} and
        valid_budgets?(trace, harness)
    end
  end

  # Check the trace by attempt segments, independently of the machine's internal counters.
  # A segment ends at a confirmation or a final verdict. It can spend each budget once.
  defp valid_budgets?(trace, harness) do
    trace
    |> Enum.chunk_while(
      [],
      fn entry = {_, action}, acc ->
        if action in [:confirm, :done],
          do: {:cont, Enum.reverse([entry | acc]), []},
          else: {:cont, [entry | acc]}
      end,
      fn [] -> {:cont, []} end
    )
    |> Enum.all?(fn segment ->
      retries = Enum.drop(segment, -1)
      backoff = Enum.count(retries, &match?({_, {:retry, :backoff}}, &1))
      immediate = Enum.count(retries, &match?({_, {:retry, :immediate}}, &1))
      {last, _action} = List.last(segment)

      backoff <= 4 and immediate <= harness and
        Enum.all?(retries, fn
          {attempt, {:retry, :backoff}} ->
            OutcomePolicy.retry(attempt.outcome) == :boot_contention

          {attempt, {:retry, :immediate}} ->
            OutcomePolicy.retry(attempt.outcome) == :harness
        end) and
        case OutcomePolicy.retry(last.outcome) do
          :boot_contention -> backoff == 4
          :harness -> immediate == harness
          :none -> true
        end
    end)
  end

  defp run(outcomes, harness, kills) do
    outcomes
    |> Enum.with_index(1)
    |> Enum.reduce_while({Attempts.new(harness, kills), []}, fn {outcome, i}, {state, trace} ->
      result = %Result{outcome: outcome, duration_ms: i, output: "attempt #{i}", exit_status: i}

      case Attempts.next(state, result) do
        {:retry, delay, next} -> {:cont, {next, [{result, {:retry, delay}} | trace]}}
        {:confirm, next} -> {:cont, {next, [{result, :confirm} | trace]}}
        {:done, final} -> {:halt, {final, Enum.reverse([{result, :done} | trace])}}
      end
    end)
  end
end
