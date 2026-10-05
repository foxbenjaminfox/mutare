defmodule Mutare.Runner.PartitionCheck do
  @moduledoc false
  # After the per-mutant phase, warn about a partition (`:partition_env`) whose kills may be
  # false. Only partition 1 is used before the mutants run — the compile, baseline and
  # coverage probe all run there — so a partition whose environment is broken (its database
  # missing or unmigrated) fails every run there, and each failure records as a kill.
  #
  # Each other partition is asked directly: the tests behind its fastest kill run again
  # there with no mutant active. The baseline passed them, so on a working partition they
  # pass again. The fastest kill because it is the cheapest to rerun and a broken
  # environment fails at once; a partition with no kill has nothing to doubt. The rerun
  # fails only if it fails on every `:kill_runs` attempt, as a kill must, so a user who has
  # called the suite flaky is not told a partition is broken on one failure.
  # With `:confirm_timeouts`, a timed-out rerun is repeated on its original partition
  # after all concurrent checks finish, so contention cannot masquerade as a broken
  # environment when compared with the uncontended partition-1 control.
  #
  # A rerun that fails is then checked against a control: the same tests, with no mutant
  # active, on partition 1. If the control passes, partition k is broken — its environment
  # killed that mutant, not the mutation. If it fails too, the tests fail with no mutant
  # wherever they run — they rely on tests outside their selection, or are flaky — so the
  # kills they made may be false on any partition, and the warning says that instead. A
  # rerun, confirmation or control that reaches no verdict warns only that the partition
  # could not be checked, and records nothing.
  # Verdicts are left as recorded: the warning names the partition so the user can repair
  # it and rerun. NOTES "A partition's kills are checked by rerunning one with no mutant".

  alias Mutare.{Result, Site}
  alias Mutare.Run.BrokenPartition
  alias Mutare.Runner.{MutantRun, OutcomePolicy, RunCtx}
  alias Mutare.Sandbox.Command.Output

  require Logger

  # The partition the baseline checked.
  @baseline_partition 1

  @doc """
  Rerun each partition's fastest kill (`kills_to_rerun/1`) there with no mutant active,
  and warn about each partition where those tests fail while they pass on partition 1.
  Returns those partitions, for `Mutare.Run`'s `:broken_partitions`. When partitioning is
  off, no result has a partition, so there is nothing to rerun.

  Announces `{:checking_partitions, count}` through `on_phase` when there is something to
  rerun: no result reports in while it runs, so without it the finished progress display
  would sit still. The reruns run at once, one per partition. Once they all finish,
  timeout confirmations (`:confirm_timeouts`) and controls on partition 1 run
  sequentially, so this must run after the stream, while no pooled run holds a
  partition. It ignores the time budget: it launches no mutant. Each confirmation and
  control adds capped `:kill_runs` attempts and their infrastructure retries.
  """
  @spec run(RunCtx.t(), [Result.t()]) :: [BrokenPartition.t()]
  def run(%RunCtx{} = ctx, results) do
    case kills_to_rerun(results) do
      [] ->
        []

      kills ->
        ctx.on_phase.({:checking_partitions, length(kills)})

        kills
        |> Task.async_stream(&rerun(ctx, &1), max_concurrency: length(kills), timeout: :infinity)
        |> Enum.flat_map(fn {:ok, failed} -> failed end)
        # Drain every concurrent check before confirming timeouts without contention.
        |> Enum.flat_map(&confirm_timeout(ctx, &1))
        # Partition 1 is one environment, so the controls run one at a time.
        |> Enum.flat_map(&control(ctx, &1))
    end
  end

  @doc """
  The kill to rerun for each partition other than partition 1, in partition order: its
  fastest. Pure.
  """
  @spec kills_to_rerun([Result.t()]) :: [Result.t()]
  def kills_to_rerun(results) do
    results
    |> Enum.filter(&(&1.partition not in [nil, @baseline_partition] and Result.kill?(&1.status)))
    |> Enum.group_by(& &1.partition)
    |> Enum.sort()
    |> Enum.map(fn {_partition, kills} -> Enum.min_by(kills, & &1.duration_ms) end)
  end

  # The kill's tests, rerun on its own partition with no mutant.
  defp rerun(%RunCtx{} = ctx, %Result{site: site, partition: partition} = kill) do
    selection = MutantRun.selection(ctx, site)
    failed_on_partition(kill, selection, MutantRun.unmutated(ctx, selection, partition))
  end

  defp confirm_timeout(
         %RunCtx{options: %{confirm_timeouts: true}} = ctx,
         {%Result{partition: partition} = kill, selection, %{outcome: :timeout}}
       ) do
    failed_on_partition(kill, selection, MutantRun.unmutated(ctx, selection, partition))
  end

  defp confirm_timeout(_ctx, failed), do: [failed]

  # `[{kill, selection, rerun}]` when the rerun on the kill's partition failed; `[]` when it
  # passed, or when it reached no verdict, which leaves that partition unchecked.
  defp failed_on_partition(%Result{site: site, partition: partition} = kill, selection, rerun) do
    cond do
      OutcomePolicy.kill?(rerun.outcome) ->
        [{kill, selection, rerun}]

      rerun.outcome == :passed ->
        []

      true ->
        warn_unchecked(
          partition,
          "the tests that killed #{mutant(site)} reached no verdict there with no mutant " <>
            "active (#{rerun.outcome})",
          rerun
        )

        []
    end
  end

  defp control(%RunCtx{} = ctx, {%Result{site: site, partition: partition}, selection, rerun}) do
    control = MutantRun.unmutated(ctx, selection, @baseline_partition)

    cond do
      control.outcome == :passed ->
        broken = %BrokenPartition{
          partition: partition,
          mutant: site.id,
          failure: failure(rerun.outcome),
          reason: Output.salient_line(rerun.output)
        }

        warn(ctx, site, broken)
        [broken]

      OutcomePolicy.kill?(control.outcome) ->
        warn_fails_everywhere(site, partition, control)
        []

      true ->
        warn_unchecked(
          partition,
          "with no mutant active, the tests that killed #{mutant(site)} fail there, but on " <>
            "partition #{@baseline_partition} they reached no verdict (#{control.outcome}), " <>
            "so Mutare could not tell whether partition #{partition} is to blame",
          control
        )

        []
    end
  end

  defp failure(:app_start_failure), do: :app_start
  defp failure(:timeout), do: :timeout
  defp failure(_failed), do: :tests_failed

  defp warn(%RunCtx{options: options}, %Site{} = site, %BrokenPartition{} = broken) do
    env = options.partition_env
    partition = broken.partition
    what_failed = BrokenPartition.what_failed(broken, mutant(site))

    Logger.warning(
      "partition #{partition}'s kills may be false. With no mutant active, " <>
        "#{what_failed} on partition #{partition}, though the " <>
        "same tests pass on partition #{@baseline_partition}. Every run on partition " <>
        "#{partition} may have failed the same way and been counted as a kill. Check that " <>
        "whatever #{env}=#{partition} selects (its database, say) exists and is set up like " <>
        "#{env}=#{@baseline_partition}'s, then rerun." <> ended_with(broken.reason)
    )
  end

  defp warn_fails_everywhere(%Site{} = site, partition, control) do
    Logger.warning(
      "with no mutant active, the tests that killed #{mutant(site)} on partition " <>
        "#{partition} fail there and on partition #{@baseline_partition} too, though the " <>
        "whole suite passed in the baseline. Run as Mutare selects them, they fail on " <>
        "their own — they may rely on tests outside the selection, or be flaky — so the " <>
        "kills they make may be false on any partition. Check that they pass when run " <>
        "alone, or rerun with --kill-runs 2 if they are flaky." <>
        ended_with(Output.salient_line(control.output))
    )
  end

  # A check that could not finish: `partition`'s kills stand unchecked, and nothing is
  # recorded, so no report or gate hears of it. `run` is the attempt that reached no verdict.
  defp warn_unchecked(partition, why, run) do
    Logger.warning(
      "could not check partition #{partition}'s kills: #{why}." <>
        ended_with(Output.salient_line(run.output))
    )
  end

  defp mutant(%Site{} = site), do: "mutant #{site.id} (#{Site.location(site)})"

  defp ended_with(nil), do: ""
  defp ended_with(reason), do: "\nThe rerun ended with: #{reason}"
end
