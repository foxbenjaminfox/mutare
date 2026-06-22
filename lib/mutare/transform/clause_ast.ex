defmodule Mutare.Transform.ClauseAST do
  @moduledoc false

  # The shared shape of a `def`/`defp` clause and the primitives that navigate it — the one
  # place the clause-shape invariant is matched, so a fix to it lands once rather than drifting
  # between `Mutare.Transform` (the emission half of lifting) and
  # `Mutare.Transform.FunctionPlan` (the discovery half), which both take clauses apart.
  #
  # A clause is `{vis, meta, [head | body]}`:
  #
  #   * `vis` is `:def`/`:defp` (or another def-like form);
  #   * `head` is the call `{name, meta, args}`, or a guarded `{:when, meta, [call | guards]}`;
  #   * `body` is `[]` (a **bodiless header** — a default-args/docs declaration) or `[body_kw]`.
  #
  # `args` is a list, or a non-list (a `nil` context) for a 0-arity head — which every reader
  # here normalises to `[]`. `\\ default` annotations are kept verbatim (this module never
  # strips them; callers that need the base arity strip their own).

  @doc "A head node → its call node, peeling any `when` guard."
  @spec head_call(Macro.t()) :: Macro.t()
  def head_call({:when, _meta, [call | _guards]}), do: call
  def head_call(call), do: call

  @doc "A clause → its head call node (peeling the clause wrapper, then any `when`)."
  @spec clause_head_call(Macro.t()) :: Macro.t()
  def clause_head_call({_vis, _meta, [head | _rest]}), do: head_call(head)

  @doc "A clause → its `when` node, or `nil` when unguarded."
  @spec clause_when(Macro.t()) :: Macro.t() | nil
  def clause_when({_vis, _meta, [{:when, _, _} = when_node | _rest]}), do: when_node
  def clause_when(_clause), do: nil

  @doc "A clause → its guard list (`[]` when unguarded)."
  @spec guards(Macro.t()) :: [Macro.t()]
  def guards({_vis, _meta, [{:when, _, [_call | guards]} | _rest]}), do: guards
  def guards(_clause), do: []

  @doc "Replace a clause's guard list (the clause must be guarded)."
  @spec put_guards(Macro.t(), [Macro.t()]) :: Macro.t()
  def put_guards({vis, meta, [{:when, when_meta, [call | _guards]} | rest]}, new_guards),
    do: {vis, meta, [{:when, when_meta, [call | new_guards]} | rest]}

  @doc """
  A clause → its head pattern args, **defaults intact** (`\\` kept), peeling any `when`;
  `[]` for a 0-arity head (whose call carries a `nil` context rather than an arg list).
  """
  @spec head_args(Macro.t()) :: [Macro.t()]
  def head_args({_vis, _meta, [head | _rest]}), do: call_args(head_call(head))
  def head_args(_clause), do: []

  defp call_args({_name, _meta, args}) when is_list(args), do: args
  defp call_args(_call), do: []

  @doc "Replace a clause's head pattern args with `new_args`, restoring any `when` guard."
  @spec put_head_args(Macro.t(), [Macro.t()]) :: Macro.t()
  def put_head_args({vis, meta, [head | rest]}, new_args),
    do: {vis, meta, [put_call_args(head, new_args) | rest]}

  @doc "Replace a call (or `when`) node's args with `new_args`, restoring any `when` guard."
  @spec put_call_args(Macro.t(), [Macro.t()]) :: Macro.t()
  def put_call_args({:when, when_meta, [call | guards]}, new_args),
    do: {:when, when_meta, [put_call_args(call, new_args) | guards]}

  def put_call_args({name, meta, _args}, new_args), do: {name, meta, new_args}

  @doc """
  Whether a clause carries a body (`[head, body | _]`) — i.e. it is a real, droppable/liftable
  clause rather than a bodiless header.
  """
  @spec body_bearing?(Macro.t()) :: boolean()
  def body_bearing?({_vis, _meta, [_head, _body | _]}), do: true
  def body_bearing?(_clause), do: false

  @doc """
  The complement of `body_bearing?/1`: a bodiless function header (`def f(a, b \\ 1)` with no
  `do`) — a default-args/docs declaration, not an implementation. Its only element after the
  visibility/meta is the head.
  """
  @spec bodiless_header?(Macro.t()) :: boolean()
  def bodiless_header?({_vis, _meta, [_head]}), do: true
  def bodiless_header?(_clause), do: false

  @doc """
  Strip a clause's whole `when`, leaving the head **exactly as written** (and the body) — the
  guard-drop mutant clause. Only called on a guarded clause.

  A head variable the guard read but the body does not (`def f(x) when is_binary(x), do: :ok`)
  becomes an unused variable once the guard is gone, which warns; that warning is harmless and
  is left alone. We deliberately do *not* rename it to `_`: a macro in the body can read a
  bound variable by name (`binding/0,1`, or any custom macro that captures the caller's
  bindings), undetectable from the source, so renaming could silently change behaviour. Keep
  the name, always.
  """
  @spec drop_clause_guard(Macro.t()) :: Macro.t()
  def drop_clause_guard({vis, meta, [{:when, _wm, [call | _guards]} | rest]}),
    do: {vis, meta, [call | rest]}
end
