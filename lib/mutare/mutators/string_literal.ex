defmodule Mutare.Mutators.StringLiteral do
  @moduledoc """
  String-literal mutations: replace a string with both the empty string `""` and
  a non-empty sentinel (`"mutare"`), dropping whichever already equals the
  original. So a typical non-empty string yields *two* mutants (empties it and
  swaps its content); `""` yields just the sentinel; `"mutare"` yields just `""`.

  Only plain string literals are touched: interpolated strings (`"a\#{x}b"`) parse
  as a `<<>>` construction, not a literal, and are left alone.
  """
  @behaviour Mutare.Mutator

  alias Mutare.AST

  @sentinel AST.sentinel_string()

  @impl Mutare.Mutator
  def name, do: :string

  @impl Mutare.Mutator
  def mutate({:__block__, _meta, [s]}) when is_binary(s) do
    ["", @sentinel]
    |> Enum.reject(&(&1 == s))
    |> Enum.map(&AST.literal/1)
  end

  def mutate(_node), do: :skip
end
