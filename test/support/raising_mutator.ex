defmodule Mutare.Test.RaisingMutator do
  @moduledoc """
  A mutator that *raises* (a stand-in for a bug in mutator/transform code) when
  it meets a `+`. Used to prove `Mutare.Schema` lets an internal error during a
  successful-parse transform crash, rather than swallowing it as a skipped file.
  """
  @behaviour Mutare.Mutator

  @impl Mutare.Mutator
  def name, do: :raising

  @impl Mutare.Mutator
  def mutate({:+, _meta, [_left, _right]}), do: raise("boom from mutator")
  def mutate(_node), do: :skip
end
