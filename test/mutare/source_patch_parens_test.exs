defmodule Mutare.SourcePatchParensTest do
  # A site's range covers the node, not the parentheses written around it: the text a Site
  # renders never includes them, so a patch over the wider span shows a different program from
  # the mutant that ran (`Mutare.Transform.NodeRange`). Checked against real patches.
  use ExUnit.Case, async: false

  import Mutare.Test.SourcePatch

  test "a parenthesized operand keeps its parentheses" do
    source = """
    defmodule Fixture do
      def run(a, b, c), do: (a + b) * c
    end
    """

    sites = assert_patches(source, [:arithmetic], run: [2, 3, 4])
    assert patch(source, Enum.find(sites, &(&1.original_code == "a + b"))) =~ "(a - b) * c"
  end

  test "a capture's body keeps the parentheses the capture requires" do
    source = """
    defmodule Fixture do
      def run(xs), do: Enum.reject(xs, &(&1 > 2))
    end
    """

    assert [_ | _] = assert_patches(source, [:relational, :integer], run: [[1, 2, 3]])
  end

  test "doubled, padded and multi-line parentheses" do
    source = """
    defmodule Fixture do
      def run(a, b, c) do
        x = ((a + b)) * c
        y = ( a + b ) * c

        z =
          (a +
             b) * c

        {x, y, z, -(a + b)}
      end
    end
    """

    sites = assert_patches(source, [:arithmetic], run: [2, 3, 4])

    # Every layer stays: a range stopping one layer short would still patch to a correct
    # program, so behaviour alone cannot tell.
    patched = patch(source, Enum.find(sites, &(&1.line == 3 and &1.original_code == "a + b")))
    assert patched =~ "x = ((a - b)) * c"
  end

  test "a mutant that lowers an operator's precedence is patched as the program that ran" do
    source = """
    defmodule Fixture do
      def run(a, b, c), do: a - b * c
    end
    """

    assert [_ | _] = assert_patches(source, [:arithmetic], run: [20, 3, 4])
  end

  test "a node that begins with a call on a parenthesized callee starts at that parenthesis" do
    # Sourceror ranges `(callee).(args)` from *inside* the callee's parentheses, and so every
    # node that begins with one: a whole-expression replacement would leave the `(` behind.
    source = """
    defmodule Fixture do
      def run(a) do
        if a > 0 do
          (fn x -> x + a end).(1) |> Integer.to_string()
        else
          (&(&1 * a)).(2) + 1
        end
      end
    end
    """

    sites = assert_patches(source, [:return_value, :arithmetic], run: [3], run: [-3])

    whole = Enum.find(sites, &(&1.mutator == :return_value and &1.original_code =~ "|>"))
    assert patch(source, whole) =~ ~r/do\n\s+(nil|:mutare|"")\n\s+else/
  end

  test "a node that ends with a parenthesized operand ends at that parenthesis" do
    source = """
    defmodule Fixture do
      def run(a) do
        if 0 == (if a > 0, do: 0, else: 1) do
          -(a + 1)
        else
          a * (a - 1)
        end
      end
    end
    """

    assert [_ | _] =
             assert_patches(source, [:relational, :conditional, :arithmetic, :return_value],
               run: [3],
               run: [-3]
             )
  end

  test "a bitstring that ends a clause body stops at its `>>`" do
    # Sourceror ranges a `<<…>>` carrying `end_of_expression` meta one column too far — over
    # the line break, so the patch joined the next clause onto this one.
    source = """
    defmodule Fixture do
      def run(a) do
        cond do
          a -> <<0>>
          true -> <<1, 2>>
        end
      end
    end
    """

    sites = assert_patches(source, [:bitstring, :integer], run: [true], run: [false])
    assert Enum.any?(sites, &(&1.mutator == :bitstring))
  end

  describe "a replacement that needs parentheses where it lands gets them" do
    test "an operand that binds looser than the expression it replaces" do
      # `!(a == b)` → `a == b`: bare beside `|>` it would read `a == (b |> …)`.
      source = """
      defmodule Fixture do
        def run(a, b) do
          piped = !(a == b) |> to_string()
          compared = !(a == b) == b
          {piped, compared, to_string(a + b) <> "!"}
        end
      end
      """

      sites = assert_patches(source, [:logical, :call_removal], run: [1, 1], run: [1, 2])

      piped = Enum.find(sites, &(&1.mutator == :logical and &1.line == 3))
      assert piped.mutated_code == "(a == b)"
      assert patch(source, piped) =~ "piped = (a == b) |> to_string()"
    end

    test "a do-block call the user parenthesized, in the head of a block call" do
      source = """
      defmodule Fixture do
        def run(a) do
          case 1 +
                 (if a > 0 do
                    1
                  else
                    2
                  end) do
            2 -> :two
            _ -> :other
          end
        end
      end
      """

      sites = assert_patches(source, [:arithmetic], run: [3], run: [-3])
      assert Enum.any?(sites, &String.starts_with?(&1.mutated_code, "(1 -"))
    end

    test "a do-block call the user parenthesized, under an operator in such a head" do
      source = """
      defmodule Fixture do
        def run(a) do
          with w <-
                 (if a > 0 do
                    1
                  else
                    2
                  end) + (a + 0) do
            w
          end
        end
      end
      """

      assert [_ | _] = assert_patches(source, [:arithmetic], run: [3], run: [-3])
    end

    test "a do-block call the user parenthesized, in a clause head; a clause body needs nothing" do
      source = """
      defmodule Fixture do
        def run(a) do
          cond do
            1 +
                (if a > 0 do
                   1
                 else
                   2
                 end) == 2 ->
              !(a == 3)

            true ->
              -a
          end
        end
      end
      """

      sites = assert_patches(source, [:arithmetic, :logical], run: [3], run: [-3])
      assert "a == 3" in Enum.map(sites, & &1.mutated_code)
    end

    test "a do-block call whose parentheses went with the operator around it" do
      source = """
      defmodule Fixture do
        def run(a) do
          if !(if a > 0 do
                 true
               else
                 false
               end) do
            :no
          else
            :yes
          end
        end
      end
      """

      assert [_ | _] = assert_patches(source, [:logical], run: [3], run: [-3])
    end

    test "a negative literal under a written minus" do
      source = """
      defmodule Fixture do
        def run(a), do: {-0.75 * a, a - 0.75, -3 + a}
      end
      """

      # `:arithmetic` gives each unary minus a selector of its own; without one the metamutant
      # renders `-case … end + a`, a baseline defect of its own (NOTES "A unary operator over a
      # selector").
      sites = assert_patches(source, [:float, :integer, :arithmetic], run: [2])

      under_minus = Enum.filter(sites, &(&1.mutated_code =~ "-0.25"))
      assert Enum.map(under_minus, & &1.mutated_code) == ["(-0.25)", "-0.25"]
    end

    test "and nothing else does: a statement, an argument, a slot already parenthesized" do
      source = """
      defmodule Fixture do
        def run(a, b) do
          x = !(a == b)
          y = Enum.max([!(a == b), (a - b) * 0])
          !(x == y)
        end
      end
      """

      sites = assert_patches(source, [:logical, :arithmetic, :integer], run: [1, 1], run: [1, 2])

      codes = Enum.map(sites, & &1.mutated_code)
      assert "a == b" in codes and "x == y" in codes and "a + b" in codes
      refute Enum.any?(codes, &(&1 in ["(a == b)", "(x == y)", "(a + b)", "(-1)"]))
      assert Enum.any?(sites, &(&1.mutated_code == "-1"))
    end
  end

  test "a parenthesized pipe" do
    source = """
    defmodule Fixture do
      import Mutare.Test.PipeSyntaxDSL
      def run(n), do: (n |> plus(1)) * 2
    end
    """

    assert [_ | _] =
             assert_patches(source, [Mutare.Test.PipeSyntaxMutator, :integer, :arithmetic],
               run: [5]
             )
  end
end
