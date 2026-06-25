defmodule Mutare.Mutators.StringSigilLiteral do
  @moduledoc """
  String-sigil mutation: the `~s`/`~S` analogue of `Mutare.Mutators.StringLiteral`.
  A `~s(…)`/`~S(…)` sigil is a plain string wearing different delimiters, so it is
  mutated exactly the same way — into both the empty string `""` and a non-empty
  sentinel (`"mutare"`), dropping whichever already equals the sigil's content. So a
  typical `~s(hello)` yields *two* mutants (empties it and swaps its content); `~s()`
  yields just the sentinel; `~s(mutare)` yields just `""`. Equivalence is judged on
  the sigil's content binary as parsed, mirroring `StringLiteral`'s `&(&1 == s)`.

  The mutant is a **plain string literal** (`""` / `"mutare"`), not a re-wrapped
  sigil: unlike `~w`'s `a`/`c` modifier (which `Mutare.Mutators.WordListLiteral`
  preserves to keep the element type), a `~s`/`~S` sigil takes no type-changing
  modifier — the value is a binary either way — so the plain form gives the cleaner
  diff. This is why it is a sibling of `StringLiteral` rather than folded into it:
  `StringLiteral` matches only a quoted `{:__block__, _, [binary]}` literal, while a
  sigil parses as `{:sigil_s, _, [<<…>>, modifiers]}` whose content is a *bare*
  binary segment — neither shape the other touches.

  **Interpolated** sigils are mutated too. A non-interpolated `~s(hello)`/`~S(…)` has
  a single static binary segment, so the empty/sentinel no-op is dropped as above. An
  interpolated `~s(a\#{x}b)` parses with multiple `<<>>` parts (`~S` never
  interpolates); its runtime binary can never be statically `""`/`"mutare"`, so both
  variants always apply, while the interpolation's own sub-expressions still mutate
  independently underneath. `Mutare.Transform` offers the **whole** sigil node here
  (it never offers a sigil's content `<<>>` wrapper or bare-binary segment
  separately), so this is the *only* whole-string mutation a `~s`/`~S` receives — and,
  like every sigil offer, only in a runtime position, never in a pattern.
  """
  @behaviour Mutare.Mutator

  alias Mutare.AST

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

  defp sigil_mutations(segments) do
    case segments do
      [content] when is_binary(content) ->
        # Non-interpolated: a single static binary — drop the no-op variant.
        ["", @sentinel]
        |> Enum.reject(&(&1 == content))
        |> Enum.map(&AST.literal/1)

      _ ->
        # Interpolated (`~s` only): multiple `<<>>` parts / a lone interpolation. The
        # runtime binary is never statically `""`/`"mutare"`, so both variants apply.
        [AST.literal(""), AST.literal(@sentinel)]
    end
  end
end
