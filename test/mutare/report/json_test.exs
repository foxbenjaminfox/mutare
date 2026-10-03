defmodule Mutare.Report.JsonTest do
  use ExUnit.Case, async: true

  alias Mutare.{Report.Json, Result, Site}
  alias Mutare.Run.BrokenPartition

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
      exit_status: opts[:exit_status],
      selection: opts[:selection]
    }
  end

  defp decode(results, sources \\ %{"lib/a.ex" => "a >= b"}, opts \\ []) do
    results |> Json.render(sources, opts) |> JSON.decode!()
  end

  test "a site with no result is Pending, beside the results, in id order" do
    pending = [site(3, file: "lib/a.ex"), site(1, file: "lib/b.ex", mutated_code: "a - b")]

    doc =
      decode([result(:killed, id: 2)], %{"lib/a.ex" => "a >= b", "lib/b.ex" => "a + b"},
        pending: pending
      )

    assert Enum.map(doc["files"]["lib/a.ex"]["mutants"], &{&1["id"], &1["status"]}) ==
             [{"2", "Killed"}, {"3", "Pending"}]

    assert [%{"id" => "1", "status" => "Pending", "replacement" => "a - b"} = mutant] =
             doc["files"]["lib/b.ex"]["mutants"]

    refute Map.has_key?(mutant, "duration")
    assert doc["files"]["lib/b.ex"]["source"] == "a + b"
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

    assert mutant["position"] == %{"line" => 3, "column" => 5}
  end

  test "position is where the mutant is keyed; location is the span its replacement patches" do
    # Removing the middle stage rewrites the whole pipe, so its patch starts at `xs` (line 3);
    # the mutant is keyed at the removed stage call (5:8), as the human report prints it.
    source = """
    defmodule Chain do
      def run(xs) do
        xs
        |> Enum.map(&(&1 * 2))
        |> Enum.uniq()
      end
    end
    """

    [removal] =
      Mutare.Transform.transform_string_with_sites(source,
        file: "lib/a.ex",
        mutators: [Mutare.Mutators.CallRemoval]
      ).sites

    [mutant] =
      decode([%Result{site: removal, status: :survived}], %{"lib/a.ex" => source})["files"][
        "lib/a.ex"
      ]["mutants"]

    assert mutant["location"]["start"] == %{"line" => 3, "column" => 5}
    assert mutant["position"] == %{"line" => 5, "column" => 8}
    assert Mutare.Site.location(removal) == "lib/a.ex:5:8"
  end

  test "position omits a missing column, and is absent with no line" do
    [with_line] =
      decode([%{result(:survived) | site: %{site(1, []) | column: nil}}])["files"]["lib/a.ex"][
        "mutants"
      ]

    assert with_line["position"] == %{"line" => 3}

    [bare] =
      decode([%{result(:survived) | site: %{site(1, []) | line: nil, column: nil}}])["files"][
        "lib/a.ex"
      ]["mutants"]

    refute Map.has_key?(bare, "position")
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

  test "records which tests the run covered as testSelection, only for a mutant that ran" do
    for shape <- [:suite, :app, :files, :tests] do
      [mutant] = decode([result(:killed, selection: shape)])["files"]["lib/a.ex"]["mutants"]
      assert mutant["testSelection"] == Atom.to_string(shape)
    end

    [bare] = decode([result(:no_coverage)])["files"]["lib/a.ex"]["mutants"]
    refute Map.has_key?(bare, "testSelection")
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

  describe "partitions" do
    @broken %BrokenPartition{partition: 2, mutant: 7, failure: :app_start, reason: nil}

    defp on_partition(status, partition, id),
      do: %{result(status, id: id) | partition: partition}

    test "records the partition a mutant's run used, only when partitioned" do
      [partitioned, bare] =
        decode([on_partition(:killed, 3, 1), result(:killed, id: 2)])["files"]["lib/a.ex"][
          "mutants"
        ]

      assert partitioned["partition"] == 3
      refute Map.has_key?(bare, "partition")
    end

    test "a kill on a broken partition says it may be false; nothing else does" do
      results = [
        on_partition(:killed, 2, 1),
        on_partition(:timeout, 2, 2),
        on_partition(:survived, 2, 3),
        on_partition(:killed, 1, 4)
      ]

      mutants =
        decode(results, %{"lib/a.ex" => "a >= b"}, broken_partitions: [@broken])["files"][
          "lib/a.ex"
        ]["mutants"]

      reason =
        "This kill may be false: on partition 2, where it ran, with no mutant active, " <>
          "the application would not start"

      assert Enum.map(mutants, & &1["statusReason"]) == [reason, reason, nil, nil]
    end
  end
end
