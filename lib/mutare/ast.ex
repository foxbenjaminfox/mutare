defmodule Mutare.AST do
  @moduledoc """
  Small constructors and predicates for Sourceror AST nodes.

  These helpers are the supported way for custom mutators to build AST. `literal/1` is the most important one: it builds literal nodes with fresh metadata, so Sourceror renders the new value rather than stale source text. It also handles string delimiters, numeric token metadata, and negative-number shape correctly.

  `literal_value/1` reads supported literal nodes back to their values. The `sentinel_*` helpers return the same survivor markers used by the built-in families, and `numeric_alternatives/3` the same off-by-one/zero alternatives (with their variant labels and collapse rule) the numeric literal families produce. `absolute_alias/1`, `absolute_call/3`, and `remote_call/3` build references that are not affected by aliases or imports in the target source. `keyword_key/1` and `clean_var/1` cover the remaining node shapes a mutator emits into existing source: fresh keyword keys and re-declared bindings.

  `parse!/1` and `to_string/1` expose the Sourceror round trip without requiring custom mutators to depend on Sourceror directly.
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
  Builds a scalar-literal node with fresh metadata.

  Sourceror parses a literal as `{:__block__, meta, [value]}` and may render it
  from cached token metadata. Reusing metadata from a parsed literal can therefore
  render the original source text after the value has changed. This helper builds a
  fresh literal node for replacement values.

  String values include a double-quote delimiter. Without it, Sourceror may render a
  printable binary as a charlist.

  Numbers carry a `:token` derived from the new value. The formatter fetches token
  metadata for every numeric literal and can raise when it cannot synthesize one in
  an embedded position — for example inside a call node a mutator weaves into
  already-parsed source. Because the token is the new value's own text, it can never
  re-render stale source.

  Negative numbers use the same unary-minus AST shape the parser emits. This keeps
  nested negative-number mutations renderable and parseable, for example when a
  mutation inside `-0.5` would otherwise format as an invalid `--0.5`.

      iex> Mutare.AST.literal(0)
      {:__block__, [token: "0"], [0]}
      iex> Mutare.AST.literal("mutare")
      {:__block__, [delimiter: ~s(")], ["mutare"]}
      iex> Mutare.AST.literal(-1)
      {:-, [], [{:__block__, [token: "1"], [1]}]}
  """
  @spec literal(term()) :: Macro.t()
  def literal(value) when is_binary(value), do: {:__block__, [delimiter: ~s(")], [value]}
  def literal(value) when is_number(value) and value < 0, do: {:-, [], [literal(-value)]}

  def literal(value) when is_integer(value),
    do: {:__block__, [token: Integer.to_string(value)], [value]}

  def literal(value) when is_float(value),
    do: {:__block__, [token: Float.to_string(value)], [value]}

  def literal(value), do: {:__block__, [], [value]}

  @doc """
  Reads the scalar value from a literal node.

  Returns `{:ok, value}` for a number, binary, or atom in either bare scalar
  form or Sourceror's `{:__block__, _, [value]}` wrapper. Returns `:error` for
  variables, calls, collections, unary-minus literal expressions such as
  `Mutare.AST.literal(-1)`, and other non-scalar nodes.

  Booleans and `nil` are atoms and are returned as values; filter them separately
  when a mutator does not own them.

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
  Removes one Sourceror literal wrapper.

  A single-element `{:__block__, _, [inner]}` returns `inner`; any other node is
  returned unchanged. Unlike `literal_value/1`, this helper does not require the
  inner term to be a scalar literal and does not wrap the result in `{:ok, _}`.

      iex> Mutare.AST.unwrap_literal({:__block__, [], [:persistent_term]})
      :persistent_term
      iex> Mutare.AST.unwrap_literal(:persistent_term)
      :persistent_term
  """
  @spec unwrap_literal(Macro.t()) :: Macro.t()
  def unwrap_literal({:__block__, _meta, [inner]}), do: inner
  def unwrap_literal(node), do: node

  @doc """
  Strips a variable node's metadata, keeping its name and hygiene context.

  Use it to re-declare a binding inside synthesized scaffolding — a wrapper call a
  mutator builds around existing code — where the source line/column and token
  metadata are stale but the context atom must survive for the variable to stay
  the same variable.

      iex> Mutare.AST.clean_var({:user, [line: 3, column: 7], nil})
      {:user, [], nil}
  """
  @spec clean_var(Macro.t()) :: Macro.t()
  def clean_var({name, _meta, ctx}) when is_atom(name) and is_atom(ctx), do: {name, [], ctx}

  @doc """
  Builds an absolute-qualified module alias.

  The result is the `Elixir.`-prefixed form that alias and import resolution do
  not rewrite. Use it when a mutation must refer to a specific module regardless of
  aliases in the target source. Pair it with `absolute_call/3` to build a call.

      iex> Mutare.AST.absolute_alias([:Kernel])
      {:__aliases__, [], [:"Elixir", :Kernel]}
  """
  @spec absolute_alias([atom()]) :: Macro.t()
  def absolute_alias(path) when is_list(path), do: {:__aliases__, [], [:"Elixir" | path]}

  @doc """
  Builds an absolute-qualified remote call.

  The callee cannot be redirected by aliases or imports in the target source. This
  is useful when a mutator replaces a call with a function from another module, such
  as replacing `String.length(s)` with `Kernel.byte_size(s)`.

      iex> Mutare.AST.absolute_call([:Kernel], :==, [1, 2])
      {{:., [], [{:__aliases__, [], [:"Elixir", :Kernel]}, :==]}, [], [1, 2]}
  """
  @spec absolute_call([atom()], atom(), [Macro.t()]) :: Macro.t()
  def absolute_call(path, fun, args) when is_list(path) and is_atom(fun) and is_list(args),
    do: remote_call(absolute_alias(path), fun, args)

  @doc """
  Builds a remote call `mod.fun(args)` around a pre-built callee node.

  The general form of `absolute_call/3`: use it when the module reference is
  already a node — an `absolute_alias/1` result, a variable, or an alias taken
  from the source being mutated.

      iex> Mutare.AST.remote_call(Mutare.AST.absolute_alias([:Kernel]), :==, [1, 2])
      {{:., [], [{:__aliases__, [], [:"Elixir", :Kernel]}, :==]}, [], [1, 2]}
  """
  @spec remote_call(Macro.t(), atom(), [Macro.t()]) :: Macro.t()
  def remote_call(mod, fun, args) when is_atom(fun) and is_list(args),
    do: {{:., [], [mod, fun]}, [], args}

  @doc """
  The bare keyword atom of a key node, whether plain (`:do`) or Sourceror-wrapped
  (`{:__block__, _, [:do]}`); `nil` for anything that isn't an atom key.
  """
  @spec key_atom(Macro.t()) :: atom() | nil
  def key_atom({:__block__, _meta, [atom]}) when is_atom(atom), do: atom
  def key_atom(atom) when is_atom(atom), do: atom
  def key_atom(_), do: nil

  @doc """
  Builds a keyword-list **key** node that renders as `key:` rather than `{:key, …}`.

  The `format: :keyword` marker is what the renderer keys on; `keyword_label?/1`
  is the matching reader. Use it when a mutation emits a fresh keyword entry.

      iex> Mutare.AST.keyword_key(:limit)
      {:__block__, [format: :keyword], [:limit]}
  """
  @spec keyword_key(atom()) :: Macro.t()
  def keyword_key(atom) when is_atom(atom), do: {:__block__, [format: :keyword], [atom]}

  @doc """
  Returns the value bound to `key` in a Sourceror-form keyword list.

  Returns `default` when the key is absent. Keys are read with `key_atom/1`, so
  both `[as: B]` and `[{:as, B}]` match.
  """
  @spec opts_get([Macro.t()], atom(), term()) :: Macro.t() | term()
  def opts_get(opts, key, default \\ nil) when is_list(opts) do
    Enum.find_value(opts, default, fn
      {k, value} -> if key_atom(k) == key, do: value
      _ -> nil
    end)
  end

  @doc """
  Map over a keyword list, replacing the value of the `:do` entry with `fun.(value)`.

  Recognises both Sourceror's keyword-block key (`{:__block__, _, [:do]}`)
  and a plain `:do` (via `key_atom/1`), preserves the original key node (so its
  `format: :keyword` marker survives for the renderer), and leaves every other entry
  — and a non-list argument — untouched.
  """
  @spec update_do_block(Macro.t(), (Macro.t() -> Macro.t())) :: Macro.t()
  def update_do_block(keyword, fun) when is_list(keyword) do
    Enum.map(keyword, fn
      {key, value} = entry -> if key_atom(key) == :do, do: {key, fun.(value)}, else: entry
      entry -> entry
    end)
  end

  def update_do_block(other, _fun), do: other

  @doc """
  `update_do_block/2` threading an accumulator: `fun.(value, acc)` returns
  `{new_value, acc}`, like `Enum.map_reduce/3`. Non-`:do` entries (and a non-list
  argument) pass the accumulator through unchanged.
  """
  @spec update_do_block_reduce(Macro.t(), acc, (Macro.t(), acc -> {Macro.t(), acc})) ::
          {Macro.t(), acc}
        when acc: var
  def update_do_block_reduce(keyword, acc, fun) when is_list(keyword) do
    Enum.map_reduce(keyword, acc, fn
      {key, value} = entry, acc ->
        if key_atom(key) == :do do
          {value, acc} = fun.(value, acc)
          {{key, value}, acc}
        else
          {entry, acc}
        end

      entry, acc ->
        {entry, acc}
    end)
  end

  def update_do_block_reduce(other, acc, _fun), do: {other, acc}

  @doc """
  Returns whether `node` is the key side of an inline keyword pair.

  Sourceror represents `a:` as `{:__block__, meta, [:a]}` with
  `format: :keyword`. Such keys are structural labels, not runtime values.

  This predicate checks only the inline-keyword marker. Value-context block keys
  such as `do` and `else` are handled separately.
  """
  @spec keyword_label?(Macro.t()) :: boolean()
  def keyword_label?({:__block__, meta, [atom]}) when is_atom(atom) and is_list(meta),
    do: Keyword.get(meta, :format) == :keyword

  def keyword_label?(_), do: false

  @doc """
  Whether a `{:<<>>, meta, _}` node is really a **string**, not a `<<…>>` bitstring.

  Sourceror parses an interpolated string (`"a\#{x}b"`, or an interpolated heredoc) into a
  `<<>>` node, distinguished from a true `<<…>>` bitstring literal by a `:delimiter` key cached
  in its metadata. The string- and bitstring-literal families route on it with opposite intent
  — `StringLiteral` mutates these (an interpolated string), `BitstringLiteral`/`BitstringSpec`
  skip them (they own real bitstrings). A non-`<<>>` node is never a string binary.

      iex> Mutare.AST.string_binary?({:<<>>, [delimiter: ~s(")], ["hi"]})
      true
      iex> Mutare.AST.string_binary?({:<<>>, [], [1, 2]})
      false
      iex> Mutare.AST.string_binary?({:__block__, [], [:atom]})
      false
  """
  @spec string_binary?(Macro.t()) :: boolean()
  def string_binary?({:<<>>, meta, _segments}) when is_list(meta),
    do: Keyword.has_key?(meta, :delimiter)

  def string_binary?(_node), do: false

  @doc """
  Whether `node` is a `nil` literal in either bare or Sourceror-wrapped form.
  """
  @spec nil_literal?(Macro.t()) :: boolean()
  def nil_literal?(nil), do: true
  def nil_literal?({:__block__, _meta, [nil]}), do: true
  def nil_literal?(_), do: false

  @doc """
  Whether `node` is an *always-empty enumerable literal* admitted on the right of
  `in` in a guard: `List` → `[]`, `WordListLiteral` → `~w()`, or
  `CharlistLiteral` → `~c""`.

  In a guard, `x in <empty>` is equivalent to the `false` mutant that
  `Mutare.Mutators.Conditional` already produces on the `in` node: guards have no
  observable side effects and a guard error is a failed guard. `Mutare.Transform.Tag`
  therefore drops the empty-literal sibling there. Body expressions do not use this
  predicate because evaluating `x` can be observable.
  """
  @spec empty_collection_literal?(Macro.t()) :: boolean()
  def empty_collection_literal?([]), do: true
  def empty_collection_literal?({:__block__, _meta, [[]]}), do: true

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

  @doc """
  The "off-by-one + zero sentinel" alternatives for a numeric literal `value`, exactly as the
  built-in `Mutare.Mutators.IntegerLiteral` (`step` 1, `zero` 0) and `Mutare.Mutators.FloatLiteral`
  (`step` 1.0, `zero` 0.0) produce them: `value + step` (labelled `"succ"`), `value - step`
  (`"pred"`), and `zero` (`"zero"`), as ordered `{value, labels}` pairs.

  Two rules ride along, so a custom mutator that mints the same alternatives somewhere core can't
  reach (a literal inside a DSL fragment it hosts) stays in step with the built-ins and their
  `# mutare:ignore` variant vocabulary: an alternative equal to `value` is dropped (`0` is never
  re-emitted for `0`), and alternatives that collapse onto one value are **merged** into a single
  pair carrying every label, positioned at the first occurrence — so `1`'s `pred` and its `zero`
  sentinel become one `{0, ["pred", "zero"]}` that either qualifier suppresses.

      iex> Mutare.AST.numeric_alternatives(5, 1, 0)
      [{6, ["succ"]}, {4, ["pred"]}, {0, ["zero"]}]
      iex> Mutare.AST.numeric_alternatives(1, 1, 0)
      [{2, ["succ"]}, {0, ["pred", "zero"]}]
      iex> Mutare.AST.numeric_alternatives(0.0, 1.0, 0.0)
      [{1.0, ["succ"]}, {-1.0, ["pred"]}]

  Values, not nodes — build each with `literal/1` (and filter first if a position can't take
  some of them, e.g. a negative index).
  """
  @spec numeric_alternatives(number(), number(), number()) :: [{number(), [String.t()]}]
  def numeric_alternatives(value, step, zero) do
    [{value + step, "succ"}, {value - step, "pred"}, {zero, "zero"}]
    |> Enum.reject(fn {v, _label} -> v == value end)
    |> merge_labels_by_value()
  end

  # Group `{value, label}` pairs by value, preserving first-seen order and collecting *all* labels
  # for a value — so a collapse (`value ± step == zero`) yields one pair carrying both kinds,
  # positioned at the first occurrence (the order the built-in families' mutant ids depend on).
  defp merge_labels_by_value(pairs) do
    {order, labels} =
      Enum.reduce(pairs, {[], %{}}, fn {value, label}, {order, labels} ->
        if Map.has_key?(labels, value),
          do: {order, Map.update!(labels, value, &(&1 ++ [label]))},
          else: {[value | order], Map.put(labels, value, [label])}
      end)

    order |> Enum.reverse() |> Enum.map(&{&1, labels[&1]})
  end
end
