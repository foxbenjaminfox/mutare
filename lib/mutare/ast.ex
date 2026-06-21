defmodule Mutare.AST do
  @moduledoc """
  Small constructors and predicates over the Sourceror AST — the rules about *how* a node
  must be built live here rather than being re-derived in every mutator.

  Custom mutators (`Mutare.Mutator`) should use these instead of hand-rolling AST. In
  particular `literal/1` encodes the **clean-meta rule**: Sourceror parses a literal as
  `{:__block__, meta, [value]}` and renders it from a `:token`/`delimiter` cached in `meta`,
  so a hand-built node gets this subtly wrong — reusing a parsed literal's meta re-renders the
  *original* text even after you change the value (a silent equivalent no-op), and a bare
  `{:__block__, [], ["x"]}` for a string renders as the *charlist* `~c"x"`. `literal/1` gets
  both right. The `sentinel_*` helpers give the same survivor marker the built-in families use,
  so a custom mutant reads consistently in reports.
  """

  @doc """
  A scalar-literal node with clean (fresh) metadata.

  Sourceror parses a literal as `{:__block__, meta, [value]}` and renders it from a
  `:token` string cached in `meta`. Reusing a node's *original* meta would therefore
  render the *original* text even after the value changed — a silent equivalent
  no-op. So a mutator that emits a new literal value must give it fresh metadata,
  which is what this builds.

  A **string** value additionally needs a `delimiter` in its metadata, or Sourceror
  renders a printable binary as a charlist (`~c"…"`); this adds the double-quote
  delimiter automatically, so callers never have to remember the distinction.

      iex> Mutare.AST.literal(0)
      {:__block__, [], [0]}
      iex> Mutare.AST.literal("mutare")
      {:__block__, [delimiter: ~s(")], ["mutare"]}
  """
  @spec literal(term()) :: Macro.t()
  def literal(value) when is_binary(value), do: {:__block__, [delimiter: ~s(")], [value]}
  def literal(value), do: {:__block__, [], [value]}

  @doc """
  The bare keyword atom of a key node, whether plain (`:do`) or Sourceror-wrapped
  (`{:__block__, _, [:do]}`); `nil` for anything that isn't an atom key.
  """
  @spec key_atom(Macro.t()) :: atom() | nil
  def key_atom({:__block__, _meta, [atom]}) when is_atom(atom), do: atom
  def key_atom(atom) when is_atom(atom), do: atom
  def key_atom(_), do: nil

  @doc """
  Whether `node` is an *inline keyword label* — the key side of an `a: x` pair,
  which Sourceror wraps as `{:__block__, meta, [atom]}` carrying a
  `format: :keyword` marker. Such a key is a structural label, never a runtime
  value, so it must not be offered to a mutator.

  This is the head/pattern-context check (`format: :keyword` only). The value
  context additionally treats block keys (`do`/`else`/…) as labels — that fuller
  rule lives in `Mutare.Transform.Analyze`, which owns the block-key set.
  """
  @spec keyword_label?(Macro.t()) :: boolean()
  def keyword_label?({:__block__, meta, [atom]}) when is_atom(atom) and is_list(meta),
    do: Keyword.get(meta, :format) == :keyword

  def keyword_label?(_), do: false

  @doc """
  Whether `node` is a `nil` literal in either bare or Sourceror-wrapped form.
  """
  @spec nil_literal?(Macro.t()) :: boolean()
  def nil_literal?(nil), do: true
  def nil_literal?({:__block__, _meta, [nil]}), do: true
  def nil_literal?(_), do: false

  @doc """
  Whether `node` is an *always-empty enumerable literal* — the result of a
  collection-emptying mutation: `List` → `[]`, `MapLiteral` → `%{}`,
  `WordListLiteral` → `~w()`, `CharlistLiteral` → `~c""`.

  On the right side of `in`, such a value makes `x in <empty>` constantly `false`,
  which `Mutare.Mutators.Conditional` already produces on the `in` node — so
  `Mutare.Transform` drops these mutations there as redundant siblings. A non-list/map
  collection (tuple, bitstring) is deliberately *excluded*: it isn't enumerable, so
  `x in {…}` raises rather than testing membership (emptying it changes nothing
  observable about that).

  This recognises the **standard** literal shapes, for any mutator. A custom mutator with
  a *non-standard* empty collection (its own sigil, a `MapSet.new([])` builder) declares it
  through the optional `c:Mutare.Mutator.empty_collection?/1` callback instead — the two are
  OR-ed at the drop site by `Mutare.Mutator.empty_collection?/2`.
  """
  @spec empty_collection_literal?(Macro.t()) :: boolean()
  def empty_collection_literal?([]), do: true
  def empty_collection_literal?({:__block__, _meta, [[]]}), do: true
  def empty_collection_literal?({:%{}, _meta, []}), do: true

  def empty_collection_literal?({sigil, _meta, [{:<<>>, _bmeta, [""]}, _modifiers]})
      when sigil in [:sigil_w, :sigil_W, :sigil_c, :sigil_C],
      do: true

  def empty_collection_literal?(_node), do: false

  @doc """
  The survivor sentinel as a string: a value distinctive enough to flag a
  surviving mutant in a report, yet unlikely to occur in real code. The literal
  families (`StringLiteral`, `ReturnValue`, …) all substitute it, so the single
  word lives here.
  """
  @spec sentinel_string() :: String.t()
  def sentinel_string, do: "mutare"

  @doc "The survivor sentinel as an atom (`:mutare`)."
  @spec sentinel_atom() :: atom()
  def sentinel_atom, do: :mutare

  @doc "The survivor sentinel as a module-alias path (`Mutare.Mutant`)."
  @spec sentinel_alias() :: [atom()]
  def sentinel_alias, do: [:Mutare, :Mutant]
end
