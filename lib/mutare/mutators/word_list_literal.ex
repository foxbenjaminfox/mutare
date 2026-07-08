defmodule Mutare.Mutators.WordListLiteral do
  @moduledoc """
  Replaces a non-interpolated `~w` or `~W` word list with an empty list and a one-element sentinel list:

    * `~w(a b)` → `~w()`
    * `~w(a b)` → `~w(mutare)`

  The sigil modifier is retained, so `a` and `c` word lists keep atom and charlist elements. Equivalent replacements are detected from the parsed words rather than the raw source; for example, a whitespace-only word list does not produce another empty-list mutant.

  Interpolated `~w` sigils are not mutated. `~W` never interpolates.

  On the right side of a guard `in`, the empty replacement is suppressed because membership in an empty list is already covered by `Mutare.Mutators.Conditional`. The sentinel replacement remains eligible. Body `in` expressions keep the empty replacement because left-side evaluation is observable.

  The ignore variants are `empty` and `sentinel`.
  """
  @behaviour Mutare.Mutator
  use Mutare.Mutator.SkipArguments

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
