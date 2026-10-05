defmodule Mutare.Transform.ImportWitnessTest do
  # Direct tests of the dead-code import-witness builder, focused on the fallback clauses and the
  # zero-arity witness an integration fixture seldom produces.
  use ExUnit.Case, async: true

  alias Mutare.Transform.{Candidate, ImportWitness, Imports}
  alias Mutare.Transform.Candidate.Report

  describe "for_candidate/1" do
    test "nil for a candidate whose nodes are not AST calls (the from_node fallback)" do
      candidate = %Candidate.InPlace{
        mutator: nil,
        original: :not_a_node,
        mutated: :not_a_node,
        report: nil
      }

      assert ImportWitness.for_candidate(candidate) == nil
    end

    # An `InPlace`'s report may name a narrower edit than the call it executes (an adapter's
    # attributed clause, a written pipe stage), so its witnesses come from the executed nodes;
    # reading its report instead would lose the imported call's proof.
    test "an InPlace is witnessed by its executed nodes, not its narrower report" do
      original = witnessed_call(:flatten, {[:Enum], :flatten, 1})
      mutated = witnessed_call(:reverse, {[:Enum], :reverse, 1})
      inner = {:x, [line: 1, column: 9], nil}

      candidate = %Candidate.InPlace{
        mutator: nil,
        original: original,
        mutated: mutated,
        report: Report.replace(inner, {:y, [], nil}, range())
      }

      assert ImportWitness.for_candidate(candidate) ==
               [{[:Enum], :flatten, 1}, {[:Enum], :reverse, 1}]
    end

    test "every other candidate is witnessed by its report's nodes" do
      original = witnessed_call(:flatten, {[:Enum], :flatten, 1})
      candidate = %Candidate.RescueDrop{report: Report.delete(original, range())}

      assert ImportWitness.for_candidate(candidate) == {[:Enum], :flatten, 1}
    end
  end

  defp witnessed_call(fun, witness) do
    {fun, Imports.put_import_witness([line: 1, column: 1], witness), [{:x, [], nil}]}
  end

  defp range do
    Sourceror.Range.new([line: 1, column: 1], line: 1, column: 20)
  end

  describe "wrap/2" do
    test "a nil witness is a no-op" do
      node = {:x, [], nil}
      assert ImportWitness.wrap(node, nil) == node
    end

    test "a zero-arity witness builds a dead-code block (args(0) → no closure params)" do
      node = {:x, [], nil}
      assert {:__block__, [], [witness, ^node]} = ImportWitness.wrap(node, {[:Enum], :flatten, 0})
      # the witness is the `case false do …` scaffold carrying the import directive
      assert {:case, _, _} = witness
    end
  end

  describe "prepend/2" do
    test "nil witness is a no-op" do
      assert ImportWitness.prepend([do: 1], nil) == [do: 1]
    end

    test "a body that isn't a single keyword list is returned unchanged (the fallback)" do
      assert ImportWitness.prepend([1, 2], {[:Enum], :flatten, 1}) == [1, 2]
      assert ImportWitness.prepend(:not_a_body, {[:Enum], :flatten, 1}) == :not_a_body
    end
  end
end
