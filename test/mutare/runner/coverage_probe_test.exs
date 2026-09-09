defmodule Mutare.Runner.CoverageProbeTest do
  use ExUnit.Case, async: true

  alias Mutare.Runner.CoverageProbe
  alias Mutare.{Schema, Site}

  # A coverage dump shaped exactly as `Mutare.Coverage.read_dump/1` returns (MapSets throughout).
  defp coverage(fields) do
    %{
      aggregate: MapSet.new(fields[:aggregate] || []),
      by_file: Map.new(fields[:by_file] || %{}, fn {f, ids} -> {f, MapSet.new(ids)} end),
      unlabeled: MapSet.new(fields[:unlabeled] || []),
      by_test: Map.new(fields[:by_test] || %{}, fn {id, names} -> {id, MapSet.new(names)} end),
      wholefile: MapSet.new(fields[:wholefile] || [])
    }
  end

  defp schema(ids), do: %Schema{sites: Enum.map(ids, &%Site{id: &1})}

  describe "select/3 — :tests mode narrows to covering test cases" do
    test "a narrowable id runs its covering files plus one --only per covering test" do
      cov =
        coverage(
          aggregate: [1],
          by_file: %{"test/a_test.exs" => [1]},
          by_test: %{1 => ["test alpha", "test beta"]}
        )

      assert {:selective, %{1 => {:run, args}}} = CoverageProbe.select(:tests, schema([1]), cov)
      # File(s) first, then sorted `--only test:<name>` flags.
      assert args == ["test/a_test.exs", "--only", "test:test alpha", "--only", "test:test beta"]
    end

    test "narrowing unions files and names across the modules that covered a shared-lib id" do
      cov =
        coverage(
          aggregate: [7],
          by_file: %{"test/a_test.exs" => [7], "test/b_test.exs" => [7]},
          by_test: %{7 => ["test in b", "test in a"]}
        )

      assert {:selective, %{7 => {:run, args}}} = CoverageProbe.select(:tests, schema([7]), cov)

      assert args == [
               "test/a_test.exs",
               "test/b_test.exs",
               "--only",
               "test:test in a",
               "--only",
               "test:test in b"
             ]
    end

    test "an id with a non-narrowable (setup_all/on_exit) attribution keeps its whole covering files" do
      cov =
        coverage(
          aggregate: [2],
          by_file: %{"test/a_test.exs" => [2]},
          by_test: %{2 => ["test alpha"]},
          wholefile: [2]
        )

      # Even though a per-test name exists, the whole-file attribution forbids narrowing.
      assert {:selective, %{2 => {:run, ["test/a_test.exs"]}}} =
               CoverageProbe.select(:tests, schema([2]), cov)
    end

    test "an unlabeled id runs the whole suite (never narrowed)" do
      cov =
        coverage(
          aggregate: [3],
          by_file: %{"test/a_test.exs" => [3]},
          by_test: %{3 => ["test alpha"]},
          unlabeled: [3]
        )

      assert {:selective, %{3 => {:run, []}}} = CoverageProbe.select(:tests, schema([3]), cov)
    end

    test "a covered id with no per-test names falls back to whole covering files" do
      cov = coverage(aggregate: [4], by_file: %{"test/a_test.exs" => [4]}, by_test: %{})

      assert {:selective, %{4 => {:run, ["test/a_test.exs"]}}} =
               CoverageProbe.select(:tests, schema([4]), cov)
    end

    test "an id that never ran is :no_coverage" do
      cov = coverage(aggregate: [1], by_file: %{"test/a_test.exs" => [1]})

      assert {:selective, %{9 => :no_coverage}} = CoverageProbe.select(:tests, schema([9]), cov)
    end

    test "a valid empty aggregate skips every mutant in every selection mode" do
      for mode <- [:tests, :coverage, :full] do
        selection = CoverageProbe.select(mode, schema([1, 2]), coverage([]))
        assert selection == {:selective, %{1 => :no_coverage, 2 => :no_coverage}}

        assert CoverageProbe.summarize(selection) ==
                 %{covered: 0, no_coverage: 2, run_all?: false}

        refute CoverageProbe.broad_runs?(selection)
      end
    end
  end

  describe "select/3 — :coverage and :full are unchanged by the per-test data" do
    test ":coverage runs whole covering files, ignoring by_test" do
      cov =
        coverage(
          aggregate: [1],
          by_file: %{"test/a_test.exs" => [1]},
          by_test: %{1 => ["test alpha"]}
        )

      assert {:selective, %{1 => {:run, ["test/a_test.exs"]}}} =
               CoverageProbe.select(:coverage, schema([1]), cov)
    end

    test ":full runs the whole suite for any covered id" do
      cov = coverage(aggregate: [1], by_test: %{1 => ["test alpha"]})

      assert {:selective, %{1 => {:run, []}}} = CoverageProbe.select(:full, schema([1]), cov)
    end
  end

  describe "summarize/1" do
    test ":run_all carries no per-mutant counts" do
      assert CoverageProbe.summarize(:run_all) ==
               %{covered: 0, no_coverage: 0, run_all?: true}
    end

    test "a selective selection counts covered vs. no-coverage mutants" do
      selection =
        {:selective,
         %{
           1 => {:run, []},
           2 => {:run, ["test/a_test.exs"]},
           3 => :no_coverage,
           4 => {:run, ["test/b_test.exs"]},
           5 => :no_coverage
         }}

      assert CoverageProbe.summarize(selection) ==
               %{covered: 3, no_coverage: 2, run_all?: false}
    end

    test "an all-covered selection reports zero no-coverage" do
      selection = {:selective, %{1 => {:run, []}, 2 => {:run, []}}}

      assert CoverageProbe.summarize(selection) ==
               %{covered: 2, no_coverage: 0, run_all?: false}
    end
  end
end
