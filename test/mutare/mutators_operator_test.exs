defmodule Mutare.MutatorsOperatorTest do
  # Unit tests of the in-place operator/value-swap families' `mutate/1`: the swap
  # tables, exclusions, and `name/0`. Integration/runtime coverage of these families
  # lives in their own files (e.g. operand_swap_test.exs) and in transform_test.exs.
  use ExUnit.Case, async: true

  alias Mutare.Mutators.{
    Arithmetic,
    Conditional,
    List,
    Logical,
    Relational,
    StrictEquality
  }

  describe "Arithmetic" do
    test "swaps binary arithmetic operators" do
      assert Arithmetic.mutate({:+, [], [1, 2]}) == [{:-, [], [1, 2]}]
      assert Arithmetic.mutate({:-, [], [1, 2]}) == [{:+, [], [1, 2]}]
      assert Arithmetic.mutate({:*, [], [1, 2]}) == [{:/, [], [1, 2]}]
      assert Arithmetic.mutate({:/, [], [1, 2]}) == [{:*, [], [1, 2]}]
    end

    test "swaps div/rem (call form) only at effective arity 2, pipe-aware" do
      # div/rem are bare Kernel calls handled in mutate/2 (mutate/1 skips them).
      assert Arithmetic.mutate({:div, [], [1, 2]}) == :skip
      assert Arithmetic.mutate({:div, [], [1, 2]}, %{pipe_mode: :unpiped}) == [{:rem, [], [1, 2]}]
      assert Arithmetic.mutate({:rem, [], [1, 2]}, %{pipe_mode: :unpiped}) == [{:div, [], [1, 2]}]

      # Piped: the stage carries one fewer arg (`x |> div(2)` is div/2), so a 1-arg
      # node at piped effective-arity 2 still swaps (the rename keeps the arg list).
      assert Arithmetic.mutate({:div, [], [2]}, %{pipe_mode: :piped}) == [{:rem, [], [2]}]

      # A same-named user call at another arity is left alone (not Kernel's div/2).
      assert Arithmetic.mutate({:div, [], [1, 2, 3]}, %{pipe_mode: :unpiped}) == :skip
      assert Arithmetic.mutate({:div, [], [2]}, %{pipe_mode: :unpiped}) == :skip
    end

    test "skips a div/rem call displaced from Kernel by `import Kernel, except:`" do
      # Regression: a bare `div`/`rem` displaced (`import Kernel, except: [div: 2]`) names another
      # module's function, so the Kernel `div`↔`rem` swap must NOT fire — it would rewrite to a
      # sibling that may not exist (poisoning the single build) or mean something else. The
      # displacement is stamped on the call meta by `Mutare.Transform.Imports`; Arithmetic honors
      # it via `Helpers.swap_bare_kernel/3`. (Before that guard a displaced `div` was wrongly
      # swapped to `rem` — the bug this pins.)
      displaced = [mutare_kernel_displaced: true]
      assert Arithmetic.mutate({:div, displaced, [1, 2]}, %{pipe_mode: :unpiped}) == :skip
      assert Arithmetic.mutate({:rem, displaced, [1, 2]}, %{pipe_mode: :unpiped}) == :skip

      # Without the stamp the same call still swaps — the displacement guard is the only difference.
      assert Arithmetic.mutate({:div, [], [1, 2]}, %{pipe_mode: :unpiped}) == [{:rem, [], [1, 2]}]
    end

    test "preserves operand AST and operator metadata" do
      meta = [line: 7, column: 3]
      operands = [{:a, [], nil}, {:b, [], nil}]
      assert Arithmetic.mutate({:+, meta, operands}) == [{:-, meta, operands}]
    end

    test "strips unary minus (arity 1): -x → x" do
      assert Arithmetic.mutate({:-, [], [{:x, [], nil}]}) == [{:x, [], nil}]
    end

    test "skips unary minus on an integer literal zero (-0 === 0 is equivalent)" do
      assert Arithmetic.mutate({:-, [], [0]}) == :skip
      assert Arithmetic.mutate({:-, [], [{:__block__, [token: "0"], [0]}]}) == :skip
    end

    test "DOES strip unary minus on a float zero (-0.0 → 0.0 normalizes negative zero)" do
      assert Arithmetic.mutate({:-, [], [0.0]}) == [0.0]

      assert Arithmetic.mutate({:-, [], [{:__block__, [token: "0.0"], [0.0]}]}) ==
               [{:__block__, [token: "0.0"], [0.0]}]
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
      assert Arithmetic.mutate({:div, [], [a, 1]}, %{pipe_mode: :unpiped}) == [{:rem, [], [a, 1]}]
      assert Arithmetic.mutate({:rem, [], [a, 1]}, %{pipe_mode: :unpiped}) == [{:div, [], [a, 1]}]
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

  describe "StrictEquality" do
    test "relaxes strict equality to value equality, one direction only" do
      assert StrictEquality.mutate({:===, [], [1, 2]}) == [{:==, [], [1, 2]}]
      assert StrictEquality.mutate({:!==, [], [1, 2]}) == [{:!=, [], [1, 2]}]
    end

    test "never tightens the relaxed operators (no == → ===, != → !==)" do
      assert StrictEquality.mutate({:==, [], [1, 2]}) == :skip
      assert StrictEquality.mutate({:!=, [], [1, 2]}) == :skip
    end

    test "skips ordering and non-equality nodes" do
      assert StrictEquality.mutate({:>, [], [1, 2]}) == :skip
      assert StrictEquality.mutate({:+, [], [1, 2]}) == :skip
      assert StrictEquality.mutate({:x, [], nil}) == :skip
      assert StrictEquality.mutate(:atom) == :skip
    end

    test "name" do
      assert StrictEquality.name() == :strict_equality
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

  defp parse(source), do: Sourceror.parse_string!(source)
  defp render(nodes), do: Enum.map(nodes, &Sourceror.to_string/1)
end
