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

  In-place and compile-safe — a charlist sigil is legal wherever the original
  was. Only non-interpolated charlists are touched: an interpolated `~c"a\#{x}b"`
  parses with multiple `<<>>` parts (not a single binary), so the operand is
  always a static charlist.

  On the **RHS of `in`** (`x in ~c"ab"`) the *empty* variant `~c""` is dropped — it is
  `x in []` ≡ `false`, which `Mutare.Mutators.Conditional` already produces on the `in`
  node — but the non-empty sentinel `~c"mutare"` is kept. Per-mutation, shared via
  `Mutare.AST.empty_collection_literal?/1`. See NOTES "Equivalent-sibling suppression,
  generalized".
  """
  @behaviour Mutare.Mutator

  alias Mutare.AST

  @sentinel AST.sentinel_string()

  @impl Mutare.Mutator
  def name, do: :charlist

  @impl Mutare.Mutator
  def mutate({:sigil_c, meta, [{:<<>>, bmeta, [content]}, modifiers]}) when is_binary(content) do
    ["", @sentinel]
    |> Enum.reject(&(&1 == content))
    |> Enum.map(&{:sigil_c, meta, [{:<<>>, bmeta, [&1]}, modifiers]})
  end

  def mutate(_node), do: :skip
end
