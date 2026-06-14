defmodule Mutare.Test.BooleanMutator do
  @moduledoc """
  A reference custom mutator (boolean operator swaps), used in tests to exercise
  the public `Mutare.Mutator` extension point. Mirrors the example in the
  `Mutare.Mutator` docs.
  """
  @behaviour Mutare.Mutator

  @impl Mutare.Mutator
  def name, do: :boolean

  @impl Mutare.Mutator
  def mutate({:and, meta, [left, right]}), do: [{:or, meta, [left, right]}]
  def mutate({:or, meta, [left, right]}), do: [{:and, meta, [left, right]}]
  def mutate({:&&, meta, [left, right]}), do: [{:||, meta, [left, right]}]
  def mutate({:||, meta, [left, right]}), do: [{:&&, meta, [left, right]}]
  def mutate(_node), do: :skip
end
