defmodule Mutare.TransformSourcePatchPropertyTest do
  use ExUnit.Case, async: false
  use PropCheck

  alias Mutare.Test.SourcePatch
  alias Mutare.Test.SourcePatchGenerators, as: Gen

  @moduletag :property
  @moduletag timeout: 600_000

  # A reference compile per site is deliberately more expensive than the isolation soak.
  # Keep programs small and check every site; never sample away a troublesome mutant.
  property "every mutant behaves like its source patch, including effects and escaping bindings",
    numtests: 40,
    max_size: 8 do
    forall recipe <- Gen.recipe() do
      check(recipe)
    end
  end

  # Every pair of values from two different dimensions, in a few dozen recipes: which
  # combinations ran is asserted below, not sampled. The random property above composes
  # three and more at a time, with shrinking over the recipe.
  for recipe <- Gen.pairwise() do
    test "pairwise: #{recipe |> Map.delete(:offset) |> inspect()}" do
      check(unquote(Macro.escape(recipe)))
    end
  end

  test "the pairwise recipes leave no pair of values untested" do
    covered = Gen.pairwise() |> Enum.flat_map(&Gen.pairs/1) |> MapSet.new()

    dimensions = Gen.dimensions()

    expected =
      for {{left, left_values}, i} <- Enum.with_index(dimensions),
          {right, right_values} <- Enum.drop(dimensions, i + 1),
          left_value <- left_values,
          right_value <- right_values,
          into: MapSet.new(),
          do: {{left, left_value}, {right, right_value}}

    assert MapSet.difference(expected, covered) == MapSet.new()
    # A covering array earns its keep only while it stays far below the 540-recipe product.
    assert length(Gen.pairwise()) < 50
  end

  defp check(recipe) do
    fixture = Gen.fixture(recipe)

    try do
      sites =
        SourcePatch.assert_patches(
          fixture.source,
          fixture.mutators,
          fixture.calls,
          fixture.opts
        )

      # A silent loss of the targeted delivery must not make this property vacuous.
      delivered =
        sites
        |> Enum.reject(&(&1.mutator in [:relational, :host_filter]))
        |> Enum.map(& &1.mutator)

      expected =
        case {recipe.callee, recipe.delivery} do
          {:static, :retained} -> [:arithmetic]
          {:static, :moved} -> [:operand_swap]
          {:static, :split} -> [:arithmetic, :operand_swap]
          {_dynamic, :split} -> [:dynamic_arithmetic, :dynamic_arithmetic]
          {_dynamic, _} -> [:dynamic_arithmetic]
        end

      assert Enum.sort(delivered) == Enum.sort(expected)

      # The hosted fragment's mutants are the host's own, woven inside the DSL call.
      assert Enum.any?(sites, &(&1.mutator == :host_filter)) == (recipe.operand == :hosted)
      assert Enum.any?(sites, &(&1.mutator == :relational and &1.original_code == "n < 1"))
      true
    rescue
      exception ->
        IO.puts("Source-patch recipe: #{inspect(recipe)}\n#{fixture.source}")
        reraise exception, __STACKTRACE__
    end
  end
end
