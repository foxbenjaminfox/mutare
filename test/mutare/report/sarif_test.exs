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

  test "no survivors still yields a valid log with an empty results array" do
    [run] = decode([%Result{site: site(1), status: :killed}])["runs"]
    assert run["results"] == []
  end
end
