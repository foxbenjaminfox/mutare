defmodule Mutare.Mutators.StringLiteral do
  @moduledoc """
  String-literal mutations: replace a string with both the empty string `""` and
  a non-empty sentinel (`"mutare"`), dropping whichever already equals the
  original. So a typical non-empty string yields *two* mutants (empties it and
  swaps its content); `""` yields just the sentinel; `"mutare"` yields just `""`.

  Both plain and **interpolated** strings are mutated. A plain literal parses as
  `{:__block__, _, [binary]}` and gets the value-based no-op drop above. An
  interpolated string (`"a\#{x}b"`) — and an interpolated heredoc — parses instead
  as a `<<>>` carrying a `delimiter` meta key; the whole thing is replaced by
  `""`/`"mutare"` (its runtime value can never be statically either, so both variants
  apply), while the interpolation's own sub-expressions still mutate independently
  underneath. A real `<<…>>` bitstring (no `delimiter`) is *not* a string — it is left
  to `Mutare.Mutators.BitstringLiteral`.
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

  # An interpolated string (`"a#{x}b"`, or a heredoc) parses as a `<<>>` carrying a
  # `delimiter` meta key — the discriminator from a real `<<…>>` bitstring (no
  # delimiter, BitstringLiteral's domain). Its runtime binary is never statically
  # `""`/`"mutare"`, so both variants always apply.
  def mutate({:<<>>, meta, segments} = node)
      when is_list(meta) and is_list(segments) and segments != [] do
    if AST.string_binary?(node),
      do: [AST.literal(""), AST.literal(@sentinel)],
      else: :skip
  end

  def mutate(_node), do: :skip
end
