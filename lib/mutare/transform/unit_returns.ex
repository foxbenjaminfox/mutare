defmodule Mutare.Transform.UnitReturns do
  @moduledoc false
  # The **unit-return** classification pre-pass. A function whose every return path, across all
  # its clauses, is literally `:ok` or `nil` returns *no data* — Elixir has no unit type, and
  # `:ok` (or `nil`) at the tail of a side-effecting function is its conventional spelling. Such a
  # tail is not a value position: replacing it (`ReturnValue`'s `nil`/`:mutare`, `ConventionAtom`'s
  # `:ok → :error`) mints mutants that survive whenever the caller discards the value — the norm
  # for a side-effect helper — and whose only kill is a test asserting a static fact
  # (`:ok = notify(x)`). So this pass finds those tails and stamps them (`Meta.put_unit_tail/1`),
  # and both consumers decline: the in-place offer (`Analyze.Attach.offer/4`) and the return-tail
  # attach (`Analyze.Returns`). Transform-enforced, like call-routing `:skip`, not a mark. See
  # NOTES "Unit-returning functions are not return-value positions".
  #
  # The criterion is deliberately narrow, and one-sided in its errors:
  #
  #   * **`:ok`/`nil` literals only.** A constant that is *data* — `:pending`, `3`, `{:ok, :done}` —
  #     stays mutated: its value flows into state and behaviour, and the mutant asks whether any
  #     test observes it. `:ok` alone is the "no value" convention; `nil` already gets the same
  #     treatment from every value family, so a mixed `:ok`/`nil` body (an else-less `if` around
  #     a side effect returns `:ok | nil`) counts too.
  #   * **All paths, all clauses.** One `:ok` path beside a `{:error, _}` path is not unit — that
  #     `:ok` carries the success bit, and mutating it is how the tool finds an untested happy
  #     path. Clauses are grouped by `{name, arity}` across the module body (a head split across
  #     an `if`/`for` wrapper counts), so a sibling clause returning data disqualifies the group.
  #     A tail that never *returns* — `raise`/`reraise`/`throw`/`exit`, or their `:erlang`
  #     forms — is not a return path, so an `:ok`-or-raise function (`validate!`-style) is unit;
  #     the raising tail itself is not stamped and keeps its own return mutants (`raise … → nil`
  #     asks whether the error path is tested).
  #   * **Not a behaviour callback.** The premise — the caller discards a lone `:ok` — fails
  #     when the caller is a behaviour's runtime, which the source never shows: `Oban.Worker`'s
  #     `perform/1` returning `:ok` is one of six contract outcomes the runtime inspects, and a
  #     `GenServer.terminate/2` is read by nothing, yet the tool can't tell the two apart from
  #     the body. So a function whose `{name, arity}` is a callback of one of the module's
  #     declared behaviours (`Mutare.Transform.Behaviours`' stamp, read through
  #     `behaviour_info(:callbacks)` when the behaviour is loadable — stdlib always, a companion's
  #     library via `required_modules/0`), or whose first clause carries an `@impl` other than
  #     `@impl false` (the syntactic signal, covering an unloadable behaviour), is never unit.
  #     Conservative in the pass's own direction: a callback that really is unit regains its
  #     low-value `:ok → :error` survivor; a callback whose `:ok` is its contract outcome keeps
  #     the mutant that asks whether that outcome is asserted.
  #   * **Misses are the only errors, on the clauses the source shows.** A call tail
  #     (`Logger.info(x)`), a variable bound to `:ok`, a `with` whose implicit pass-through is a
  #     path, a displaced `if` that is somebody else's macro — all non-unit here, even when they
  #     return unit at runtime. The pass never classifies a *visible* data-returning clause group
  #     as unit; what it cannot see is a clause a macro generates beside hand-written ones of the
  #     same signature (see "Static visibility").
  #   * **Only what the caller receives.** An `else` on a `try` (or on a `def`, the implicit one)
  #     *consumes* the `do` value: the clauses match on it and their own tails are the return.
  #     So a `do` tail under an `else` is an ordinary value position and stays mutable — swapping
  #     it picks a different clause, a real behaviour change under an unchanged unit return.
  #
  # Anonymous functions are the same notion one level down (`Enum.each(xs, fn x -> …; :ok end)`):
  # a `fn` whose every clause body's leaf tails are unit gets its tails stamped too, on its own
  # (no grouping — a `fn` is self-contained).
  #
  # ## Static visibility
  #
  # A module whose body defines a function with a **dynamic name** — `def unquote(n)()`, or the
  # whole-head `def unquote(head)` — is left unclassified entirely: that clause could belong to
  # any signature. A **spliced** head (`def f(unquote_splicing(args))`) blocks its name at every
  # arity. A **`defdelegate`** blocks the signature it names: the delegate mints a sibling `def`
  # clause nothing static can see, and it can return anything — "one explicit clause, delegate
  # the rest" is exactly the shape where a visible `:ok` carries a success bit. A delegate is
  # read by the same two planner helpers as a `def` (`ModulePlan.name_arity/1` + `spliced?/1`),
  # so a dynamic delegate head forfeits the module just as a dynamic `def` head does.
  # All of it mirrors the residual holes `Mutare.Transform.ModulePlan` accepts for lifting. Nested
  # module scopes are pruned at the same boundaries the planner uses (`scope_boundary?/1`, which
  # reads the boundary through the resolver — a *displaced* `defmodule/2` is somebody else's
  # macro and may splice its block into the caller, so its definitions are siblings) and
  # classified on their own when the walk reaches them. A definition nested in a *definition* is
  # pruned the same way only when it is **quoted**: that is data for elsewhere, since a generated
  # `def` inside a function body is illegal. Live, it runs during the outer definition's
  # expansion and really does add a clause here, so it blocks.
  #
  # A **qualified** definition (`Kernel.def f(x)`, or an aliased `K.def` — a definition macro may
  # be invoked qualified) blocks too: the clause it mints is as real as a bare one, and read by
  # name alone the node is just a call. A definition inside a **`quote`** is visible but
  # unreadable, so it blocks like a `defdelegate`: `Module.eval_quoted(__MODULE__, …)` really can inject one beside the visible
  # clauses (the metaprogramming route the planner also refuses to prune), yet `Resolve` stamps
  # nothing in there — quoted code resolves where it is *invoked* — so a bare `raise("x")` in that
  # body may be a local `raise/1` that returns, and an `if` may be anyone's. For the same reason
  # `annotate/1` classifies nothing inside a `quote` at all. (Belt and braces on that half: the
  # analyzer already offers no position inside a `quote`, so no mutant hangs on it today.)
  # Clauses defined under a module-level `if`/`for` are ordinary (only scope boundaries prune the
  # walk), so a conditional definition joins its siblings' group. The residual hole — the
  # planner's too — is a clause a **macro generates** next to visible clauses of the same
  # signature (`defhandler :foo` emitting `def handle(:foo, x), do: {:reply, …}` beside a
  # hand-written `def handle(_, _), do: :ok`): invisible here, so the visible `:ok` fallback
  # reads as unit. Narrow in practice: `use`-injected defaults are `defoverridable`, so a visible
  # clause *replaces* rather than joins them, and non-overridable generated clauses beside
  # hand-written ones of one signature draw the compiler's "clauses not grouped" warning.
  #
  # Runs after `Resolve` (the stamp is meta-only, so `NodeIds` and every resolution stamp survive)
  # and before `Analyze`. The single-tree walk is `Analyze.Returns`' own leaf-tail descent in
  # classification mode, so what counts as a return path here is what the return mutator sees —
  # plus the conservative fallbacks that mode adds.

  alias Mutare.Transform.{Behaviours, Calls, Imports, Meta, ModulePlan}
  alias Mutare.Transform.Analyze.{Returns, Syntax}

  # The statements that define a function of the enclosing module. `defdelegate` is here for
  # classification only — it names a signature but hides its body, so it can never be *stamped*
  # (`signature/1` is `nil` for one, and the stamping pass keys on that).
  @definition_forms [:def, :defp, :defdelegate]

  # Macro definitions: pruned like a definition body rather than like another module's scope
  # (`nesting_kind/2`).
  @macro_forms [:defmacro, :defmacrop]

  # Nested scopes are pruned at `ModulePlan.scope_boundary?/1` — the planner's set, read through
  # the resolver so a *displaced* `defmodule/2` (somebody else's macro, which may splice its
  # block into the caller) is not mistaken for one.

  @unit_atoms [:ok, nil]

  @doc "Stamp every unit-returning function's (and `fn`'s) leaf return tails across the tree."
  @spec annotate(Macro.t()) :: Macro.t()
  def annotate(ast) do
    {ast, 0} = Macro.traverse(ast, 0, &enter/2, &leave/2)
    ast
  end

  # Nothing *inside* a `quote` is classified. `Resolve` stamps none of it — quoted code resolves
  # where the macro is invoked, not here — so its calls cannot be read: a bare `raise("x")` there
  # may be a local `raise/1` that returns, and an `if` there may be anyone's. Heads stay visible
  # to `stamp_defs/1`, which blocks their signatures; only the bodies are off limits.
  defp enter({:quote, _meta, _args} = node, depth), do: {node, depth + 1}
  defp enter(node, 0), do: {stamp_scope(node), 0}
  defp enter(node, depth), do: {node, depth}

  defp leave({:quote, _meta, _args} = node, depth), do: {node, depth - 1}
  defp leave(node, depth), do: {node, depth}

  defp stamp_scope({:defmodule, meta, [head, body]} = node) when is_list(body) do
    if ModulePlan.scope_boundary?(node),
      do: {:defmodule, meta, [head, stamp_module_body(body, callback_signatures(meta))]},
      else: node
  end

  # `defimpl P, for: T do … end` / `defimpl P, for: T, do: …`: the `do` block is always in
  # the last argument (a standalone block keyword, or the combined `for:`/`do:` list). A
  # `defimpl` carries no behaviour stamp (`Behaviours` doesn't stamp one), so only an `@impl`
  # can exempt a function there.
  defp stamp_scope({:defimpl, meta, args} = node) when is_list(args) and length(args) >= 2 do
    if ModulePlan.scope_boundary?(node) do
      {lead, [last]} = Enum.split(args, -1)
      {:defimpl, meta, lead ++ [stamp_module_body(last, MapSet.new())]}
    else
      node
    end
  end

  defp stamp_scope({:fn, _meta, clauses} = node) when is_list(clauses), do: stamp_fn(node)
  defp stamp_scope(node), do: node

  # --- module bodies ----------------------------------------------------------

  # Stamp the unit signatures' clause tails inside a module's `do` block (other keys — a
  # `defimpl`'s `for:` — pass through). Two walks over the body, both pruned at nested scopes:
  # collect + classify, then stamp only the clauses of signatures that qualified. `callbacks`
  # is the module's behaviour-callback signature set: never unit, whatever the body says.
  defp stamp_module_body(body_kw, callbacks) when is_list(body_kw) do
    Enum.map(body_kw, fn
      {key, block} = pair ->
        if Syntax.do_key?(key), do: {key, stamp_defs(block, callbacks)}, else: pair

      other ->
        other
    end)
  end

  defp stamp_module_body(other, _callbacks), do: other

  defp stamp_defs(block, callbacks) do
    units = unit_signatures(block, MapSet.union(callbacks, impl_signatures(block)))

    if MapSet.size(units) == 0 do
      block
    else
      {stamped, nil} =
        map_reduce_defs(block, nil, fn clause, _form, quoted?, nil ->
          if not quoted? and signature(clause) in units,
            do: {stamp_clause(clause), nil},
            else: {clause, nil}
        end)

      stamped
    end
  end

  # The `{name, arity}` signatures whose every clause is unit-bodied: fold each definition's
  # verdict into its group, then drop any group a static-visibility hole could reach, and any
  # that is a behaviour callback (`callbacks` — declared or `@impl`-marked; its return is the
  # contract's, not the body's). `blocked`
  # is the planner's `{exact, wildcard}` pair — a `defdelegate` blocks the signature it names, a
  # spliced head blocks its whole name (its arity is unknowable) — while a head whose *name* is
  # unknowable sets `dynamic?` and forfeits the module.
  defp unit_signatures(block, callbacks) do
    {_block, {groups, dynamic?, {exact, wildcard}}} =
      map_reduce_defs(
        block,
        {%{}, false, {MapSet.new(), MapSet.new()}},
        fn clause, form, quoted?, acc -> {clause, classify(clause, form, quoted?, acc)} end
      )

    if dynamic? do
      MapSet.new()
    else
      for {{name, _arity} = sig, verdicts} <- groups,
          name not in wildcard,
          sig not in exact,
          sig not in callbacks,
          Enum.all?(verdicts),
          into: MapSet.new(),
          do: sig
    end
  end

  # --- behaviour callbacks ----------------------------------------------------

  # The `{name, arity}` callbacks of every behaviour stamped on a module node
  # (`Behaviours.behaviours/1`, direct `@behaviour` plus `use`-injected), read off each
  # behaviour's `behaviour_info/1` when it is loadable in this process. An unloadable behaviour
  # contributes nothing here — its callbacks are reachable only through `@impl`
  # (`impl_signatures/1`).
  defp callback_signatures(meta) do
    meta
    |> Behaviours.behaviours()
    |> Enum.flat_map(&behaviour_callbacks/1)
    |> MapSet.new()
  end

  defp behaviour_callbacks(mod) when is_atom(mod) do
    if Code.ensure_loaded?(mod) and function_exported?(mod, :behaviour_info, 1),
      do: mod.behaviour_info(:callbacks),
      else: []
  end

  defp behaviour_callbacks(_other), do: []

  # The signatures of the definitions an `@impl` statement precedes, among a module body's
  # direct statements — `@impl true` or `@impl Behaviour`, not `@impl false`, which is the
  # author saying the function is *not* a callback. The attribute marks a signature's first
  # clause by convention; blocking the signature covers every clause of the group.
  defp impl_signatures({:__block__, _meta, stmts}) when is_list(stmts) do
    stmts
    |> Enum.chunk_every(2, 1, :discard)
    |> Enum.flat_map(fn
      [{:@, _ameta, [{:impl, _imeta, [value]}]}, next] ->
        if impl_false?(value), do: [], else: List.wrap(signature(next))

      _pair ->
        []
    end)
    |> MapSet.new()
  end

  defp impl_signatures(_single), do: MapSet.new()

  defp impl_false?({:__block__, _meta, [false]}), do: true
  defp impl_false?(false), do: true
  defp impl_false?(_value), do: false

  # Two kinds of definition whose *head* is visible but whose body this pass cannot read, so the
  # signature is unclassifiable rather than unit: a `defdelegate` (the body lives in another
  # module and can return anything — "one explicit clause, delegate the rest" is exactly where a
  # visible `:ok` carries a success bit), and anything inside a `quote` (unresolved, so its calls
  # can't be read).
  defp classify({_form, _meta, [funs | _opts]}, :defdelegate, _quoted?, acc),
    do: block_heads(ModulePlan.delegate_heads(funs), acc)

  # A **qualified** definition (`Kernel.def f(x)`, or an aliased `K.def`): a definition macro may
  # be invoked qualified, and the clause it mints is as real as a bare one. Block rather than read
  # a body reached through so unusual a spelling.
  defp classify({{:., _, _}, _meta, [head | _rest]}, _form, _quoted?, acc),
    do: block_heads([head], acc)

  defp classify({_vis, _meta, [head | _rest]}, _form, true, acc), do: block_heads([head], acc)

  defp classify({_vis, _meta, [head | rest]} = clause, _form, false, {groups, dynamic?, blocked}) do
    case signature(clause) do
      nil ->
        {groups, true, blocked}

      sig ->
        blocked =
          if ModulePlan.spliced?(head), do: block_name(blocked, elem(sig, 0)), else: blocked

        case rest do
          # A bodiless head (`def f(x \\ default)`) defines no return path.
          [] ->
            {groups, dynamic?, blocked}

          [body_kw] when is_list(body_kw) ->
            {add_verdict(groups, sig, unit_body?(body_kw)), dynamic?, blocked}

          _ ->
            {add_verdict(groups, sig, false), dynamic?, blocked}
        end
    end
  end

  # Block every signature these heads name; a head whose *name* is unknowable forfeits the module,
  # as a dynamic `def` head does.
  defp block_heads(heads, acc) do
    Enum.reduce(heads, acc, fn head, {groups, dynamic?, blocked} ->
      case ModulePlan.name_arity(head) do
        :error ->
          {groups, true, blocked}

        {name, _arity} = sig ->
          if ModulePlan.spliced?(head),
            do: {groups, dynamic?, block_name(blocked, name)},
            else: {groups, dynamic?, block_signature(blocked, sig)}
      end
    end)
  end

  defp block_name({exact, wildcard}, name), do: {exact, MapSet.put(wildcard, name)}
  defp block_signature({exact, wildcard}, sig), do: {MapSet.put(exact, sig), wildcard}

  defp add_verdict(groups, sig, verdict),
    do: Map.update(groups, sig, [verdict], &[verdict | &1])

  # `{name, arity}` of a `def`/`defp` clause, or `nil` for a dynamic head. Visibility is dropped:
  # the classification is about what a function returns, not who may call it.
  defp signature(clause) do
    case ModulePlan.clause_signature(clause) do
      {_vis, name, arity} -> {name, arity}
      nil -> nil
    end
  end

  # Whether every leaf return tail of one clause body is a unit literal or never returns.
  defp unit_body?(body_kw) do
    {_kw, all?} =
      Returns.map_reduce_clause_returns(body_kw, true, fn leaf, all? ->
        {leaf, all? and (unit_leaf?(leaf) or non_returning?(leaf))}
      end)

    all?
  end

  # Stamp the unit leaves only — a non-returning tail stays an ordinary return position.
  defp stamp_clause({vis, meta, [head, body_kw]}) when is_list(body_kw) do
    {stamped, nil} =
      Returns.map_reduce_clause_returns(body_kw, nil, fn leaf, nil -> {stamp_leaf(leaf), nil} end)

    {vis, meta, [head, stamped]}
  end

  # A bodiless head (`def f(x \\ 1)`) shares a unit signature but has no tails to stamp.
  defp stamp_clause(clause), do: clause

  # Map-reduce `fun.(definition, quoted?, acc)` over every definition node
  # (`@definition_forms`) directly in this module scope. Nested scopes (`@scope_boundaries`) are
  # entered for depth-tracking only, never visited here — another module's, or a definition
  # inside a definition, which can only be data for elsewhere. A `quote` is *not* a boundary:
  # `Module.eval_quoted(__MODULE__, …)` really does inject its defs here (the one route the
  # planner also refuses to prune), so their heads must be seen — but `quoted?` tells the caller
  # their bodies carry no resolution and must not be read.
  defp definition_args?({_form, _meta, args}), do: match?([_ | _], args)
  defp definition_args?(_node), do: false

  defp map_reduce_defs(block, acc, fun) do
    {block, {0, 0, 0, acc}} =
      Macro.traverse(block, {0, 0, 0, acc}, &enter_definition(&1, &2, fun), &leave_definition/2)

    {block, acc}
  end

  # Three counters, because the three kinds of nesting mean different things:
  #
  #   * `scope` — inside another module's body (`ModulePlan.scope_boundary?/1`): none of it is
  #     this module's, so it is not visited at all (it gets its own pass);
  #   * `nesting` — inside a definition. Quoted, that is data for elsewhere (a `def` generated
  #     inside a function body is illegal, so it can only be eval'd into another module) and is
  #     likewise not visited. *Un*quoted it is live — `def g, do: unquote((def f(:bad), …; 1))`
  #     runs during expansion and really does add a clause here — so it blocks;
  #   * `quoted` — inside a `quote`, where `Resolve` stamped nothing, so a body is unreadable
  #     and only the head can be trusted: blocks.
  defp enter_definition({:quote, _meta, _args} = node, {scope, nesting, quoted, acc}, _fun),
    do: {node, {scope, nesting, quoted + 1, acc}}

  defp enter_definition(node, {scope, nesting, quoted, acc} = state, fun) do
    form = ModulePlan.definition_form(node)

    case nesting_kind(form, node) do
      :definition ->
        {node, acc} =
          if scope > 0 or (nesting > 0 and quoted > 0),
            do: {node, acc},
            else: fun.(node, form, nesting > 0 or quoted > 0, acc)

        {node, {scope, nesting + 1, quoted, acc}}

      :macro ->
        {node, {scope, nesting + 1, quoted, acc}}

      :scope ->
        {node, {scope + 1, nesting, quoted, acc}}

      nil ->
        {node, state}
    end
  end

  defp leave_definition({:quote, _meta, _args} = node, {scope, nesting, quoted, acc}),
    do: {node, {scope, nesting, quoted - 1, acc}}

  defp leave_definition(node, {scope, nesting, quoted, acc} = state) do
    case nesting_kind(ModulePlan.definition_form(node), node) do
      nil -> {node, state}
      :scope -> {node, {scope - 1, nesting, quoted, acc}}
      _definition_or_macro -> {node, {scope, nesting - 1, quoted, acc}}
    end
  end

  # How a node nests the walk. A **macro** definition counts as a definition body, not as another
  # module's scope: its `quote` blocks are data for wherever the macro is invoked, but anything
  # *outside* them runs while this module is compiled, so `defmacro g, do: unquote((def f(:bad),
  # …))` really does add a clause here. (NOTES "Metaprogramming-augmented clauses" states the
  # invocation-only rule the planner prunes on; a definition-time `unquote` is its exception.)
  defp nesting_kind(form, node) do
    cond do
      definition?(form, node) -> :definition
      not ModulePlan.scope_boundary?(node) -> nil
      form in @macro_forms -> :macro
      true -> :scope
    end
  end

  defp definition?(form, node), do: form in @definition_forms and definition_args?(node)

  # --- anonymous functions ----------------------------------------------------

  defp stamp_fn(node) do
    {_node, all?} =
      Returns.map_reduce_fn_returns(node, true, fn leaf, all? ->
        {leaf, all? and (unit_leaf?(leaf) or non_returning?(leaf))}
      end)

    if all? do
      {stamped, nil} =
        Returns.map_reduce_fn_returns(node, nil, fn leaf, nil -> {stamp_leaf(leaf), nil} end)

      stamped
    else
      node
    end
  end

  # --- leaves -----------------------------------------------------------------

  # A leaf return tail that is literally `:ok` or `nil` — Sourceror wraps every literal in a
  # single-child `:__block__` (parentheses add no further nesting); a bare `nil` can't be
  # stamped, but nothing mutates it either.
  defp unit_leaf?({:__block__, _meta, [atom]}) when atom in @unit_atoms, do: true
  defp unit_leaf?(nil), do: true
  defp unit_leaf?(_leaf), do: false

  defp stamp_leaf(leaf), do: if(unit_leaf?(leaf), do: Meta.put_unit_tail(leaf), else: leaf)

  # A tail that never returns to the caller, so it is no return path: `Kernel.raise/1,2`,
  # `reraise/2,3`, `throw/1`, `exit/1` — bare (auto-imported, neither displaced by
  # `import Kernel, except:` nor shadowed by another import, which `Imports` stamps) or written
  # `Kernel.`-qualified — and the Erlang primitives underneath (`:erlang.error/1,2,3`,
  # `:erlang.throw/1`, `:erlang.exit/1`; not `exit/2`, which signals another process and returns).
  @kernel_non_returning %{raise: [1, 2], reraise: [2, 3], throw: [1], exit: [1]}
  @erlang_non_returning %{error: [1, 2, 3], throw: [1], exit: [1]}
  @kernel_key Calls.module_key(Kernel)

  defp non_returning?({fun, meta, args} = node)
       when is_map_key(@kernel_non_returning, fun) and is_list(args) and is_list(meta) do
    case Calls.resolved_call(node) do
      nil ->
        length(args) in Map.fetch!(@kernel_non_returning, fun) and
          not Imports.kernel_displaced?(meta)

      resolved ->
        resolved_non_returning?(resolved)
    end
  end

  defp non_returning?(node), do: resolved_non_returning?(Calls.resolved_call(node))

  defp resolved_non_returning?({@kernel_key, fun, args, _rebuild}),
    do: length(args) in Map.get(@kernel_non_returning, fun, [])

  defp resolved_non_returning?({:erlang, fun, args, _rebuild}),
    do: length(args) in Map.get(@erlang_non_returning, fun, [])

  defp resolved_non_returning?(_other), do: false
end
