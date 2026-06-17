defmodule Mutare.Mutators.WordListLiteral do
  @moduledoc """
  Word-sigil mutations: a `~w(…)`/`~W(…)` word list is a list literal in disguise,
  so it is mutated the same way `Mutare.Mutators.List` collapses one and
  `Mutare.Mutators.CharlistLiteral` mutates a charlist — into both the empty word
  list `~w()` (→ `[]`) and a single-element sentinel `~w(mutare)` (→ `["mutare"]`),
  dropping whichever already equals the original. A contrasting pair like
  `StringLiteral`/`CharlistLiteral`: between them they catch a suite that never
  checks the list's emptiness or its contents.

  The modifier is preserved, so the mutant stays the same element type as the
  original: `~w(a b)a` → `~w()a` (`[]`) and `~w(mutare)a` (`[:mutare]`); likewise
  for the `c` (charlist) modifier. Equivalence is judged on the *words produced*
  (`String.split/1`, which mirrors the sigil's own whitespace splitting), not the
  raw content — so a whitespace-only `~w(   )` (already `[]`) doesn't re-emit the
  empty mutant.

  In-place and compile-safe — a word sigil is legal wherever the original was, and
  every replacement is a static, valid word list. Only non-interpolated word lists
  are touched: an interpolated `~w(a \#{x} b)` parses with multiple `<<>>` parts
  (not a single binary), so the operand is always a static binary — `~W` never
  interpolates, so it always is.
  """
  @behaviour Mutare.Mutator

  @sentinel "mutare"

  @impl Mutare.Mutator
  def name, do: :word_list

  @impl Mutare.Mutator
  def mutate({sigil, meta, [{:<<>>, bmeta, [content]}, modifiers]})
      when sigil in [:sigil_w, :sigil_W] and is_binary(content) do
    words = String.split(content)

    ["", @sentinel]
    |> Enum.reject(&(String.split(&1) == words))
    |> Enum.map(&{sigil, meta, [{:<<>>, bmeta, [&1]}, modifiers]})
  end

  def mutate(_node), do: :skip
end
