defmodule Mutare.Report.Sarif do
  @moduledoc """
  Renders surviving mutants as a SARIF 2.1.0 log.

  A surviving mutant is a gap in the suite at a specific location, which is
  exactly what SARIF models — so GitHub code scanning (and other SARIF
  consumers) surface each survivor as an inline annotation on the PR diff. Only
  `:survived` results become findings; killed/skipped mutants are not
  actionable and are omitted. The mutation description (`Mutare.Site.describe/1`)
  is reused verbatim as the finding message.

  Emitted by `mix mutare --format sarif`.
  """

  alias Mutare.{Result, Site}

  @schema "https://docs.oasis-open.org/sarif/sarif/v2.1.0/errata01/os/schemas/sarif-schema-2.1.0.json"
  @rule_id "surviving-mutant"

  @doc "Render the survivors in `results` as a SARIF 2.1.0 log string."
  @spec render([Result.t()], %{optional(String.t()) => String.t()}, keyword()) :: String.t()
  def render(results, _sources, _opts \\ []) do
    survivors = Enum.filter(results, &(&1.status == :survived))

    %{
      "$schema" => @schema,
      "version" => "2.1.0",
      "runs" => [
        %{
          "tool" => %{"driver" => %{"name" => "Mutare", "rules" => [rule()]}},
          "results" => Enum.map(survivors, &result/1)
        }
      ]
    }
    |> JSON.encode!()
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
