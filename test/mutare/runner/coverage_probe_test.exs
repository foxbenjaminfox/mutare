defmodule Mutare.Runner.CoverageProbeTest do
  use ExUnit.Case, async: true

  alias Mutare.Runner.CoverageProbe

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
