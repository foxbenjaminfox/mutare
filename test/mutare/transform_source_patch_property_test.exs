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

  # Guarantee the routing/scope × spelling pairs and callee × delivery pairs. Random
  # generation then composes across the two groups, with shrinking over the recipe.
  for operand <- Gen.operands(), spelling <- Gen.spellings() do
    test "#{operand} operand, #{spelling} spelling" do
      check(%{
        operand: unquote(operand),
        spelling: unquote(spelling),
        delivery: :split,
        callee: :static,
        wrapped?: false,
        offset: 0
      })
    end
  end

  for callee <- Gen.callees(), delivery <- Gen.deliveries() do
    test "#{callee} callee, #{delivery} delivery" do
      check(%{
        operand: :binding,
        spelling: :piped,
        delivery: unquote(delivery),
        callee: unquote(callee),
        wrapped?: true,
        offset: 0
      })
    end
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
      delivered = sites |> Enum.reject(&(&1.mutator == :relational)) |> Enum.map(& &1.mutator)

      expected =
        case {recipe.callee, recipe.delivery} do
          {:static, :retained} -> [:arithmetic]
          {:static, :moved} -> [:operand_swap]
          {:static, :split} -> [:arithmetic, :operand_swap]
          {:dynamic, :split} -> [:dynamic_arithmetic, :dynamic_arithmetic]
          {:dynamic, _} -> [:dynamic_arithmetic]
        end

      assert Enum.sort(delivered) == Enum.sort(expected)
      assert Enum.any?(sites, &(&1.mutator == :relational and &1.original_code == "n < 1"))
      true
    rescue
      exception ->
        IO.puts("Source-patch recipe: #{inspect(recipe)}\n#{fixture.source}")
        reraise exception, __STACKTRACE__
    end
  end
end
