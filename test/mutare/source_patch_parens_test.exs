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
