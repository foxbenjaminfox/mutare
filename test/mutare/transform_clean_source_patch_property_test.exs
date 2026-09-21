defmodule Mutare.TransformCleanSourcePatchPropertyTest do
  use ExUnit.Case, async: false
  use PropCheck

  alias Mutare.Test.CleanSourcePatchGenerators, as: Gen
  alias Mutare.Test.SourcePatch
  alias Mutare.Transform

  @moduletag :property
  @moduletag timeout: 600_000

  property "recursive clean copies and active mutants agree with their source patches",
    numtests: 30,
    max_size: 6 do
    forall recipe <- Gen.recipe() do
      check(recipe)
    end
  end

  for boundary <- Gen.boundaries(), routing <- Gen.routings() do
    test "#{boundary} payload under #{routing} routing" do
      for spelling <- Gen.spellings() do
        check(%{
          boundary: unquote(boundary),
          routing: unquote(routing),
          spelling: spelling,
          values: [2, 0, 1],
          initial: 1
        })
      end
    end
  end

  defp check(recipe) do
    fixture = Gen.fixture(recipe)

    try do
      # Require the optimization this property targets. Semantic equality would otherwise
      # pass vacuously if a future change stopped making a clean copy altogether.
      result =
        Transform.transform_string_with_sites(
          fixture.source,
          Keyword.put(fixture.opts, :mutators, fixture.mutators)
        )

      assert Enum.any?(result.clean_decisions, fn decision ->
               decision.function == {:walk, 2} and decision.delivery == :lifted and
                 decision.verdict == :clean
             end)

      sites =
        SourcePatch.assert_patches(
          fixture.source,
          fixture.mutators,
          fixture.calls,
          fixture.opts
        )

      assert Enum.count(sites, &(&1.original_code == "acc + n")) == 1
      assert Enum.count(sites, &(&1.original_code == "n < 1")) == 2
      true
    rescue
      exception ->
        IO.puts("Clean source-patch recipe: #{inspect(recipe)}\n#{fixture.source}")
        reraise exception, __STACKTRACE__
    end
  end
end
