defmodule Mutare.Test.PoisonMutator do
  @moduledoc """
  A deliberately *compile-poisoning* mutator for tests: it mutates `+` into a
  bare, unbound variable, which fails to compile. Used to exercise the runner's
  compile-poisoning recovery.
  """
  @behaviour Mutare.Mutator

  @impl Mutare.Mutator
  def name, do: :poison

  @impl Mutare.Mutator
  def mutate({:+, _meta, [_left, _right]}), do: [{:mutare_unbound_xyz, [], nil}]
  def mutate(_node), do: :skip
end
