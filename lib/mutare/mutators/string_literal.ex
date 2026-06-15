defmodule Mutare.Mutators.StringLiteral do
  @moduledoc """
  String-literal mutations: replace a string with both the empty string `""` and
  a non-empty sentinel (`"mutare"`), dropping whichever already equals the
  original. So a typical non-empty string yields *two* mutants (empties it and
  swaps its content); `""` yields just the sentinel; `"mutare"` yields just `""`.

  In-place and compile-safe — a binary literal is legal wherever the original
  was. Only plain string literals are touched: interpolated strings parse as a
  `<<>>` construction (not a literal) and are left alone, so the operand is
  always a static binary.
  """
  @behaviour Mutare.Mutator

  @sentinel "mutare"

  @impl Mutare.Mutator
  def name, do: :string

  @impl Mutare.Mutator
  def mutate({:__block__, _meta, [s]}) when is_binary(s) do
    ["", @sentinel]
    |> Enum.reject(&(&1 == s))
    |> Enum.map(&{:__block__, [delimiter: ~s(")], [&1]})
  end

  def mutate(_node), do: :skip
end
