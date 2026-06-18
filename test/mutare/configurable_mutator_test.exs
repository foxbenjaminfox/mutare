defmodule Mutare.ConfigurableMutatorTest do
  @moduledoc """
  End-to-end coverage of the `{module, opts}` configurable-mutator path: options
  flow from `:mutators` through `Mutare.Mutator.Spec` into `mutate/2`'s
  `context.opts`, and the `:as` override names the recorded mutator.
  """
  use ExUnit.Case, async: true

  alias Mutare.Test.ConfigurableMutator

  @source """
  defmodule M do
    def f, do: 7
  end
  """

  test "opts from a {module, opts} entry reach mutate/2 and drive the mutation" do
    {metamutant, sites, _next} =
      Mutare.transform_string(@source, mutators: [{ConfigurableMutator, replacement: 99}])

    assert [site] = sites
    assert site.mutator == :configurable
    assert site.mutated_code == "99"
    # The replacement is embedded behind the selector in the single metamutant.
    assert metamutant =~ "99"
  end

  test "a bare module (no opts) produces no mutants — its logic is opts-gated" do
    {_metamutant, sites, _next} =
      Mutare.transform_string(@source, mutators: [ConfigurableMutator])

    assert sites == []
  end

  test ":as overrides the recorded family name (the same module, a distinct identity)" do
    {_metamutant, sites, _next} =
      Mutare.transform_string(@source,
        mutators: [{ConfigurableMutator, as: :tweaked, replacement: 1}]
      )

    assert [site] = sites
    assert site.mutator == :tweaked
  end

  test "two configurations of one module run independently under distinct names" do
    {_metamutant, sites, _next} =
      Mutare.transform_string(@source,
        mutators: [
          {ConfigurableMutator, as: :to_one, replacement: 1},
          {ConfigurableMutator, as: :to_two, replacement: 2}
        ]
      )

    assert Enum.map(sites, & &1.mutator) |> Enum.sort() == [:to_one, :to_two]
    assert Enum.map(sites, & &1.mutated_code) |> Enum.sort() == ["1", "2"]
  end
end
