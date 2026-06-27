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

  Only non-interpolated word lists are touched: an interpolated `~w(a \#{x} b)` parses
  with multiple `<<>>` parts, not a single binary (`~W` never interpolates).

  Not mutated: on the **RHS of `in`** (`x in ~w(a b)`) the *empty* variant `~w()` is
  dropped — it is `x in []` ≡ `false`, which `Mutare.Mutators.Conditional` already
  produces — but the non-empty *sentinel* `~w(mutare)` is kept.

  Filterable variants — qualify a `# mutare:ignore` filter with `:label` to
  suppress just one half (`c:Mutare.Mutator.variants/0`): `empty` (the `~w()`) or
  `sentinel` (the `~w(mutare)`).
  """
  @behaviour Mutare.Mutator

  alias Mutare.AST
  alias Mutare.Mutator.Mutation
  alias Mutare.Mutators.Helpers

  @sentinel AST.sentinel_string()

  @impl Mutare.Mutator
  def name, do: :word_list

  @impl Mutare.Mutator
  def mutate({sigil, meta, [{:<<>>, bmeta, [content]}, modifiers]})
      when sigil in [:sigil_w, :sigil_W] and is_binary(content) do
    words = String.split(content)

    ["", @sentinel]
    |> Enum.reject(&(String.split(&1) == words))
    |> Enum.map(fn new ->
      Mutation.tagged(
        {sigil, meta, [{:<<>>, bmeta, [new]}, modifiers]},
        Helpers.empty_sentinel_variant(new, @sentinel)
      )
    end)
  end

  def mutate(_node), do: :skip

  # Variant vocabulary for `# mutare:ignore[word_list:<label>]` — `empty` (the `~w()`) / `sentinel`
  # (the `~w(mutare)`). Each mutant is a re-wrapped `~w`/`~W` sigil tagged at production with its
  # label, so it rides on the `Mutare.Mutator.Mutation` rather than being re-derived via `variant/2`.
  @impl Mutare.Mutator
  def variants, do: Helpers.empty_sentinel_variants()
end
