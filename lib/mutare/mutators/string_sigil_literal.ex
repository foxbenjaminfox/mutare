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

  Only **non-interpolated** sigils are mutated: an interpolated `~s(a\#{x}b)` parses
  with multiple `<<>>` parts, not a single binary, so the match (a lone binary
  segment) declines it — left, like an interpolated `"a\#{x}b"`, to its own runtime
  sub-expressions (`~S` never interpolates, so it always matches). `Mutare.Transform`
  offers the **whole** sigil node here (it never offers a sigil's content `<<>>`
  wrapper or bare-binary segment separately), so this is the *only* string mutation a
  `~s`/`~S` receives — and, like every sigil offer, only in a runtime position, never
  in a pattern.
  """
  @behaviour Mutare.Mutator

  alias Mutare.AST

  @sentinel AST.sentinel_string()

  @impl Mutare.Mutator
  def name, do: :string_sigil

  @impl Mutare.Mutator
  def mutate({sigil, _meta, [{:<<>>, _bmeta, [content]}, _modifiers]})
      when sigil in [:sigil_s, :sigil_S] and is_binary(content) do
    ["", @sentinel]
    |> Enum.reject(&(&1 == content))
    |> Enum.map(&AST.literal/1)
  end

  def mutate(_node), do: :skip
end
