defmodule Mutare.Transform.Analyze.Conditions do
  @moduledoc false

  # Condition analysis for `if`/`unless`/`cond`: the binding-ancestor prune that keeps an
  # in-place selector from trapping an escaping condition binding, the IfCondition decision
  # attach, and the `if`/`unless` *hoisting* path that lifts a spine binding out so a
  # binding-free condition can still carry the decision mutant. Split out of
  # `Mutare.Transform.Analyze`: it builds condition candidates the descent hands off to. The
  # `cond` path re-enters the walk through `Analyze.annotate/2` (the `:runtime` walk) and
  # `Analyze.descend/3` (an arbitrary liveness); the `if`/`unless` helpers (`finish_condition/3`,
  # `hoist_if?/2`, `hoist_if/6`) need no descent, since they only post-process an
  # already-analyzed condition.
  #
  # Entry points the descent calls (`Mutare.Transform.Analyze`):
  #   * cond          → `cond_blocks/3` (routes each clause condition → `analyze_condition/2`)
  #   * if/unless     → `hoist_if?/2` + `hoist_if/6` (hoistable) or `finish_condition/3` (plain)

  alias Mutare.AST
  alias Mutare.Mutator.Dispatch
  alias Mutare.Mutator.Spec
  alias Mutare.Transform.{Candidate, Meta}
  alias Mutare.Transform.Analyze
  alias Mutare.Transform.Analyze.Env
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
  def analyze_condition(condition, env) do
    analyzed = Analyze.annotate(condition, env)
    finish_condition(analyzed, condition, env)
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
  #
  # A `:skip`-routed condition (`if String.valid?(x)` under `{String, :valid?, 1, :skip}`) is an
  # inert leaf and gets no decision pair either: `condition_replacements` is an offer *of the
  # condition node*, structural or not, and the node-offered twin (`Conditional`'s `true`/`false`
  # on a skipped `x > 0`) is already withheld by the dispatcher — the two families must agree.
  # (The function-level return contract is the deliberate exception, NOTES "Call routing".)
  def finish_condition(analyzed, raw_condition, env) do
    if Meta.skipped?(raw_condition) do
      analyzed
    else
      case prune_binding_ancestors(analyzed) do
        {pruned, true} -> pruned
        {_pruned, false} -> attach_if_condition(analyzed, raw_condition, env)
      end
    end
  end

  # === cond ==================================================================
  #
  # The descent hands the whole `cond`'s block list here (the `:cond` clause in
  # `Mutare.Transform.Analyze`). A `cond` clause's *left* is a runtime condition, not a
  # pattern, so each is routed through `analyze_condition/2` (runtime + IfCondition +
  # binding-safe) — unlike every other `->` construct, whose LHS is a pattern. `context` is
  # the construct's liveness: `:runtime` for an ordinary `cond`; `:scaffold` for a module-level
  # `cond` wrapping a metaprogrammed `def`, whose conditions run once at compile time with
  # mutant 0 (so a selector there could never activate) and stay inert.
  def cond_blocks(blocks, context, env) do
    Enum.map(blocks, &cond_block(&1, context, env))
  end

  # One `cond` do-block: a `{key, clauses}` pair whose key is the `:do` label (kept raw, never
  # mutated). Anything unexpected falls back to a plain descent in `context`.
  defp cond_block({key, clauses}, context, env) when is_list(clauses),
    do: {key, Enum.map(clauses, &cond_clause(&1, context, env))}

  defp cond_block(other, context, env),
    do: Analyze.descend(other, context, env)

  defp cond_clause({:->, meta, [conds, body]}, context, env) when is_list(conds) do
    analyzed_conds =
      Enum.map(conds, fn cond_node ->
        if context == :runtime,
          do: analyze_condition(cond_node, env),
          else: Analyze.descend(cond_node, context, env)
      end)

    {:->, meta, [analyzed_conds, Analyze.descend(body, context, env)]}
  end

  defp cond_clause(other, context, env),
    do: Analyze.descend(other, context, env)

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
  # the original `if` in every position — statement, expression RHS, call argument —
  # except the *direct argument of a capture*, the one expression position that rejects
  # a block; the `&` clause in `Mutare.Transform.Analyze` re-delivers that case via
  # `fold_hoist_into_condition/1`).
  # A **refutable** pattern (`if {:ok, v} = f() do`) keeps its `MatchError` semantics
  # by binding the match value to a temp first: `mutare_cond = f(); {:ok, v} =
  # mutare_cond; if … mutare_cond … do`. The temp is the file's salted `cond_var`, carried
  # in on the env (`Mutare.Transform.Analyze.Env`).
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
  #   * At most **one** refutable spine binding (they would all need a distinct temp, and
  #     the env carries one — `env.cond_var`; with none, in collect mode, zero), while
  #     bare-variable bindings reuse their own name, so any number is fine.
  #   * Gated on some `condition_replacements` implementer being enabled — `IfCondition` or a
  #     custom condition mutator — since the hoist exists only to deliver a condition offer;
  #     with none, the plain prune path is the same program with less rewriting.
  # The decision `Site` references the **original** condition (range and code), so the
  # report diff stays faithful (`(name = f()) != nil` → `true`), independent of the
  # rewrite emit actually delivers.
  def hoist_if?(analyzed_condition, env) do
    # A skipped condition is never hoisted: the rewrite would lift bindings out of an inert leaf.
    not Meta.skipped?(analyzed_condition) and
      condition_implementers(env) != [] and
      escaping_binding?(analyzed_condition) and
      not offspine_escaping_binding?(analyzed_condition) and
      not spine_reorders?(analyzed_condition) and
      refutable_spine_count(analyzed_condition) <= refutable_cap(env)
  end

  # How many refutable spine bindings the hoist can name: one with a temp, none without.
  defp refutable_cap(%Env{cond_var: nil}), do: 0
  defp refutable_cap(%Env{}), do: 1

  # Build the hoisted `__block__`: lift every spine binding into a preceding statement,
  # rewrite the condition to read the lifted value, and attach the decision pair to the
  # rewritten root (with `original`/`range` from the *raw* condition, for the report).
  def hoist_if(form, meta, raw_condition, analyzed_condition, analyzed_body, env) do
    {pruned, _has} = prune_binding_ancestors(analyzed_condition)
    {rewritten, hoists} = spine_rewrite(pruned, env.cond_var)
    rewritten = attach_decision(rewritten, raw_condition, env)
    if_node = {form, meta, [rewritten, analyzed_body]}
    {:__block__, [], hoists ++ [if_node]}
  end

  @doc """
  Re-deliver a statement-hoisted `if`/`unless` (`hoist_if/6`'s `__block__`) with the hoists
  folded *into the condition* — `if (v = f(); <condition>) do …` — for the one expression
  position where a `__block__` is illegal: the **direct argument of a capture**.
  `&if(v = f(&1), do: …)` would otherwise emit `&(v = f(&1); if …)`, which the capture
  operator rejects ("block expressions are not allowed inside the capture operator &"),
  sinking the single compile. A block *nested in* the condition is legal under `&`, and the
  semantics are identical: the hoists still run unconditionally, exactly once, before the
  condition, and their bindings still leak into the branches. Anything that is not the hoist
  shape passes through untouched (a multi-statement block can't be written under `&` in
  source, so only the hoist manufactures one there).
  """
  @spec fold_hoist_into_condition(Macro.t()) :: Macro.t()
  def fold_hoist_into_condition({:__block__, _bmeta, [_, _ | _] = stmts} = block) do
    case Enum.split(stmts, -1) do
      {hoists, [{form, meta, [condition, body_kw]}]}
      when form in [:if, :unless] and is_list(body_kw) ->
        {form, meta, [{:__block__, [], hoists ++ [condition]}, body_kw]}

      _ ->
        block
    end
  end

  def fold_hoist_into_condition(other), do: other

  # Attach every enabled condition mutator's offer on the rewritten condition root, ranged
  # on the original condition. This is the hoist path's twin of `attach_if_condition/3`:
  # each `condition_replacements` implementer is asked with the **rewritten** (binding-free)
  # condition, the shape its replacement will actually stand in for — the raw one still
  # embeds the binding the hoist just lifted out.
  #
  # `IfCondition` alone is not asked but synthesized (`true`/`false`): its hook declines a
  # boolean-operator root on *ownership* grounds (`Conditional` forces that node), but on
  # this path the `Conditional` candidates on that root were pruned as binding ancestors —
  # so the ownership premise is void, and the transform, which knows that, delivers the pair
  # itself. Asking the hook would lose the decision on exactly the headline shape
  # (`(name = f()) != nil`).
  defp attach_decision(rewritten_root, raw_condition, env) do
    candidates =
      env
      |> condition_implementers()
      |> Enum.flat_map(fn
        %Spec{module: Mutare.Mutators.IfCondition} = spec ->
          [{spec, AST.literal(true)}, {spec, AST.literal(false)}]

        spec ->
          Enum.map(Dispatch.condition_replacements(spec, rewritten_root), &{spec, &1})
      end)

    case candidates do
      [] -> rewritten_root
      _ -> append_condition_candidates(rewritten_root, raw_condition, candidates)
    end
  end

  # The enabled specs implementing the condition hook at either arity — the one discovery
  # both the plain path (`attach_if_condition/3`) and the hoist path share.
  defp condition_implementers(env),
    do: Dispatch.implementing_any(env.mutators, :condition_replacements, [1, 2])

  # The cluster below is `@doc false` public: `conditions_property_test.exs` pins each walk
  # against a reference model and the hoist rewrite against evaluation (value, bindings, effect
  # order), the precondition NOTES sets for ever collapsing them into one generic walk.
  #
  # ── NOTE on the spine-walk helper cluster (spine_rewrite, spine_bindings, eval_steps,
  # offspine_escaping_binding?, escaping_binding?, prune_binding_ancestors) ──
  #
  # A dogfood run leaves a cluster of equivalent / niche survivors across these mirror walks,
  # deliberately left as *reported* survivors (the project's stance: surface a suspected-
  # equivalent rather than hide it). The observable hoist behaviours — recursing into call
  # args / tuples / lists / short-circuit spines, the condition-mutator gate, and the ≤1-refutable
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
  @doc false
  def spine_rewrite({op, meta, [left, right]}, cond_var) when op in @short_circuit_ops do
    {left2, hoists} = spine_rewrite(left, cond_var)
    {{op, meta, [left2, right]}, hoists}
  end

  def spine_rewrite({form, _meta, _args} = node, _cond_var)
      when form in @branch_forms or form in @binding_isolating_forms,
      do: {node, []}

  def spine_rewrite({:=, _meta, [lhs, rhs]}, cond_var), do: hoist_one(lhs, rhs, cond_var)

  # mutare:ignore[guard_drop] equivalent — a non-leaf AST node always carries a list of args, so the `is_list/1` guard never excludes a real node.
  def spine_rewrite({form, meta, args}, cond_var) when is_list(args) do
    {args2, hoists} = spine_rewrite_each(args, cond_var)
    {{form, meta, args2}, hoists}
  end

  def spine_rewrite({left, right}, cond_var) do
    {left2, lh} = spine_rewrite(left, cond_var)
    {right2, rh} = spine_rewrite(right, cond_var)
    {{left2, right2}, lh ++ rh}
  end

  def spine_rewrite(list, cond_var) when is_list(list), do: spine_rewrite_each(list, cond_var)

  def spine_rewrite(other, _cond_var), do: {other, []}

  defp spine_rewrite_each(list, cond_var) do
    {nodes, hoists} = list |> Enum.map(&spine_rewrite(&1, cond_var)) |> Enum.unzip()
    {nodes, List.flatten(hoists)}
  end

  # One spine binding → `{read_node, [hoist_statement(s)]}`. The read node and the
  # hoist's RHS keep the *analyzed* EXPR, so its mutations are delivered in the lifted
  # statement.
  defp hoist_one(lhs, rhs, cond_var) do
    if bare_var?(lhs) do
      {clean_var(lhs), [{:=, [], [lhs, rhs]}]}
    else
      temp = {cond_var, [], nil}
      {temp, [{:=, [], [temp, rhs]}, {:=, [], [lhs, temp]}]}
    end
  end

  # The bindings on the unconditional spine (mirrors `spine_rewrite/1`'s reach).
  @doc false
  def spine_bindings({op, _meta, [left, _right]}) when op in @short_circuit_ops,
    do: spine_bindings(left)

  def spine_bindings({form, _meta, _args})
      when form in @branch_forms or form in @binding_isolating_forms,
      do: []

  def spine_bindings({:=, _meta, _args} = node), do: [node]

  def spine_bindings(node), do: Enum.flat_map(children(node), &spine_bindings/1)

  @doc false
  def refutable_spine_count(node) do
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
  @doc false
  def spine_reorders?(condition) do
    condition |> eval_steps() |> impure_before_binding?(false)
  end

  defp impure_before_binding?([], _seen_other?), do: false

  defp impure_before_binding?([:binding | rest], seen?),
    do: seen? or impure_before_binding?(rest, seen?)

  defp impure_before_binding?([:other | rest], _seen?), do: impure_before_binding?(rest, true)
  defp impure_before_binding?([:pure | rest], seen?), do: impure_before_binding?(rest, seen?)

  # A spine `=` rides into the hoist as one unit (its internals keep their relative
  # order), so it is a single `:binding` step — not descended.
  @doc false
  def eval_steps({:=, _meta, _args}), do: [:binding]

  # A short-circuit: only the left operand is on the spine; the right is evaluated
  # conditionally and (by `offspine_escaping_binding?/1`) holds no binding, so it is one
  # opaque `:other` step after the left.
  def eval_steps({op, _meta, [left, _right]}) when op in @short_circuit_ops,
    do: eval_steps(left) ++ [:other]

  # A nested branch / binding-isolating subtree holds no spine binding either; it is one
  # opaque `:other` step (so a `case`/`fn`/… *before* a binding correctly vetoes).
  def eval_steps({form, _meta, _args})
      when form in @branch_forms or form in @binding_isolating_forms,
      do: [:other]

  # A Sourceror scalar literal (`{:__block__, meta, [value]}`) — pure.
  def eval_steps({:__block__, _meta, [value]})
      when is_atom(value) or is_number(value) or is_binary(value),
      do: [:pure]

  # A bare variable read — pure (an atom name with an atom hygiene context).
  def eval_steps({name, _meta, ctx}) when is_atom(name) and is_atom(ctx), do: [:pure]

  # Any other call/operator (including a remote `{:., …}` call): its arguments evaluate
  # left to right, then the application itself runs — one `:other` step after the args.
  # mutare:ignore[guard_drop] equivalent — a non-leaf AST node always carries a list of args, so the `is_list/1` guard never excludes a real node.
  def eval_steps({_form, _meta, args}) when is_list(args),
    do: Enum.flat_map(args, &eval_steps/1) ++ [:other]

  def eval_steps({left, right}), do: eval_steps(left) ++ eval_steps(right)

  # mutare:ignore[guard_drop] equivalent — only an actual list reaches this clause (leaves match the clauses above/below), so the `is_list/1` guard is always satisfied.
  def eval_steps(list) when is_list(list), do: Enum.flat_map(list, &eval_steps/1)
  def eval_steps(leaf) when is_atom(leaf) or is_number(leaf) or is_binary(leaf), do: [:pure]
  def eval_steps(_other), do: [:other]

  # Is there an escaping binding *off* the unconditional spine — under a short-circuit
  # right operand or inside a nested branch — that hoisting therefore can't lift?
  # (A binding-isolating form's bindings never escape, so they are not a concern; a
  # spine `=` rides into the hoist whole, so its own nested bindings are not off-spine.)
  @doc false
  def offspine_escaping_binding?({op, _meta, [left, right]}) when op in @short_circuit_ops,
    do: offspine_escaping_binding?(left) or escaping_binding?(right)

  def offspine_escaping_binding?({form, _meta, _args} = node) when form in @branch_forms,
    do: escaping_binding?(node)

  def offspine_escaping_binding?({form, _meta, _args}) when form in @binding_isolating_forms,
    do: false

  def offspine_escaping_binding?({:=, _meta, _args}), do: false

  def offspine_escaping_binding?(node),
    do: Enum.any?(children(node), &offspine_escaping_binding?/1)

  # Does the subtree contain an escaping `=` binding (one not isolated inside a
  # closure/comprehension/`try`/`quote`)? The presence counterpart of
  # `prune_binding_ancestors/1`'s taint.
  @doc false
  def escaping_binding?({form, _meta, _args}) when form in @binding_isolating_forms, do: false
  def escaping_binding?({:=, _meta, _args}), do: true
  def escaping_binding?(node), do: Enum.any?(children(node), &escaping_binding?/1)

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
  @doc false
  def prune_binding_ancestors({form, _meta, _args} = node)
      when form in @binding_isolating_forms,
      do: {node, false}

  def prune_binding_ancestors({form, meta, args}) when is_list(args) do
    {pruned_args, child_has?} = prune_binding_ancestors_each(args)
    node = {form, meta, pruned_args}
    node = if child_has?, do: strip_inplace_candidates(node), else: node
    {node, child_has? or form == :=}
  end

  def prune_binding_ancestors({left, right}) do
    {pruned_left, left_has?} = prune_binding_ancestors(left)
    {pruned_right, right_has?} = prune_binding_ancestors(right)
    {{pruned_left, pruned_right}, left_has? or right_has?}
  end

  # A bare list operand (`length([x = f(), y])`) — walk each element so a binding
  # nested in it still taints the call that holds it. A list carries no metadata, so
  # there is nothing of its own to strip.
  def prune_binding_ancestors(list) when is_list(list),
    do: prune_binding_ancestors_each(list)

  def prune_binding_ancestors(other), do: {other, false}

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
  defp attach_if_condition(analyzed_condition, raw_condition, env) do
    candidates =
      env
      |> condition_implementers()
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
