defmodule Mutare.Transform.Super do
  @moduledoc false

  # `super(...)` rewriting for lifted function bodies.
  #
  # `super` is a special form legal *only* inside the overriding function — it
  # invokes the function it overrides. Lifting relocates a clause body into a
  # private `defp __mutare_…` whose name is not the overridden one, so a `super`
  # there is a compile error ("super is undefined").
  #
  # The fix keeps the rewrite local. The public dispatcher *is* the overriding
  # function (it keeps the original name), and `super` is allowed captured there, so
  # the dispatcher binds
  #
  #     <super_var> = &super/arity
  #
  # and passes that closure to the base as an extra argument; in the lifted body a
  # `super` *call* is rewritten to `<super_var>.(args)` and a `super` *capture*
  # `&super/arity` to the bare `<super_var>` (the closure already *is* that capture).
  # `&super/arity` is exactly `fn a1, …, aN -> super(a1, …, aN) end`, and the arity is
  # the function's full formal-parameter count — `super` must be *called* (and can only
  # be *captured*) with exactly that arity ("super must be called with the same number
  # of arguments as the current definition"), so the single capture forwards every
  # legal `super`, defaults included, and a source `&super/arity` is value-identical to
  # it. `Mutare.Transform` owns building the closure + threading the extra arg (it
  # shares the dispatcher/lifted-clause emission); this module owns only recognising
  # and rewriting the `super` nodes.
  #
  # **Quote is level-aware, not pruned.** A `super` inside `quote do … end` is usually
  # quoted *data* — it names whatever context the AST is later spliced into, not a live
  # call here — so it is left untouched, and a body with only such `super`s reads as
  # super-free and lifts without a closure. But a quote can *evaluate* a `super` while
  # building the AST: `unquote(super(x))` (the unquote escapes the quote) and
  # `bind_quoted: [x: super(x)]` (an option, evaluated at construction) both run the
  # `super` now. The walk tracks the quote-nesting level (`walk/3`): a `super` is live
  # only at level 0; `quote` raises the level for its block, `unquote`/`unquote_splicing`
  # lower it, and quote *option* values stay at the quote's level — so those live
  # `super`s are detected and rewritten while the plain quoted ones are left as data.
  # (Out of scope, like the analyzer: `quote unquote: false` — a rare `unquote(super …)`
  # there is data, but would still be rewritten; harmless unless that exact shape is
  # used.)

  @doc """
  Whether any clause's *body* contains a rewriteable `super` call or capture.

  The decision the dispatcher uses to know whether to build the closure at all —
  off by default, so a `super`-free group emits exactly as before. Only the body is
  inspected (head/`when`/default-value positions can't host a base-relocated
  `super`: a default rides on the dispatcher, which may call `super` directly).
  """
  @spec in_clauses?([Macro.t()]) :: boolean()
  def in_clauses?(clauses), do: Enum.any?(clauses, &body_has_super?/1)

  @doc """
  Rewrite every live `super` in `body`: a call `super(args)` to `<super_var>.(args)`,
  and a capture `&super/arity` to the bare `<super_var>` (the closure already holds the
  override captured at that arity — its only legal one).

  Returns `{rewritten_body, found?}`; `found?` is `false` when the body had no
  `super`, so the caller can keep the extra closure parameter unused (a bare `_`) on
  that base clause while still matching the shared arity.
  """
  @spec rewrite(Macro.t(), atom()) :: {Macro.t(), boolean()}
  def rewrite(body, super_var), do: walk(body, super_var, 0)

  # A throwaway variable name for detection-only walks: the rewritten AST is
  # discarded, only `found?` is read, so the value is irrelevant — but reusing the
  # one walk keeps detection and rewriting provably in lock-step.
  @super_canary :__mutare_super_canary__

  # `quote` keys whose value is the *quoted block* (data, one level deeper); every
  # other quote option (`bind_quoted:`, `unquote:`, `location:`, …) is evaluated when
  # the quote is built, at the quote's own level.
  @quote_block_keys ~w(do else after catch rescue)a

  defp body_has_super?({_vis, _meta, [_head | body]}) do
    {_ast, found} = walk(body, @super_canary, 0)
    found
  end

  # mutare:ignore[boolean, clause_drop] unreachable — `in_clauses?` only maps over well-formed def/defp clauses, matched by the clause above, so neither the value nor the whole fallback is ever observed
  defp body_has_super?(_), do: false

  # `level` is the quote-nesting depth: 0 is live code, where a `super` runs and is
  # rewritten; level > 0 is inside a `quote` block, where a `super` is quoted *data*.
  # `quote` raises the level for its block, `unquote`/`unquote_splicing` lower it (they
  # escape back toward live code), and a quote's *option* values (notably `bind_quoted`)
  # stay at the quote's own level — so a `super` in `unquote(super(x))` or
  # `bind_quoted: [x: super(x)]` is live at construction and *is* rewritten, while one
  # in the plain quoted body is left as data.

  # A `quote`: split its args (keyword lists) into block values (deeper) and option
  # values (same level) — see `walk_quote_arg/3`.
  defp walk({:quote, meta, args}, var, level) when is_list(args) do
    {args, found} = walk_quote_args(args, var, level)
    {{:quote, meta, args}, found}
  end

  # An `unquote`/`unquote_splicing` inside a quote escapes one level toward live code,
  # so its argument is evaluated one level shallower. (At level 0 — not inside a quote,
  # where these are invalid source anyway — it is descended as an ordinary call below.)
  defp walk({unq, meta, [expr]}, var, level)
       when unq in [:unquote, :unquote_splicing] and level > 0 do
    {expr, found} = walk(expr, var, level - 1)
    {{unq, meta, [expr]}, found}
  end

  # A `&super/arity` capture (only when live): `super` can only ever be captured at the
  # function's full param count — its single legal arity ("super must be called with
  # the same number of arguments as the current definition") — which is exactly the
  # arity the closure is bound at, so the whole capture is value-identical to `<var>`
  # and rewrites to the bare variable. (Not `&<var>/arity`: `<var>` is a *variable*
  # holding the function, and `&name/arity` captures a *function* of that name —
  # `&<var>/arity` would fail to compile.) The super node here carries an atom context,
  # not an arg list, so the call clause below skips it; without this clause a
  # capture-only body would lift without a closure, leaving an uncompilable `&super/`.
  # mutare:ignore[guard_drop] equivalent — a compilable `&super/arity` capture always has an atom context; the only non-atom-ctx shape, `&(super(args)/n)`, doesn't compile
  defp walk({:&, _meta, [{:/, _slash, [{:super, _smeta, ctx}, _arity]}]}, var, 0)
       when is_atom(ctx) do
    {{var, [], nil}, true}
  end

  # A live `super(args)` call (level 0): rewrite to `<var>.(args)`, still descending the
  # args (a nested `super`, or one inside an argument, is rewritten too). Covers a
  # `super` *called* inside a capture too (`&super(&1)` → `&<var>.(&1)`, via the n-ary
  # descent below reaching this clause), distinct from the `&super/arity` shorthand
  # above. A quoted-data `super` (level > 0) falls to the n-ary clause below instead —
  # left as-is, but still descended so a nested `unquote` within it is reached.
  # mutare:ignore[guard_drop] equivalent — a compilable `super` is always a call (list args) or the `&super/n` capture handled above; a bare `super` identifier (atom context) doesn't compile
  defp walk({:super, meta, args}, var, 0) when is_list(args) do
    {args, _found} = walk_many(args, var, 0)
    {{{:., meta, [{var, [], nil}]}, meta, args}, true}
  end

  # Any other n-ary node: descend its form (a remote-call `{:., …}` / anon-call
  # subject can be a node) and its args, at the same level.
  defp walk({form, meta, args}, var, level) when is_list(args) do
    {form, found_form} = walk(form, var, level)
    {args, found_args} = walk_many(args, var, level)
    {{form, meta, args}, found_form or found_args}
  end

  # A 2-tuple (a keyword/map pair shape): descend both sides.
  defp walk({left, right}, var, level) do
    {left, found_left} = walk(left, var, level)
    {right, found_right} = walk(right, var, level)
    {{left, right}, found_left or found_right}
  end

  defp walk(list, var, level) when is_list(list), do: walk_many(list, var, level)

  # A leaf (atom form, var, literal): nothing to rewrite.
  defp walk(leaf, _var, _level), do: {leaf, false}

  # Each `quote` arg is a keyword list (an options list and/or the block list); walk
  # every pair, sending a block key's value one level deeper and every option value
  # (evaluated when the quote runs) at the quote's own level.
  defp walk_quote_args(args, var, level) do
    map_reduce(args, fn arg -> walk_quote_arg(arg, var, level) end)
  end

  # mutare:ignore[guard_drop] equivalent — a compilable `quote`'s args are always keyword lists, so a non-list arg can't reach here (a non-list arg doesn't compile)
  defp walk_quote_arg(pairs, var, level) when is_list(pairs) do
    map_reduce(pairs, fn
      {key, value} ->
        sublevel = if block_key?(key), do: level + 1, else: level
        {value, found} = walk(value, var, sublevel)
        {{key, value}, found}

      other ->
        walk(other, var, level + 1)
    end)
  end

  # A non-keyword `quote` arg (unusual): treat wholesale as quoted data.
  # mutare:ignore[clause_drop] unreachable — a compilable `quote`'s args are always keyword lists (the is_list clause above always matches)
  defp walk_quote_arg(other, var, level), do: walk(other, var, level + 1)

  # A keyword key is a bare atom (`Code.string_to_quoted`) or `{:__block__, _, [atom]}`
  # (Sourceror); recognise a block key in either form.
  defp block_key?({:__block__, _meta, [key]}), do: block_key?(key)

  # mutare:ignore[guard_drop] equivalent — a non-atom `key in @quote_block_keys` is already `false`, identical to the `_` fallback below
  defp block_key?(key) when is_atom(key), do: key in @quote_block_keys

  # mutare:ignore[clause_drop] unreachable — keys come from compilable quote option lists, always an atom or `{:__block__, _, [atom]}`
  defp block_key?(_), do: false

  defp walk_many(list, var, level) do
    map_reduce(list, fn node -> walk(node, var, level) end)
  end

  # `Enum.map_reduce` accumulating `found?` (any element found a live `super`), where
  # `fun` returns the `{node, found?}` pair for one element.
  defp map_reduce(list, fun) do
    Enum.map_reduce(list, false, fn node, acc ->
      {node, found} = fun.(node)
      {node, acc or found}
    end)
  end
end
