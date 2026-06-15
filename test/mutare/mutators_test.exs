defmodule Mutare.MutatorsTest do
  use ExUnit.Case, async: true

  alias Mutare.Mutators

  alias Mutare.Mutators.{
    Arithmetic,
    Collection,
    Conditional,
    FloatLiteral,
    List,
    Literal,
    Logical,
    Relational,
    StringLiteral
  }

  describe "registry (single source of truth)" do
    test "all/0 is every registered module, in order — the default/`:all` set" do
      assert Mutators.all() == Keyword.values(Mutators.registry())

      assert Mutators.all() ==
               [Arithmetic, Relational, Logical, Literal] ++
                 [Conditional, List, Collection, StringLiteral, FloatLiteral]
    end

    test "families/0 are the registry's keys, in order — all on by default" do
      assert Mutators.families() == Keyword.keys(Mutators.registry())

      assert Mutators.families() ==
               [:arithmetic, :relational, :logical, :literal] ++
                 [:conditional, :list, :collection, :string, :float]
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

    test "resolve/1 maps any registered family by name" do
      assert Mutators.resolve([:conditional, :collection]) == [Conditional, Collection]
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

    test "strips unary minus (arity 1): -x → x" do
      assert Arithmetic.mutate({:-, [], [{:x, [], nil}]}) == [{:x, [], nil}]
    end

    test "skips unary minus on a literal zero (-0 == 0 is equivalent)" do
      assert Arithmetic.mutate({:-, [], [0]}) == :skip
      assert Arithmetic.mutate({:-, [], [{:__block__, [token: "0"], [0]}]}) == :skip
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

  describe "Logical" do
    test "swaps the strict and relaxed boolean connectives" do
      l = {:a, [], nil}
      r = {:b, [], nil}
      assert Logical.mutate({:and, [], [l, r]}) == [{:or, [], [l, r]}]
      assert Logical.mutate({:or, [], [l, r]}) == [{:and, [], [l, r]}]
      assert Logical.mutate({:&&, [], [l, r]}) == [{:||, [], [l, r]}]
      assert Logical.mutate({:||, [], [l, r]}) == [{:&&, [], [l, r]}]
    end

    test "strips a negation: not x → x and !x → x" do
      x = {:x, [], nil}
      assert Logical.mutate({:not, [], [x]}) == [x]
      assert Logical.mutate({:!, [], [x]}) == [x]
    end

    test "skips non-logical nodes" do
      assert Logical.mutate({:+, [], [1, 2]}) == :skip
      assert Logical.mutate({:x, [], nil}) == :skip
    end

    test "name" do
      assert Logical.name() == :logical
    end
  end

  describe "Literal" do
    test "mutates an integer to n+1, n-1 and 0, deduped and never itself" do
      assert render(Literal.mutate(parse("2"))) == ["3", "1", "0"]
      assert render(Literal.mutate(parse("1"))) == ["2", "0"]
      assert render(Literal.mutate(parse("0"))) == ["1", "-1"]
    end

    test "flips a boolean" do
      assert render(Literal.mutate(parse("true"))) == ["false"]
      assert render(Literal.mutate(parse("false"))) == ["true"]
    end

    test "emits clean metadata so the new value renders (not the original token)" do
      # The original carries `token: \"1\"`; reusing it would render \"1\".
      assert render(Literal.mutate(parse("1"))) == ["2", "0"]
      assert Enum.all?(Literal.mutate(parse("1")), fn {:__block__, meta, _} -> meta == [] end)
    end

    test "skips non-integer, non-boolean literals and operators" do
      assert Literal.mutate(parse("1.5")) == :skip
      assert Literal.mutate(parse(~s("s"))) == :skip
      assert Literal.mutate({:+, [], [1, 2]}) == :skip
    end

    test "name" do
      assert Literal.name() == :literal
    end
  end

  describe "Conditional" do
    test "replaces a boolean-valued node with the constants true and false" do
      assert render(Conditional.mutate(parse("a > b"))) == ["true", "false"]
      assert render(Conditional.mutate(parse("a == b"))) == ["true", "false"]
      assert render(Conditional.mutate(parse("a in b"))) == ["true", "false"]
      assert render(Conditional.mutate(parse("a and b"))) == ["true", "false"]
      assert render(Conditional.mutate(parse("not a"))) == ["true", "false"]
    end

    test "skips nodes that are not boolean-valued" do
      assert Conditional.mutate(parse("a + b")) == :skip
      assert Conditional.mutate(parse("1")) == :skip
    end

    test "name" do
      assert Conditional.name() == :conditional
    end
  end

  describe "List" do
    test "swaps ++ and --" do
      l = {:a, [], nil}
      r = {:b, [], nil}
      assert List.mutate({:++, [], [l, r]}) == [{:--, [], [l, r]}]
      assert List.mutate({:--, [], [l, r]}) == [{:++, [], [l, r]}]
    end

    test "collapses a non-empty list literal to []" do
      assert render(List.mutate(parse("[1, 2, 3]"))) == ["[]"]
      assert render(List.mutate(parse("[a | b]"))) == ["[]"]
    end

    test "leaves an empty list literal alone" do
      assert List.mutate(parse("[]")) == :skip
    end

    test "name" do
      assert List.name() == :list
    end
  end

  describe "Collection" do
    test "swaps complementary Enum/List calls, keeping arguments" do
      assert render(Collection.mutate(parse("Enum.filter(xs, f)"))) == ["Enum.reject(xs, f)"]
      assert render(Collection.mutate(parse("Enum.reject(xs, f)"))) == ["Enum.filter(xs, f)"]
      assert render(Collection.mutate(parse("Enum.all?(xs, f)"))) == ["Enum.any?(xs, f)"]
      assert render(Collection.mutate(parse("Enum.min(xs)"))) == ["Enum.max(xs)"]
      assert render(Collection.mutate(parse("List.first(xs)"))) == ["List.last(xs)"]
    end

    test "skips unrelated remote calls and other modules' functions" do
      assert Collection.mutate(parse("Enum.map(xs, f)")) == :skip
      assert Collection.mutate(parse("Other.filter(xs, f)")) == :skip
      assert Collection.mutate(parse("local(xs)")) == :skip
    end

    test "name" do
      assert Collection.name() == :collection
    end
  end

  describe "StringLiteral" do
    test "mutates a non-empty string into both the empty string and the sentinel" do
      assert render(StringLiteral.mutate(parse(~s("hello")))) == [~s(""), ~s("mutare")]
    end

    test "drops the replacement that already equals the original" do
      # "" can't become "" again; "mutare" can't become "mutare" again
      assert render(StringLiteral.mutate(parse(~s("")))) == [~s("mutare")]
      assert render(StringLiteral.mutate(parse(~s("mutare")))) == [~s("")]
    end

    test "skips non-string literals" do
      assert StringLiteral.mutate(parse("1")) == :skip
      assert StringLiteral.mutate(parse(":atom")) == :skip
    end

    test "name" do
      assert StringLiteral.name() == :string
    end
  end

  describe "FloatLiteral" do
    test "mutates a float to x+1.0, x-1.0 and 0.0, deduped and never itself" do
      assert render(FloatLiteral.mutate(parse("1.5"))) == ["2.5", "0.5", "0.0"]
      assert render(FloatLiteral.mutate(parse("0.0"))) == ["1.0", "-1.0"]
    end

    test "skips integers" do
      assert FloatLiteral.mutate(parse("1")) == :skip
    end

    test "name" do
      assert FloatLiteral.name() == :float
    end
  end

  defp parse(source), do: Sourceror.parse_string!(source)
  defp render(nodes), do: Enum.map(nodes, &Sourceror.to_string/1)
end
