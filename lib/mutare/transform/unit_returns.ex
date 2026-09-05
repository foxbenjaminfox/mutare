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
  # attach (`Analyze.Returns`). Transform-enforced, like macro-routing `:skip`, not a mark. See
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
  #   * **Misses are the only errors, on the clauses the source shows.** A call tail
  #     (`Logger.info(x)`), a variable bound to `:ok`, a `with` whose implicit pass-through is a
  #     path — all non-unit here, even when they return unit at runtime. The pass never classifies
  #     a *visible* data-returning clause group as unit; what it cannot see is a clause a macro
  #     generates beside hand-written ones of the same signature (see "Static visibility").
  #
  # Anonymous functions are the same notion one level down (`Enum.each(xs, fn x -> …; :ok end)`):
  # a `fn` whose every clause body's leaf tails are unit gets its tails stamped too, on its own
  # (no grouping — a `fn` is self-contained).
  #
  # ## Static visibility
  #
  # A module whose body defines a function with a **dynamic name** (`def unquote(n)()`) is left
  # unclassified entirely — that clause could belong to any signature. A **spliced** head
  # (`def f(unquote_splicing(args))`) blocks its name at every arity. Both mirror the residual
  # holes `Mutare.Transform.ModulePlan` accepts for lifting. Nested module scopes are pruned at
  # the same boundaries the planner uses and classified on their own when the walk reaches them.
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

  alias Mutare.Transform.{Calls, Imports, Meta, ModulePlan}
  alias Mutare.Transform.Analyze.{Returns, Syntax}

  # Where a function definition stops belonging to the enclosing module body — the planner's set.
  @scope_boundaries [:defmodule, :defimpl, :defprotocol, :defmacro, :defmacrop]

  @unit_atoms [:ok, nil]

  @doc "Stamp every unit-returning function's (and `fn`'s) leaf return tails across the tree."
  @spec annotate(Macro.t()) :: Macro.t()
  def annotate(ast) do
    Macro.prewalk(ast, fn
      {:defmodule, meta, [head, body]} when is_list(body) ->
        {:defmodule, meta, [head, stamp_module_body(body)]}

      # `defimpl P, for: T do … end` / `defimpl P, for: T, do: …`: the `do` block is always in
      # the last argument (a standalone block keyword, or the combined `for:`/`do:` list).
      {:defimpl, meta, args} when is_list(args) and length(args) >= 2 ->
        {lead, [last]} = Enum.split(args, -1)
        {:defimpl, meta, lead ++ [stamp_module_body(last)]}

      {:fn, _meta, clauses} = node when is_list(clauses) ->
        stamp_fn(node)

      node ->
        node
    end)
  end

  # --- module bodies ----------------------------------------------------------

  # Stamp the unit signatures' clause tails inside a module's `do` block (other keys — a
  # `defimpl`'s `for:` — pass through). Two walks over the body, both pruned at nested scopes:
  # collect + classify, then stamp only the clauses of signatures that qualified.
  defp stamp_module_body(body_kw) when is_list(body_kw) do
    Enum.map(body_kw, fn
      {key, block} = pair ->
        if Syntax.do_key?(key), do: {key, stamp_defs(block)}, else: pair

      other ->
        other
    end)
  end

  defp stamp_module_body(other), do: other

  defp stamp_defs(block) do
    units = unit_signatures(block)

    if MapSet.size(units) == 0 do
      block
    else
      {stamped, nil} =
        map_reduce_defs(block, nil, fn clause, nil ->
          if signature(clause) in units, do: {stamp_clause(clause), nil}, else: {clause, nil}
        end)

      stamped
    end
  end

  # The `{name, arity}` signatures whose every clause is unit-bodied: fold each clause's verdict
  # into its group, then drop any group a static-visibility hole could reach.
  defp unit_signatures(block) do
    {_block, {groups, dynamic?, spliced}} =
      map_reduce_defs(block, {%{}, false, MapSet.new()}, fn clause, acc ->
        {clause, classify(clause, acc)}
      end)

    if dynamic? do
      MapSet.new()
    else
      for {{name, _arity} = sig, verdicts} <- groups,
          name not in spliced,
          Enum.all?(verdicts),
          into: MapSet.new(),
          do: sig
    end
  end

  defp classify({_vis, _meta, [head | rest]} = clause, {groups, dynamic?, spliced}) do
    case signature(clause) do
      nil ->
        {groups, true, spliced}

      sig ->
        spliced =
          if ModulePlan.spliced?(head), do: MapSet.put(spliced, elem(sig, 0)), else: spliced

        case rest do
          # A bodiless head (`def f(x \\ default)`) defines no return path.
          [] ->
            {groups, dynamic?, spliced}

          [body_kw] when is_list(body_kw) ->
            {add_verdict(groups, sig, unit_body?(body_kw)), dynamic?, spliced}

          _ ->
            {add_verdict(groups, sig, false), dynamic?, spliced}
        end
    end
  end

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

  # Map-reduce `fun` over every `def`/`defp` clause node directly in this module scope — nested
  # scopes (`@scope_boundaries`) are entered for depth-tracking only, never classified here (they
  # get their own pass when `annotate/1`'s walk reaches them).
  defp map_reduce_defs(block, acc, fun) do
    {block, {0, acc}} =
      Macro.traverse(
        block,
        {0, acc},
        fn
          {form, _meta, _args} = node, {depth, acc} when form in @scope_boundaries ->
            {node, {depth + 1, acc}}

          {form, _meta, [_ | _]} = node, {0, acc} when form in [:def, :defp] ->
            {node, acc} = fun.(node, acc)
            {node, {0, acc}}

          node, state ->
            {node, state}
        end,
        fn
          {form, _meta, _args} = node, {depth, acc} when form in @scope_boundaries ->
            {node, {depth - 1, acc}}

          node, state ->
            {node, state}
        end
      )

    {block, acc}
  end

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
