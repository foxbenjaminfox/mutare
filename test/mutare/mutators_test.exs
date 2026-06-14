defmodule Mutare.MutatorsTest do
  use ExUnit.Case, async: true

  alias Mutare.Mutators.{Arithmetic, Relational}

  describe "Arithmetic" do
    test "swaps binary arithmetic operators" do
      assert Arithmetic.mutate({:+, [], [1, 2]}) == [{:-, [], [1, 2]}]
      assert Arithmetic.mutate({:-, [], [1, 2]}) == [{:+, [], [1, 2]}]
      assert Arithmetic.mutate({:*, [], [1, 2]}) == [{:/, [], [1, 2]}]
      assert Arithmetic.mutate({:/, [], [1, 2]}) == [{:*, [], [1, 2]}]
      assert Arithmetic.mutate({:div, [], [1, 2]}) == [{:rem, [], [1, 2]}]
      assert Arithmetic.mutate({:rem, [], [1, 2]}) == [{:div, [], [1, 2]}]
    end

    test "preserves operand AST and operator metadata" do
      meta = [line: 7, column: 3]
      operands = [{:a, [], nil}, {:b, [], nil}]
      assert Arithmetic.mutate({:+, meta, operands}) == [{:-, meta, operands}]
    end

    test "skips unary minus (arity 1)" do
      assert Arithmetic.mutate({:-, [], [{:x, [], nil}]}) == :skip
    end

    test "skips non-arithmetic nodes" do
      assert Arithmetic.mutate({:>, [], [1, 2]}) == :skip
      assert Arithmetic.mutate({:foo, [], [1, 2]}) == :skip
      assert Arithmetic.mutate(42) == :skip
      assert Arithmetic.mutate({:x, [], nil}) == :skip
    end

    test "name and kind" do
      assert Arithmetic.name() == :arithmetic
      assert Arithmetic.kind() == :in_place
    end

    test "skips an identity right operand (the swap would be equivalent)" do
      a = {:a, [], nil}

      assert Arithmetic.mutate({:*, [], [a, 1]}) == :skip
      assert Arithmetic.mutate({:/, [], [a, 1]}) == :skip
      assert Arithmetic.mutate({:+, [], [a, 0]}) == :skip
      assert Arithmetic.mutate({:-, [], [a, 0]}) == :skip
    end

    test "recognizes Sourceror-wrapped literal operands" do
      a = {:a, [], nil}
      one = {:__block__, [token: "1"], [1]}
      zero = {:__block__, [token: "0"], [0]}

      assert Arithmetic.mutate({:*, [], [a, one]}) == :skip
      assert Arithmetic.mutate({:+, [], [a, zero]}) == :skip
    end

    test "only the right operand counts — left identities are real mutations" do
      a = {:a, [], nil}

      # 1 * a -> 1 / a is a reciprocal, 0 - a -> 0 + a flips a sign
      assert Arithmetic.mutate({:*, [], [1, a]}) == [{:/, [], [1, a]}]
      assert Arithmetic.mutate({:-, [], [0, a]}) == [{:+, [], [0, a]}]
      assert Arithmetic.mutate({:+, [], [0, a]}) == [{:-, [], [0, a]}]
    end

    test "div/rem are never treated as identity (rem(a, 1) is 0, not a)" do
      a = {:a, [], nil}
      assert Arithmetic.mutate({:div, [], [a, 1]}) == [{:rem, [], [a, 1]}]
      assert Arithmetic.mutate({:rem, [], [a, 1]}) == [{:div, [], [a, 1]}]
    end

    test "a non-identity literal (e.g. * 2, + 1) still mutates" do
      a = {:a, [], nil}
      assert Arithmetic.mutate({:*, [], [a, 2]}) == [{:/, [], [a, 2]}]
      assert Arithmetic.mutate({:+, [], [a, 1]}) == [{:-, [], [a, 1]}]
    end
  end

  describe "Relational" do
    test "ordering operators mutate to boundary neighbour and direction flip" do
      assert Relational.mutate({:>, [], [1, 2]}) == [{:>=, [], [1, 2]}, {:<, [], [1, 2]}]
      assert Relational.mutate({:>=, [], [1, 2]}) == [{:>, [], [1, 2]}, {:<=, [], [1, 2]}]
      assert Relational.mutate({:<, [], [1, 2]}) == [{:<=, [], [1, 2]}, {:>, [], [1, 2]}]
      assert Relational.mutate({:<=, [], [1, 2]}) == [{:<, [], [1, 2]}, {:>=, [], [1, 2]}]
    end

    test "equality operators flip polarity" do
      assert Relational.mutate({:==, [], [1, 2]}) == [{:!=, [], [1, 2]}]
      assert Relational.mutate({:!=, [], [1, 2]}) == [{:==, [], [1, 2]}]
      assert Relational.mutate({:===, [], [1, 2]}) == [{:!==, [], [1, 2]}]
      assert Relational.mutate({:!==, [], [1, 2]}) == [{:===, [], [1, 2]}]
    end

    test "skips non-relational nodes" do
      assert Relational.mutate({:+, [], [1, 2]}) == :skip
      assert Relational.mutate({:x, [], nil}) == :skip
      assert Relational.mutate(:atom) == :skip
    end

    test "name and kind" do
      assert Relational.name() == :relational
      assert Relational.kind() == :in_place
    end
  end
end
