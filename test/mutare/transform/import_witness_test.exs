defmodule Mutare.Transform.ImportWitnessTest do
  # Direct tests of the dead-code import-witness builder, focused on the fallback clauses and the
  # zero-arity witness an integration fixture seldom produces.
  use ExUnit.Case, async: true

  alias Mutare.Transform.ImportWitness

  describe "for_candidate/1" do
    test "nil for a candidate whose `:original` is not an AST node (the from_node fallback)" do
      assert ImportWitness.for_candidate(%{original: :not_a_node}) == nil
    end

    test "nil for a candidate without an `:original` key" do
      assert ImportWitness.for_candidate(%{}) == nil
    end
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
