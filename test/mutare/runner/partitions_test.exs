defmodule Mutare.Runner.PartitionsTest do
  use ExUnit.Case, async: true

  alias Mutare.Runner.Partitions

  doctest Mutare.Runner.Partitions

  describe "disabled (no env name)" do
    test "new/2 is :disabled, and stop/1 is a no-op" do
      assert Partitions.new(nil, 4) == :disabled
      assert Partitions.stop(:disabled) == :ok
    end

    test "with_slot/2 yields no slot, and entry/2 and slot_entry/2 are empty" do
      assert Partitions.with_slot(:disabled, fn slot -> slot end) == nil
      assert Partitions.entry(nil, 1) == []
      assert Partitions.slot_entry(:disabled, nil) == []
    end
  end

  describe "slot_entry/2 (a pooled slot's env entry)" do
    test "names the slot under the pool's own variable" do
      pool = Partitions.new("MY_DB_SLOT", 3)
      assert Partitions.slot_entry(pool, 3) == [{"MY_DB_SLOT", "3"}]
      Partitions.stop(pool)
    end

    test "refuses no slot, or one outside the pool" do
      pool = Partitions.new("P", 2)

      for slot <- [nil, 0, 3] do
        assert_raise FunctionClauseError, fn -> Partitions.slot_entry(pool, slot) end
      end

      Partitions.stop(pool)
    end
  end

  describe "entry/2 (fixed partition for the baseline/probe)" do
    test "builds a single env tuple under the named var" do
      assert Partitions.entry("MIX_TEST_PARTITION", 1) == [{"MIX_TEST_PARTITION", "1"}]
      assert Partitions.entry("MY_DB_SLOT", 7) == [{"MY_DB_SLOT", "7"}]
    end
  end

  describe "with_slot/2 (the pool)" do
    test "hands the function this slot's number" do
      pool = Partitions.new("PART", 2)
      assert Partitions.with_slot(pool, fn slot -> slot end) == 1
      Partitions.stop(pool)
    end

    test "checks a slot back in after use, so a sequential caller reuses it" do
      pool = Partitions.new("P", 1)
      a = Partitions.with_slot(pool, & &1)
      b = Partitions.with_slot(pool, & &1)
      assert {a, b} == {1, 1}
      Partitions.stop(pool)
    end

    test "returns the slot even when the function raises (checkin in `after`)" do
      pool = Partitions.new("P", 1)

      assert_raise RuntimeError, fn ->
        Partitions.with_slot(pool, fn _slot -> raise "boom" end)
      end

      # The single slot was returned, so the next checkout still succeeds.
      assert Partitions.with_slot(pool, & &1) == 1
      Partitions.stop(pool)
    end

    # The whole point of the pool: under `max_concurrency == size` no two
    # concurrently-running tasks ever hold the same partition, the ids stay within
    # `1..size`, and they recycle (30 runs over 3 slots). A naive
    # `rem(index, workers)` would fail this — tasks don't finish in index order.
    test "never hands the same partition to two concurrent runs; recycles within 1..size" do
      size = 3
      pool = Partitions.new("PART", size)
      {:ok, live} = Agent.start_link(fn -> MapSet.new() end)

      results =
        1..30
        |> Task.async_stream(
          fn _i ->
            Partitions.with_slot(pool, fn n ->
              # Was this partition already checked out by another live run?
              collision? =
                Agent.get_and_update(live, fn held ->
                  {MapSet.member?(held, n), MapSet.put(held, n)}
                end)

              # Widen the concurrency window so a collision would actually overlap.
              Process.sleep(2)
              Agent.update(live, &MapSet.delete(&1, n))
              {n, collision?}
            end)
          end,
          max_concurrency: size,
          ordered: false,
          timeout: :infinity
        )
        |> Enum.map(fn {:ok, result} -> result end)

      Agent.stop(live)
      Partitions.stop(pool)

      partitions = Enum.map(results, &elem(&1, 0))

      assert length(partitions) == 30
      assert Enum.all?(partitions, &(&1 in 1..size))
      refute Enum.any?(results, fn {_n, collision?} -> collision? end)
    end
  end
end
