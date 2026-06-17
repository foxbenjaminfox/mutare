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
      candidates (`Candidate.Guard` / `Candidate.Pattern` / `Candidate.Drop`) it admits.
    * `Mutare.Transform.Candidate.{InPlace,Guard,Pattern,Drop}` — the typed, pre-id
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
  `case`), so when a mutated node is a **pipe stage**, emission hoists the pipe
  *into* the selector — each branch becomes `lhs |> <branch>` — so the `case` is a
  standalone expression (`hoist_pipe/1`). The Site still records the bare stage, so
  the diff is unchanged.

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

  alias Mutare.Site
  alias Mutare.Coverage.Recorder

  alias Mutare.Transform.{
    Aliases,
    Analyze,
    Candidate,
    Ctx,
    FunctionPlan,
    ModulePlan,
    Names,
    Render
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
    * `:mutators` — list of mutator modules (default arithmetic + relational)
    * `:start_id` — first mutant id to assign (default `1`)
  """
  @spec transform_string(String.t(), keyword()) :: {String.t(), [Site.t()], pos_integer()}
  def transform_string(source, opts \\ []) when is_binary(source) do
    ctx = %Ctx{
      file: Keyword.get(opts, :file, "nofile"),
      mutators: Keyword.get(opts, :mutators, @default_mutators),
      next_id: Keyword.get(opts, :start_id, 1),
      # Mutant ids to drop (e.g. compile-poisoning, found by the runner): their
      # site is still recorded (`poisoned: true`, for the denominator and id
      # stability) but no selector/copy is generated, so the metamutant compiles.
      skip_ids: Keyword.get(opts, :skip_ids, MapSet.new())
      # `group` and `sites` start at their struct defaults (0 / []).
    }

    parsed = Sourceror.parse_string!(source)
    # Pin the generated names this source provably never collides with before any
    # lifting assigns them: the private-function prefix and the dispatch variable
    # (see `Mutare.Transform.Names`).
    {prefix, active_var} = Names.generated_names(parsed)
    ctx = %{ctx | prefix: prefix, active_var: active_var}
    # Resolve `alias`es first, stamping each call's module position with the module it
    # refers to (`Mutare.Transform.Aliases`), so the call-matching mutators recognise an
    # aliased `S.upcase` as `String.upcase`. `parsed` itself stays pristine for the
    # comment-based ignore scan below.
    {transformed, ctx} = transform_node(Aliases.annotate(parsed), ctx)

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

  # Transform each clause in place (body selectors only), preserving its position.
  defp in_place_clauses(clauses, ctx) do
    Enum.flat_map_reduce(clauses, ctx, fn clause, ctx ->
      {clause, ctx} = in_place(clause, ctx)
      {[clause], ctx}
    end)
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
    cond do
      Analyze.module_scaffold_statement?(node) ->
        node |> Analyze.scaffold(ctx.mutators) |> emit(ctx)

      Analyze.module_macro_block_statement?(node) ->
        node |> Analyze.analyze_module_macro_block(ctx.mutators) |> emit(ctx)

      true ->
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

    # Source clauses with in-place body selectors — claims the body ids first.
    {orig_clauses, ctx} = in_place_clauses(plan.clauses, ctx)

    # Then the lifted candidates, in order, each claiming its id. Non-skipped ones
    # yield `{id, clause_index, mutated_clause | :drop}`; a skipped (poisoned) id
    # yields nothing here (its site is still recorded), so it is neither emitted as
    # a mutant clause nor excluded from its original — i.e. it behaves as baseline.
    {claimed, ctx} =
      Enum.flat_map_reduce(FunctionPlan.candidates(plan), ctx, fn candidate, ctx ->
        claim_id(ctx, candidate, &lifted_site/3, fn id, candidate ->
          {index, clause} = FunctionPlan.mutated_clause(plan, candidate)
          {id, index, clause}
        end)
      end)

    mut_ids = Enum.map(claimed, fn {id, _i, _c} -> id end)
    # Every claimed candidate overrides (guard/literal/structure) or drops its
    # clause, so its id excludes that clause's *original* version.
    excluded = Enum.group_by(claimed, fn {_id, i, _c} -> i end, fn {id, _i, _c} -> id end)

    lifted =
      orig_clauses
      |> Enum.with_index()
      |> Enum.flat_map(fn {orig, index} ->
        mutant_clauses =
          for {id, ^index, clause} <- claimed,
              clause != :drop,
              do: lifted_mutant(base, id, clause, var)

        mutant_clauses ++ [lifted_original(base, orig, Map.get(excluded, index, []), var)]
      end)

    {[build_dispatcher(vis, name, arity, mut_ids, base, var) | lifted], ctx}
  end

  # The public dispatcher: read the active mutant id once, record coverage for the
  # group's lifted ids (inert off the probe — see `Mutare.Coverage.Recorder`), then
  # tail-call the lifted function with the id threaded as the extra first argument.
  #   def f(mutare_arg1, ...) do
  #     mutare_active = :persistent_term.get(:mutare_active, 0)
  #     <record ids>
  #     <base>(mutare_active, mutare_arg1, ...)
  #   end
  defp build_dispatcher(vis, name, arity, mut_ids, base, var) do
    args = dispatcher_args(arity)
    var_node = Recorder.catch_all_pattern(var)
    read = {:=, [], [var_node, Mutare.Metamutant.subject_ast()]}
    call = {base, [], [var_node | args]}

    body =
      case mut_ids do
        [] -> {:__block__, [], [read, call]}
        ids -> {:__block__, [], [read, Recorder.record_ast(ids, var), call]}
      end

    {vis, [], [{name, [], args}, [do: body]]}
  end

  # One lifted *mutant* clause: the candidate's single mutated source clause,
  # renamed to `<base>`, given the `mutare_active` extra arg, and gated `when
  # mutare_active === <id> [and <its own guard>]`. Raw body (no in-place selectors):
  # only one mutant is ever active, so a body selector here could never fire.
  defp lifted_mutant(base, id, clause, var) do
    {clause_meta, call_meta, args, guards, body} = clause_parts(clause)
    gate = {:===, [], [Recorder.catch_all_pattern(var), id_literal(id)]}
    guard = and_into_guard(gate, combine_guards(guards))
    lifted_clause(base, clause_meta, call_meta, args, guard, body, var)
  end

  # One lifted *original* clause: the source clause (with its in-place body
  # selectors), renamed to `<base>`, given the `mutare_active` extra arg, and gated
  # `when mutare_active !== <id>` for each `id` that overrides/drops it — so it
  # yields to its mutant clauses when their id is active, and behaves normally
  # otherwise (including for any skipped/poisoned id, which is never excluded).
  defp lifted_original(base, clause, excluded_ids, var) do
    {clause_meta, call_meta, args, guards, body} = clause_parts(clause)
    guard = merge_guards(exclusion_guard(excluded_ids, var), combine_guards(guards))
    lifted_clause(base, clause_meta, call_meta, args, guard, body, var)
  end

  # Assemble a `<base>` clause: `defp <base>(mutare_active, <args...>) [when <guard>], <body>`.
  # The source clause's `meta` (its line) is preserved on the `defp` and the head call
  # — *not* reset to `[]` — so `Sourceror`'s line-assigning normalizer stays anchored to
  # the original source lines. Without it the body's `[]`-meta selector clauses (`<id>
  # -> …`) get stale lines, and a bare integer id then renders as a `:line`-but-no-
  # `:token` literal that crashes the Elixir formatter.
  defp lifted_clause(base, clause_meta, call_meta, args, guard, body, var) do
    call = {base, call_meta, [Recorder.catch_all_pattern(var) | args]}
    head = if guard, do: {:when, [], [call, guard]}, else: call
    {:defp, clause_meta, [head | body]}
  end

  # Deconstruct a function clause into `{clause_meta, head_call_meta, head_args,
  # guards, body_kw}`. A 0-arity head carries a `nil` arg context rather than a
  # list, which becomes `[]`.
  defp clause_parts({_vis, clause_meta, [head | body]}) do
    {call, guards} =
      case head do
        {:when, _meta, [call | gs]} -> {call, gs}
        call -> {call, []}
      end

    {_name, call_meta, args} = call
    {clause_meta, call_meta, if(is_list(args), do: args, else: []), guards, body}
  end

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
  defp in_place_site(id, %Candidate.InPlace{} = c, file) do
    Site.in_place(id, file, c.range, c.original, c.mutated, c.mutator)
  end

  # A return-value mutation is delivered in place (the tail is a body position),
  # but it is structural — no node-level `mutator`, no operator — so it gets its
  # own `Site` constructor (`:return_value` mutator, `nil` ops).
  defp in_place_site(id, %Candidate.Return{} = c, file) do
    Site.return_value(id, file, c.range, c.original, c.mutated)
  end

  # A `case` clause-pattern mutation is delivered in place (the whole case is wrapped in a
  # selector). The diff stays focused on the pattern (`original`/`mutated`); the selector
  # branch carries the whole mutated case (`branch_node/1`), not these nodes.
  defp in_place_site(id, %Candidate.CasePattern{} = c, file) do
    Site.in_place(id, file, c.range, c.original, c.mutated, c.mutator)
  end

  defp lifted_site(id, %Candidate.Guard{} = c, file) do
    Site.lifted_replace(id, file, c.range, c.original, c.mutated, c.mutator)
  end

  # A head-pattern literal swap is lifted (a `case` is illegal in a pattern) and
  # records the same `:lifted` replacement shape as a guard — only the mutator
  # name (a literal family) and the position differ.
  defp lifted_site(id, %Candidate.Pattern{} = c, file) do
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

  defp strip_candidates({form, meta, args}) when is_list(meta),
    do: {form, Keyword.delete(meta, :mutare), args}

  defp strip_candidates(node), do: node

  # --- assign + emit: ids in post-order, selectors built from candidates ------

  # Bottom-up walk: a node's children are wrapped before it is, so ids are
  # assigned in post-order DFS (children before parents) — and the catch-all of
  # an outer selector holds the already-wrapped children, keeping nested sites
  # reachable when the outer mutant is inactive.
  defp emit(node, ctx) do
    Macro.postwalk(node, ctx, fn current, ctx ->
      case candidates_of(current) do
        # A `|>` never carries candidates itself, but its already-emitted RHS may
        # now be a selector `case` — illegal as a pipe target — so rewrite it here.
        [] -> {hoist_pipe(current), ctx}
        candidates -> emit_site(current, candidates, ctx)
      end
    end)
  end

  # `x |> case … end` does not compile — `Kernel.|>/2` cannot pipe into a `case`.
  # When emit wrapped a *pipe stage* (the call right of a `|>`) in a selector, the
  # selector lands in exactly that illegal RHS position. Run on the parent `|>`
  # during the same postwalk (the RHS is already emitted), this hoists the pipe
  # *into* the selector: each branch becomes `lhs |> <that branch's expr>`, so the
  # `case` is a standalone expression — and a valid pipe LHS for any later stage,
  # which keeps chained pipes (`a |> b |> c`) working as the rewrite nests. The
  # bare stage stays the Site's recorded node, so the diff is unaffected.
  defp hoist_pipe(
         {:|>, _meta, [lhs, {:__block__, bmeta, [{:case, cmeta, [subject, [do: clauses]]}]}]} =
           node
       ) do
    if Mutare.Metamutant.subject?(subject) do
      piped =
        Enum.map(clauses, fn {:->, m, [pat, body]} -> {:->, m, [pat, pipe_tail(lhs, body)]} end)

      {:__block__, bmeta, [{:case, cmeta, [subject, [do: piped]]}]}
    else
      node
    end
  end

  defp hoist_pipe(node), do: node

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
          {:->, [], [[id], branch_node(candidate)]}
        end)
      end)

    # `hoist_pipe`: when this node is itself a `|>` (e.g. its tail carries a
    # ReturnValue candidate) whose RHS is an already-emitted selector, the selector
    # would sit illegally as a pipe target inside this default/catch-all — hoist the
    # pipe into it. A no-op for every other node shape.
    default = hoist_pipe(strip_candidates(node))

    # All mutations here skipped → no selector; emit the node unchanged.
    case clauses do
      [] -> {default, ctx}
      _ -> {build_case(default, clauses, ctx.active_var), ctx}
    end
  end

  # The selector-branch value for an in-place candidate. A `CasePattern` carries the whole
  # mutated `case` (`replacement`); for every other in-place candidate the branch *is* its
  # `mutated` node (an operator swap, a return constant).
  defp branch_node(%Candidate.CasePattern{replacement: replacement}), do: replacement
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

  # (case :persistent_term.get(:mutare_active, 0) do <id> -> <mutated> ; _ -> <default> end)
  #
  # The selector is `Render.block_wrap`ped so it renders safely in any position.
  defp build_case(default_node, mutant_clauses, var) do
    selector = Mutare.Metamutant.subject_ast()
    ids = for {:->, _, [[id], _]} <- mutant_clauses, do: id
    catch_all = catch_all_clause(ids, default_node, var)
    case_node = {:case, [], [selector, [do: mutant_clauses ++ [catch_all]]]}
    Render.block_wrap(case_node)
  end

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
