defmodule Mutare.Mutators.CharlistLiteral do
  @moduledoc """
  Charlist-sigil mutations: replace a `~c"…"` (or `~C"…"`) charlist with both the empty charlist `~c""` and a non-empty sentinel (`~c"mutare"`), dropping whichever already equals the original and preserving the sigil head (`~C` stays `~C`). The charlist counterpart of `Mutare.Mutators.StringLiteral`.

  Interpolated charlists are mutated as a whole too, and both replacements always apply (their runtime value can never statically be either); the expressions inside the interpolation stay eligible for their own mutations. That covers the sigil form `~c"a\#{x}b"` *and* the legacy single-quoted form `'a\#{x}b'` — the latter parses as a `List.to_charlist/1` call, and its replacements are rendered in the modern `~c` syntax.

  The *non-interpolated* legacy form `'…'` parses as an ordinary list literal (`{:__block__, _, [charlist]}` carrying the `'` delimiter), so its mutations are split by ownership: `Mutare.Mutators.List` owns the *empty* collapse (the node is a list literal to it; emitting `~c""` here too would duplicate that mutant), while this family owns the *sentinel* — `'abc'` → `~c"mutare"` — so legacy charlist content is challenged exactly like `~c` content. An already-sentinel `'mutare'` is skipped.

  Not mutated: on the RHS of a guard `in` (`when x in ~c"ab"`) the *empty* variant `~c""` is dropped — it is `x in []` ≡ `false`, which `Mutare.Mutators.Conditional` already produces — but the non-empty sentinel `~c"mutare"` is kept. Body `in` expressions keep the empty variant because left-side evaluation is observable.

  Filterable variants — qualify a `# mutare:ignore` filter with `:label` to suppress just one half (`c:Mutare.Mutator.variants/0`): `empty` (the `~c""`) or `sentinel` (the `~c"mutare"`).
  """
  @behaviour Mutare.Mutator
  use Mutare.Mutator.SkipArguments

  alias Mutare.AST
  alias Mutare.Mutator.Mutation
  alias Mutare.Mutators.Helpers

  @sentinel AST.sentinel_string()
  @sentinel_charlist String.to_charlist(AST.sentinel_string())

  @impl Mutare.Mutator
  def name, do: :charlist

  @impl Mutare.Mutator
  def mutate({sigil, meta, [{:<<>>, bmeta, segments}, modifiers]})
      when sigil in [:sigil_c, :sigil_C] do
    # Only real `~c`/`~C` sigil syntax carries the parser's `:delimiter` meta — a call to
    # a *function* named `sigil_c`/`sigil_C` (a local sigil shadowing `Kernel`'s) parses to
    # the same head without it (see `Mutare.Mutators.StringSigilLiteral`, the same guard).
    # The head is preserved so a `~C` replacement stays `~C` (`~C` never interpolates, so
    # only the static single-binary path applies to it).
    if Keyword.has_key?(meta, :delimiter) do
      segments
      |> replacement_contents()
      |> Enum.map(fn new ->
        Mutation.tagged(
          {sigil, meta, [{:<<>>, bmeta, [new]}, modifiers]},
          Helpers.empty_sentinel_variant(new, @sentinel)
        )
      end)
    else
      :skip
    end
  end

  # A legacy interpolated charlist (`'a#{x}b'`) parses as a `List.to_charlist/1` call whose
  # single argument is the segment list, with the parser's `:delimiter` on the call meta —
  # the gate that separates charlist *syntax* from a hand-written call to the same function
  # (no delimiter: skipped). Both replacements always apply (interpolated — never statically
  # equal), built as `~c` sigil literals: the same charlist values in the modern syntax.
  def mutate({{:., _dot, [List, :to_charlist]}, meta, [segments]}) when is_list(segments) do
    if Keyword.has_key?(meta, :delimiter) do
      Enum.map(["", @sentinel], fn new ->
        Mutation.tagged(sigil_charlist(new), Helpers.empty_sentinel_variant(new, @sentinel))
      end)
    else
      :skip
    end
  end

  # A plain legacy charlist (`'abc'`) parses as an ordinary *list literal* carrying the `'`
  # delimiter — the discriminator from a real list (`[97, 98]`, no delimiter: skipped).
  # Ownership split with `Mutare.Mutators.List` (see @moduledoc): List owns the empty
  # collapse, this family adds only the sentinel, rendered in the modern `~c` syntax.
  def mutate({:__block__, meta, [charlist]}) when is_list(charlist) do
    if meta[:delimiter] == "'" and charlist != @sentinel_charlist do
      [
        Mutation.tagged(
          sigil_charlist(@sentinel),
          Helpers.empty_sentinel_variant(@sentinel, @sentinel)
        )
      ]
    else
      :skip
    end
  end

  def mutate(_node), do: :skip

  # Variant vocabulary for `# mutare:ignore[charlist:<label>]` — `empty` (the `~c""`) / `sentinel`
  # (the `~c"mutare"`). Each mutant is a re-wrapped `~c` sigil tagged at production with its label,
  # so it rides on the `Mutare.Mutator.Mutation` rather than being re-derived via `variant/2`.
  @impl Mutare.Mutator
  def variants, do: Helpers.empty_sentinel_variants()

  # Non-interpolated sigil content (a single static binary): drop the no-op replacement.
  defp replacement_contents([content]) when is_binary(content),
    do: Enum.reject(["", @sentinel], &(&1 == content))

  # Interpolated (multiple segments / a lone interpolation): the runtime charlist is never
  # statically `~c""`/`~c"mutare"`, so both replacements apply.
  defp replacement_contents(_segments), do: ["", @sentinel]

  # A fresh `~c"…"` literal — `delimiter` present so Sourceror renders sigil syntax.
  defp sigil_charlist(content),
    do: {:sigil_c, [delimiter: ~s(")], [{:<<>>, [], [content]}, []]}
end
