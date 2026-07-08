defmodule Mutare.Mutators.StringLiteral do
  @moduledoc """
  String-literal mutations: replace a string with both the empty string `""` and a non-empty sentinel (`"mutare"`), dropping whichever already equals the original. So a typical non-empty string yields *two* mutants (empties it and swaps its content); `""` yields just the sentinel; `"mutare"` yields just `""`.

  Both plain and interpolated strings are mutated. A plain literal parses as `{:__block__, _, [binary]}` and gets the value-based no-op drop above. An interpolated string (`"a\#{x}b"`) — and an interpolated heredoc — parses instead as a `<<>>` carrying a `delimiter` meta key; the whole thing is replaced by `""`/`"mutare"` (its runtime value can never be statically either, so both variants apply), while the interpolation's own sub-expressions still mutate independently underneath. A real `<<…>>` bitstring (no `delimiter`) is *not* a string — it is left to `Mutare.Mutators.BitstringLiteral`.

  Add project-specific positions to leave alone with the `:skip_arguments` option (a list of `{module, function, arity, positions}`, as in `Mutare.Mutators.IntegerLiteral`).

  Filterable variants — qualify a `# mutare:ignore` filter with `:label` to suppress just one half (`c:Mutare.Mutator.variants/0`): `empty` (the `""`) or `sentinel` (the `"mutare"`).
  """
  @behaviour Mutare.Mutator

  alias Mutare.AST
  alias Mutare.Mutator.Mutation
  alias Mutare.Mutators.Helpers

  @sentinel AST.sentinel_string()

  @impl Mutare.Mutator
  def name, do: :string

  @impl Mutare.Mutator
  def argument_marks(config), do: Mutare.Mutator.skip_arguments_marks(config)

  # Decline at a user-configured `:skip_arguments` position; otherwise mutate normally.
  @impl Mutare.Mutator
  def mutate(node, context) do
    if Mutare.Mutator.self_marked?(context), do: :skip, else: mutate(node)
  end

  @impl Mutare.Mutator
  def mutate({:__block__, _meta, [s]}) when is_binary(s) do
    ["", @sentinel]
    |> Enum.reject(&(&1 == s))
    |> Enum.map(&empty_sentinel/1)
  end

  # An interpolated string (`"a#{x}b"`, or a heredoc) parses as a `<<>>` carrying a
  # `delimiter` meta key — the discriminator from a real `<<…>>` bitstring (no
  # delimiter, BitstringLiteral's domain). Its runtime binary is never statically
  # `""`/`"mutare"`, so both variants always apply.
  def mutate({:<<>>, meta, segments} = node)
      when is_list(meta) and is_list(segments) and segments != [] do
    if AST.string_binary?(node),
      do: [empty_sentinel(""), empty_sentinel(@sentinel)],
      else: :skip
  end

  def mutate(_node), do: :skip

  # Variant vocabulary for `# mutare:ignore[string:<label>]` — `empty` (the `""`) / `sentinel`
  # (the `"mutare"`). Each mutant is a plain string literal tagged at production by
  # `empty_sentinel/1`, so the label rides on the `Mutare.Mutator.Mutation` (no `variant/2`).
  @impl Mutare.Mutator
  def variants, do: Helpers.empty_sentinel_variants()

  # A plain string-literal mutant tagged with its `empty`/`sentinel` variant label.
  defp empty_sentinel(content),
    do: Mutation.tagged(AST.literal(content), Helpers.empty_sentinel_variant(content, @sentinel))
end
