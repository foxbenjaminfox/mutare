defmodule Mutare.Mutators.StringSigilLiteral do
  @moduledoc """
  Replaces a `~s` or `~S` sigil with the plain string literals `""` and
  `"mutare"`. A replacement equal to a static sigil value is omitted:

    * `~s(hello)` produces both replacements
    * `~s()` produces only `"mutare"`
    * `~s(mutare)` produces only `""`

  Replacements are plain string literals because these sigils have no modifier that
  changes their value type.

  Interpolated `~s` sigils also receive both replacements because their runtime value
  cannot be compared statically. Expressions inside the interpolation remain eligible
  for their own mutations. `~S` sigils do not interpolate.

  The whole sigil is mutated only in runtime positions, not in patterns. The ignore
  variants are `empty` and `sentinel`.
  """
  @behaviour Mutare.Mutator

  alias Mutare.AST
  alias Mutare.Mutator.Mutation
  alias Mutare.Mutators.Helpers

  @sentinel AST.sentinel_string()

  @impl Mutare.Mutator
  def name, do: :string_sigil

  @impl Mutare.Mutator
  def mutate({sigil, meta, [{:<<>>, _bmeta, segments}, _modifiers]})
      when sigil in [:sigil_s, :sigil_S] do
    # Only a real `~s`/`~S` sigil carries the parser's `:delimiter` meta. A call to a
    # *function* named `sigil_s`/`sigil_S` (a local sigil shadowing `Kernel`'s) parses to the
    # same head with a `<<…>>` first arg, but it is not a string sigil — decline it, mirroring
    # the `is_binary(content)` shape guard the other sigil families lean on. (The transform's
    # `Mutare.Transform.Analyze` already gates sigil *routing* on `:delimiter` too.)
    if Keyword.has_key?(meta, :delimiter), do: sigil_mutations(segments), else: :skip
  end

  def mutate(_node), do: :skip

  # Variant vocabulary for `# mutare:ignore[string_sigil:<label>]` — `empty` / `sentinel`, exactly
  # like `Mutare.Mutators.StringLiteral`. Each mutant is a plain string literal tagged at production
  # by `empty_sentinel/1`, so the label rides on the `Mutare.Mutator.Mutation` (no `variant/2`).
  @impl Mutare.Mutator
  def variants, do: Helpers.empty_sentinel_variants()

  defp sigil_mutations(segments) do
    case segments do
      [content] when is_binary(content) ->
        # Non-interpolated: a single static binary — drop the no-op variant.
        ["", @sentinel]
        |> Enum.reject(&(&1 == content))
        |> Enum.map(&empty_sentinel/1)

      _ ->
        # Interpolated (`~s` only): multiple `<<>>` parts / a lone interpolation. The
        # runtime binary is never statically `""`/`"mutare"`, so both variants apply.
        [empty_sentinel(""), empty_sentinel(@sentinel)]
    end
  end

  # A plain string-literal mutant tagged with its `empty`/`sentinel` variant label.
  defp empty_sentinel(content),
    do: Mutation.tagged(AST.literal(content), Helpers.empty_sentinel_variant(content, @sentinel))
end
