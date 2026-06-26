defmodule Mutare.Transform.SuppressionTest do
  # Direct tests of the equivalent-mutant suppression predicates. They are exercised
  # indirectly by the operator-family tests (StrictEquality/Relational/Logical under a
  # negation, etc.), but the bare-node and fallback clauses are most precisely pinned here.
  use ExUnit.Case, async: true

  alias Mutare.AST
  alias Mutare.Transform.Suppression, as: S

  defp op(name), do: {name, [], [{:a, [], nil}, {:b, [], nil}]}

  describe "negation_redundant?/2" do
    test "a true/false constant re-negates to the source (≡ Conditional under the outer not)" do
      assert S.negation_redundant?(AST.literal(true), :==)
      assert S.negation_redundant?(AST.literal(false), :==)
    end

    test "the polarity complement of the equality op is redundant (≡ Relational's flip)" do
      assert S.negation_redundant?(op(:!=), :==)
      assert S.negation_redundant?(op(:===), :!==)
    end

    test "a strictness relaxation (=== → ==) is NOT redundant — it survives" do
      refute S.negation_redundant?(op(:==), :===)
    end
  end

  describe "polarity_complement?/2" do
    test "true only for the operator's complement" do
      assert S.polarity_complement?(op(:!=), :==)
      assert S.polarity_complement?(op(:==), :!=)
      refute S.polarity_complement?(op(:==), :==)
    end

    test "false for an unknown op (no complement) and for a non-operator node" do
      refute S.polarity_complement?(op(:==), :not_an_op)
      # non-`{op, meta, args}` node → the fallback clause
      refute S.polarity_complement?({:a, [], nil}, :==)
      refute S.polarity_complement?(:bare_atom, :==)
    end
  end

  describe "boolean_literal?/2" do
    test "matches the block-wrapped literal (AST.literal/1's shape)" do
      assert S.boolean_literal?(AST.literal(true), true)
      assert S.boolean_literal?(AST.literal(false), false)
    end

    test "matches the bare boolean too" do
      assert S.boolean_literal?(true, true)
      assert S.boolean_literal?(false, false)
    end

    test "false on a mismatch or non-boolean" do
      refute S.boolean_literal?(AST.literal(true), false)
      refute S.boolean_literal?(AST.literal(1), true)
      refute S.boolean_literal?({:a, [], nil}, true)
    end
  end

  describe "boolean_op_node?/1" do
    test "true for a Conditional-eligible boolean operator node" do
      assert S.boolean_op_node?(op(:and))
      assert S.boolean_op_node?(op(:==))
    end

    test "false for a non-boolean operator and a non-node" do
      refute S.boolean_op_node?(op(:+))
      refute S.boolean_op_node?(:bare_atom)
    end
  end

  describe "redundant_constant/1" do
    test "false for and/&& (a false left short-circuits the node to false)" do
      assert S.redundant_constant(:and) == false
      assert S.redundant_constant(:&&) == false
    end

    test "true for or/|| (a true left short-circuits to true)" do
      assert S.redundant_constant(:or) == true
      assert S.redundant_constant(:||) == true
    end
  end
end
