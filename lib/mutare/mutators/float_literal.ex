defmodule Mutare.Mutators.FloatLiteral do
  @moduledoc """
  Float-literal mutations: `x` → `x + 1.0`, `x - 1.0`, and `0.0`, deduplicated
  and never equal to `x`.

  The float counterpart of `Mutare.Mutators.Literal`'s integer arm. On by default.
  """
  @behaviour Mutare.Mutator

  alias Mutare.Mutators.Helpers

  @impl Mutare.Mutator
  def name, do: :float

  @impl Mutare.Mutator
  def mutate({:__block__, _meta, [f]}) when is_float(f),
    do: Helpers.numeric_mutations(f, 1.0, 0.0)

  def mutate(_node), do: :skip
end
