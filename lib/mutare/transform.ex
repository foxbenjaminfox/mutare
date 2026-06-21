defmodule Mutare.Transform do
  @moduledoc """
  Source → metamutant transform, expressed as an explicit pipeline over a small
  intermediate representation.

  Rather than walk every node and then *subtract* the positions that must not be
  mutated (the old blacklist), the transform classifies each node's context
  *positively*, builds a plan, then renders it. The plan is three typed pieces:

    * `Mutare.Transform.ModulePlan` — a statement sequence (a module body)
      classified into items: a clause group to **lift**, a clause group to keep
      **in place**, or any other **statement**. This is "module planning",
      separated from emission.
    * `Mutare.Transform.FunctionPlan` — one liftable clause group: its signature,
      its clauses, a single shared *tagged* clause group, and the typed lifted
      candidates (`Candidate.Lifted` / `Candidate.Drop`) it admits.
    * `Mutare.Transform.Candidate.{InPlace,Lifted,Drop}` — the typed, pre-id
      description of a single mutant. One struct per legal kind, so the redundant
      `context`/`kind`/`operation` triple (and its illegal combinations) is gone.

  The stages, run per subtree:

    1. **Analyze + classify** — `analyze/3` is one context-threaded recursive
       descent: it *names the context* of each position as it descends and, for
       every node a mutator recognises *in a mutating context*, attaches a typed
       `Candidate.InPlace` to the node's own metadata (`meta[:mutare]`). Mutators
       run **once**, here. Routing is positional (the spec side of a `::` goes one
       way, the value side another), which is why it can't be a flat
       `Macro.traverse` accumulator. Three contexts are threaded — `:runtime`
       (mutate, → in-place; `:guard`/`:clause_drop`/head-pattern literals come from
       the lift path), `:pattern` (don't mutate in place, but keep descending so
       default-arg values and `size()` args are reached), and `:scaffold` (a known
       compile-time module-level statement: descend but never mutate its own
       expressions — they run once at compile time, so a selector there is inert —
       yet still reach any explicit `def` body, which flips back to `:runtime`);
       the rest (`:compile_time`, `:spec`, `:guard`,
       `:capture_arity`) are recognised and pruned, producing no candidate.
    2. **Plan** — a statement sequence is grouped into a `ModulePlan`; each
       liftable clause group becomes a `FunctionPlan` carrying its lifted
       candidates. No ids are assigned yet.
    3. **Assign** — emission walks the plan and the annotated tree bottom-up and
       hands each candidate the next mutant id. Ids are assigned in post-order DFS
       and the counter advances even for `:skip_ids`, so ids stay stable across
       the poison-recovery rebuilds the runner relies on.
    4. **Emit** — an in-place candidate becomes a tail-position selector `case`; a
       `FunctionPlan` becomes one private function (threading the active id as an
       extra arg) behind a dispatcher, each mutant a single guarded clause.
    5. **Render** — annotations are stripped and the tree is rendered to source
       (with a Sourceror keyword-block workaround); `# mutare:ignore` directives
       (parsed by `Mutare.Ignore`) are applied to the recorded sites.

  Carrying the `Candidate.InPlace` in the node's *own* metadata is what lets
  emission find "this exact node" without a fragile `{line, column}` identity:
  metadata is intrinsic to the node and rides through any `Macro` rebuild, so
  duplicate subtrees can never collide.

  ## In-place selector (body expressions)

  An operator inside a body is wrapped in a tail-position `case` reading the
  active mutant id from `:persistent_term`:

      # source:   total >= threshold
      case :persistent_term.get(:mutare_active, 0) do
        17 -> total > threshold     # mutant 17:  >= → >
        _  -> total >= threshold    # baseline + every other mutant
      end

  Substituting a node with a value-equivalent `case` preserves its position, so
  tail calls stay tail calls (LCO). Nested sites work because the catch-all holds
  the *transformed* children, reachable whenever an outer mutant is inactive.

  One position the selector `case` is *not* legal in: the right side of a pipe.
  `x |> case … end` parses but fails to compile (`Kernel.|>/2` cannot pipe into a
  `case`), so when a mutated node is a **pipe stage**, emission lifts the selector
  out of the pipe into a one-shot closure invoked on the piped value
  (`hoist_pipe/2`): `lhs |> (fn v -> case … (each branch pipes `v`) … end).()`. The
  piped value is computed once (it stays the pipe's LHS) and bound to `v`, so each
  branch references a cheap variable — keeping a chain of mutated stages **linear**
  in the rendered source, where distributing `lhs` into every branch would copy the
  whole upstream chain per branch and blow up exponentially. The Site still records
  the bare stage, so the diff is unchanged.

  ## Function lifting + dispatcher (guards, dispatch)

  A `case` is illegal in a `when` guard, and guards drive dispatch *across*
  clauses, so guard mutations (and head-pattern / clause-drop mutations) cannot be
  done in place. Instead the whole clause group becomes **one** private function
  that takes the active mutant id as an extra first arg (`mutare_active`); the
  public `f/arity` becomes a dispatcher that reads the id and forwards. Each source
  clause is emitted **once** as an original gated `when mutare_active !== <id>` for
  every mutant that overrides/drops it; each mutant adds a **single** clause gated
  `when mutare_active === <id>`, placed before the original it replaces:

      def f(a) do
        mutare_active = :persistent_term.get(:mutare_active, 0)
        __mutare_f_1_g1(mutare_active, a)
      end
      defp __mutare_f_1_g1(mutare_active, a) when mutare_active === 5 and a > 1, do: ...  # mutant 5: guard >= → >
      defp __mutare_f_1_g1(mutare_active, a) when mutare_active !== 5 and a >= 1, do: ... # original (in-place applies here)

  Exactly one clause wins for any `(id, args)`: the mutant when its id is active and
  its head/guard match, else the original. This is **per-clause**: a mutant touching
  one clause no longer copies the other N−1, so a group with C clauses and M mutants
  emits ~C+M clauses, not C×M (see NOTES "lifting blowup"). In-place selectors live
  only in the *original* clauses (and non-lifted code); a mutant clause reuses the
  raw body — sound because exactly one mutant is ever active. The public `f/arity`
  is unchanged at the module boundary.

  Ranges are captured against the *original* AST, which is what the diff report
  patches against.

  ## Where the work lives

  `Mutare.Transform.{ModulePlan,FunctionPlan,Candidate}` own the *vocabulary* —
  the plan structs and pure discovery (chunking clauses, finding guard/drop
  candidates). Emission — id assignment, site recording, building the selector
  `case` and the dispatcher — stays here, because it shares the `Ctx`
  id-threading discipline across the in-place and lifted paths too tightly to
  split cleanly (`claim_id/4` is the single owner of that dance).
  """

  alias Mutare.AST
  alias Mutare.Site
  alias Mutare.Coverage.Recorder
  alias Mutare.Mutator.Spec

  alias Mutare.Transform.{
    Analyze,
    Candidate,
    Ctx,
    FunctionPlan,
    Imports,
    ModulePlan,
    Names,
    Overlap,
    Render,
    Resolve,
    Super
  }

  # The default set is the built-in catalog's `all/0` — one source of truth, so a
  # family registered in `Mutare.Mutators` is part of the default automatically.
  @default_mutators Mutare.Mutators.all()

  @doc """
  Transform a source string into `{metamutant_source, [%Site{}], next_id}`.

  `next_id` is the first mutant id left unassigned — what the next file in a
  schema should start from. It equals `:start_id` when nothing was mutated, so
  the caller never has to recover it from the last site.

  Options:

    * `:file` — path recorded on each site (default `"nofile"`)
    * `:mutators` — list of mutator entries (family atoms, modules, `{module, opts}`
      pairs, or `Mutare.Mutator.Spec`s); defaults to the full built-in set
    * `:macros` — list of known-macro entries (`{module, name, arity, treatment}` /
      `{module, name, treatment}`, see `Mutare.Macros`) that route a macro's
      arguments specially; merged with the built-ins and any enabled mutator's
      `macros/0`. Defaults to `[]`.
    * `:start_id` — first mutant id to assign (default `1`)
  """
  @spec transform_string(String.t(), keyword()) :: {String.t(), [Site.t()], pos_integer()}
  def transform_string(source, opts \\ []) when is_binary(source) do
    ctx = %Ctx{
      file: Keyword.get(opts, :file, "nofile"),
      # Normalize to `Mutare.Mutator.Spec`s — `:mutators` may arrive as family
      # atoms / bare modules (tests, the default set) or already-resolved specs
      # (the Options/Config path); `resolve/1` is idempotent on specs.
      mutators: opts |> Keyword.get(:mutators, @default_mutators) |> Mutare.Mutators.resolve(),
      next_id: Keyword.get(opts, :start_id, 1),
      # Mutant ids to drop (e.g. compile-poisoning, found by the runner): their
      # site is still recorded (`poisoned: true`, for the denominator and id
      # stability) but no selector/copy is generated, so the metamutant compiles.
      skip_ids: Keyword.get(opts, :skip_ids, MapSet.new())
      # `group` and `sites` start at their struct defaults (0 / []).
    }

    parsed = Sourceror.parse_string!(source)
    # Pin the generated names this source provably never collides with before any
    # lifting assigns them: the private-function prefix, the dispatch variable, the
    # super-forwarding closure variable, and the hoisted pipe-stage closure variable
    # (see `Mutare.Transform.Names`).
    {prefix, active_var, super_var, piped_var, cond_var} = Names.generated_names(parsed)

    ctx = %{
      ctx
      | prefix: prefix,
        active_var: active_var,
        super_var: super_var,
        piped_var: piped_var,
        cond_var: cond_var
    }

    # The known-macro registry (`Mutare.Macros`): built-ins (`Kernel.match?`/`destructure`)
    # merged with the declarative `:macros` option and any enabled mutator's `macros/0`. It
    # tells the resolution pass how to route a recognised macro's arguments (a pattern, an
    # opaque DSL body). Built from the resolved mutator specs in `ctx`, so a library's mutator
    # auto-registers the macros it relies on.
    macros = Mutare.Macros.build(Keyword.get(opts, :macros, []), ctx.mutators)

    # Resolve `alias`es and `import`s in one lexical pass (`Mutare.Transform.Resolve`),
    # stamping each call with the module it refers to, so the call-matching mutators recognise
    # an aliased `S.upcase` as `String.upcase` and a bare imported `reject(xs, f)` (after
    # `import Enum`) as `Enum.reject`. The two interleave in source order (an `alias` can
    # rebind a later `import`'s module), which the single fold gets right by construction.
    # The same pass stamps each known-macro call with its argument routing. `parsed` itself
    # stays pristine for the comment-based ignore scan below.
    {transformed, ctx} = transform_node(Resolve.annotate(parsed, macros), ctx)

    metamutant = transformed |> silence_helper_xref() |> Render.to_source()

    # Reuse the AST we just parsed — its comment metadata is intact (transform
    # works on copies), so `Ignore` need not re-parse the source. A directive may
    # be scoped to a mutator family, so the decision is per `{line, mutator}`, not
    # per line; a matching directive's reason rides along onto the site.
    directives = Mutare.Ignore.directives_from_ast(parsed)
    sites = Enum.map(Enum.reverse(ctx.sites), &apply_ignore(&1, directives))

    {metamutant, sites, ctx.next_id}
  end

  # Mark a site ignored (and record the reason) when a `# mutare:ignore` directive
  # on its line admits its mutator. Untouched sites pass through unchanged.
  defp apply_ignore(site, directives) do
    case Mutare.Ignore.directive_for(directives, site.line, site.mutator) do
      nil -> site
      %{reason: reason} -> %{site | ignored: true, ignore_reason: reason}
    end
  end

  # Prepend `@compile {:no_warn_undefined, {:mutare_cov, :hit, 1}}` to every module
  # body, so the coverage `hit/1` call in each selector catch-all draws no xref
  # warning when the umbrella compiles a mutated app before the generated helper
  # app (see `Mutare.Coverage.Recorder.no_warn_attr_ast/0`). Both `defmodule` and
  # `defimpl` define modules with mutatable bodies; `defprotocol` has no bodies (so
  # no `hit/1` call) and is left alone. A prewalk reaches nested modules too — an
  # ancestor without its own call gets a harmless no-op attribute.
  defp silence_helper_xref(ast) do
    attr = Recorder.no_warn_attr_ast()

    Macro.prewalk(ast, fn
      {form, meta, args} when form in [:defmodule, :defimpl] and is_list(args) and args != [] ->
        {init, [do_keyword]} = Enum.split(args, -1)
        {form, meta, init ++ [prepend_module_attr(do_keyword, attr)]}

      other ->
        other
    end)
  end

  # Prepend `attr` as the first statement of a module's `do` body. Handles both
  # Sourceror's keyword-block key (`{:__block__, _, [:do]}`) and a plain `:do`, and
  # both a block body and a single-expression body. A last arg that is not a `do`
  # keyword list passes through untouched.
  defp prepend_module_attr(do_keyword, attr) when is_list(do_keyword) do
    Enum.map(do_keyword, fn
      {{:__block__, _, [:do]} = key, body} -> {key, prepend_statement(body, attr)}
      {:do, body} -> {:do, prepend_statement(body, attr)}
      other -> other
    end)
  end

  defp prepend_module_attr(do_keyword, _attr), do: do_keyword

  defp prepend_statement({:__block__, meta, stmts}, attr), do: {:__block__, meta, [attr | stmts]}
  defp prepend_statement(single, attr), do: {:__block__, [], [attr, single]}

  # === module / statement structure =========================================

  # A module: transform the body of its do-block(s).
  defp transform_node({:defmodule, meta, [alias_node, do_keyword]}, ctx)
       when is_list(do_keyword) do
    {do_keyword, ctx} = transform_do_keyword(do_keyword, ctx)
    {{:defmodule, meta, [alias_node, do_keyword]}, ctx}
  end

  # A block: either a module body (contains clauses → plan + emit) or an
  # ordinary sequence (recurse so nested modules are still reached).
  defp transform_node({:__block__, meta, statements}, ctx) do
    if Enum.any?(statements, &ModulePlan.clause_signature/1) do
      {statements, ctx} = transform_statements(statements, ctx)
      {{:__block__, meta, statements}, ctx}
    else
      {statements, ctx} = Enum.map_reduce(statements, ctx, &transform_node/2)
      {{:__block__, meta, statements}, ctx}
    end
  end

  # Anything else is an expression: mutate operators in place.
  defp transform_node(node, ctx), do: in_place(node, ctx)

  defp transform_do_keyword(keyword, ctx) do
    Enum.map_reduce(keyword, ctx, fn
      {{:__block__, _, [:do]} = key, body}, ctx ->
        {body, ctx} = transform_body(body, ctx)
        {{key, body}, ctx}

      {:do, body}, ctx ->
        {body, ctx} = transform_body(body, ctx)
        {{:do, body}, ctx}

      entry, ctx ->
        {entry, ctx}
    end)
  end

  defp transform_body({:__block__, meta, statements}, ctx) do
    {statements, ctx} = transform_statements(statements, ctx)
    {{:__block__, meta, statements}, ctx}
  end

  defp transform_body(single, ctx) do
    case transform_statements([single], ctx) do
      {[one], ctx} -> {one, ctx}
      {many, ctx} -> {{:__block__, [], many}, ctx}
    end
  end

  # Plan the statement sequence, then emit it (assigning ids). The split is the
  # whole point: `ModulePlan.build/3` decides *what* each statement is (a lifted
  # group, an in-place group, or another statement), id-free; emission does the
  # id-threading.
  defp transform_statements(statements, ctx) do
    statements
    |> ModulePlan.build(ctx.mutators, ctx.file)
    |> emit_module_plan(ctx)
  end

  # === emission: walk the plan, thread ids, render ===========================

  defp emit_module_plan(%ModulePlan{items: items}, ctx) do
    Enum.flat_map_reduce(items, ctx, fn
      {:lift, plan}, ctx ->
        emit_function_plan(plan, ctx)

      {:in_place, clauses}, ctx ->
        in_place_clauses(clauses, ctx)

      {:statement, statement}, ctx ->
        {node, ctx} = transform_statement(statement, ctx)
        {[node], ctx}
    end)
  end

  # Transform each *non-lifted* clause in place (body selectors only), preserving its
  # position. The `:do` block's active-id read is hoisted to a once-per-call prologue
  # (`emit_clause/3` with `prologue: true`); the head's default values and the other body
  # blocks keep the self-contained `:persistent_term` read (out of the prologue's scope).
  defp in_place_clauses(clauses, ctx) do
    Enum.flat_map_reduce(clauses, ctx, fn clause, ctx ->
      {clause, ctx} = emit_clause(clause, ctx, prologue: true)
      {[clause], ctx}
    end)
  end

  # Transform each *source* clause of a lifted group (the originals the dispatcher
  # forwards to). The dispatcher threads the active id as the base clause's first
  # parameter, so the whole body reads it directly (no prologue, every body block
  # covered); only the head's default values — extracted onto the dispatcher head, out of
  # any binding's scope — keep the self-contained read.
  defp lifted_source_clauses(clauses, ctx) do
    Enum.flat_map_reduce(clauses, ctx, fn clause, ctx ->
      {clause, ctx} = emit_clause(clause, ctx, prologue: false)
      {[clause], ctx}
    end)
  end

  # Emit one def/defp clause with the active-id read hoisted out of its per-site selectors.
  # The head (default values) is emitted with the read *unbound* (those expressions run in
  # a generated head clause where no binding is in scope), the body with it *bound*. The
  # one-shot `active_bound` toggles are scoped to this clause and restored on the way out,
  # so they never leak into the next module item.
  defp emit_clause(clause, ctx, opts) do
    prologue? = Keyword.get(opts, :prologue, false)
    bound0 = ctx.active_bound
    {emitted, ctx} = emit_annotated_clause(Analyze.annotate(clause, ctx.mutators), ctx, prologue?)
    {emitted, %{ctx | active_bound: bound0}}
  end

  # A normal body-bearing def/defp clause: emit the head with the read unbound, then the
  # body blocks (`emit_clause_body/3`).
  defp emit_annotated_clause({vis, meta, [head, body_kw]}, ctx, prologue?)
       when vis in [:def, :defp] and is_list(body_kw) do
    {head, ctx} = emit(head, %{ctx | active_bound: false})
    {body_kw, ctx} = emit_clause_body(body_kw, ctx, prologue?)
    {{vis, meta, [head, body_kw]}, ctx}
  end

  # A bodiless header (`def f(a, b \\ 1)` with no `do`) or any unexpected shape: no body
  # to hoist into, so emit the whole node with the read unbound — identical to the
  # pre-hoist behaviour. (A header's only runtime sub-positions are its default values,
  # which keep the self-contained read regardless.)
  defp emit_annotated_clause(node, ctx, _prologue?), do: emit(node, %{ctx | active_bound: false})

  # Emit each body block's value with the active-id read bound where the binding reaches:
  # the `:do` block always (a non-lifted clause's prologue binds it; a lifted clause's
  # dispatcher parameter is in scope there), and the other blocks (`rescue`/`catch`/`else`/
  # `after`) only for a lifted clause — there the parameter is in scope everywhere, whereas
  # a non-lifted clause's `:do`-block prologue is *not* visible in its sibling blocks, so
  # they keep the self-contained read. Block order (`:do` first) is preserved, so ids land
  # exactly as a single whole-clause emit would assign them. The `is_list` guard asserts
  # the caller's contract (`emit_annotated_clause/3` only reaches here for a list body_kw);
  # there is no fallback because a body-bearing def/defp clause always has a keyword body.
  defp emit_clause_body(body_kw, ctx, prologue?) when is_list(body_kw) do
    other_bound = not prologue?

    {body_kw, ctx} =
      Enum.map_reduce(body_kw, ctx, fn {key, value}, ctx ->
        bound = AST.key_atom(key) == :do or other_bound
        {value, ctx} = emit(value, %{ctx | active_bound: bound})
        {{key, value}, ctx}
      end)

    {if(prologue?, do: prepend_do_prologue(body_kw, ctx.active_var), else: body_kw), ctx}
  end

  # Prepend `<var> = :persistent_term.get(...)` to the `:do` block — but only when that
  # block actually references the hoisted variable (i.e. it spliced at least one hoisted
  # selector). With no reference the binding would draw an "unused variable" warning, so
  # an unmutated `:do` block is left untouched.
  defp prepend_do_prologue(body_kw, var) do
    Enum.map(body_kw, fn {key, value} = pair ->
      if AST.key_atom(key) == :do and references_var?(value, var),
        do: {key, prepend_statement(value, active_read(var))},
        else: pair
    end)
  end

  # Whether `ast` mentions `var` as a variable/bare-name node *in this scope*. Since `var`
  # is a generated name the source provably never uses, any occurrence is a spliced hoisted
  # selector's scrutinee/record — so this is exactly "did the `:do` block get a hoisted
  # selector". A runtime nested `defmodule` is pruned (replaced with `nil` on the way down):
  # its inner selectors use the inline read, so any `var` there is a *local* catch-all
  # binding, not a use of this body's prologue — counting it would add an unused prologue.
  defp references_var?(ast, var) do
    {_ast, found?} =
      Macro.traverse(
        ast,
        false,
        fn node, acc -> if(module_scope?(node), do: {nil, acc}, else: {node, acc}) end,
        fn
          {^var, _meta, context} = node, _acc when is_atom(context) -> {node, true}
          node, acc -> {node, acc}
        end
      )

    found?
  end

  # A non-clause-group module statement (an `{:other}` in the plan). Four routes:
  #
  #   * a nested `defmodule` recurses through the full planner
  #     (`transform_node`), so an inner module is lifted/mutated like a top-level one;
  #   * a parenthesized/semicolon `__block__` keeps its block shape but sends its
  #     children back through this module-statement pipeline — clause groups still
  #     plan together, nested scopes still recurse, and compile-time-only children
  #     stay scaffolded instead of falling into the runtime expression walk;
  #   * an unknown module-level macro call with a block keeps the macro shell and
  #     non-block args compile-time, but analyzes block bodies as runtime because
  #     a DSL macro may unquote them into generated functions;
  #   * known compile-time module statements are **`:scaffold`**. A module body
  #     runs **once, at compile time, with mutant 0 active**, so a selector spliced
  #     into the statement's own expressions (an `if` condition, a `for` generator,
  #     a bare module-body calculation, an unquoted generated head pattern) could
  #     never activate at runtime — it would only add inert no-coverage mutants and
  #     waste poison-recovery rounds. The `:scaffold` descent does **not** mutate
  #     those, but still reaches any explicit `def`/`defp` and mutates its *body*
  #     (`:runtime`, via the def clause), while its head stays `:pattern`
  #     (unmutated; these functions are not lifted). Nesting (`for` in `if` in …)
  #     is handled for free — `:scaffold` propagates through the generic descent.
  defp transform_statement({:defmodule, _meta, _args} = node, ctx), do: transform_node(node, ctx)

  defp transform_statement({:__block__, meta, statements}, ctx) do
    {statements, ctx} = transform_statements(statements, ctx)
    {{:__block__, meta, statements}, ctx}
  end

  defp transform_statement(node, ctx) do
    # Scaffold is the default. Only an *unknown* macro call carrying a `do` block
    # takes the DSL route — and a known scaffold form (`if`/`for`/`case`/… with a
    # `do … end`) *also* looks like a macro-with-block, so it must be excluded here
    # or it would wrongly route to `analyze_module_macro_block` instead of scaffolding.
    if Analyze.module_macro_block_statement?(node) and
         not Analyze.module_scaffold_statement?(node) do
      node |> Analyze.analyze_module_macro_block(ctx.mutators) |> emit(ctx)
    else
      node |> Analyze.scaffold(ctx.mutators) |> emit(ctx)
    end
  end

  # A lifted clause group becomes ONE private function `<base>` plus a public
  # dispatcher. Each *source* clause is emitted once as a `<base>` clause that
  # takes the active mutant id as an extra first argument (`mutare_active`); each
  # lifted mutant adds a single extra `<base>` clause, gated `when mutare_active
  # === <id>`, placed *before* the source clause it overrides — so a mutant
  # touching one clause no longer duplicates the other N-1 (the C×M → C+M win; see
  # NOTES "lifting blowup"). The original clauses are gated `when mutare_active !==
  # <id>` for every mutant that overrides or drops them, so exactly one wins for
  # any (id, args): the mutant when its id is active and its head/guard match, else
  # the original. Ids are assigned exactly as before — in-place **body** ids first
  # (`in_place_clauses` over the source clauses), then the lifted candidates in
  # `candidates/1` order — so the scheme is invisible to ids, Sites, and coverage.
  defp emit_function_plan(%FunctionPlan{signature: {vis, name, arity}} = plan, ctx) do
    group = ctx.group + 1
    ctx = %{ctx | group: group}
    base = :"#{base_name(name, arity, group, ctx.prefix)}"
    var = ctx.active_var

    # If any lifted body calls `super`, the relocated base copies can't (super is
    # legal only in the overriding function). `super_var` is the closure variable the
    # dispatcher binds and forwards (`Mutare.Transform.Super`); `nil` when the group
    # is super-free, leaving the common path byte-for-byte unchanged.
    super_var = if Super.in_clauses?(plan.clauses), do: ctx.super_var, else: nil

    # Source clauses with in-place body selectors — claims the body ids first. The body
    # reads the threaded `mutare_active` parameter directly (the dispatcher binds it);
    # head default values keep the self-contained read (they ride onto the dispatcher).
    {orig_clauses, ctx} = lifted_source_clauses(plan.clauses, ctx)

    # Then the lifted candidates, in order, each claiming its id. Non-skipped ones
    # yield `{id, clause_index, mutated_clause | :drop}`; a skipped (poisoned) id
    # yields nothing here (its site is still recorded), so it is neither emitted as
    # a mutant clause nor excluded from its original — i.e. it behaves as baseline.
    {claimed, ctx} =
      Enum.flat_map_reduce(FunctionPlan.candidates(plan), ctx, fn candidate, ctx ->
        claim_id(ctx, candidate, &lifted_site/3, fn id, candidate ->
          {index, clause} = FunctionPlan.mutated_clause(plan, candidate)
          {id, index, clause, candidate_import_witness(candidate)}
        end)
      end)

    mut_ids = Enum.map(claimed, fn {id, _i, _c, _w} -> id end)

    # Default arguments (`def f(a, b \\ 1)`) expand to multiple arities. They stay
    # on the public dispatcher — which keeps the original arity contract — while the
    # base function takes the full arity with `\\` stripped (`clause_parts`). The
    # default *expressions* are taken from the already-emitted clauses, so their
    # in-place selectors ride along and the dispatcher keeps mutating its defaults.
    defaults = clause_defaults(orig_clauses)

    base_clauses = build_base_clauses(orig_clauses, claimed, base, var, super_var)
    dispatcher = build_dispatcher(vis, name, arity, mut_ids, base, var, defaults, super_var)
    {[dispatcher | base_clauses], ctx}
  end

  # Emit the lifted function's base clauses by interleaving: for each source clause, its
  # mutant clauses (one per candidate overriding it, gated `when mutare_active === <id>`)
  # come *before* the source clause itself (gated `when mutare_active !== <those ids>`, so it
  # steps aside when a mutant is active). A dropped clause contributes only its exclusion (no
  # mutant clause); a bodiless header (`def f(a, b \\ 1)` with no `do`) contributes neither —
  # its defaults ride on the dispatcher and it has no body to lift.
  defp build_base_clauses(orig_clauses, claimed, base, var, super_var) do
    # Every claimed candidate overrides (guard/literal/structure) or drops its clause, so its
    # id excludes that clause's *original* version.
    excluded = Enum.group_by(claimed, fn {_id, i, _c, _w} -> i end, fn {id, _i, _c, _w} -> id end)

    orig_clauses
    |> Enum.with_index()
    |> Enum.flat_map(fn {orig, index} ->
      mutant_clauses =
        for {id, ^index, clause, witness} <- claimed,
            clause != :drop,
            do: lifted_mutant(base, id, clause, var, super_var, witness)

      if bodiless_header?(orig) do
        mutant_clauses
      else
        mutant_clauses ++
          [lifted_original(base, orig, Map.get(excluded, index, []), var, super_var)]
      end
    end)
  end

  # The public dispatcher: read the active mutant id once, record coverage for the
  # group's lifted ids (inert off the probe — see `Mutare.Coverage.Recorder`), then
  # tail-call the lifted function with the id threaded as the extra first argument.
  #   def f(mutare_arg1, mutare_arg2 \\ <default>, ...) do
  #     mutare_active = :persistent_term.get(:mutare_active, 0)
  #     <record ids>
  #     <base>(mutare_active, mutare_arg1, mutare_arg2, ...)
  #   end
  #
  # `defaults` (position → expression, from the source's default args) is overlaid
  # onto the dispatcher *head* — so the public function keeps the original
  # multi-arity contract — while the call to the base passes the *plain* vars (the
  # defaults are already resolved by the time the head's body runs). The base
  # therefore always sees the full arity.
  #
  # `super_var` (non-`nil` only when a lifted body calls `super`) adds a closure
  # `<super_var> = &super/arity` bound here — `super` is legal inside the dispatcher
  # (the overriding function), even captured — and threaded to the base as its second
  # argument, so the relocated body can call `super` through it
  # (`Mutare.Transform.Super`).
  defp build_dispatcher(vis, name, arity, mut_ids, base, var, defaults, super_var) do
    call_args = dispatcher_args(arity)
    head_args = with_defaults(call_args, defaults)
    var_node = Recorder.catch_all_pattern(var)
    read = {:=, [], [var_node, Mutare.Metamutant.subject_ast()]}

    {super_args, super_stmts} = super_closure_binding(super_var, arity)
    call = {base, [], [var_node | super_args] ++ call_args}

    record = if mut_ids == [], do: [], else: [Recorder.record_ast(mut_ids, var)]
    body = {:__block__, [], [read] ++ super_stmts ++ record ++ [call]}

    {vis, [], [{name, [], head_args}, [do: body]]}
  end

  # The super-forwarding closure binding for the dispatcher, plus the extra call arg
  # that threads it to the base: `{[<super_var>], [<super_var> = &super/arity]}` when
  # the group uses `super`, else `{[], []}` (unchanged dispatcher). `&super/arity` is
  # exactly `fn a1, …, aN -> super(a1, …, aN) end` — `super`'s only legal arity is the
  # full param count, so the single capture forwards every legal call — but needs no
  # synthesised arg list of its own.
  defp super_closure_binding(nil, _arity), do: {[], []}

  defp super_closure_binding(super_var, arity) do
    super_node = {super_var, [], nil}
    closure = {:&, [], [{:/, [], [{:super, [], nil}, arity]}]}
    {[super_node], [{:=, [], [super_node, closure]}]}
  end

  # Overlay each `\\ default` from `defaults` (position → expression) onto the
  # dispatcher's catch-all arg at that position. A `\\` may only appear in a
  # `def`/`defp` head, which the dispatcher is.
  defp with_defaults(args, defaults) when map_size(defaults) == 0, do: args

  defp with_defaults(args, defaults) do
    args
    |> Enum.with_index()
    |> Enum.map(fn {arg, pos} ->
      case Map.fetch(defaults, pos) do
        {:ok, default} -> {:\\, [], [arg, default]}
        :error -> arg
      end
    end)
  end

  # One lifted *mutant* clause: the candidate's single mutated source clause,
  # renamed to `<base>`, given the `mutare_active` extra arg, and gated `when
  # mutare_active === <id> [and <its own guard>]`. Raw body (no in-place selectors):
  # only one mutant is ever active, so a body selector here could never fire.
  defp lifted_mutant(base, id, clause, var, super_var, witness) do
    {clause_meta, call_meta, args, guards, body} = clause_parts(clause)
    gate = {:===, [], [Recorder.catch_all_pattern(var), id_literal(id)]}
    guard = and_into_guard(gate, combine_guards(guards))
    body = prepend_import_witness(body, witness)
    lifted_clause(base, clause_meta, call_meta, args, guard, body, var, super_var)
  end

  # One lifted *original* clause: the source clause (with its in-place body
  # selectors), renamed to `<base>`, given the `mutare_active` extra arg, and gated
  # `when mutare_active !== <id>` for each `id` that overrides/drops it — so it
  # yields to its mutant clauses when their id is active, and behaves normally
  # otherwise (including for any skipped/poisoned id, which is never excluded).
  defp lifted_original(base, clause, excluded_ids, var, super_var) do
    {clause_meta, call_meta, args, guards, body} = clause_parts(clause)
    guard = merge_guards(exclusion_guard(excluded_ids, var), combine_guards(guards))
    lifted_clause(base, clause_meta, call_meta, args, guard, body, var, super_var)
  end

  # Assemble a `<base>` clause: `defp <base>(mutare_active, [<super_var>,] <args...>)
  # [when <guard>], <body>`. The source clause's `meta` (its line) is preserved on the
  # `defp` and the head call — *not* reset to `[]` — so `Sourceror`'s line-assigning
  # normalizer stays anchored to the original source lines. Without it the body's
  # `[]`-meta selector clauses (`<id> -> …`) get stale lines, and a bare integer id
  # then renders as a `:line`-but-no-`:token` literal that crashes the Elixir formatter.
  #
  # When the group uses `super` (`super_var` non-`nil`), every base clause takes the
  # forwarding closure as its second parameter; this clause's body is rewritten to call
  # `super` through it. A clause whose own body has no `super` still takes the (shared)
  # parameter but ignores it — a bare `_` (`super_param/2`).
  defp lifted_clause(base, clause_meta, call_meta, args, guard, body, var, super_var) do
    {body, super_params} = super_param(body, super_var)
    call = {base, call_meta, [Recorder.catch_all_pattern(var) | super_params] ++ args}
    head = if guard, do: {:when, [], [call, guard]}, else: call
    {:defp, clause_meta, [head | body]}
  end

  # The super-closure parameter for one base clause, plus its rewritten body. `nil`
  # (super-free group) leaves both untouched. Otherwise the body's `super(...)` calls
  # become `<super_var>.(...)`; the clause takes the closure as a parameter, named
  # `<super_var>` when it is used and a bare `_` when this clause has no `super` (the
  # parameter exists only to match the base's shared arity). A bare `_` — not a salted
  # `_<super_var>` — because the latter could *duplicate* a source variable already in
  # the head (a sibling clause head reusing `_mutare_super`): a repeated underscored
  # name warns *and* silently turns the head into an equality match, breaking dispatch.
  # `_` never binds, so it can neither collide nor constrain however many appear.
  defp super_param(body, nil), do: {body, []}

  defp super_param(body, super_var) do
    case Super.rewrite(body, super_var) do
      {body, true} -> {body, [{super_var, [], nil}]}
      {body, false} -> {body, [{:_, [], nil}]}
    end
  end

  # Deconstruct a function clause into `{clause_meta, head_call_meta, head_args,
  # guards, body_kw}`. A 0-arity head carries a `nil` arg context rather than a
  # list, which becomes `[]`. Default-argument annotations (`a \\ 1`) are stripped
  # from the head args — the base function takes the full arity (the dispatcher
  # already resolved the defaults), and `\\` is legal only in a public head anyway.
  defp clause_parts({_vis, clause_meta, [head | body]}) do
    {call, guards} =
      case head do
        {:when, _meta, [call | gs]} -> {call, gs}
        call -> {call, []}
      end

    {_name, call_meta, args} = call
    args = if is_list(args), do: strip_arg_defaults(args), else: []
    {clause_meta, call_meta, args, guards, body}
  end

  defp strip_arg_defaults(args) do
    Enum.map(args, fn
      {:\\, _meta, [pattern, _default]} -> pattern
      arg -> arg
    end)
  end

  # The default-argument expressions of a lifted group, keyed by 0-based head
  # position. They live on exactly one source clause — a bodiless header in a
  # multi-clause group, or the lone clause of a single-clause group — so the first
  # clause carrying any `\\` supplies them all. The expressions come straight from
  # the *emitted* clauses, so their in-place default-value selectors are intact and
  # the dispatcher that hosts them keeps mutating the defaults at call time.
  defp clause_defaults(clauses) do
    Enum.find_value(clauses, %{}, fn clause ->
      defaults =
        clause
        |> head_arg_list()
        |> Enum.with_index()
        |> Enum.flat_map(fn
          {{:\\, _meta, [_pattern, default]}, pos} -> [{pos, default}]
          _arg -> []
        end)
        |> Map.new()

      if map_size(defaults) > 0, do: defaults, else: nil
    end)
  end

  # The raw head pattern args of a clause (peeling any `when`), with `\\` defaults
  # intact — unlike `clause_parts`, which strips them for the base function.
  defp head_arg_list({_vis, _meta, [head | _rest]}) do
    case head do
      {:when, _meta, [call | _guards]} -> call_arg_list(call)
      call -> call_arg_list(call)
    end
  end

  defp head_arg_list(_), do: []

  defp call_arg_list({_name, _meta, args}) when is_list(args), do: args
  defp call_arg_list(_), do: []

  # A bodiless function header (`def f(a, b \\ 1)` with no `do`): a default-args
  # declaration, not an implementation. One element after the visibility/meta (just
  # the head); a real clause has two (head + body keyword).
  defp bodiless_header?({_vis, _meta, [_head]}), do: true
  defp bodiless_header?(_), do: false

  # AND `gate` into a guard expression, distributing over a top-level `when`
  # (`a when b` is the guard's OR) so each alternative becomes `gate and <alt>` — a
  # `when` may never appear *inside* `and`, so we recurse to the leaves. `nil` (no
  # original guard) leaves just the gate.
  defp and_into_guard(gate, nil), do: gate

  defp and_into_guard(gate, {:when, meta, alts}),
    do: {:when, meta, Enum.map(alts, &and_into_guard(gate, &1))}

  defp and_into_guard(gate, expr), do: {:and, [], [gate, expr]}

  # Collapse a clause's guard list (`guards_of` yields `[]` or a single expr;
  # multiple is a defensive `and`-fold) into one expression or `nil`.
  defp combine_guards([]), do: nil
  defp combine_guards([guard]), do: guard
  defp combine_guards([g | rest]), do: Enum.reduce(rest, g, &{:and, [], [&2, &1]})

  # `mutare_active !== id1 and mutare_active !== id2 …` (chained `!==`, not `not in
  # [list]` — a bare small-integer list can render as a charlist). `nil` for none.
  defp exclusion_guard([], _var), do: nil

  defp exclusion_guard(ids, var) do
    ids
    |> Enum.map(&{:!==, [], [Recorder.catch_all_pattern(var), id_literal(&1)]})
    |> Enum.reduce(&{:and, [], [&2, &1]})
  end

  defp merge_guards(nil, orig), do: orig
  defp merge_guards(excl, nil), do: excl
  defp merge_guards(excl, orig), do: and_into_guard(excl, orig)

  # A generated integer-id literal with clean (empty) metadata. A *bare* integer
  # makes Sourceror's normalizer assign a `:line` but no `:token`, which then
  # crashes the Elixir formatter (`Keyword.fetch!(meta, :token)`); the clean-meta
  # `{:__block__, [], [n]}` shape renders via the inspect path instead (the same
  # rule literal mutators follow — see CLAUDE.md).
  defp id_literal(id), do: {:__block__, [], [id]}

  defp dispatcher_args(0), do: []
  defp dispatcher_args(arity), do: Enum.map(1..arity, &{:"mutare_arg#{&1}", [], nil})

  # A stamped bare imported call can be silently wrong when a macro hidden from our
  # lexical pre-pass re-imports the same module with `except:` and replaces the function from
  # another module. The generated witness re-imports the provider we believe the original call
  # used, then references the same bare name/arity inside an unreachable expression. If a hidden
  # replacement is also in scope, Elixir raises "imported from both ... ambiguous" during the
  # single metamutant compile, and poison recovery drops the generated mutant instead of letting
  # it run against the wrong provider.
  defp candidate_import_witness(%{original: original}), do: node_import_witness(original)
  defp candidate_import_witness(_candidate), do: nil

  defp node_import_witness({_form, meta, _args}) when is_list(meta),
    do: Imports.import_witness(meta)

  defp node_import_witness(_node), do: nil

  defp wrap_import_witness(node, nil), do: node

  defp wrap_import_witness(node, witness),
    do: {:__block__, [], [import_witness_ast(witness), node]}

  defp prepend_import_witness(body, nil), do: body

  defp prepend_import_witness([kw], witness) when is_list(kw) do
    [
      Enum.map(kw, fn
        {key, expr} = entry ->
          if AST.key_atom(key) == :do, do: {key, wrap_import_witness(expr, witness)}, else: entry

        entry ->
          entry
      end)
    ]
  end

  defp prepend_import_witness(body, _witness), do: body

  defp import_witness_ast({module, fun, arity}) do
    args = witness_args(arity)
    call = {fun, [], args}
    closure = {:fn, [], [{:->, [], [args, call]}]}
    import_directive = {:import, [], [witness_module(module), [only: [{fun, arity}]]]}
    true_body = {:__block__, [], [import_directive, closure]}

    {:case, [],
     [
       {:__block__, [], [false]},
       [
         do: [
           {:->, [], [[{:__block__, [], [true]}], true_body]},
           {:->, [], [[{:_, [], nil}], {:__block__, [], [nil]}]}
         ]
       ]
     ]}
  end

  defp witness_args(0), do: []
  defp witness_args(arity), do: Enum.map(1..arity, &{:"mutare_import_arg#{&1}", [], nil})

  defp witness_module(module) when is_list(module), do: {:__aliases__, [], [:"Elixir" | module]}
  defp witness_module(module) when is_atom(module), do: {:__block__, [], [module]}

  # Private base name for a lifted group. `prefix` is the file's collision-free
  # generated-name prefix (`Ctx.prefix`, normally `"__mutare_"`); the trailing
  # `g<group>` keeps generated names unique across groups; `?`/`!` (valid only at
  # the end of a function name) are replaced so the sanitized base is a legal
  # identifier (e.g. `ok?` → `__mutare_ok__1_g1`). The public dispatcher keeps the
  # real name (including any `?`/`!`).
  defp base_name(name, arity, group, prefix) do
    sanitized = name |> Atom.to_string() |> String.replace(["?", "!"], "_")
    "#{prefix}#{sanitized}_#{arity}_g#{group}"
  end

  # === sites: pick the constructor from the candidate variant =================

  # Transform owns which constructor each candidate maps to; `Mutare.Site` owns
  # the struct's fields. The candidate's *type* (not a stored `kind`/`operation`)
  # selects the shape.
  # Most in-place candidates record the *same* plain replacement Site — the diff is
  # `original` → `mutated` at `range`, tagged with the mutator. They differ only in the
  # emit *scaffolding* that delivers them, none of which reaches the Site:
  #
  #   * `InPlace`      — the body operator's own selector `case`.
  #   * `CasePattern`  — the `receive`/`fn` whole-construct selector (the branch carries
  #     the whole mutated construct, `branch_node/1`).
  #   * `CaseClause`   — the `case` tuple-the-scrutinee rewrite (`emit_case_pattern_site/3`).
  #   * `MatchPattern` — the `=`-match tuple-export selector (`emit_match_site/3`).
  #   * `MacroPattern` — the binding-macro tuple-export selector (`emit_macro_pattern_site/3`).
  #
  # See each emit_* and the `Mutare.Transform.Candidate` moduledoc for the per-type detail.
  defp in_place_site(id, c, file)
       when is_struct(c, Candidate.InPlace) or is_struct(c, Candidate.CasePattern) or
              is_struct(c, Candidate.CaseClause) or is_struct(c, Candidate.MatchPattern) or
              is_struct(c, Candidate.MacroPattern) do
    Site.in_place(id, file, c.range, c.original, c.mutated, c.mutator)
  end

  # A return-value mutation is delivered in place (the tail is a body position),
  # but it is structural — no operator — so it gets its own `Site` constructor
  # (`nil` ops); the producing spec (`ReturnValue` or a custom return mutator) on the
  # candidate supplies the recorded name.
  defp in_place_site(id, %Candidate.Return{} = c, file) do
    Site.return_value(id, file, c.range, c.original, c.mutated, c.mutator)
  end

  # A whole `rescue` clause dropped from a `try`, delivered in place by the whole-`try`
  # selector (`branch_node/1` returns the rebuilt try). The diff is a `:delete` of the
  # dropped clause's lines (`Site.in_place_drop/5`), like a function `clause_drop` — the
  # one in-place candidate whose Site isn't the plain `original`/`mutated` replacement.
  defp in_place_site(id, %Candidate.RescueDrop{} = c, file) do
    Site.in_place_drop(id, file, c.range, c.dropped, c.mutator)
  end

  # A lifted candidate — a `when`-guard operator swap or a head-pattern literal swap
  # (a `case` is illegal in both positions) — records the `:lifted` replacement shape;
  # only the mutator family and the tagged position differ, both already on the Site.
  defp lifted_site(id, %Candidate.Lifted{} = c, file) do
    Site.lifted_replace(id, file, c.range, c.original, c.mutated, c.mutator)
  end

  # A head-pattern structure rewrite (variable swap / wildcard) is lifted too, and
  # records the same `:lifted` replacement shape — `original`/`mutated` are the clause's
  # head call node before/after (`f(x, x)` → `f(_, x)`), so the diff is a clean one-liner.
  defp lifted_site(id, %Candidate.PatternStructure{} = c, file) do
    Site.lifted_replace(id, file, c.range, c.original, c.mutated, c.mutator)
  end

  defp lifted_site(id, %Candidate.Drop{} = c, file) do
    Site.clause_drop(id, file, c.range, c.original)
  end

  # === in-place transform: analyze (annotate) then assign/emit ===============

  # Apply the in-place selector transform to one subtree: annotate mutating body
  # nodes with their candidates, then emit selectors as ids are assigned.
  defp in_place(node, ctx) do
    node
    |> Analyze.annotate(ctx.mutators)
    |> emit(ctx)
  end

  defp candidates_of({_form, meta, _args}) when is_list(meta), do: Keyword.get(meta, :mutare, [])
  defp candidates_of(_), do: []

  # The per-clause `Candidate.CaseClause`s a `case` node carries (the tuple-the-scrutinee
  # path), kept under a dedicated meta key separate from `:mutare` because they drive a
  # different emit (rewriting the `case`, not wrapping the node in a selector).
  defp case_candidates_of({_form, meta, _args}) when is_list(meta),
    do: Keyword.get(meta, :mutare_case, [])

  defp case_candidates_of(_), do: []

  defp strip_candidates({form, meta, args}) when is_list(meta),
    do: {form, Keyword.drop(meta, [:mutare, :mutare_case]), args}

  defp strip_candidates(node), do: node

  # --- assign + emit: ids in post-order, selectors built from candidates ------

  # Bottom-up walk: a node's children are wrapped before it is, so ids are
  # assigned in post-order DFS (children before parents) — and the catch-all of
  # an outer selector holds the already-wrapped children, keeping nested sites
  # reachable when the outer mutant is inactive.
  defp emit(node, ctx) do
    # Substitute the salted `cond_var` for the placeholder a refutable `if`/`unless`
    # condition-hoist left behind (`Mutare.Transform.Analyze` builds the hoist in the
    # id-free analyze pass, which has no per-file names). A no-op when nothing was
    # hoisted refutably; runs before everything else so the rest of emit sees a real var.
    node = Names.substitute_hoist_placeholder(node, ctx.cond_var)

    # Drop redundant leaf candidates a call-rewriting mutator already covers (ModeSwap's
    # mode atom / `shift` key vs AtomLiteral), *before* id assignment — so they leave no id
    # or site and ids stay contiguous (like `gate_candidates/1`). A no-op when nothing is
    # covering. Cross-node, so it can't ride the per-node postwalk below: the postwalk is
    # post-order (the leaf is visited before its enclosing call), too late to suppress it.
    node = Overlap.resolve(node)

    # A `Macro.traverse`, not a `postwalk`, so a nested **module** scope can be tracked on
    # the way *down* (`emit_descend/2`): a runtime `defmodule`/`defimpl`/`defprotocol` in a
    # function body hides the outer function's hoisted `active_var` binding from its inner
    # `def` bodies, so selectors emitted there must use the self-contained read. The post
    # step (`emit_node/2`) is the id-assigning walk — identical to the old postwalk callback.
    Macro.traverse(node, ctx, &emit_descend/2, &emit_node/2)
  end

  # The pre step: entering a nested module scope increments `module_depth` (so
  # `selector_subject/1` falls back to the inline read inside it); leaving is handled in the
  # post step. Every other node passes through untouched.
  defp emit_descend(node, ctx) do
    if module_scope?(node),
      do: {node, %{ctx | module_depth: ctx.module_depth + 1}},
      else: {node, ctx}
  end

  # The post step: a module-scope node only restores the depth (it carries no candidates);
  # every other node runs the id-assigning emit.
  defp emit_node(current, ctx) when ctx.module_depth > 0 do
    if module_scope?(current),
      do: {current, %{ctx | module_depth: ctx.module_depth - 1}},
      else: emit_one(current, ctx)
  end

  defp emit_node(current, ctx), do: emit_one(current, ctx)

  # A node that begins a fresh **module** scope, where outer function locals (the hoisted
  # `active_var` binding) are not visible.
  defp module_scope?({form, _meta, _args}) when form in [:defmodule, :defimpl, :defprotocol],
    do: true

  defp module_scope?(_node), do: false

  defp emit_one(current, ctx) do
    # A `case` carrying per-clause `CaseClause`s is rewritten by the tuple-the-scrutinee
    # path (its clauses can't each host a selector, and a `case` isn't a liftable function
    # group). Checked first: a `case` node carries `:mutare_case`, never `:mutare`.
    case case_candidates_of(current) do
      [] ->
        case gate_candidates(candidates_of(current)) do
          # A `|>` never carries candidates itself, but its already-emitted RHS may
          # now be a selector `case` — illegal as a pipe target — so rewrite it here.
          # `strip_candidates` clears any meta left by candidates the gate dropped (a
          # no-op when there were none), so the gated node renders clean.
          [] ->
            {hoist_pipe(strip_candidates(current), ctx), ctx}

          # A `=`-match in statement position is rewritten to a tuple-export selector
          # (its bindings must escape, so it can't be wrapped like an ordinary node). It
          # only ever carries `MatchPattern` candidates, so the head match is exhaustive.
          [%Candidate.MatchPattern{} | _] = candidates ->
            emit_match_site(current, candidates, ctx)

          # A binding-escaping known macro (`destructure([x, y], v)`) in a value-discarded
          # position is rewritten to the same tuple-export selector, but each branch runs
          # the *macro* (with the original/mutated pattern) instead of a `case` match.
          [%Candidate.MacroPattern{} | _] = candidates ->
            emit_macro_pattern_site(current, candidates, ctx)

          candidates ->
            emit_site(current, candidates, ctx)
        end

      case_candidates ->
        emit_case_pattern_site(current, case_candidates, ctx)
    end
  end

  # Drop the candidates a mutator opts out of *before* id assignment, so they leave no
  # id, selector, or site — they simply don't exist for this run (unlike a poisoned id,
  # which is recorded). The only opt today is **per-mutator** and read straight from the
  # candidate's own `Mutare.Mutator.Spec`: a mutator configured `{Module, call_option_keys:
  # false}` suppresses its mutations of a *call-option key* (a key of a keyword list passed
  # as a call's final argument, tagged `call_option_key?` by the analyzer) while still
  # mutating everywhere else. Ids stay stable across a run's poison rebuilds because the
  # mutator list — hence each spec's opts — is constant within a run.
  defp gate_candidates(candidates) do
    Enum.reject(candidates, fn
      %Candidate.InPlace{call_option_key?: true, mutator: spec} -> call_option_keys_off?(spec)
      _candidate -> false
    end)
  end

  defp call_option_keys_off?(%Spec{opts: opts}) when is_list(opts),
    do: Keyword.get(opts, :call_option_keys, true) == false

  defp call_option_keys_off?(_spec), do: false

  # `x |> case … end` does not compile — `Kernel.|>/2` cannot pipe into a `case`.
  # When emit wrapped a *pipe stage* (the call right of a `|>`) in a selector, the
  # selector lands in exactly that illegal RHS position. Run on the parent `|>`
  # during the same postwalk (the RHS is already emitted), this lifts the selector
  # out of the pipe into a one-shot closure invoked on the piped value:
  #
  #     lhs |> (fn mutare_piped ->
  #               case <subject> do
  #                 <id> -> mutare_piped |> <mutant stage>
  #                 _    -> <cov>; mutare_piped |> <original stage>
  #               end
  #             end).()
  #
  # The piped value is computed **once** (it stays the pipe's LHS, so the upstream
  # chain appears once) and bound to the closure's param; each branch pipes that
  # cheap variable instead of a copy of `lhs`. This keeps a chain of mutated stages
  # **linear** in the rendered source — the earlier "distribute `lhs` into every
  # branch" form copied the whole prefix per branch and grew ≈(mutants+1)^depth (a
  # long pipe of stdlib calls could render to megabytes). `(fn … end).()` is itself
  # a valid pipe LHS, so chained pipes still nest; the bare stage stays the Site's
  # recorded node, so the diff is unaffected. The param name (`piped_var`) is salted
  # per file so a stage argument mentioning the same identifier isn't captured.
  defp hoist_pipe(
         {:|>, meta, [lhs, {:__block__, bmeta, [{:case, cmeta, [subject, [do: clauses]]}]}]} =
           node,
         ctx
       ) do
    # Recognise the selector subject in *either* shape — the inline `:persistent_term`
    # read (a head-default pipe stage) or the hoisted bare active-id variable (a body
    # pipe stage). The closure body references that variable (the hoisted form) or the
    # inline read, both valid inside the immediately-invoked closure.
    if Mutare.Metamutant.subject?(subject, ctx.active_var) do
      var = {ctx.piped_var, [], nil}

      piped =
        Enum.map(clauses, fn {:->, m, [pat, body]} -> {:->, m, [pat, pipe_tail(var, body)]} end)

      selector = {:__block__, bmeta, [{:case, cmeta, [subject, [do: piped]]}]}
      closure = {:fn, [], [{:->, [], [[var], selector]}]}
      invocation = {{:., [], [closure]}, [], []}
      {:|>, meta, [lhs, invocation]}
    else
      node
    end
  end

  defp hoist_pipe(node, _ctx), do: node

  # Pipe `lhs` into a selector clause body. A mutant clause body is a single
  # expression (the mutated stage), piped whole; the catch-all body is a block
  # whose head is the coverage record and whose tail is the original stage, so only
  # the tail is piped (the record must stay a bare statement before it).
  defp pipe_tail(lhs, {:__block__, bmeta, stmts}) when stmts != [],
    do: {:__block__, bmeta, List.update_at(stmts, -1, &{:|>, [], [lhs, &1]})}

  defp pipe_tail(lhs, body), do: {:|>, [], [lhs, body]}

  defp emit_site(node, candidates, ctx) do
    {clauses, ctx} =
      Enum.flat_map_reduce(candidates, ctx, fn candidate, ctx ->
        claim_id(ctx, candidate, &in_place_site/3, fn id, candidate ->
          {:->, [],
           [
             [id],
             candidate
             |> branch_node()
             |> wrap_import_witness(candidate_import_witness(candidate))
           ]}
        end)
      end)

    # `hoist_pipe`: when this node is itself a `|>` (e.g. its tail carries a
    # ReturnValue candidate) whose RHS is an already-emitted selector, the selector
    # would sit illegally as a pipe target inside this default/catch-all — hoist the
    # pipe into it. A no-op for every other node shape.
    default = hoist_pipe(strip_candidates(node), ctx)

    # All mutations here skipped → no selector; emit the node unchanged.
    case clauses do
      [] -> {default, ctx}
      _ -> {build_case(default, clauses, ctx), ctx}
    end
  end

  # Rewrite a `=`-match in statement position so its LHS pattern can be mutated. A
  # selector `case` can't wrap the match directly (the bindings made inside its branches
  # would no longer escape to the enclosing scope), so the bound variables are re-exported
  # through a tuple and rebound *outside* the selector:
  #
  #     {x, y} =
  #       case <sel> do
  #         <id> -> case <raw_rhs> do <mutated_pat> -> {x, y} end   # one per mutant
  #         mutare_active ->
  #           <record ids>
  #           case <emitted_rhs> do <orig_pat> -> {x, y} end        # baseline + inactive
  #       end
  #
  # The outer match (and the `{x, y}` each inner case returns) is the shared `export`
  # tuple, so every branch binds the same variables. Mutant branches match the *raw* rhs
  # (no nested selectors — only one mutant is ever active, so a body selector there could
  # never fire), while the catch-all matches the *emitted* rhs so a nested mutation in the
  # matched expression still fires when its (non-match) id is active. Mirrors `emit_site/3`
  # / `build_case/3` for id claiming, coverage, and the all-poisoned fallback.
  defp emit_match_site({:=, _meta, [_lhs, emitted_rhs]} = match_node, candidates, ctx) do
    %Candidate.MatchPattern{export: export, original: original_lhs} = hd(candidates)

    emit_binding_site(match_node, export, candidates, ctx,
      mutant_body: fn c -> match_inner_case(c.raw_rhs, c.mutated, export) end,
      catch_all: fn ids ->
        match_catch_all(ids, match_inner_case(emitted_rhs, original_lhs, export), ctx.active_var)
      end
    )
  end

  # The shared skeleton of the two tuple-export rewrites — `emit_match_site/3` (a `=` match)
  # and `emit_macro_pattern_site/3` (a binding-escaping macro call). Both bind a pattern whose
  # variables must **escape** the selector, so neither can wrap the node in an ordinary
  # selector `case` (the bindings would be trapped in a branch); instead each mutant runs in a
  # branch of
  #
  #     <export> = case <sel> do <id> -> <mutant_body>; … ; mutare_active -> <catch_all> end
  #
  # and the escaping variables are re-exported through the shared `export` tuple and rebound
  # outside. The callers differ only in the per-mutant branch body (`:mutant_body`, called per
  # candidate) and the baseline catch-all (`:catch_all`, called with the hosted ids — it
  # records coverage then runs the emitted node). Mirrors `emit_site/3`/`build_case/3` for id
  # claiming, and shares their all-poisoned fallback (no live mutant → emit the node unchanged).
  defp emit_binding_site(node, export, candidates, ctx, opts) do
    mutant_body = Keyword.fetch!(opts, :mutant_body)
    catch_all = Keyword.fetch!(opts, :catch_all)

    {clauses, ctx} =
      Enum.flat_map_reduce(candidates, ctx, fn candidate, ctx ->
        claim_id(ctx, candidate, &in_place_site/3, fn id, candidate ->
          {:->, [], [[id], mutant_body.(candidate)]}
        end)
      end)

    case clauses do
      [] ->
        {strip_candidates(node), ctx}

      _ ->
        ids = for {:->, _, [[id], _]} <- clauses, do: id
        selector = selector_subject(ctx)
        case_node = {:case, [], [selector, [do: clauses ++ [catch_all.(ids)]]]}
        {{:=, [], [export, case_node]}, ctx}
    end
  end

  # `case <rhs> do <pattern> -> <export>; u -> Kernel.raise(Elixir.MatchError, term: u) end`
  # — re-binds the match by matching `rhs` against `pattern` and returning the shared export
  # tuple. The trailing clause makes a non-match raise the *same* `MatchError` the original
  # `=` raised (not a `CaseClauseError`): exact baseline semantics, and still a clean kill on
  # a mutant whose pattern stopped matching. The pattern is a refutable container (a bare
  # var / pin-only LHS is never offered), so that clause is always reachable.
  defp match_inner_case(rhs, pattern, export) do
    {:case, [], [rhs, [do: [{:->, [], [[pattern], export]}, match_raise_clause()]]]}
  end

  # `mutare_unmatched -> Kernel.raise(Elixir.MatchError, term: mutare_unmatched)`.
  #
  # Both names are spelled to resolve **independently of the target module's lexical
  # environment**, so the generated raise behaves identically to the `=` it replaces — which
  # always raises `Elixir.MatchError` regardless of imports/aliases:
  #
  #   * `Kernel.raise` is *qualified*, so it survives `import Kernel, except: [raise: 2]`
  #     (an exclusion only removes the *unqualified* macro); an unqualified `raise` there
  #     would make the metamutant baseline fail to compile.
  #   * `Elixir.MatchError` is the *absolute* form (`__aliases__` led by `:Elixir`, which
  #     alias resolution never rewrites), so `alias Foo, as: MatchError` / a nested
  #     `MatchError` module can't redirect it to the wrong exception.
  #
  # The binding is local to this one clause body (a fresh case-clause pattern variable, used
  # only here), so a fixed name can't capture or collide — unlike a lifted *head* arg, the
  # gated-equality hazard `Names` salts against doesn't apply to a body case clause.
  defp match_raise_clause do
    unmatched = {:mutare_unmatched, [], nil}
    raise_fun = {:., [], [{:__aliases__, [], [:Kernel]}, :raise]}
    match_error = {:__aliases__, [], [:"Elixir", :MatchError]}
    raise_node = {raise_fun, [], [match_error, [term: unmatched]]}
    {:->, [], [[unmatched], raise_node]}
  end

  # The selector catch-all for a rewritten match: record the hosted ids (inert outside the
  # probe), then run the baseline inner case. Mirrors `catch_all_clause/3`.
  defp match_catch_all(ids, baseline_case, var) do
    body = {:__block__, [], [Recorder.record_ast(ids, var), baseline_case]}
    {:->, [], [[Recorder.catch_all_pattern(var)], body]}
  end

  # === binding-escaping macro pattern mutation: tuple re-export ==============

  # Rewrite a binding-escaping known-macro call (`destructure([x, y], v)`, declared
  # `:binding_pattern`) in a value-discarded position so its pattern arg can be mutated. The
  # `emit_match_site/3` mechanism with the inner `case rhs do <pat> -> {x, y} end` generalized
  # to running the macro itself: the macro does the binding, those bindings escape, so — like a
  # `=` — the call can't be wrapped in a selector (the bindings would be trapped in the branch).
  # The bound variables are re-exported through a tuple and rebound outside:
  #
  #     {x, y} =
  #       case <sel> do
  #         <id> -> destructure(<mutated_pat>, v); {x, y}            # one per mutant (raw value)
  #         mutare_active ->
  #           <record ids>
  #           destructure(<pat>, v); {x, y}                          # baseline (emitted value)
  #       end
  #
  # `node` is the already-emitted macro/pipe call (nested mutations in the value arg in place),
  # used for the baseline branch; each mutant branch runs `candidate.mutant_expr` (the *raw*
  # call with the mutated pattern). Mirrors `emit_match_site/3` for id claiming, coverage, the
  # shared export tuple, and the all-poisoned fallback.
  defp emit_macro_pattern_site(node, candidates, ctx) do
    %Candidate.MacroPattern{export: export} = hd(candidates)
    baseline = strip_candidates(node)

    emit_binding_site(node, export, candidates, ctx,
      mutant_body: fn c -> macro_pattern_branch(c.mutant_expr, export) end,
      catch_all: fn ids -> macro_pattern_catch_all(ids, baseline, export, ctx.active_var) end
    )
  end

  # One selector branch body: run the macro (binding the pattern's vars into the branch
  # scope), then yield the shared export tuple for the outer rebind. `{macro; export}`.
  defp macro_pattern_branch(macro_call, export),
    do: {:__block__, [], [macro_call, export]}

  # The selector catch-all for a rewritten binding-pattern macro: record the hosted ids
  # (inert outside the probe), run the baseline (emitted) macro, then yield the export.
  defp macro_pattern_catch_all(ids, baseline, export, var) do
    body = {:__block__, [], [Recorder.record_ast(ids, var), baseline, export]}
    {:->, [], [[Recorder.catch_all_pattern(var)], body]}
  end

  # === case clause-pattern mutation: tuple-the-scrutinee =====================

  # Rewrite a `case` so its clause patterns/guards can be mutated *per clause* (the C+M
  # analogue of head lifting). The subject is tupled with the active id, and each mutant
  # adds **one** clause — `{<active>, <mutant_pattern>} when <active> === <id> [and
  # <mutant_guard>] -> <raw_body>` — placed before its original, which is gated `when
  # <active> !== <its ids>` to step aside when the mutant is active:
  #
  #     case {:persistent_term.get(:mutare_active, 0), <subject>} do
  #       {mutare_active, <mut_pat>} when mutare_active === <id> -> <raw_body>   # one per mutant
  #       {mutare_active, <orig_pat>} when mutare_active !== <id> ->             # original (gated)
  #         <record all ids>; <emitted_body>
  #       …
  #     end
  #
  # Precedence is preserved (each mutant sits immediately before its own original), so a
  # changed/broadened pattern shadows exactly what the source mutant would. Mutant clauses
  # use the **raw** body (only one mutant is ever active, so a body selector there could
  # never fire); originals keep their **emitted** body (selectors intact) and prepend the
  # coverage record of the *full* id-set — whichever original matches at baseline records
  # them all, so a mutant killable by a value that matches a *different* clause is still
  # attributed (the probe runs at baseline). Every clause binds `mutare_active` and uses it
  # (originals via the record, mutants via the gate), so there is no unused-variable warning.
  #
  # A **non-exhaustive** source `case` needs one more clause. Without the rewrite an unmatched
  # subject raised `CaseClauseError` on the *bare* subject; the tupled subject would instead
  # fall through as `{active, subject}` — raising on the *wrong* term **and**, fatally, running
  # no clause body, so the coverage record never fires and a pattern mutant that *would* make
  # the value match is wrongly scored `:no_coverage` (at baseline the value falls through, so
  # the probe never attributes the ids). So a trailing `{<active>, mutare_unmatched} -> <record
  # all ids>; Kernel.raise(Elixir.CaseClauseError, term: mutare_unmatched)` clause restores
  # both: it records the hosted ids and re-raises the original error on the bare subject
  # (`case_unmatched_clause/2`). It is omitted when an original clause is already an
  # unconditional catch-all (`exhaustive_clauses?/2`) — the subject can never fall through, so
  # the clause would be unreachable and Elixir would warn "cannot match".
  #
  # Mirrors `emit_function_plan/2` for gating and `emit_match_site/3` for the all-poisoned
  # fallback.
  defp emit_case_pattern_site(node, candidates, ctx) do
    {:case, meta, [emitted_subject, [{do_key, emitted_clauses}]]} = strip_candidates(node)
    var = ctx.active_var

    {claimed, ctx} =
      Enum.flat_map_reduce(candidates, ctx, fn candidate, ctx ->
        claim_id(ctx, candidate, &in_place_site/3, fn id, candidate ->
          {id, candidate.clause_index, case_mutant_clause(id, candidate, var)}
        end)
      end)

    # Every mutation here skipped (poisoned) → no rewrite; emit the case unchanged.
    case claimed do
      [] ->
        {{:case, meta, [emitted_subject, [{do_key, emitted_clauses}]]}, ctx}

      _ ->
        all_ids = Enum.map(claimed, fn {id, _i, _c} -> id end)
        excluded = Enum.group_by(claimed, fn {_id, i, _c} -> i end, fn {id, _i, _c} -> id end)
        mutants = Enum.group_by(claimed, fn {_id, i, _c} -> i end, fn {_id, _i, c} -> c end)

        rewritten =
          emitted_clauses
          |> Enum.with_index()
          |> Enum.flat_map(fn {emitted_clause, index} ->
            original =
              case_original_clause(emitted_clause, Map.get(excluded, index, []), all_ids, var)

            Map.get(mutants, index, []) ++ [original]
          end)

        new_clauses =
          if exhaustive_clauses?(emitted_clauses, excluded),
            do: rewritten,
            else: rewritten ++ [case_unmatched_clause(all_ids, var)]

        subject = {selector_subject(ctx), emitted_subject}
        {{:case, meta, [subject, [{do_key, new_clauses}]]}, ctx}
    end
  end

  # One mutant clause: `{<active>, <mutant_pattern>} when <active> === <id> [and
  # <mutant_guard>] -> <raw_body>`. The first tuple element binds `mutare_active` (used in
  # the gate); `and_into_guard/2` ANDs the `=== <id>` gate into the clause's own (possibly
  # `nil`) guard.
  defp case_mutant_clause(id, %Candidate.CaseClause{} = c, var) do
    tuple = {Recorder.catch_all_pattern(var), c.mutant_pattern}
    gate = {:===, [], [Recorder.catch_all_pattern(var), id_literal(id)]}
    head = {:when, [], [tuple, and_into_guard(gate, c.mutant_guard)]}
    {:->, [], [[head], c.raw_body]}
  end

  # One original clause: `{<active>, <orig_pattern>} when <active> !== <its ids> [and
  # <orig_guard>] -> <record all ids>; <emitted_body>`. With no exclusions and no source
  # guard the head is the bare tuple (`mutare_active` still used by the record). The record
  # prepends the *full* id-set (see `emit_case_pattern_site/3`).
  defp case_original_clause(emitted_clause, excluded_ids, all_ids, var) do
    {clause_meta, pattern, orig_guard, body} = emitted_clause_parts(emitted_clause)
    tuple = {Recorder.catch_all_pattern(var), pattern}
    guard = merge_guards(exclusion_guard(excluded_ids, var), orig_guard)
    head = if guard, do: {:when, [], [tuple, guard]}, else: tuple
    record_body = {:__block__, [], [Recorder.record_ast(all_ids, var), body]}
    {:->, clause_meta, [[head], record_body]}
  end

  # The trailing unmatched fallback for a non-exhaustive tupled `case`: `{<active>,
  # mutare_unmatched} -> <record all ids>; Kernel.raise(Elixir.CaseClauseError, term:
  # mutare_unmatched)`. The first tuple element binds `mutare_active` (used by the record) and
  # `mutare_unmatched` binds the *bare* subject (used by the raise), so neither warns unused; it
  # both attributes the hosted ids at baseline (else a value that matches no original clause
  # falls through recording nothing, scoring a re-targeting mutant `:no_coverage`) and re-raises
  # the same `CaseClauseError` the original `case` did, on the original term. `Kernel.raise` is
  # qualified and `Elixir.CaseClauseError` absolute so the raise is independent of the target's
  # imports/aliases (the rationale `match_raise_clause/0` spells out); `mutare_unmatched` is a
  # case-clause-local pattern var, so a fixed name can't capture or collide.
  defp case_unmatched_clause(all_ids, var) do
    unmatched = {:mutare_unmatched, [], nil}
    tuple = {Recorder.catch_all_pattern(var), unmatched}
    raise_fun = {:., [], [{:__aliases__, [], [:Kernel]}, :raise]}
    case_clause_error = {:__aliases__, [], [:"Elixir", :CaseClauseError]}
    raise_node = {raise_fun, [], [case_clause_error, [term: unmatched]]}
    body = {:__block__, [], [Recorder.record_ast(all_ids, var), raise_node]}
    {:->, [], [[tuple], body]}
  end

  # Whether the rewritten clause list already matches every subject — an original clause is an
  # unconditional catch-all (an irrefutable pattern, no source guard) that the rewrite leaves
  # ungated (no mutant excludes it). When so the subject can never fall through, so the unmatched
  # fallback would be an unreachable clause (Elixir warns "cannot match"); otherwise the subject
  # may fall through and the fallback is needed (see `emit_case_pattern_site/3`).
  defp exhaustive_clauses?(emitted_clauses, excluded) do
    emitted_clauses
    |> Enum.with_index()
    |> Enum.any?(fn {clause, index} ->
      {_meta, pattern, guard, _body} = emitted_clause_parts(clause)
      irrefutable_pattern?(pattern) and is_nil(guard) and Map.get(excluded, index, []) == []
    end)
  end

  # A pattern that matches any value: `_`, `_name`, or a plain variable — the only nodes shaped
  # `{atom_name, _meta, atom_context}`. Anything structured (a literal `{:__block__, _, […]}`, a
  # tuple/map/struct, a pin, a call) carries a *list* in that slot, so is refutable — *except* a
  # **match chain** `a = b = … = z` (`{:=, _, [lhs, rhs]}`, possibly nested), which is irrefutable
  # exactly when every operand is: `x = _ = y` binds three names and matches anything, but `x = {1,
  # 2}` (refutable rhs) or `^x = y` (a pin) is not. The `:=` node carries a *list* in its third
  # slot, so it falls past the variable clause to the recursive one.
  defp irrefutable_pattern?({name, _meta, ctx}) when is_atom(name) and is_atom(ctx), do: true

  defp irrefutable_pattern?({:=, _meta, [lhs, rhs]}),
    do: irrefutable_pattern?(lhs) and irrefutable_pattern?(rhs)

  defp irrefutable_pattern?(_), do: false

  # Deconstruct an (already-emitted) `case` clause into `{meta, pattern, guard | nil, body}`.
  # A `case` clause has a single pattern; its guard (if any) is the last `when` arg (patterns
  # aren't mutated in place and guards are pruned by the analyzer, so both are the originals).
  defp emitted_clause_parts({:->, meta, [[{:when, _wm, when_args}], body]})
       when length(when_args) >= 2 do
    {patterns, [guard]} = Enum.split(when_args, -1)
    {meta, hd(patterns), guard, body}
  end

  defp emitted_clause_parts({:->, meta, [[pattern], body]}), do: {meta, pattern, nil, body}

  # The selector-branch value for an in-place candidate. A `CasePattern` (and a `RescueDrop`)
  # carries the whole mutated construct (`replacement`); for every other in-place candidate the
  # branch *is* its `mutated` node (an operator swap, a return constant).
  defp branch_node(%Candidate.CasePattern{replacement: replacement}), do: replacement
  defp branch_node(%Candidate.RescueDrop{replacement: replacement}), do: replacement
  defp branch_node(candidate), do: candidate.mutated

  # The single owner of the id-claim + site-record dance that poison recovery
  # leans on. Both the in-place path (emit_site/3) and the lifted path
  # (emit_function_plan/2) route every candidate through here, so ids advance
  # identically — even for a skipped (poisoned) id — and stay stable across
  # rebuilds. Keeping this in one place is what stops the two paths from drifting
  # out of lockstep.
  #
  # `site_fn.(id, candidate, file)` builds the %Site{}; `emit_fn.(id, candidate)`
  # builds the artifact (an in-place `->` clause, or a lifted `{id, defs}` pair).
  # Returns `{[], ctx}` for a poisoned id (site recorded, nothing emitted) or
  # `{[artifact], ctx}` otherwise — list-shaped to drop into a `flat_map_reduce`.
  defp claim_id(ctx, candidate, site_fn, emit_fn) do
    id = ctx.next_id
    site = site_fn.(id, candidate, ctx.file)
    ctx = %{ctx | next_id: id + 1}

    if id in ctx.skip_ids do
      {[], %{ctx | sites: [poison(site) | ctx.sites]}}
    else
      {[emit_fn.(id, candidate)], %{ctx | sites: [site | ctx.sites]}}
    end
  end

  defp poison(%Site{} = site), do: %{site | poisoned: true}

  # (case <subject> do <id> -> <mutated> ; <var> -> <record>; <default> end)
  #
  # `<subject>` is the hoisted active-id variable when it is bound in scope, else the
  # self-contained `:persistent_term.get(...)` read (`selector_subject/1`). The selector
  # is `Render.block_wrap`ped so it renders safely in any position.
  defp build_case(default_node, mutant_clauses, ctx) do
    selector = selector_subject(ctx)
    ids = for {:->, _, [[id], _]} <- mutant_clauses, do: id
    catch_all = catch_all_clause(ids, default_node, ctx.active_var)
    case_node = {:case, [], [selector, [do: mutant_clauses ++ [catch_all]]]}
    Render.block_wrap(case_node)
  end

  # The selector `case` scrutinee for the current emit scope. When the active-id variable
  # is already bound here (`active_bound` — inside a lifted base clause, where the
  # dispatcher threads it as the first parameter, or inside a non-lifted function's `:do`
  # block, where a prologue binds it once), every selector reads that variable directly —
  # the active id is process-constant, so reading it once per function activation is
  # identical and drops the per-site `:persistent_term.get` (see NOTES "Hoist the per-site
  # active-id read"). Otherwise the self-contained inline read is kept: a module/scaffold
  # body, a head's default-value position (evaluated in a generated head clause out of any
  # binding's scope), or — `module_depth > 0` — a selector inside a runtime nested
  # `defmodule` in this body, whose inner `def` can't see the outer function's binding.
  defp selector_subject(%Ctx{active_bound: true, module_depth: 0, active_var: var}),
    do: {var, [], nil}

  defp selector_subject(%Ctx{}), do: Mutare.Metamutant.subject_ast()

  # The active-id prologue a non-lifted function's `:do` block is prefixed with:
  # `<var> = :persistent_term.get(...)`, bound once so the block's selectors read it
  # (`selector_subject/1`). Shape-identical to the lifted dispatcher's read.
  defp active_read(var),
    do: {:=, [], [Recorder.catch_all_pattern(var), Mutare.Metamutant.subject_ast()]}

  # The selector catch-all (`<var> -> …`): the baseline + every-inactive-mutant
  # branch. It carries the coverage record (inert outside the probe, see
  # `Mutare.Coverage.Recorder`) *before* the original, so the original stays the
  # clause's last expression — preserving tail position / LCO in the dispatcher.
  # With no ids to attribute (an all-poisoned lifted group) there is nothing to
  # record, so the plain `_ ->` is emitted unchanged.
  defp catch_all_clause([], default_node, _var), do: {:->, [], [[{:_, [], nil}], default_node]}

  defp catch_all_clause(ids, default_node, var) do
    body = {:__block__, [], [Recorder.record_ast(ids, var), default_node]}
    {:->, [], [[Recorder.catch_all_pattern(var)], body]}
  end
end
