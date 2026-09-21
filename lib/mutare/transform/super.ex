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
  # `super` now. Which parts of a quote run is `Mutare.Transform.QuoteStructure`'s reading,
  # shared with the analyzer: those live `super`s are detected and rewritten, while a plain
  # quoted one, a nested quote, and a body under `unquote: false` are left as data.

  alias Mutare.Transform.{QuoteStructure, Resolve}

  @doc """
  Whether any clause's *body* contains a rewriteable `super` call or capture.

  Whether the dispatcher needs to build the closure —
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
  def rewrite(body, super_var), do: walk(body, super_var, 0, %{})

  # A throwaway variable name for detection-only walks: the rewritten AST is
  # discarded, only `found?` is read, so the value is irrelevant — but reusing the
  # one walk keeps detection and rewriting provably in lock-step.
  @super_canary :__mutare_super_canary__

  defp body_has_super?({_vis, _meta, [_head | body]}) do
    {_ast, found} = walk(body, @super_canary, 0, %{})
    found
  end

  # mutare:ignore[boolean, clause_drop] unreachable — `in_clauses?` only maps over well-formed def/defp clauses, matched by the clause above, so neither the value nor the whole fallback is ever observed
  defp body_has_super?(_), do: false

  # `level` is 0 in live code, where a `super` runs and is rewritten, and 1 in quoted data,
  # where it is left alone. `Mutare.Transform.QuoteStructure` says what crosses: a live
  # quote's option values (notably `bind_quoted:`) and an escape's argument are live, so a
  # `super` in `unquote(super(x))` or `bind_quoted: [x: super(x)]` is rewritten; a nested
  # quote, or a body whose unquoting is disabled, is data throughout.

  defp walk({_form, meta, _args} = node, var, level, context) when is_list(meta),
    do: do_walk(node, var, level, Resolve.context(node, context))

  defp walk(node, var, level, context), do: do_walk(node, var, level, context)

  # Preserved arguments have no inner resolution stamps. Thread explicit lexical
  # directives across a live block, keeping its environment local to that block.
  defp do_walk({:__block__, meta, statements}, var, 0, context) when is_list(statements) do
    {statements, {found, _context}} =
      Enum.map_reduce(statements, {false, context}, fn statement, {found, context} ->
        {rewritten, found_here} = walk(statement, var, 0, context)
        {rewritten, {found or found_here, Resolve.advance_context(statement, context)}}
      end)

    {{:__block__, meta, statements}, found}
  end

  defp do_walk({:quote, meta, args}, var, 0, context) when is_list(args) do
    {parts, rebuild} = QuoteStructure.parts(args)

    {values, found} =
      map_reduce(parts, fn
        {value, :live} -> walk(value, var, 0, context)
        {value, :quoted} -> walk(value, var, 1, context)
        {value, :inert} -> {value, false}
      end)

    {{:quote, meta, rebuild.(values)}, found}
  end

  defp do_walk({form, meta, args} = node, var, 1, context) when is_list(args) do
    case QuoteStructure.quoted(node) do
      {:escape, arg, rebuild} ->
        {arg, found} = walk(arg, var, 0, context)
        {rebuild.(arg), found}

      {:options, options, rebuild} ->
        {options, found} = walk(options, var, 1, context)
        {rebuild.(options), found}

      :inert ->
        {node, false}

      :data ->
        {form, found_form} = walk(form, var, 1, context)
        {args, found_args} = walk_many(args, var, 1, context)
        {{form, meta, args}, found_form or found_args}
    end
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
  defp do_walk({:&, _meta, [{:/, _slash, [{:super, _smeta, ctx}, _arity]}]}, var, 0, _context)
       when is_atom(ctx) do
    {{var, [], nil}, true}
  end

  # Raw/skipped arguments preserve written pipes, including a bare `super` stage. Keep
  # the pipe intact and make its stage an anonymous call; Kernel supplies the piped argument.
  # Restrict the atom-context shape to a stage, so a bare identifier elsewhere stays data.
  # The boundary's retained environment identifies the operator without routing its contents.
  defp do_walk({:|>, meta, [left, right]} = pipe, var, 0, context) do
    {left, found_left} = walk(left, var, 0, context)

    {right, found_right} =
      if Resolve.kernel_pipe?(pipe, context) do
        walk_stage(right, var, context)
      else
        walk(right, var, 0, context)
      end

    {{:|>, meta, [left, right]}, found_left or found_right}
  end

  # A live `super(args)` call (level 0): rewrite to `<var>.(args)`, still descending the
  # args (a nested `super`, or one inside an argument, is rewritten too). Covers a
  # `super` *called* inside a capture too (`&super(&1)` → `&<var>.(&1)`, via the n-ary
  # descent below reaching this clause), distinct from the `&super/arity` shorthand
  # above. A quoted-data `super` (level > 0) falls to the n-ary clause below instead —
  # left as-is, but still descended so a nested `unquote` within it is reached.
  # mutare:ignore[guard_drop] equivalent — calls have list args; bare pipe stages and captures are handled above
  defp do_walk({:super, meta, args}, var, 0, context) when is_list(args) do
    {args, _found} = walk_many(args, var, 0, context)
    {{{:., meta, [{var, [], nil}]}, meta, args}, true}
  end

  # Any other n-ary node: descend its form (a remote-call `{:., …}` / anon-call
  # subject can be a node) and its args, at the same level.
  defp do_walk({form, meta, args}, var, level, context) when is_list(args) do
    {form, found_form} = walk(form, var, level, context)
    {args, found_args} = walk_many(args, var, level, context)
    {{form, meta, args}, found_form or found_args}
  end

  # A 2-tuple (a keyword/map pair shape): descend both sides.
  defp do_walk({left, right}, var, level, context) do
    {left, found_left} = walk(left, var, level, context)
    {right, found_right} = walk(right, var, level, context)
    {{left, right}, found_left or found_right}
  end

  defp do_walk(list, var, level, context) when is_list(list),
    do: walk_many(list, var, level, context)

  # A leaf (atom form, var, literal): nothing to rewrite.
  defp do_walk(leaf, _var, _level, _context), do: {leaf, false}

  # Kernel flattens the entire RHS with Macro.unpipe/1: both sides of a grouped
  # pipeline are stages, including its leftmost bare `super`. Traverse that grammar
  # without changing the written grouping or treating the outer input as a stage.
  defp walk_stage({:|>, meta, [left, right]}, var, context) do
    {left, found_left} = walk_stage(left, var, context)
    {right, found_right} = walk_stage(right, var, context)
    {{:|>, meta, [left, right]}, found_left or found_right}
  end

  defp walk_stage({:super, meta, ctx}, var, context) when is_atom(ctx),
    do: walk({:super, meta, []}, var, 0, context)

  defp walk_stage(node, var, context), do: walk(node, var, 0, context)

  defp walk_many(list, var, level, context) do
    map_reduce(list, fn node -> walk(node, var, level, context) end)
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
