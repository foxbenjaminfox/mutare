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
    * `Mutare.Transform.Candidate` — the typed, pre-id description of a single
      mutant. One struct per legal kind (see that module's moduledoc for the current
      set), so the redundant `context`/`kind`/`operation` triple (and its illegal
      combinations) is gone.

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
  candidates). This module owns the top-level emission walk and the lifted-function
  orchestrator; focused delivery modules own the smaller specialized paths, with shared
  selector mechanics factored through `SelectorEmit`.

  Focused helper modules keep the pure node-building and the smaller specialized
  delivery paths out of this file:

    * `Mutare.Transform.ClauseAST` — the shared `def`/`defp` clause shape and the
      primitives that navigate it (head/args/guards/`when`), used by both this
      module and `FunctionPlan`.
    * `Mutare.Transform.GuardBuild` — the dispatch guards (`<var> === <id>` gate,
      exclusion, `and`-into), shared by the lifted and `case` paths.
    * `Mutare.Transform.LiftedEmit` — the dispatcher + gated base clauses for a
      lifted group (the assembly half of `emit_function_plan/2`).
    * `Mutare.Transform.CaseClauseEmit` — the tuple-the-scrutinee delivery for
      per-clause `case` pattern/guard mutants.
    * `Mutare.Transform.BindingEscapeEmit` — the tuple-export delivery for binding
      escaping `=` matches and known macros.
    * `Mutare.Transform.HostedEmit` — the selector-host delivery for hosted DSL
      fragments.
    * `Mutare.Transform.ImportWitness` — the dead-code import witness spliced
      alongside a mutated bare imported call.
    * `Mutare.Transform.SelectorEmit` — the shared id/site claim, selector
      subject, catch-all coverage branch, and ordinary selector-case assembly.
  """

  alias Mutare.AST
  alias Mutare.Coverage.Recorder
  alias Mutare.Site
  alias Mutare.Mutator.Spec

  alias Mutare.Transform.{
    Analyze,
    Behaviours,
    BindingEscapeEmit,
    Candidate,
    Candidate.Delivery,
    CaseClauseEmit,
    Ctx,
    FunctionPlan,
    HostedEmit,
    ImportWitness,
    LiftedEmit,
    MetaKeys,
    ModulePlan,
    Names,
    Overlap,
    Render,
    Resolve,
    SelectorEmit,
    Super,
    Uses
  }

  # The default set is the built-in catalog's `all/0` — one source of truth, so a
  # family registered in `Mutare.Mutators` is part of the default automatically.
  @default_mutators Mutare.Mutators.all()

  # The candidate-bearing meta keys `strip_candidates/1` clears once a node's candidates
  # are consumed. Canonical list (and the full registry) in `Mutare.Transform.MetaKeys`.
  @delivery_keys MetaKeys.delivery()

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
    * `:plugins` — list of `Mutare.Plugin` entries (third-party extensions), each a
      bare module or a `{module, opts}` pair. Their `macros/0` registrations merge into
      the macro registry and their `expand_use/3` overrides feed `use`-expansion (the
      plugin's `opts` ride along to `expand_use/3`'s context). Defaults to `[]`.
    * `:start_id` — first mutant id to assign (default `1`)
    * `:expand_uses` — when `true` (the default), expand module-level `use` statements with
      static args and feed their injected `import`/`alias` directives into resolution (see
      `Mutare.Transform.Uses`); `false` freezes the pre-expansion behaviour (and, with it, any
      plugin `use`-expansion overrides)
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
    names = Names.generated_names(parsed)

    ctx = %{
      ctx
      | prefix: names.prefix,
        active_var: names.active_var,
        super_var: names.super_var,
        piped_var: names.piped_var,
        cond_var: names.cond_var,
        # Prime the per-module mutator cache for the top-level (empty-behaviours) scope;
        # `put_behaviours/2` refreshes it at each `defmodule` boundary.
        analysis_mutators: enrich_mutators(ctx.mutators, ctx.behaviours)
    }

    # Third-party plugins (`Mutare.Plugin`): their `macros/0` extends the registry below and
    # their `expand_use/3` overrides `use`-expansion. Not mutators — they make the built-in
    # mutators' work land on a library's DSL (the Gettext case). Validated + resolved here at the
    # boundary (like `:mutators` above) to `Mutare.Plugin.Spec`s — carrying each plugin's `opts`,
    # delivered to `expand_use/3`'s context — so a non-plugin entry fails loudly rather than being
    # silently dropped by the downstream per-callback filters. `Mutare.Options` validates the same
    # way, so the `Mutare.run/2` path is covered too.
    plugins = opts |> Keyword.get(:plugins, []) |> Mutare.Plugin.validate!()

    # The known-macro registry (`Mutare.Macros`): built-ins (`Kernel.match?`/`destructure`)
    # merged with the declarative `:macros` option, any enabled mutator's `macros/0`, and any
    # enabled plugin's `macros/0`. It tells the resolution pass how to route a recognised
    # macro's arguments (a pattern, an opaque DSL body). Built from the resolved mutator specs
    # in `ctx`, so a library's mutator/plugin auto-registers the macros it relies on. The plugin
    # *specs* are passed straight through (`build/3` reads each's `macros/0`); a `macros/0`
    # registration is opts-independent (a library fact), so the `opts` they carry are ignored there
    # and ride along separately to `expand_use/3`'s context.
    macros = Mutare.Macros.build(Keyword.get(opts, :macros, []), ctx.mutators, plugins)

    # Resolve `alias`es and `import`s in one lexical pass (`Mutare.Transform.Resolve`),
    # stamping each call with the module it refers to, so the call-matching mutators recognise
    # an aliased `S.upcase` as `String.upcase` and a bare imported `reject(xs, f)` (after
    # `import Enum`) as `Enum.reject`. The two interleave in source order (an `alias` can
    # rebind a later `import`'s module), which the single fold gets right by construction.
    # The same pass stamps each known-macro call with its argument routing. `parsed` itself
    # stays pristine for the comment-based ignore scan below.
    #
    # First, surface directives hidden behind `use` (`Mutare.Transform.Uses`): a module-level
    # `use MyAppWeb, :controller` / `use Ecto.Schema` is expanded in-process and the
    # `import`/`alias` it injects is stamped onto the `use` node, so `Resolve` resolves the
    # calls (and DSL macros) that depend on it. Stamps only meta, so `parsed` stays usable for
    # the ignore scan; degrades to a no-op when a `use` can't be expanded.
    expanded =
      if Keyword.get(opts, :expand_uses, true), do: Uses.annotate(parsed, plugins), else: parsed

    # Gather each module's `@behaviour` set (direct + `use`-injected) and stamp it on the
    # `defmodule` nodes (`Mutare.Transform.Behaviours`), so a behaviour-aware custom mutator
    # can gate on it. Runs after `Uses` (to see the injected behaviours) and before
    # `Resolve` (which preserves the stamp); `transform_node` reads it per module.
    with_behaviours = Behaviours.annotate(expanded)

    {transformed, ctx} = transform_node(Resolve.annotate(with_behaviours, macros), ctx)

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
        do_keyword = AST.update_do_block(do_keyword, &prepend_statement(&1, attr))
        {form, meta, init ++ [do_keyword]}

      other ->
        other
    end)
  end

  defp prepend_statement({:__block__, meta, stmts}, attr), do: {:__block__, meta, [attr | stmts]}
  defp prepend_statement(single, attr), do: {:__block__, [], [attr, single]}

  # === module / statement structure =========================================

  # A module: transform the body of its do-block(s). The module's `@behaviour` set (stamped
  # by `Mutare.Transform.Behaviours`) is bound on `ctx` for the body and restored on the way
  # out, so it folds onto the specs handed to analyze/plan (`put_behaviours/2` refreshes the
  # cached enriched list) while the body is walked. Behaviours don't inherit, so a nested
  # module that re-enters here overwrites and then restores the outer set.
  defp transform_node({:defmodule, meta, [alias_node, do_keyword]}, ctx)
       when is_list(do_keyword) do
    outer = ctx.behaviours
    outer_mutators = ctx.analysis_mutators

    {do_keyword, ctx} =
      transform_do_keyword(do_keyword, put_behaviours(ctx, Behaviours.behaviours(meta)))

    {{:defmodule, meta, [alias_node, do_keyword]},
     %{ctx | behaviours: outer, analysis_mutators: outer_mutators}}
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

  defp transform_do_keyword(keyword, ctx),
    do: AST.update_do_block_reduce(keyword, ctx, &transform_body/2)

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
    |> ModulePlan.build(ctx.analysis_mutators, ctx.file)
    |> emit_module_plan(ctx)
  end

  # Enter a module scope: bind its `@behaviour` set and refresh the cached, behaviour-
  # enriched mutator list (`ctx.analysis_mutators`) the analyze/plan call sites read.
  # `behaviours` changes only here (and is restored on the way out), so the enrichment —
  # one fold over ~all mutators — happens once per module scope rather than once per
  # clause/statement.
  defp put_behaviours(ctx, behaviours) do
    %{ctx | behaviours: behaviours, analysis_mutators: enrich_mutators(ctx.mutators, behaviours)}
  end

  # Fold a `@behaviour` set onto each spec, so it carries the behaviours to every leaf
  # where a mutator runs (`Mutator.Dispatch.mutations/3`, the structural callbacks) and a
  # behaviour-aware mutator sees `context.behaviours` without any new threading. The base
  # `ctx.mutators` stays untouched (the empty-behaviours config); this enrichment is the
  # one place per-module context meets the spec list. Outside any module `behaviours` is
  # empty, so the specs pass through carrying the empty set.
  defp enrich_mutators(mutators, behaviours) do
    Enum.map(mutators, &%{&1 | behaviours: behaviours})
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
  # (`emit_clause/3`'s `lifted?: false`); the head's default values and the other body
  # blocks keep the self-contained `:persistent_term` read (out of the prologue's scope).
  defp in_place_clauses(clauses, ctx), do: emit_clauses(clauses, ctx, false)

  # Transform each *source* clause of a lifted group (the originals the dispatcher
  # forwards to). The dispatcher threads the active id as the base clause's first
  # parameter, so the whole body reads it directly (no prologue, every body block
  # covered); only the head's default values — extracted onto the dispatcher head, out of
  # any binding's scope — keep the self-contained read.
  defp lifted_source_clauses(clauses, ctx), do: emit_clauses(clauses, ctx, true)

  # Emit each clause in turn, threading `ctx`. `lifted?` selects the active-id read
  # strategy (`emit_clause/3`): hoisted-to-a-prologue for an in-place `:do` block, or
  # dispatcher-threaded for a lifted base clause.
  defp emit_clauses(clauses, ctx, lifted?) do
    Enum.flat_map_reduce(clauses, ctx, fn clause, ctx ->
      {clause, ctx} = emit_clause(clause, ctx, lifted?)
      {[clause], ctx}
    end)
  end

  # Emit one def/defp clause with the active-id read hoisted out of its per-site selectors.
  # `lifted?` is the clause kind: a lifted base clause reads the id from the dispatcher's
  # threaded parameter (in scope across every body block), a non-lifted clause binds it in a
  # `:do`-block prologue (in scope in `:do` only). The head (default values) is emitted with
  # the read *unbound* either way (those expressions run in a generated head clause where no
  # binding is in scope), the body with it bound where the binding reaches. The one-shot
  # `active_bound` toggles are scoped to this clause and restored on the way out, so they
  # never leak into the next module item.
  defp emit_clause(clause, ctx, lifted?) do
    bound0 = ctx.active_bound

    {emitted, ctx} =
      emit_annotated_clause(Analyze.annotate(clause, ctx.analysis_mutators), ctx, lifted?)

    {emitted, %{ctx | active_bound: bound0}}
  end

  # A normal body-bearing def/defp clause: emit the head with the read unbound, then the
  # body blocks (`emit_clause_body/3`).
  defp emit_annotated_clause({vis, meta, [head, body_kw]}, ctx, lifted?)
       when vis in [:def, :defp] and is_list(body_kw) do
    {head, ctx} = emit(head, %{ctx | active_bound: false})
    {body_kw, ctx} = emit_clause_body(body_kw, ctx, lifted?)
    {{vis, meta, [head, body_kw]}, ctx}
  end

  # A bodiless header (`def f(a, b \\ 1)` with no `do`) or any unexpected shape: no body
  # to hoist into, so emit the whole node with the read unbound — identical to the
  # pre-hoist behaviour. (A header's only runtime sub-positions are its default values,
  # which keep the self-contained read regardless.)
  defp emit_annotated_clause(node, ctx, _lifted?), do: emit(node, %{ctx | active_bound: false})

  # Emit each body block's value with the active-id read bound where the binding reaches:
  # the `:do` block always (a non-lifted clause's prologue binds it; a lifted clause's
  # dispatcher parameter is in scope there), and the other blocks (`rescue`/`catch`/`else`/
  # `after`) only for a lifted clause — there the parameter is in scope everywhere, whereas
  # a non-lifted clause's `:do`-block prologue is *not* visible in its sibling blocks, so
  # they keep the self-contained read. Block order (`:do` first) is preserved, so ids land
  # exactly as a single whole-clause emit would assign them. The `is_list` guard asserts
  # the caller's contract (`emit_annotated_clause/3` only reaches here for a list body_kw);
  # there is no fallback because a body-bearing def/defp clause always has a keyword body.
  defp emit_clause_body(body_kw, ctx, lifted?) when is_list(body_kw) do
    # A lifted clause's threaded parameter is in scope in every block (so every block reads the
    # bound var); a non-lifted clause's prologue binds the id in `:do` only, so its sibling blocks
    # keep the inline read and `:do` alone gets the prepended prologue.
    {body_kw, ctx} =
      Enum.map_reduce(body_kw, ctx, fn {key, value}, ctx ->
        bound = AST.key_atom(key) == :do or lifted?
        {value, ctx} = emit(value, %{ctx | active_bound: bound})
        {{key, value}, ctx}
      end)

    {if(lifted?, do: body_kw, else: prepend_do_prologue(body_kw, ctx.active_var)), ctx}
  end

  # Prepend `<var> = :persistent_term.get(...)` to the `:do` block — but only when that
  # block actually references the hoisted variable (i.e. it spliced at least one hoisted
  # selector). With no reference the binding would draw an "unused variable" warning, so
  # an unmutated `:do` block is left untouched.
  defp prepend_do_prologue(body_kw, var) do
    Enum.map(body_kw, fn {key, value} = pair ->
      if AST.key_atom(key) == :do and references_var?(value, var),
        do: {key, prepend_statement(value, LiftedEmit.active_read(var))},
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
      emit_block_macro(node, ctx)
    else
      node |> Analyze.scaffold(ctx.analysis_mutators) |> emit(ctx)
    end
  end

  # An unknown module-level block macro (`custom_dsl do … end`): its `do` body is
  # analyzed as runtime on the guess a DSL unquotes it into a function, but the
  # injected selector `case` may be illegal in the DSL and poison the single build.
  # Tag every site the body produces with this invocation's identity so poison
  # recovery can skip the *whole* block at once (`Mutare.Runner.escalate_block_poison/3`,
  # on the block's second strike) — the runtime-stable equivalent of `:skip` — rather than
  # dropping one mutant at a time and re-hitting the next selector. A *registered* macro is left
  # untagged (`tag` is `nil`), so the user's `:macros` choice is honoured and never auto-skipped.
  #
  # Sites accumulate newest-first (`SelectorEmit.claim_items/4` prepends), so the ones
  # this `emit` created are exactly the head of `ctx.sites` above the count we held before it.
  defp emit_block_macro(node, ctx) do
    before = length(ctx.sites)

    {emitted, ctx} =
      node |> Analyze.analyze_module_macro_block(ctx.analysis_mutators) |> emit(ctx)

    {emitted, tag_block_macro_sites(ctx, before, block_macro_tag(node))}
  end

  # The per-invocation tag for an unknown block macro: `{name, nid}`, or `nil` for a
  # registered one. The bare name alone would group *every* `custom_dsl do … end` in the
  # file together, so a poison in one block would wrongly suppress a sibling block of the
  # *same* macro that expands differently (`guarded :guard do …` splices into a guard,
  # `guarded :body do …` into a body). The statement node's stable `nid` (the same
  # DFS-counter identity `Overlap` uses — injective, unlike a Sourceror range, and stable
  # across rebuilds) makes the tag per-invocation; the name rides along for readability.
  defp block_macro_tag(node) do
    case Analyze.unknown_block_macro_name(node) do
      nil -> nil
      name -> {name, Resolve.nid(node)}
    end
  end

  # A registered macro (or one that produced no sites) needs no tagging.
  defp tag_block_macro_sites(ctx, _before, nil), do: ctx

  defp tag_block_macro_sites(ctx, before, tag) do
    {new, prior} = Enum.split(ctx.sites, length(ctx.sites) - before)
    %{ctx | sites: Enum.map(new, &%{&1 | block_macro: tag}) ++ prior}
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
    base = :"#{LiftedEmit.base_name(name, arity, group, ctx.prefix)}"
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
      SelectorEmit.claim_items(
        FunctionPlan.candidates(plan),
        ctx,
        &Delivery.site/3,
        fn id, candidate ->
          {index, clause} = FunctionPlan.mutated_clause(plan, candidate)
          {id, index, clause, ImportWitness.for_candidate(candidate)}
        end
      )

    mut_ids = Enum.map(claimed, fn {id, _i, _c, _w} -> id end)

    # Default arguments (`def f(a, b \\ 1)`) expand to multiple arities. They stay
    # on the public dispatcher — which keeps the original arity contract — while the
    # base function takes the full arity with `\\` stripped (`clause_parts`). The
    # default *expressions* are taken from the already-emitted clauses, so their
    # in-place selectors ride along and the dispatcher keeps mutating its defaults.
    defaults = LiftedEmit.clause_defaults(orig_clauses)

    base_clauses = LiftedEmit.build_base_clauses(orig_clauses, claimed, base, var, super_var)

    dispatcher =
      LiftedEmit.build_dispatcher(vis, name, arity, mut_ids, base, var, defaults, super_var)

    {[dispatcher | base_clauses], ctx}
  end

  # === in-place transform: analyze (annotate) then assign/emit ===============

  # Apply the in-place selector transform to one subtree: annotate mutating body
  # nodes with their candidates, then emit selectors as ids are assigned.
  defp in_place(node, ctx) do
    node
    |> Analyze.annotate(ctx.analysis_mutators)
    |> emit(ctx)
  end

  defp candidates_of(node), do: meta_candidates(node, :mutare)

  # The per-clause `Candidate.CaseClause`s a `case` node carries (the tuple-the-scrutinee
  # path), kept under a dedicated meta key separate from `:mutare` because they drive a
  # different emit (rewriting the `case`, not wrapping the node in a selector).
  defp case_candidates_of(node), do: meta_candidates(node, :mutare_case)

  # The `Candidate.Hosted`s a known-macro node carries (the selector-host path), under a
  # dedicated meta key — like `:mutare_case`, a different emit (weaving a host-supplied selector
  # into the node) than the node-wrapping `:mutare` selectors.
  defp hosted_candidates_of(node), do: meta_candidates(node, :mutare_hosted)

  # Read a node's candidate list stored under `key` in its metadata; `[]` for a node with no
  # metadata (a bare atom/literal) or no candidates of that kind. The three delivery keys
  # (`:mutare`, `:mutare_case`, `:mutare_hosted`) each drive a different emit but share this read.
  defp meta_candidates({_form, meta, _args}, key) when is_list(meta),
    do: Keyword.get(meta, key, [])

  defp meta_candidates(_, _), do: []

  defp strip_candidates({form, meta, args}) when is_list(meta),
    do: {form, Keyword.drop(meta, @delivery_keys), args}

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
  # `SelectorEmit.subject/1` falls back to the inline read inside it); leaving is handled in the
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
    # A known-macro node carrying `Candidate.Hosted`s weaves a host-supplied selector into the
    # DSL fragment(s) (`HostedEmit.emit/5`), so it is checked first: it is the only path that
    # delivers a `:hosted` argument's mutations, and it also picks up any whole-node `:mutare`
    # mutations the same node carries.
    case hosted_candidates_of(current) do
      [] ->
        emit_one_unhosted(current, ctx)

      hosted ->
        HostedEmit.emit(
          current,
          hosted,
          gate_candidates(candidates_of(current)),
          ctx,
          &emit_hosted_inplace/3
        )
    end
  end

  # Dispatch a node's candidates to the selector-emitting path classified by the candidate
  # delivery table. `Candidate.Delivery` owns which variant goes to which path; the selected
  # delivery module owns any specialized assembly.
  defp emit_one_unhosted(current, ctx) do
    case delivery_route(current) do
      # A `case` carrying per-clause `CaseClause`s is rewritten by the tuple-the-scrutinee path
      # (its clauses can't each host a selector, and a `case` isn't a liftable function group).
      {:case_clause, candidates} ->
        CaseClauseEmit.emit(current, candidates, ctx)

      # A `=`-match in statement position → a tuple-export selector (its bindings must escape,
      # so it can't be wrapped like an ordinary node).
      {:match_pattern, candidates} ->
        BindingEscapeEmit.match_site(current, candidates, ctx)

      # A binding-escaping known macro (`destructure([x, y], v)`) in a value-discarded position
      # → the same tuple-export selector, but each branch runs the *macro* (with the
      # original/mutated pattern) instead of a `case` match.
      {:macro_pattern, candidates} ->
        BindingEscapeEmit.macro_pattern_site(current, candidates, ctx)

      # Every other in-place kind shares the ordinary wrap-in-a-selector path.
      {:in_place, candidates} ->
        emit_site(current, candidates, ctx)

      # No deliverable candidates. A `|>` never carries candidates itself, but its
      # already-emitted RHS may now be a selector `case` — illegal as a pipe target — so
      # rewrite it here. `strip_candidates` clears any meta left by candidates the gate dropped
      # (a no-op when there were none), so the node renders clean.
      :none ->
        {hoist_pipe(strip_candidates(current), ctx), ctx}
    end
  end

  # A `case`'s per-clause `:mutare_case` candidates dominate and are never gated; otherwise
  # `:mutare` candidates are gated before the candidate delivery table classifies them.
  defp delivery_route(node) do
    case case_candidates_of(node) do
      [] ->
        node |> candidates_of() |> gate_candidates() |> Delivery.classify()

      case_candidates ->
        Delivery.classify(case_candidates)
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
  defp hoist_pipe({:|>, meta, [lhs, rhs]} = node, ctx) do
    # Recognise a block-wrapped selector `case` as the pipe's RHS (the shape
    # `SelectorEmit.selector_case/3` produces, owned by `Render.selector_case/2`), then confirm its
    # subject in *either* shape — the inline `:persistent_term` read (a head-default
    # pipe stage) or the hoisted bare active-id variable (a body pipe stage). The
    # closure body references that variable (the hoisted form) or the inline read,
    # both valid inside the immediately-invoked closure.
    with {:ok, subject, clauses} <- Render.selector_case_parts(rhs),
         true <- Mutare.Metamutant.subject?(subject, ctx.active_var) do
      var = {ctx.piped_var, [], nil}

      piped =
        Enum.map(clauses, fn {:->, m, [pat, body]} -> {:->, m, [pat, pipe_tail(var, body)]} end)

      closure = {:fn, [], [{:->, [], [[var], Render.selector_case(subject, piped)]}]}
      invocation = {{:., [], [closure]}, [], []}
      {:|>, meta, [lhs, invocation]}
    else
      _ -> node
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
      SelectorEmit.claim_items(candidates, ctx, &Delivery.site/3, fn id, candidate ->
        {:->, [],
         [
           [id],
           candidate
           |> Delivery.selector_branch()
           |> ImportWitness.wrap(ImportWitness.for_candidate(candidate))
         ]}
      end)

    # `hoist_pipe`: when this node is itself a `|>` (e.g. its tail carries a
    # ReturnValue candidate) whose RHS is an already-emitted selector, the selector
    # would sit illegally as a pipe target inside this default/catch-all — hoist the
    # pipe into it. A no-op for every other node shape.
    default = hoist_pipe(strip_candidates(node), ctx)

    # All mutations here skipped → no selector; emit the node unchanged.
    case clauses do
      [] -> {default, ctx}
      _ -> {pin_if_needed(SelectorEmit.selector_case(default, clauses, ctx), candidates), ctx}
    end
  end

  # A `:pinned` in-place candidate's selector must be **`^`-pinned**: the value sits in a
  # compile-time DSL position (an Ecto keyword-shorthand value) that accepts `^(case …)` but
  # rejects a bare `case`. The `:pinned` route flags *every* in-place candidate on the node, so
  # a pinned value carries only pinned candidates and wrapping the whole built selector is sound.
  # No pinned candidate ⇒ the selector is returned untouched (every existing site is unaffected).
  defp pin_if_needed(case_node, candidates) do
    if Enum.any?(candidates, &match?(%Candidate.InPlace{pin?: true}, &1)),
      do: {:^, [], [case_node]},
      else: case_node
  end

  # Deliver any whole-node `:mutare` mutations the hosted macro *also* carries, now that the
  # hosted selectors are woven into `spliced`. The dispatch mirrors `emit_one_unhosted/2`'s
  # inner one: a **binding-escaping** known macro (`destructure`-like, routed `:binding_pattern`)
  # in a value-discarded position carries `Candidate.MacroPattern`s whose bindings must escape
  # through a tuple — they *can't* ride an ordinary node-wrapping selector (it would trap the
  # bindings in a branch, and emit a bare mutated-pattern AST as the branch body), so they take
  # the tuple-export path (`BindingEscapeEmit.macro_pattern_site/3`), whose baseline branch is the
  # spliced macro — the hosted mutations still fire there. Everything else (an ordinary whole-call
  # `InPlace`, or none — the common case) rides an ordinary selector wrapping the spliced result
  # (`emit_site/3`, a no-op for `[]`). A macro node is never a `=`, so `MatchPattern` (the
  # `BindingEscapeEmit.match_site/3` kind) can't occur here.
  defp emit_hosted_inplace(spliced, [%Candidate.MacroPattern{} | _] = candidates, ctx),
    do: BindingEscapeEmit.macro_pattern_site(spliced, candidates, ctx)

  defp emit_hosted_inplace(spliced, candidates, ctx),
    do: emit_site(spliced, candidates, ctx)
end
