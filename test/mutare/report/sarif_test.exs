defmodule Mutare.Report.SarifTest do
  use ExUnit.Case, async: true

  alias Mutare.{Report.Sarif, Result, Site}

  defp site(id, file \\ "lib/a.ex") do
    %Site{
      id: id,
      file: file,
      line: 3,
      column: 5,
      range: %{start: [line: 3, column: 5], end: [line: 3, column: 11]},
      mutator: :relational,
      kind: :in_place,
      operation: :replace,
      original_code: "a >= b",
      mutated_code: "a > b"
    }
  end

  defp decode(results), do: results |> Sarif.render(%{}) |> JSON.decode!()

  test "emits a SARIF 2.1.0 log envelope with a tool driver and rule" do
    log = decode([%Result{site: site(1), status: :survived}])

    assert log["version"] == "2.1.0"
    assert log["$schema"] =~ "sarif-schema-2.1.0.json"
    assert [run] = log["runs"]
    assert run["tool"]["driver"]["name"] == "Mutare"
    assert [%{"id" => "surviving-mutant"}] = run["tool"]["driver"]["rules"]
  end

  test "emits one warning-level result per surviving mutant; killed/other are omitted" do
    results = [
      %Result{site: site(1), status: :survived},
      %Result{site: site(2), status: :killed},
      %Result{site: site(3), status: :survived}
    ]

    [run] = decode(results)["runs"]
    assert length(run["results"]) == 2
    assert Enum.all?(run["results"], &(&1["ruleId"] == "surviving-mutant"))
    assert Enum.all?(run["results"], &(&1["level"] == "warning"))
  end

  test "a result locates the mutant with a 1-based region and describes the mutation" do
    [run] = decode([%Result{site: site(1), status: :survived}])["runs"]
    [result] = run["results"]

    assert result["message"]["text"] =~ "relational"
    location = hd(result["locations"])["physicalLocation"]
    assert location["artifactLocation"]["uri"] == "lib/a.ex"

    assert location["region"] == %{
             "startLine" => 3,
             "startColumn" => 5,
             "endLine" => 3,
             "endColumn" => 11
           }
  end

  test "a multi-line negation mutant's endColumn is clamped to the operand, not past it" do
    # Regression: Sourceror over-counts a multi-line prefix `not`/`!` end column, and the raw value
    # used to flow verbatim into the SARIF region — pointing a few columns past the closing
    # delimiter (here into ` do`). `Mutare.Transform.NodeRange` now clamps it to the operand's real
    # end, so the machine reporter locates the real span.
    src = """
    defmodule M do
      def run(x) do
        if not valid?(
             long(x)
           ) do
          :ok
        end
      end
    end
    """

    %{sites: [site]} =
      Mutare.Transform.transform_string_with_sites(src, mutators: [Mutare.Mutators.Logical])

    [run] = decode([%Result{site: site, status: :survived}])["runs"]
    region = hd(hd(run["results"])["locations"])["physicalLocation"]["region"]

    # The `)` closes on line 5 column 8, so the exclusive end is column 9 (the over-count was 12).
    assert region["endLine"] == 5
    assert region["endColumn"] == 9
  end

  test "no survivors still yields a valid log with an empty results array" do
    [run] = decode([%Result{site: site(1), status: :killed}])["runs"]
    assert run["results"] == []
  end

  test "a broken partition becomes a warning notification on the run's invocation" do
    broken = %{partition: 2, mutant: 7, failure: :tests_failed, reason: "** (RuntimeError) no db"}

    results = [
      %Result{site: site(1), status: :killed, partition: 2},
      %Result{site: site(2), status: :killed, partition: 2},
      %Result{site: site(3), status: :killed, partition: 1}
    ]

    [run] =
      results
      |> Sarif.render(%{}, broken_partitions: [broken])
      |> JSON.decode!()
      |> Map.fetch!("runs")

    assert [%{"executionSuccessful" => true, "toolExecutionNotifications" => [notification]}] =
             run["invocations"]

    assert notification["level"] == "warning"
    assert notification["descriptor"] == %{"id" => "broken-partition"}

    assert notification["message"]["text"] ==
             "Partition 2's kills may be false: with no mutant active, the tests that killed " <>
               "mutant 7 failed: ** (RuntimeError) no db. Some of the 2 mutants killed there " <>
               "may be survivors missing from these results."

    [plain] = decode(results)["runs"]
    refute Map.has_key?(plain, "invocations")
  end
end
