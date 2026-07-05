defmodule Mutare.Report.JsonTest do
  use ExUnit.Case, async: true

  alias Mutare.{Report.Json, Result, Site}

  defp site(id, opts) do
    %Site{
      id: id,
      file: Keyword.get(opts, :file, "lib/a.ex"),
      line: 3,
      column: 5,
      range: %{start: [line: 3, column: 5], end: [line: 3, column: 11]},
      mutator: Keyword.get(opts, :mutator, :relational),
      kind: :in_place,
      operation: :replace,
      original_code: "a >= b",
      mutated_code: Keyword.get(opts, :mutated_code, "a > b"),
      ignore_reason: Keyword.get(opts, :ignore_reason)
    }
  end

  defp result(status, opts \\ []) do
    %Result{
      site: site(Keyword.get(opts, :id, 1), opts),
      status: status,
      duration_ms: opts[:duration_ms],
      output: opts[:output],
      exit_status: opts[:exit_status]
    }
  end

  defp decode(results, sources \\ %{"lib/a.ex" => "a >= b"}, opts \\ []) do
    results |> Json.render(sources, opts) |> JSON.decode!()
  end

  test "emits the schema envelope: version, thresholds, files" do
    doc = decode([result(:survived)])
    assert doc["schemaVersion"] == "1.0"
    assert doc["thresholds"] == %{"high" => 80, "low" => 60}
    assert Map.has_key?(doc["files"], "lib/a.ex")
  end

  test "thresholds collapse onto the gate when :min_score is set" do
    doc = decode([result(:survived)], %{"lib/a.ex" => "a >= b"}, min_score: 70)
    assert doc["thresholds"] == %{"high" => 70, "low" => 70}
  end

  test "a file carries language, source, and its mutants" do
    doc = decode([result(:survived)], %{"lib/a.ex" => "the source"})
    file = doc["files"]["lib/a.ex"]

    assert file["language"] == "elixir"
    assert file["source"] == "the source"
    assert [mutant] = file["mutants"]
    assert mutant["id"] == "1"
    assert mutant["mutatorName"] == "relational"
    assert mutant["replacement"] == "a > b"
    assert mutant["status"] == "Survived"

    assert mutant["location"] == %{
             "start" => %{"line" => 3, "column" => 5},
             "end" => %{"line" => 3, "column" => 11}
           }
  end

  test "maps every Mutare status onto the schema's MutantStatus vocabulary" do
    pairs = [
      {:killed, "Killed"},
      {:survived, "Survived"},
      {:no_coverage, "NoCoverage"},
      {:timeout, "Timeout"},
      {:atom_exhausted, "Timeout"},
      {:ignored, "Ignored"},
      {:poisoned, "CompileError"},
      {:harness_error, "RuntimeError"}
    ]

    for {status, expected} <- pairs do
      doc = decode([result(status)])
      assert [%{"status" => ^expected}] = doc["files"]["lib/a.ex"]["mutants"]
    end
  end

  test "includes killed mutants too — the report shows the full picture, not just survivors" do
    doc = decode([result(:killed, id: 1), result(:survived, id: 2)])
    statuses = doc["files"]["lib/a.ex"]["mutants"] |> Enum.map(& &1["status"]) |> Enum.sort()
    assert statuses == ["Killed", "Survived"]
  end

  test "records statusReason and duration only when present" do
    doc = decode([result(:ignored, ignore_reason: "deliberate", duration_ms: 42)])
    [mutant] = doc["files"]["lib/a.ex"]["mutants"]
    assert mutant["statusReason"] == "deliberate"
    assert mutant["duration"] == 42

    [bare] = decode([result(:survived)])["files"]["lib/a.ex"]["mutants"]
    refute Map.has_key?(bare, "statusReason")
    refute Map.has_key?(bare, "duration")
  end

  test "records a compact harness-error diagnostic as statusReason" do
    doc =
      decode([
        result(:harness_error,
          exit_status: 99,
          output: "\nCompiling 1 file\n** (RuntimeError) database checkout failed\n"
        )
      ])

    [mutant] = doc["files"]["lib/a.ex"]["mutants"]
    assert mutant["status"] == "RuntimeError"
    assert mutant["statusReason"] == "exit 99; ** (RuntimeError) database checkout failed"
  end

  test "a clause-drop mutant has an empty replacement" do
    drop = %Result{
      status: :survived,
      site:
        Site.clause_drop(
          7,
          "lib/a.ex",
          %{start: [line: 2, column: 3], end: [line: 4, column: 8]},
          Sourceror.parse_string!("def f(0) do\n  :z\nend")
        )
    }

    [mutant] = decode([drop])["files"]["lib/a.ex"]["mutants"]
    assert mutant["replacement"] == ""
    assert mutant["mutatorName"] == "clause_drop"
  end

  test "groups mutants under their file" do
    doc =
      decode(
        [result(:survived, id: 1, file: "lib/a.ex"), result(:killed, id: 2, file: "lib/b.ex")],
        %{"lib/a.ex" => "aaa", "lib/b.ex" => "bbb"}
      )

    assert map_size(doc["files"]) == 2
    assert length(doc["files"]["lib/a.ex"]["mutants"]) == 1
    assert length(doc["files"]["lib/b.ex"]["mutants"]) == 1
  end

  test "render/2 (opts defaulted) and a range-less site fall back to a 1,1 location" do
    # `render/2` exercises the defaulted-opts head, and a `range: nil` site (a malformed-site
    # guard the typespec allows) drives the `location(nil)` default rather than crashing.
    rangeless = %{site(7, []) | range: nil}
    result = %Result{site: rangeless, status: :survived, duration_ms: nil}

    doc = Json.render([result], %{"lib/a.ex" => "a >= b"}) |> JSON.decode!()
    mutant = hd(doc["files"]["lib/a.ex"]["mutants"])

    assert mutant["location"] == %{
             "start" => %{"line" => 1, "column" => 1},
             "end" => %{"line" => 1, "column" => 1}
           }
  end
end
