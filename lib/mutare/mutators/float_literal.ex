defmodule Mutare.Mutators.FloatLiteral do
  @moduledoc """
  Float-literal mutations: `x` → `x + 1.0`, `x - 1.0`, and `0.0`, deduplicated
  and never equal to `x`.

  The float counterpart of `Mutare.Mutators.Literal`'s integer arm. On by default.
  """
  @behaviour Mutare.Mutator

  alias Mutare.AST

  @impl Mutare.Mutator
  def name, do: :float

  @impl Mutare.Mutator
  def mutate({:__block__, _meta, [f]}) when is_float(f) do
    [f + 1.0, f - 1.0, 0.0]
    |> Enum.uniq()
    |> Enum.reject(&(&1 == f))
    |> Enum.map(&AST.literal/1)
  end

  def mutate(_node), do: :skip
end
