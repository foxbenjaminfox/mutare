defmodule Mutare.Mutators.CharlistLiteral do
  @moduledoc """
  Charlist-sigil mutations: replace a `~c"…"` charlist with both the empty
  charlist `~c""` and a non-empty sentinel (`~c"mutare"`), dropping whichever
  already equals the original. The charlist counterpart of
  `Mutare.Mutators.StringLiteral`.

  Only the **sigil** form `~c"…"` is mutated. The legacy single-quoted form
  `'…'` parses as an ordinary list literal (`{:__block__, _, [charlist]}`) and is
  already collapsed to `[]` by `Mutare.Mutators.List` — matching it here too would
  emit a duplicate empty-mutant, so this module leaves it alone.

  Only non-interpolated charlists are touched: an interpolated `~c"a\#{x}b"` parses
  with multiple `<<>>` parts, not a single binary.

  Not mutated: on the **RHS of `in`** (`x in ~c"ab"`) the *empty* variant `~c""` is
  dropped — it is `x in []` ≡ `false`, which `Mutare.Mutators.Conditional` already
  produces — but the non-empty sentinel `~c"mutare"` is kept.

  Filterable variants — qualify a `# mutare:ignore` filter with `:label` to
  suppress just one half (`c:Mutare.Mutator.variants/0`): `empty` (the `~c""`) or
  `sentinel` (the `~c"mutare"`).
  """
  @behaviour Mutare.Mutator

  alias Mutare.AST
  alias Mutare.Mutator.Mutation
  alias Mutare.Mutators.Helpers

  @sentinel AST.sentinel_string()

  @impl Mutare.Mutator
  def name, do: :charlist

  @impl Mutare.Mutator
  def mutate({:sigil_c, meta, [{:<<>>, bmeta, [content]}, modifiers]}) when is_binary(content) do
    ["", @sentinel]
    |> Enum.reject(&(&1 == content))
    |> Enum.map(fn new ->
      Mutation.tagged(
        {:sigil_c, meta, [{:<<>>, bmeta, [new]}, modifiers]},
        Helpers.empty_sentinel_variant(new, @sentinel)
      )
    end)
  end

  def mutate(_node), do: :skip

  # Variant vocabulary for `# mutare:ignore[charlist:<label>]` — `empty` (the `~c""`) / `sentinel`
  # (the `~c"mutare"`). Each mutant is a re-wrapped `~c` sigil tagged at production with its label,
  # so it rides on the `Mutare.Mutator.Mutation` rather than being re-derived via `variant/2`.
  @impl Mutare.Mutator
  def variants, do: Helpers.empty_sentinel_variants()
end
