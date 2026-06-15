defmodule Mutare.Mutators.FloatLiteral do
  @moduledoc """
  Float-literal mutations: `x` → `x + 1.0`, `x - 1.0`, and `0.0`, deduplicated
  and never equal to `x`.

  The float counterpart of `Mutare.Mutators.Literal`'s integer arm. In-place and
  compile-safe — a float literal is legal wherever the original was, emitted with
  fresh metadata so Sourceror renders the new value rather than a stale `:token`.

  On by default, like its integer counterpart.
  """
  @behaviour Mutare.Mutator

  @impl Mutare.Mutator
  def name, do: :float

  @impl Mutare.Mutator
  def mutate({:__block__, _meta, [f]}) when is_float(f) do
    [f + 1.0, f - 1.0, 0.0]
    |> Enum.uniq()
    |> Enum.reject(&(&1 == f))
    |> Enum.map(&{:__block__, [], [&1]})
  end

  def mutate(_node), do: :skip
end
