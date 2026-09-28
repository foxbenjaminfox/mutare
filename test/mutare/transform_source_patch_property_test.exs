# Every mutant behaves like its source patch. The random property, the pairwise recipes and
# their coverage check share `check/1`; the pairwise recipes are spread over shard modules, so
# they run side by side with the property and with each other.
defmodule Mutare.TransformSourcePatchProperty do
  @moduledoc false
  import ExUnit.Assertions

  alias Mutare.Test.SourcePatch
  alias Mutare.Test.SourcePatchGenerators, as: Gen

  @shards 8

  @doc "How many modules the pairwise recipes are spread over."
  def shards, do: @shards

  @doc "The pairwise recipes shard `shard` runs."
  def pairwise(shard) do
    for {recipe, i} <- Enum.with_index(Gen.pairwise()), rem(i, @shards) == shard, do: recipe
  end

  def check(recipe) do
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
        |> Enum.reject(&(&1.mutator in [:relational, :host_filter, :unwrap]))
        |> Enum.map(& &1.mutator)

      # `:declaration_skipped` and `:declarations_skipped` skip `destructure/2` itself, the
      # `:destructured` delivery's own head included: that pattern is then never offered, and
      # the recipe checks only that the skipped declaration still binds through the baseline
      # and the operand's mutants.
      expected =
        case {recipe.callee, recipe.delivery} do
          {_callee, :destructured}
          when recipe.operand in [:declaration_skipped, :declarations_skipped] ->
            []

          {_callee, structural} when structural in [:matched, :destructured] ->
            [:pattern_swap]

          {:static, :retained} ->
            [:arithmetic]

          {:static, :moved} ->
            [:operand_swap]

          {:static, :split} ->
            [:arithmetic, :operand_swap]

          {:static, :dropped} ->
            [:drop_argument]

          {_dynamic, :split} ->
            [:dynamic_arithmetic, :dynamic_arithmetic]

          {_dynamic, _} ->
            [:dynamic_arithmetic]
        end

      # Two operands write arithmetic of their own (`:block`'s negation, the `n - n` in
      # `:injected_pipe`'s helper): one more site where that family runs.
      negation =
        if recipe.operand in [:block, :injected_pipe] and :arithmetic in fixture.mutators,
          do: [:arithmetic],
          else: []

      # `:injected_pipe` carries a name-only `|>` route, which by design also governs Kernel's
      # pipes: the recipe's own stages are then read as that route says, not as direct calls.
      # Its counts are exact only where the recipe writes no pipe.
      if recipe.operand != :injected_pipe or recipe.spelling == :direct,
        do: assert(Enum.sort(delivered) == Enum.sort(expected ++ negation))

      # The hosted fragment's mutants are the host's own, woven inside the DSL call.
      assert Enum.any?(sites, &(&1.mutator == :host_filter)) == (recipe.operand == :hosted)
      assert Enum.any?(sites, &(&1.mutator == :unwrap)) == (recipe.operand == :block)
      assert Enum.any?(sites, &(&1.mutator == :relational and &1.original_code == "n < 1"))
      true
    rescue
      exception ->
        IO.puts("Source-patch recipe: #{inspect(recipe)}\n#{fixture.source}")
        reraise exception, __STACKTRACE__
    end
  end
end

defmodule Mutare.TransformSourcePatchPropertyTest do
  use ExUnit.Case, async: true
  use PropCheck

  import Mutare.TransformSourcePatchProperty, only: [check: 1]

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
    # A covering array earns its keep only while it stays far below the full product.
    product =
      Gen.dimensions() |> Enum.map(fn {_name, values} -> length(values) end) |> Enum.product()

    assert length(Gen.pairwise()) * 10 < product
  end
end

# Every pair of values from two different dimensions, in a few dozen recipes: which
# combinations ran is asserted above ("the pairwise recipes leave no pair of values
# untested"), not sampled. The random property composes three and more at a time, with
# shrinking over the recipe.
for shard <- 0..(Mutare.TransformSourcePatchProperty.shards() - 1) do
  defmodule Module.concat(Mutare.TransformSourcePatchPropertyTest, :"Pairwise#{shard}") do
    use ExUnit.Case, async: true

    import Mutare.TransformSourcePatchProperty, only: [check: 1]

    @moduletag :property
    @moduletag timeout: 600_000

    for recipe <- Mutare.TransformSourcePatchProperty.pairwise(shard) do
      test "pairwise: #{recipe |> Map.delete(:offset) |> inspect()}" do
        check(unquote(Macro.escape(recipe)))
      end
    end
  end
end
