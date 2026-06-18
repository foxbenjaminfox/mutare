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
  # function (it keeps the original name), and `super` is allowed inside a closure
  # there, so the dispatcher binds
  #
  #     <super_var> = fn a1, …, aN -> super(a1, …, aN) end
  #
  # and passes that closure to the base as an extra argument; each `super(args)` in
  # the lifted body is rewritten to `<super_var>.(args)`. The closure's arity is the
  # function's full formal-parameter count — `super` must be called with *exactly*
  # that arity ("super must be called with the same number of arguments as the
  # current definition"), so one fixed-arity closure forwards every legal `super`
  # call, defaults included. `Mutare.Transform` owns building the closure + threading
  # the extra arg (it shares the dispatcher/lifted-clause emission); this module owns
  # only recognising and rewriting the `super` nodes.
  #
  # **Quote is pruned.** A `super` inside `quote do … end` is quoted *data* — it
  # names whatever context the AST is later spliced into, not a live call here — so
  # it is left untouched (mirroring the in-place analyzer, which treats `quote` as
  # compile-time and never descends it). Such a body therefore reads as not using
  # `super`, lifts without a closure, and the quoted `super` rides along as-is.

  @doc """
  Whether any clause's *body* contains a rewriteable `super` call.

  The decision the dispatcher uses to know whether to build the closure at all —
  off by default, so a `super`-free group emits exactly as before. Only the body is
  inspected (head/`when`/default-value positions can't host a base-relocated
  `super`: a default rides on the dispatcher, which may call `super` directly).
  """
  @spec in_clauses?([Macro.t()]) :: boolean()
  def in_clauses?(clauses), do: Enum.any?(clauses, &body_has_super?/1)

  @doc """
  Rewrite every `super(args)` in `body` to `<super_var>.(args)`.

  Returns `{rewritten_body, found?}`; `found?` is `false` when the body had no
  `super`, so the caller can keep the extra closure parameter unused (named
  `_<super_var>`) on that base clause while still matching the shared arity.
  """
  @spec rewrite(Macro.t(), atom()) :: {Macro.t(), boolean()}
  def rewrite(body, super_var), do: walk(body, super_var)

  # A throwaway variable name for detection-only walks: the rewritten AST is
  # discarded, only `found?` is read, so the value is irrelevant — but reusing the
  # one walk keeps detection and rewriting provably in lock-step.
  @super_canary :__mutare_super_canary__

  defp body_has_super?({_vis, _meta, [_head | body]}) do
    {_ast, found} = walk(body, @super_canary)
    found
  end

  defp body_has_super?(_), do: false

  # Prune a quote: its contents are data, not a live `super` call (see moduledoc).
  defp walk({:quote, _meta, _args} = node, _var), do: {node, false}

  # A `super(args)` call: rewrite to `<var>.(args)`, still descending the args (a
  # nested `super`, or one inside an argument, is rewritten too).
  defp walk({:super, meta, args}, var) when is_list(args) do
    {args, _found} = walk_many(args, var)
    {{{:., meta, [{var, [], nil}]}, meta, args}, true}
  end

  # Any other n-ary node: descend its form (a remote-call `{:., …}` / anon-call
  # subject can be a node) and its args.
  defp walk({form, meta, args}, var) when is_list(args) do
    {form, found_form} = walk(form, var)
    {args, found_args} = walk_many(args, var)
    {{form, meta, args}, found_form or found_args}
  end

  # A 2-tuple (a keyword/map pair shape): descend both sides.
  defp walk({left, right}, var) do
    {left, found_left} = walk(left, var)
    {right, found_right} = walk(right, var)
    {{left, right}, found_left or found_right}
  end

  defp walk(list, var) when is_list(list), do: walk_many(list, var)

  # A leaf (atom form, var, literal): nothing to rewrite.
  defp walk(leaf, _var), do: {leaf, false}

  defp walk_many(list, var) do
    Enum.map_reduce(list, false, fn node, acc ->
      {node, found} = walk(node, var)
      {node, acc or found}
    end)
  end
end
