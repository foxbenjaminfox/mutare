defmodule Mutare.Test.AndOrMutator do
  @moduledoc """
  A reference custom mutator (logical-connective swaps: `and`↔`or`, `&&`↔`||`), used in tests to
  exercise the public `Mutare.Mutator` extension point. Mirrors the example in the
  `Mutare.Mutator` docs.
  """
  @behaviour Mutare.Mutator

  @impl Mutare.Mutator
  def name, do: :and_or

  @impl Mutare.Mutator
  def mutate({:and, meta, [left, right]}), do: [{:or, meta, [left, right]}]
  def mutate({:or, meta, [left, right]}), do: [{:and, meta, [left, right]}]
  def mutate({:&&, meta, [left, right]}), do: [{:||, meta, [left, right]}]
  def mutate({:||, meta, [left, right]}), do: [{:&&, meta, [left, right]}]
  def mutate(_node), do: :skip
end
