defmodule Mutare.Runner.PartitionCheckTest do
  use ExUnit.Case, async: true

  alias Mutare.{Options, Result, Site}
  alias Mutare.Runner.{PartitionCheck, RunCtx}

  defp result(partition, status, ms \\ 100) do
    %Result{
      site: %Site{id: System.unique_integer([:positive]), file: "lib/calc.ex", line: 1},
      status: status,
      partition: partition,
      duration_ms: ms
    }
  end

  describe "kills_to_rerun/1" do
    test "takes each partition's fastest kill, in partition order" do
      fastest_3 = result(3, :killed, 5)
      fastest_2 = result(2, :timeout, 50)

      results = [
        result(3, :killed, 40),
        fastest_3,
        result(2, :killed, 60),
        fastest_2,
        result(2, :survived, 1)
      ]

      assert PartitionCheck.kills_to_rerun(results) == [fastest_2, fastest_3]
    end

    test "leaves out partition 1, which the baseline checked" do
      assert PartitionCheck.kills_to_rerun([result(1, :killed, 1)]) == []
    end

    test "leaves out a partition with no kill, and results with no partition" do
      results = [
        result(2, :survived),
        result(2, :harness_error),
        result(3, :no_coverage),
        result(nil, :killed)
      ]

      assert PartitionCheck.kills_to_rerun(results) == []
    end

    test "counts every kill status" do
      for status <- [:killed, :timeout, :atom_exhausted] do
        kill = result(2, status)
        assert PartitionCheck.kills_to_rerun([kill]) == [kill]
      end
    end
  end

  test "run/2 does nothing when partitioning is off" do
    ctx = %RunCtx{
      options: Options.new([]),
      sandbox: "unused",
      project_root: "unused",
      selection: {:run_all, nil},
      cap: 1000,
      scopes: %{},
      partitions: :disabled,
      deadline: nil,
      on_start: fn _ -> :ok end,
      reporter: fn _ -> :ok end,
      on_phase: fn _ -> :ok end
    }

    assert PartitionCheck.run(ctx, [result(2, :killed)]) == []
  end
end
