defmodule Mutare.Transform.Analyze.Conditions do
  @moduledoc false

  # Condition analysis for `if`/`unless`/`cond`: the binding-ancestor prune that keeps an
  # in-place selector from trapping an escaping condition binding, the IfCondition decision
  # attach, and the `if`/`unless` *hoisting* path that lifts a spine binding out so a
  # binding-free condition can still carry the decision mutant. Split out of
  # `Mutare.Transform.Analyze`: it builds condition candidates the descent hands off to. The
  # `cond` path re-enters the walk through the **injected `descent`** (the
  # `Mutare.Transform.Analyze` module, passed in as the first argument — `descent.annotate/2`
  # for the `:runtime` walk, `descent.descend/3` for an arbitrary liveness) rather than naming
  # it statically; the `if`/`unless` helpers (`finish_condition/3`, `hoist_if?/2`, `hoist_if/6`)
  # need no descent, since they only post-process an already-analyzed condition.
  #
  # Entry points the descent calls (`Mutare.Transform.Analyze`):
  #   * cond          → `cond_blocks/4` (routes each clause condition → `analyze_condition/3`)
  #   * if/unless     → `hoist_if?/2` + `hoist_if/6` (hoistable) or `finish_condition/3` (plain)

  alias Mutare.AST
  alias Mutare.Mutator.Dispatch
  alias Mutare.Mutator.Spec
  alias Mutare.Transform.{Candidate, Meta, Names}
  alias Mutare.Transform.Analyze.Attach

  # Analyze a `cond` clause *condition*: the generic runtime walk, plus the IfCondition
  # `true`/`false` pair — but with one wrinkle the descent can't see. A binding made
  # *inside* the condition (`(name = f()) != nil`, `lookup(x = key())`) **escapes** into
  # the clause body (`if`/`cond` conditions leak their bindings), where a later
  # expression reads it. The in-place selector that wraps a mutated node is a `case`,
  # which would scope that binding to a branch — so the body's reference to it becomes
  # unbound: a hard compile error, *independent of the active mutant* (every branch,
  # including the unmutated catch-all, binds inside the `case`).
  #
  # So `finish_condition/3` runs `prune_binding_ancestors/1`, stripping the in-place
  # candidates from every node that is an *ancestor* of an escaping binding — exactly
  # the nodes whose selector would trap it — while a sibling sub-expression with no
  # binding under it still mutates. And IfCondition (which wraps the *whole* condition)
  # is skipped whenever any binding escapes within it. (IfCondition already declines a
  # *top-level* `=`; this covers a binding nested under an operator/call, where
  # Conditional/Relational/IfCondition would otherwise wrap and trap it.)
  #
  # `cond` can only prune — its clauses are evaluated in order with short-circuit, so a
  # clause's binding can't be hoisted out without changing when it runs. `if`/`unless`
  # *can* hoist (a single unconditional condition); that richer path lives in the
  # if/unless clause above (`hoist_if?/2` + `hoist_if/6`).
  def analyze_condition(descent, condition, mutators) do
    analyzed = descent.annotate(condition, mutators)
    finish_condition(analyzed, condition, mutators)
  end

  # The short-circuit operators whose right operand is evaluated *conditionally* (so a
  # binding there is off-spine), and the nested-branch forms whose internals are also
  # conditional. Binding-isolating forms (`@binding_isolating_forms`, below) are handled
  # separately — their bindings never escape at all.
  @short_circuit_ops [:and, :or, :&&, :||]
  @branch_forms [:if, :unless, :cond, :case, :receive]

  # Forms that isolate the bindings made within them — a `=` inside a closure, a
  # comprehension, a `try`, or a `quote` does not reach the enclosing clause body, so
  # it taints nothing and its (already correctly-analyzed) internals are left intact.
  # Everything else (operators, calls, `case`/`cond`/`if`, `&&`/`||`, blocks) leaks
  # bindings outward, so the taint propagates through it.
  @binding_isolating_forms [:fn, :for, :with, :try, :quote]

  # The post-analysis step shared by `cond` and the *plain* (non-hoisted) `if`/`unless`
  # path: prune the binding-ancestors; if no binding escapes, additionally offer the
  # IfCondition decision pair on the whole condition.
  def finish_condition(analyzed, raw_condition, mutators) do
    case prune_binding_ancestors(analyzed) do
      {pruned, true} -> pruned
      {_pruned, false} -> attach_if_condition(analyzed, raw_condition, mutators)
    end
  end

  # === cond ==================================================================
  #
  # The descent hands the whole `cond`'s block list here (the `:cond` clause in
  # `Mutare.Transform.Analyze`). A `cond` clause's *left* is a runtime condition, not a
  # pattern, so each is routed through `analyze_condition/3` (runtime + IfCondition +
  # binding-safe) — unlike every other `->` construct, whose LHS is a pattern. `context` is
  # the construct's liveness: `:runtime` for an ordinary `cond`; `:scaffold` for a module-level
  # `cond` wrapping a metaprogrammed `def`, whose conditions run once at compile time with
  # mutant 0 (so a selector there could never activate) and stay inert.
  def cond_blocks(descent, blocks, context, mutators) do
    Enum.map(blocks, &cond_block(descent, &1, context, mutators))
  end

  # One `cond` do-block: a `{key, clauses}` pair whose key is the `:do` label (kept raw, never
  # mutated). Anything unexpected falls back to a plain descent in `context`.
  defp cond_block(descent, {key, clauses}, context, mutators) when is_list(clauses),
    do: {key, Enum.map(clauses, &cond_clause(descent, &1, context, mutators))}

  defp cond_block(descent, other, context, mutators),
    do: descent.descend(other, context, mutators)

  defp cond_clause(descent, {:->, meta, [conds, body]}, context, mutators) when is_list(conds) do
    analyzed_conds =
      Enum.map(conds, fn cond_node ->
        if context == :runtime,
          do: analyze_condition(descent, cond_node, mutators),
          else: descent.descend(cond_node, context, mutators)
      end)

    {:->, meta, [analyzed_conds, descent.descend(body, context, mutators)]}
  end

  defp cond_clause(descent, other, context, mutators),
    do: descent.descend(other, context, mutators)

  # === if/unless condition hoisting ==========================================
  #
  # When an `if`/`unless` condition binds a variable that escapes into the body, the
  # prune path above can deliver *no* decision mutant (the selector would trap the
  # binding). But an `if` condition is evaluated **unconditionally and exactly once**,
  # so the binding can be *hoisted* out into a preceding statement — leaving a
  # binding-free condition that can host the decision selector without trapping
  # anything. `if (name = f()) != nil do use(name) …` becomes:
  #
  #     name = f()
  #     if (case <sel> do <id> -> true; <id> -> false; _ -> name != nil end) do
  #       use(name)          # `name` is bound by the hoisted statement — no trap
  #     end
  #
  # delivered as a `__block__` (which renders, compiles, and leaks `name` exactly like
  # the original `if` in every position — statement, expression RHS, call argument).
  # A **refutable** pattern (`if {:ok, v} = f() do`) keeps its `MatchError` semantics
  # by binding the match value to a temp first: `mutare_cond = f(); {:ok, v} =
  # mutare_cond; if … mutare_cond … do`. The temp is a placeholder until emit
  # substitutes the salted `cond_var` (analyze is id-/name-free).
  #
  # Scope (each a soundness or fidelity guard, the rest staying on the prune path):
  #   * The decision is delivered; everything else on a *binding-ancestor* node (an
  #     operator swap on `!=`, say) stays pruned — its mutant would still embed the
  #     binding. Safe siblings and the body mutate as always; the hoisted EXPR mutates
  #     in its new statement.
  #   * Only when **every** escaping binding is on the unconditional *spine* — not
  #     under a short-circuit (`and`/`or`/`&&`/`||`) right operand, nor inside a nested
  #     branch (`case`/`cond`/`if`) — so hoisting can't change *when* it evaluates.
  #   * Only when no binding is reordered past a side-effecting sibling (`spine_reorders?/1`):
  #     a binding hoists to *before the whole `if`*, so an expression that evaluates
  #     *before* it in the original (`check(state) == (x = f())` — `check(state)` first)
  #     would otherwise be reordered *after* it on the baseline (mutant 0 must match the
  #     original program). Vetoed when an impure expression precedes a spine binding in
  #     evaluation order — the common shapes (`if x = e`, `(x = e) != nil`, `(x = e) and
  #     g(x)`, two bindings) have the binding(s) evaluated first, so they still hoist.
  #   * At most **one** refutable spine binding (they would all need a distinct temp;
  #     bare-variable bindings reuse their own name, so any number is fine).
  #   * Gated on `IfCondition` being enabled (it owns the decision the hoist delivers).
  # The decision `Site` references the **original** condition (range and code), so the
  # report diff stays faithful (`(name = f()) != nil` → `true`), independent of the
  # rewrite emit actually delivers.
  def hoist_if?(analyzed_condition, mutators) do
    Spec.find(mutators, Mutare.Mutators.IfCondition) != nil and
      escaping_binding?(analyzed_condition) and
      not offspine_escaping_binding?(analyzed_condition) and
      not spine_reorders?(analyzed_condition) and
      refutable_spine_count(analyzed_condition) <= 1
  end

  # Build the hoisted `__block__`: lift every spine binding into a preceding statement,
  # rewrite the condition to read the lifted value, and attach the decision pair to the
  # rewritten root (with `original`/`range` from the *raw* condition, for the report).
  def hoist_if(form, meta, raw_condition, analyzed_condition, analyzed_body, mutators) do
    {pruned, _has} = prune_binding_ancestors(analyzed_condition)
    {rewritten, hoists} = spine_rewrite(pruned)
    rewritten = attach_decision(rewritten, raw_condition, mutators)
    if_node = {form, meta, [rewritten, analyzed_body]}
    {:__block__, [], hoists ++ [if_node]}
  end

  # Synthesize the `IfCondition` decision (`true`/`false`) on the rewritten condition
  # root, ranged on the original condition. We build it directly rather than calling
  # the `condition_replacements/1` hook, which declines a binding condition (and a
  # boolean-operator one) — the very shapes this path exists for.
  defp attach_decision(rewritten_root, raw_condition, mutators) do
    case Spec.find(mutators, Mutare.Mutators.IfCondition) do
      nil ->
        rewritten_root

      spec ->
        candidates = [{spec, AST.literal(true)}, {spec, AST.literal(false)}]
        append_condition_candidates(rewritten_root, raw_condition, candidates)
    end
  end

  # ── NOTE on the spine-walk helper cluster (spine_rewrite, spine_bindings, eval_steps,
  # offspine_escaping_binding?, escaping_binding?, prune_binding_ancestors) ──
  #
  # A dogfood run leaves a cluster of equivalent / niche survivors across these mirror walks,
  # deliberately left as *reported* survivors (the project's stance: surface a suspected-
  # equivalent rather than hide it). The observable hoist behaviours — recursing into call
  # args / tuples / lists / short-circuit spines, the IfCondition gate, and the ≤1-refutable
  # cap — are pinned by the `if/unless hoisting` tests in `transform_test.exs`. What remains:
  #
  #   * Membership-guard directions (`form in @branch_forms → false`, `op in @short_circuit_ops
  #     → false`, …): the SURVIVING direction is the no-op one — a node mis-routed that way
  #     falls through to the general recursion, which (since `hoist_if?/2` has already proven no
  #     escaping binding hides off-spine or inside a branch/isolating form) finds nothing to
  #     change. `escaping_binding?(node)` and "recurse into `node`'s args" detect the same inner
  #     bindings, so the two paths agree. The opposite direction (`… → true`), which would
  #     mis-hoist or trap a binding, is killed.
  #   * Symmetric `{left, right}` pattern swaps: the operands are combined commutatively
  #     (`or` / `++` / independent recursion), so swapping them is a true no-op.
  #   * `return_value`/`list` mutants on the predicate/collector clauses: `nil` for a boolean
  #     predicate (≡ false) or `[]` for a binding collector only changes the *refutable count*,
  #     which alters a decision only for ≥2 refutable bindings nested in a container — a shape no
  #     realistic condition uses.
  #   * Recursion clause drops: equivalent where the general clause/fallback covers them, else
  #     killable only by an (unusual) binding buried in a container the dropped clause handled.
  #   * `atom`/`collection` mutants on the walk structure (`offspine`'s `:= → :mutare`, its
  #     `Enum.any? → Enum.all?`): equivalent or killable only by a pathological shape — a binding
  #     nested in a spine binding's RHS *under a short-circuit*, or a multi-arg call with exactly
  #     one off-spine-binding arg — that no real condition uses. (The one that *was* naturally
  #     killable, `eval_steps`'s `:__block__ → :mutare` flipping a literal's reorder class, is
  #     killed by the `pure literal preceding a spine binding` test.)
  #
  # The three boolean/list folds (`escaping_binding?`, `spine_bindings`,
  # `offspine_escaping_binding?`) end in one `children/1`-based catch-all (below) rather than
  # re-listing the args/pair/list/leaf cases; `spine_rewrite`'s and `eval_steps`'s defensive
  # `is_list/1` guards and the cluster's unreachable fallbacks stay `# mutare:ignore`d inline.
  #
  # Rewrite the condition's *spine* (the unconditionally-evaluated nodes), replacing
  # each spine binding `PAT = EXPR` with a read of the lifted value and returning the
  # hoist statements, in evaluation (left-to-right) order. A bare-variable binding
  # `v = EXPR` lifts as `v = EXPR` and the condition reads `v`; a refutable `PAT =
  # EXPR` lifts as `tmp = EXPR; PAT = tmp` (the match value is `EXPR`, not the
  # pattern's bindings) and the condition reads `tmp`. The walk stops at short-circuit
  # right operands, nested branches, and binding-isolating forms — `hoist_if?/2` has
  # already verified no escaping binding hides there.
  defp spine_rewrite({op, meta, [left, right]}) when op in @short_circuit_ops do
    {left2, hoists} = spine_rewrite(left)
    {{op, meta, [left2, right]}, hoists}
  end

  defp spine_rewrite({form, _meta, _args} = node)
       when form in @branch_forms or form in @binding_isolating_forms,
       do: {node, []}

  defp spine_rewrite({:=, _meta, [lhs, rhs]}), do: hoist_one(lhs, rhs)

  # mutare:ignore[guard_drop] equivalent — a non-leaf AST node always carries a list of args, so the `is_list/1` guard never excludes a real node.
  defp spine_rewrite({form, meta, args}) when is_list(args) do
    {args2, hoists} = spine_rewrite_each(args)
    {{form, meta, args2}, hoists}
  end

  defp spine_rewrite({left, right}) do
    {left2, lh} = spine_rewrite(left)
    {right2, rh} = spine_rewrite(right)
    {{left2, right2}, lh ++ rh}
  end

  defp spine_rewrite(list) when is_list(list), do: spine_rewrite_each(list)

  defp spine_rewrite(other), do: {other, []}

  defp spine_rewrite_each(list) do
    {nodes, hoists} = list |> Enum.map(&spine_rewrite/1) |> Enum.unzip()
    {nodes, List.flatten(hoists)}
  end

  # One spine binding → `{read_node, [hoist_statement(s)]}`. The read node and the
  # hoist's RHS keep the *analyzed* EXPR, so its mutations are delivered in the lifted
  # statement.
  defp hoist_one(lhs, rhs) do
    if bare_var?(lhs) do
      {clean_var(lhs), [{:=, [], [lhs, rhs]}]}
    else
      placeholder = Names.hoist_placeholder()
      {placeholder, [{:=, [], [placeholder, rhs]}, {:=, [], [lhs, placeholder]}]}
    end
  end

  # The bindings on the unconditional spine (mirrors `spine_rewrite/1`'s reach).
  defp spine_bindings({op, _meta, [left, _right]}) when op in @short_circuit_ops,
    do: spine_bindings(left)

  defp spine_bindings({form, _meta, _args})
       when form in @branch_forms or form in @binding_isolating_forms,
       do: []

  defp spine_bindings({:=, _meta, _args} = node), do: [node]

  defp spine_bindings(node), do: Enum.flat_map(children(node), &spine_bindings/1)

  defp refutable_spine_count(node) do
    node
    |> spine_bindings()
    |> Enum.count(fn {:=, _meta, [lhs, _rhs]} -> not bare_var?(lhs) end)
  end

  # Would hoisting reorder a binding past a side-effecting sibling? A spine binding is
  # lifted to *before the whole `if`*, so any expression evaluated *before* it in the
  # original condition ends up *after* it on the baseline — and the baseline (mutant 0)
  # must be behaviorally identical to the original program. `check(state) == (x = f())`
  # evaluates `check(state)` first, so hoisting `x = f()` ahead of it changes the order
  # of side effects; this vetoes that, falling back to the sound prune path.
  #
  # `eval_steps/1` flattens the condition into its left-to-right evaluation order as
  # `:binding` (a spine `=`, which rides whole), `:pure` (a literal or bare-variable
  # read — no side effect, safe to reorder around), or `:other` (anything else — a call,
  # an operator application, a short-circuit/branch/isolating subtree — conservatively
  # treated as possibly side-effecting). It is unsafe iff an `:other` precedes a
  # `:binding`. The common shapes evaluate their binding(s) first (`if x = e`,
  # `(x = e) != nil`, `(x = first(a)) != (y = first(b))`), so they stay hoistable.
  defp spine_reorders?(condition) do
    condition |> eval_steps() |> impure_before_binding?(false)
  end

  defp impure_before_binding?([], _seen_other?), do: false

  defp impure_before_binding?([:binding | rest], seen?),
    do: seen? or impure_before_binding?(rest, seen?)

  defp impure_before_binding?([:other | rest], _seen?), do: impure_before_binding?(rest, true)
  defp impure_before_binding?([:pure | rest], seen?), do: impure_before_binding?(rest, seen?)

  # A spine `=` rides into the hoist as one unit (its internals keep their relative
  # order), so it is a single `:binding` step — not descended.
  defp eval_steps({:=, _meta, _args}), do: [:binding]

  # A short-circuit: only the left operand is on the spine; the right is evaluated
  # conditionally and (by `offspine_escaping_binding?/1`) holds no binding, so it is one
  # opaque `:other` step after the left.
  defp eval_steps({op, _meta, [left, _right]}) when op in @short_circuit_ops,
    do: eval_steps(left) ++ [:other]

  # A nested branch / binding-isolating subtree holds no spine binding either; it is one
  # opaque `:other` step (so a `case`/`fn`/… *before* a binding correctly vetoes).
  defp eval_steps({form, _meta, _args})
       when form in @branch_forms or form in @binding_isolating_forms,
       do: [:other]

  # A Sourceror scalar literal (`{:__block__, meta, [value]}`) — pure.
  defp eval_steps({:__block__, _meta, [value]})
       when is_atom(value) or is_number(value) or is_binary(value),
       do: [:pure]

  # A bare variable read — pure (an atom name with an atom hygiene context).
  defp eval_steps({name, _meta, ctx}) when is_atom(name) and is_atom(ctx), do: [:pure]

  # Any other call/operator (including a remote `{:., …}` call): its arguments evaluate
  # left to right, then the application itself runs — one `:other` step after the args.
  # mutare:ignore[guard_drop] equivalent — a non-leaf AST node always carries a list of args, so the `is_list/1` guard never excludes a real node.
  defp eval_steps({_form, _meta, args}) when is_list(args),
    do: Enum.flat_map(args, &eval_steps/1) ++ [:other]

  defp eval_steps({left, right}), do: eval_steps(left) ++ eval_steps(right)

  # mutare:ignore[guard_drop] equivalent — only an actual list reaches this clause (leaves match the clauses above/below), so the `is_list/1` guard is always satisfied.
  defp eval_steps(list) when is_list(list), do: Enum.flat_map(list, &eval_steps/1)
  defp eval_steps(leaf) when is_atom(leaf) or is_number(leaf) or is_binary(leaf), do: [:pure]
  defp eval_steps(_other), do: [:other]

  # Is there an escaping binding *off* the unconditional spine — under a short-circuit
  # right operand or inside a nested branch — that hoisting therefore can't lift?
  # (A binding-isolating form's bindings never escape, so they are not a concern; a
  # spine `=` rides into the hoist whole, so its own nested bindings are not off-spine.)
  defp offspine_escaping_binding?({op, _meta, [left, right]}) when op in @short_circuit_ops,
    do: offspine_escaping_binding?(left) or escaping_binding?(right)

  defp offspine_escaping_binding?({form, _meta, _args} = node) when form in @branch_forms,
    do: escaping_binding?(node)

  defp offspine_escaping_binding?({form, _meta, _args}) when form in @binding_isolating_forms,
    do: false

  defp offspine_escaping_binding?({:=, _meta, _args}), do: false

  defp offspine_escaping_binding?(node),
    do: Enum.any?(children(node), &offspine_escaping_binding?/1)

  # Does the subtree contain an escaping `=` binding (one not isolated inside a
  # closure/comprehension/`try`/`quote`)? The presence counterpart of
  # `prune_binding_ancestors/1`'s taint.
  defp escaping_binding?({form, _meta, _args}) when form in @binding_isolating_forms, do: false
  defp escaping_binding?({:=, _meta, _args}), do: true
  defp escaping_binding?(node), do: Enum.any?(children(node), &escaping_binding?/1)

  # The structural children of an AST node — the generic-recursion tail the three
  # boolean/list spine folds (`escaping_binding?`, `spine_bindings`,
  # `offspine_escaping_binding?`) share: a 3-tuple's argument list, a 2-tuple pair's two
  # elements, or a bare list's elements; a leaf (literal, bare variable, atom) has none.
  # Each fold keeps its own *specific* clauses (the short-circuit/branch/isolating/`=`
  # routing that defines it) and ends in one `children`-based catch-all rather than
  # re-listing these four structural cases. (`eval_steps`/`spine_rewrite`/`prune_binding_
  # ancestors` don't use it — their tails treat a call/leaf differently, see their clauses.)
  defp children({_form, _meta, args}) when is_list(args), do: args
  defp children({left, right}), do: [left, right]
  defp children(list) when is_list(list), do: list
  defp children(_leaf), do: []

  # A bare variable (the irrefutable, temp-free hoist case): a `{name, _, context}`
  # node with an atom name (not `_`) and an atom hygiene context. A call (`context` is
  # the arg list), an `__aliases__`, a pin, or a container is *not* a bare variable.
  #
  # NOTE (equivalent survivors): the surviving guard/pattern mutants here only matter for a
  # bound `_` (`name != :_`, the name/context swap) or distinguish the irrefutable from the
  # refutable hoist path (`hoist_one`'s `if bare_var?(lhs)`). A bound-and-read `_` is impossible
  # in a real condition, and for a *captured* refutable pattern the irrefutable path merely
  # reconstructs the (truthy) matched tuple — same observable result as the temp path; only a
  # `_`-bearing refutable pattern (e.g. `{:ok, _} = …`) would differ, a shape no test exercises.
  # The directions that *do* flip a real decision (`bare_var?(_) → true`, `not bare_var?(lhs) →
  # false`) are killed via the refutable-count cap test.
  defp bare_var?({name, _meta, context})
       when is_atom(name) and is_atom(context) and name != :_,
       do: true

  defp bare_var?(_), do: false

  defp clean_var({name, _meta, context}), do: {name, [], context}

  # Bottom-up over the analyzed condition: returns `{node, subtree_has_binding?}`,
  # stripping the in-place candidates (`meta[:mutare]`) from any node that is a
  # *proper ancestor* of an escaping `=` binding (a child subtree holds one). A `=`
  # node has no in-place candidate of its own, so it is never itself stripped; it only
  # reports its subtree as binding-bearing so its ancestors are pruned.
  defp prune_binding_ancestors({form, _meta, _args} = node)
       when form in @binding_isolating_forms,
       do: {node, false}

  defp prune_binding_ancestors({form, meta, args}) when is_list(args) do
    {pruned_args, child_has?} = prune_binding_ancestors_each(args)
    node = {form, meta, pruned_args}
    node = if child_has?, do: strip_inplace_candidates(node), else: node
    {node, child_has? or form == :=}
  end

  defp prune_binding_ancestors({left, right}) do
    {pruned_left, left_has?} = prune_binding_ancestors(left)
    {pruned_right, right_has?} = prune_binding_ancestors(right)
    {{pruned_left, pruned_right}, left_has? or right_has?}
  end

  # A bare list operand (`length([x = f(), y])`) — walk each element so a binding
  # nested in it still taints the call that holds it. A list carries no metadata, so
  # there is nothing of its own to strip.
  defp prune_binding_ancestors(list) when is_list(list),
    do: prune_binding_ancestors_each(list)

  defp prune_binding_ancestors(other), do: {other, false}

  defp prune_binding_ancestors_each(list) do
    {nodes, hass} = list |> Enum.map(&prune_binding_ancestors/1) |> Enum.unzip()
    {nodes, Enum.any?(hass)}
  end

  # Drop the in-place candidates from a binding-ancestor node (`Meta.put_candidates(_, [])` deletes
  # the key); total over a bare literal.
  defp strip_inplace_candidates(node), do: Meta.put_candidates(node, :in_place, [])

  # Force an `if`/`unless`/`cond` *condition* to `true`/`false` via the in-place
  # selector. `IfCondition.replacements/1` returns the `[true, false]` pair (or `[]`
  # when the condition is a boolean operator `Conditional` already forces, a literal,
  # or a binding `x = …` whose un-binding would poison the body — see that module).
  # Gated on the family being enabled, like `annotate_returns/3`. The candidates are
  # appended to the *analyzed* condition node — after any operator candidate already
  # there, so one selector hosts both — with `original`/`range` taken from the *raw*
  # condition for a clean diff.
  defp attach_if_condition(analyzed_condition, raw_condition, mutators) do
    candidates =
      mutators
      |> Dispatch.implementing_any(:condition_replacements, [1, 2])
      |> Enum.flat_map(fn spec ->
        Enum.map(Dispatch.condition_replacements(spec, raw_condition), &{spec, &1})
      end)

    case candidates do
      [] -> analyzed_condition
      _ -> append_condition_candidates(analyzed_condition, raw_condition, candidates)
    end
  end

  # Append a `Candidate.InPlace` per `{spec, mutated}` (`mutator` is the producing
  # *spec* — `IfCondition` or a custom condition mutator — since `Site.in_place/6` reads
  # its `name`) to the condition node's metadata, preserving any candidates already there.
  # A condition we can't range or that is not a `{f, m, a}` node gets no mutant (handled by
  # the shared `Attach.append_candidates/3`).
  defp append_condition_candidates(node, raw_condition, candidates) do
    Attach.append_candidates(node, raw_condition, fn range ->
      Enum.map(candidates, fn {spec, mutated} ->
        %Candidate.InPlace{
          mutator: spec,
          original: raw_condition,
          mutated: mutated,
          range: range
        }
      end)
    end)
  end
end
