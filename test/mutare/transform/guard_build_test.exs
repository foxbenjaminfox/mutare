defmodule Mutare.Transform.GuardBuildTest do
  # Direct tests of the dispatch-guard builders, including the multi-alternative `when` and the
  # defensive multi-guard fold that the lifted path produces only rarely.
  use ExUnit.Case, async: true

  alias Mutare.Transform.GuardBuild

  describe "and_into/2" do
    test "no original guard leaves just the gate" do
      gate = {:===, [], [{:mutare_active, [], nil}, 1]}
      assert GuardBuild.and_into(gate, nil) == gate
    end

    test "ands the gate into a plain guard expression" do
      gate = {:===, [], [{:mutare_active, [], nil}, 1]}
      expr = {:>, [], [{:a, [], nil}, 0]}
      assert {:and, [], [^gate, ^expr]} = GuardBuild.and_into(gate, expr)
    end

    test "distributes into each alternative of a `when a when b` node" do
      gate = {:===, [], [{:mutare_active, [], nil}, 1]}
      alts = [{:>, [], [{:a, [], nil}, 0]}, {:<, [], [{:a, [], nil}, 9]}]

      assert {:when, [], [first, second]} = GuardBuild.and_into(gate, {:when, [], alts})
      assert {:and, [], [^gate, _]} = first
      assert {:and, [], [^gate, _]} = second
    end
  end

  describe "combine/1" do
    test "[] → nil, [g] → g, and multiple → a left-folded `and`" do
      assert GuardBuild.combine([]) == nil

      g = {:>, [], [{:a, [], nil}, 0]}
      assert GuardBuild.combine([g]) == g

      a = {:>, [], [{:a, [], nil}, 0]}
      b = {:<, [], [{:a, [], nil}, 9]}
      assert {:and, [], [^a, ^b]} = GuardBuild.combine([a, b])
    end
  end
end
