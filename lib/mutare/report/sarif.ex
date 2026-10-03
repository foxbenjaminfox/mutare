defmodule Mutare.Report.Sarif do
  @moduledoc """
  Renders surviving mutants as a SARIF 2.1.0 log.

  A surviving mutant is a gap in the suite at a specific location, which is exactly what SARIF models — so GitHub code scanning (and other SARIF consumers) surface each survivor as an inline annotation on the PR diff. Only `:survived` results become findings; killed/skipped mutants are not actionable and are omitted. The mutation description (`Mutare.Site.describe/1`) is reused verbatim as the finding message.

  Under `--partition-db`, a partition whose environment failed the tests with no mutant active (`Mutare.Run`'s `:broken_partitions`) becomes a warning-level tool execution notification on the run's invocation: its kills may be false, so survivors may be missing from the findings.

  Emitted by `mix mutare --report sarif` or `mix mutare --report sarif:path.sarif`.
  """

  alias Mutare.{Report, Result, Site}
  alias Mutare.Run.BrokenPartition

  @schema "https://docs.oasis-open.org/sarif/sarif/v2.1.0/errata01/os/schemas/sarif-schema-2.1.0.json"
  @rule_id "surviving-mutant"
  @broken_partition_id "broken-partition"

  @doc """
  Render the survivors in `results` as a SARIF 2.1.0 log string. `opts[:broken_partitions]`
  (`Mutare.Run`'s) become notifications on the run's invocation.
  """
  @spec render([Result.t()], %{optional(String.t()) => String.t()}, keyword()) :: String.t()
  def render(results, _sources, opts \\ []) do
    survivors = Enum.filter(results, &(&1.status == :survived))

    %{
      "$schema" => @schema,
      "version" => "2.1.0",
      "runs" => [
        Keyword.get(opts, :broken_partitions, [])
        |> invocation(results)
        |> Map.merge(%{
          "tool" => %{"driver" => %{"name" => "Mutare", "rules" => [rule()]}},
          "results" => Enum.map(survivors, &result/1)
        })
      ]
    }
    |> JSON.encode!()
  end

  # The run completed either way; the notifications say its kills on those partitions
  # may be false.
  defp invocation([], _results), do: %{}

  defp invocation(broken_partitions, results) do
    %{
      "invocations" => [
        %{
          "executionSuccessful" => true,
          "toolExecutionNotifications" =>
            Enum.map(broken_partitions, &broken_partition(&1, results))
        }
      ]
    }
  end

  defp broken_partition(%BrokenPartition{partition: partition} = broken, results) do
    kills = BrokenPartition.kills(broken, results)

    %{
      "level" => "warning",
      "descriptor" => %{"id" => @broken_partition_id},
      "message" => %{
        "text" =>
          "Partition #{partition}'s kills may be false: with no mutant active, " <>
            "#{Report.rerun_failure(broken)}. Some of the #{kills} mutants killed there " <>
            "may be survivors missing from these results."
      }
    }
  end

  defp rule do
    %{
      "id" => @rule_id,
      "name" => "SurvivingMutant",
      "shortDescription" => %{"text" => "A mutant survived the test suite."},
      "fullDescription" => %{
        "text" =>
          "The suite still passed when this code was mutated, so no test " <>
            "distinguishes the original behaviour from the mutation."
      }
    }
  end

  defp result(%Result{site: site}) do
    %{
      "ruleId" => @rule_id,
      "level" => "warning",
      "message" => %{"text" => Site.describe(site)},
      "locations" => [location(site)]
    }
  end

  defp location(%Site{} = site) do
    %{
      "physicalLocation" => %{
        "artifactLocation" => %{"uri" => site.file},
        "region" => region(site.range)
      }
    }
  end

  defp region(range) do
    %{
      "startLine" => range.start[:line],
      "startColumn" => range.start[:column],
      "endLine" => range.end[:line],
      "endColumn" => range.end[:column]
    }
  end
end
