defmodule Mutare.Coverage.DumpTest do
  use ExUnit.Case, async: false

  # These tests own the capture tables; exclude them when this suite is itself
  # running under a coverage probe, whose tables must remain intact.
  @moduletag :coverage_tables
  @moduletag :tmp_dir

  import ExUnit.CaptureLog, only: [capture_log: 1]

  alias Mutare.Coverage
  alias Mutare.Coverage.HelperTemplate, as: H

  @tables [
    H.agg_table(),
    H.attr_table(),
    H.unlabeled_table(),
    H.test_table(),
    H.wholefile_table()
  ]

  setup %{tmp_dir: dir} do
    for table <- @tables do
      :ets.new(table, [:named_table, :public, :set])
    end

    path = Path.join(dir, "dump.terms")
    saved = System.get_env(H.dump_path_env())
    System.put_env(H.dump_path_env(), path)

    on_exit(fn ->
      if saved,
        do: System.put_env(H.dump_path_env(), saved),
        else: System.delete_env(H.dump_path_env())
    end)

    %{path: path}
  end

  test "initialized tables with no hits produce valid empty coverage", %{path: path} do
    assert :ok = H.dump(:ignored_suite_result)
    assert {:ok, coverage} = Coverage.read_dump(path, %{})
    assert coverage.aggregate == MapSet.new()
    assert coverage.by_file == %{}
    assert coverage.unlabeled == MapSet.new()
    assert coverage.by_test == %{}
    assert coverage.wholefile == MapSet.new()
  end

  for table <- @tables do
    @tag missing_table: table
    test "missing #{table} invalidates coverage and replaces any earlier dump", %{
      path: path,
      missing_table: table
    } do
      H.hit([1])
      assert :ok = H.dump(:ignored_suite_result)
      assert {:ok, coverage} = Coverage.read_dump(path)
      assert MapSet.member?(coverage.aggregate, 1)

      :ets.delete(table)
      assert :ok = H.dump(:ignored_suite_result)

      assert capture_log(fn ->
               assert {:error, {:missing_coverage_table, ^table}} = Coverage.read_dump(path)
             end) =~ "falling back to run-all"
    end
  end
end
