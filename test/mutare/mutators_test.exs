defmodule Mutare.MutatorsTest do
  use ExUnit.Case, async: true

  alias Mutare.Mutators
  alias Mutare.Mutators.{Arithmetic, Relational}

  describe "registry (single source of truth)" do
    test "all/0 is the registry's modules, in order — the default/`:all` set" do
      assert Mutators.all() == Keyword.values(Mutators.registry())
      assert Mutators.all() == [Arithmetic, Relational]
    end

    test "families/0 are the registry's keys, in order" do
      assert Mutators.families() == Keyword.keys(Mutators.registry())
      assert Mutators.families() == [:arithmetic, :relational]
    end

    test "resolve/1 maps family atoms to modules, preserving order" do
      assert Mutators.resolve([:relational, :arithmetic]) == [Relational, Arithmetic]
    end

    test "resolve/1 accepts a custom module implementing the behaviour, mixed with families" do
      assert Mutators.resolve([:arithmetic, Mutare.Test.BooleanMutator]) ==
               [Arithmetic, Mutare.Test.BooleanMutator]
    end

    test "resolve/1 is idempotent on already-resolved modules" do
      assert Mutators.resolve(Mutators.all()) == Mutators.all()
    end

    test "resolve/1 raises on an unknown family, listing the known ones" do
      message =
        assert_raise(ArgumentError, fn -> Mutators.resolve([:bogus_family]) end)
        |> Exception.message()

      assert message =~ "unknown mutator :bogus_family"
      assert message =~ "arithmetic"
      assert message =~ "relational"
    end

    test "resolve/1 raises on a module that does not implement the behaviour" do
      message =
        assert_raise(ArgumentError, fn -> Mutators.resolve([Enum]) end)
        |> Exception.message()

      assert message =~ "implementing Mutare.Mutator"
      assert message =~ "missing mutate/1"
    end

    test "resolve/1 reports a non-atom entry rather than crashing on a guard" do
      assert_raise ArgumentError, ~r/unknown mutator "Arithmetic"/, fn ->
        Mutators.resolve(["Arithmetic"])
      end
    end
  end

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

    test "name" do
      assert Arithmetic.name() == :arithmetic
    end

    test "skips a multiplicative identity right operand (a * 1, a / 1)" do
      a = {:a, [], nil}

      assert Arithmetic.mutate({:*, [], [a, 1]}) == :skip
      assert Arithmetic.mutate({:/, [], [a, 1]}) == :skip
    end

    test "recognizes Sourceror-wrapped literal operands" do
      a = {:a, [], nil}
      one = {:__block__, [token: "1"], [1]}

      assert Arithmetic.mutate({:*, [], [a, one]}) == :skip
      assert Arithmetic.mutate({:/, [], [a, one]}) == :skip
    end

    test "for * and /, only the right operand is an identity (1 * a is a reciprocal)" do
      a = {:a, [], nil}

      assert Arithmetic.mutate({:*, [], [1, a]}) == [{:/, [], [1, a]}]
      assert Arithmetic.mutate({:/, [], [1, a]}) == [{:*, [], [1, a]}]
    end

    test "DOES mutate additive identity (+ 0 / - 0): -0.0 normalization is testable behavior" do
      a = {:a, [], nil}

      assert Arithmetic.mutate({:+, [], [a, 0]}) == [{:-, [], [a, 0]}]
      assert Arithmetic.mutate({:-, [], [a, 0]}) == [{:+, [], [a, 0]}]
    end

    test "div/rem are never treated as identity (rem(a, 1) is 0, not a)" do
      a = {:a, [], nil}
      assert Arithmetic.mutate({:div, [], [a, 1]}) == [{:rem, [], [a, 1]}]
      assert Arithmetic.mutate({:rem, [], [a, 1]}) == [{:div, [], [a, 1]}]
    end

    test "a non-identity literal (e.g. * 2) still mutates" do
      a = {:a, [], nil}
      assert Arithmetic.mutate({:*, [], [a, 2]}) == [{:/, [], [a, 2]}]
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

    test "name" do
      assert Relational.name() == :relational
    end
  end
end
