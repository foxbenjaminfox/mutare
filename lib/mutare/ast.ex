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
  both right. `literal_value/1` is the inverse — it reads a literal node back to its value.
  The `sentinel_*` helpers give the same survivor marker the built-in families use, so a custom
  mutant reads consistently in reports, and `absolute_call/3`/`absolute_alias/1` build calls and
  module references that survive any `alias`/`import` in the target being mutated.

  `parse!/1` and `to_string/1` are the AST front door: a custom mutator and its tests
  go through these rather than naming `Sourceror` directly, so the dependency on a
  particular AST library (and its version) stays inside Mutare.
  """

  # The two ends of the round-trip route through Mutare, so callers never need a
  # direct `:sourceror` dep just to build a node or read one back.
  import Kernel, except: [to_string: 1]

  @doc """
  Parse a source string into a Sourceror AST node, raising on a syntax error.

  The inverse of `to_string/1`. This is the node shape every `Mutare.Mutator`
  receives, so a mutator's tests can parse a snippet the same way the engine does.

      iex> {op, _meta, _args} = Mutare.AST.parse!("a + b")
      iex> op
      :+
  """
  @spec parse!(String.t()) :: Macro.t()
  def parse!(source) when is_binary(source), do: Sourceror.parse_string!(source)

  @doc """
  Render an AST node back to formatted source, the inverse of `parse!/1`.

      iex> Mutare.AST.to_string(Mutare.AST.literal("mutare"))
      ~s("mutare")
  """
  @spec to_string(Macro.t()) :: String.t()
  def to_string(ast), do: Sourceror.to_string(ast)

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

  A **negative number** is built as the canonical unary-minus AST the parser itself
  produces — `-0.5` is `{:-, _, [0.5]}`, *never* a bare negative literal. A bare
  `{:__block__, [], [-0.5]}` renders fine alone but glues into `--0.5` (the invalid
  list-subtraction token) the moment it lands under a parent unary minus — exactly
  what happens when a literal mutator negates the positive magnitude of an already
  negative source literal (`-0.5` mutated via `0.5 - 1.0`). Wrapping the magnitude in
  an explicit `{:-, …}` keeps the inner node an operator (not an atomic literal), so
  the formatter spaces nested minuses (`-(-0.5)`) and the result always re-parses.

      iex> Mutare.AST.literal(0)
      {:__block__, [], [0]}
      iex> Mutare.AST.literal("mutare")
      {:__block__, [delimiter: ~s(")], ["mutare"]}
      iex> Mutare.AST.literal(-1)
      {:-, [], [{:__block__, [], [1]}]}
  """
  @spec literal(term()) :: Macro.t()
  def literal(value) when is_binary(value), do: {:__block__, [delimiter: ~s(")], [value]}
  def literal(value) when is_number(value) and value < 0, do: {:-, [], [literal(-value)]}
  def literal(value), do: {:__block__, [], [value]}

  @doc """
  The scalar value a literal node carries — `{:ok, value}` for a number, binary, or atom in
  either bare or Sourceror block-wrapped (`{:__block__, _, [value]}`) form, and `:error` for
  anything else (a variable, call, collection, …).

  The reading counterpart to `literal/1`: use it in a mutator to recover the underlying value
  of a node before deciding how — or whether — to mutate it, for example to skip a mutation
  that would be an equivalent no-op. Booleans and `nil` are atoms, so they round-trip too;
  exclude them by filtering the returned value.

      iex> Mutare.AST.literal_value({:__block__, [], [0]})
      {:ok, 0}
      iex> Mutare.AST.literal_value(:foo)
      {:ok, :foo}
      iex> Mutare.AST.literal_value({:x, [], nil})
      :error
  """
  @spec literal_value(Macro.t()) :: {:ok, term()} | :error
  def literal_value({:__block__, _meta, [value]})
      when is_number(value) or is_binary(value) or is_atom(value),
      do: {:ok, value}

  def literal_value(value) when is_number(value) or is_binary(value) or is_atom(value),
    do: {:ok, value}

  def literal_value(_node), do: :error

  @doc """
  An **absolute-qualified** module alias — `{:__aliases__, [], [:"Elixir" | path]}`, the
  `Elixir.`-prefixed form that `alias`/`import` resolution never rewrites.

  Use it in a mutator when a mutation must reference a specific module no matter what the
  target code aliases or imports: an `alias Foo, as: Kernel` in the target cannot redirect
  `absolute_alias([:Kernel])`. Pair it with `absolute_call/3` to build a whole call.

      iex> Mutare.AST.absolute_alias([:Kernel])
      {:__aliases__, [], [:"Elixir", :Kernel]}
  """
  @spec absolute_alias([atom()]) :: Macro.t()
  def absolute_alias(path) when is_list(path), do: {:__aliases__, [], [:"Elixir" | path]}

  @doc """
  An **alias-proof remote call** `Elixir.Mod.fun(args)`, built on `absolute_alias/1` so a
  target's `alias`/`import` can never redirect the callee.

  Use it in a mutator whose mutation renames a call to a function in a *different* module —
  for example swapping `String.length(s)` for a byte count with
  `absolute_call([:Kernel], :byte_size, args)`. Because the module is absolute-qualified, no
  `alias`/`import` in the target can point the swapped call elsewhere.

      iex> Mutare.AST.absolute_call([:Kernel], :==, [1, 2])
      {{:., [], [{:__aliases__, [], [:"Elixir", :Kernel]}, :==]}, [], [1, 2]}
  """
  @spec absolute_call([atom()], atom(), [Macro.t()]) :: Macro.t()
  def absolute_call(path, fun, args) when is_list(path) and is_atom(fun) and is_list(args),
    do: {{:., [], [absolute_alias(path), fun]}, [], args}

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
