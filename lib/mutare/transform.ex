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

  alias Mutare.{Mutator, Site}
  alias Mutare.Coverage.Recorder

  alias Mutare.Transform.{
    Aliases,
    Candidate,
    Ctx,
    FunctionPlan,
    ModulePlan,
    PatternStructure,
    Render
  }

  # The default set is the built-in catalog's `all/0` — one source of truth, so a
  # family registered in `Mutare.Mutators` is part of the default automatically.
  @default_mutators Mutare.Mutators.all()

  # The canonical prefix for generated private (lifted) names. `generated_names/1`
  # derives a per-file, collision-free variant of it (see that function).
  @base_prefix "__mutare_"

  # def-like forms whose names a generated private `defp` could duplicate — part of
  # the identifier set `generated_names/1` scans the source for.
  @def_forms ~w(def defp defmacro defmacrop defguard defguardp defdelegate)a

  # The try-style body blocks whose clause bodies are *return paths*
  # (`rescue`/`catch`/`else`). Their left side is always a match, and their tails
  # return — unlike `:after`, whose value `try` discards (so it is no return path
  # and is left to mutate only in place, like `:do`).
  @clause_block_keys [:rescue, :catch, :else]

  # The keyword atoms that render a construct's `do … end` block (`do:` plus the
  # `else`/`rescue`/`catch`/`after` tails). As *block* syntax these keys carry no
  # `format: :keyword` marker, so `label_key?/1` recognises them by atom — protecting
  # a key like `do:` from being mutated (which would not even render).
  @block_keys [:do, :else, :rescue, :catch, :after]

  # Module-level forms whose block/children are known compile-time structure.
  # Unknown module-level macro calls with a block are handled separately so a DSL
  # that unquotes its `do` body into generated runtime functions keeps body mutants.
  @module_scaffold_forms [
    :@,
    :if,
    :unless,
    :for,
    :case,
    :cond,
    :with,
    :try,
    :receive,
    :quote,
    :defmacro,
    :defmacrop,
    :defimpl,
    :defprotocol,
    :defdelegate,
    :import,
    :alias,
    :require,
    :use
  ]

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
    # (see `generated_names/1`).
    {prefix, active_var} = generated_names(parsed)
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
      module_scaffold_statement?(node) ->
        node |> analyze(:scaffold, ctx.mutators) |> emit(ctx)

      module_macro_block_statement?(node) ->
        node |> analyze_module_macro_block(ctx.mutators) |> emit(ctx)

      true ->
        node |> analyze(:scaffold, ctx.mutators) |> emit(ctx)
    end
  end

  defp module_scaffold_statement?({form, _meta, _args}) when form in @module_scaffold_forms,
    do: true

  defp module_scaffold_statement?(_node), do: false

  defp module_macro_block_statement?({_form, _meta, args}) when is_list(args) and args != [] do
    case List.last(args) do
      kw when is_list(kw) -> block_keyword_list?(kw)
      _other -> false
    end
  end

  defp module_macro_block_statement?(_node), do: false

  defp block_keyword_list?(kw) do
    Enum.any?(kw, fn
      {key, _value} -> block_key?(key)
      _other -> false
    end)
  end

  defp analyze_module_macro_block({form, meta, args}, mutators) do
    {init, [last]} = Enum.split(args, -1)
    init = Enum.map(init, &analyze(&1, :scaffold, mutators))
    {form, meta, init ++ [analyze_module_macro_block_arg(last, mutators)]}
  end

  defp analyze_module_macro_block_arg(kw, mutators) when is_list(kw) do
    Enum.map(kw, fn
      {key, value} ->
        context = if block_key?(key), do: :runtime, else: :scaffold
        {key, analyze(value, context, mutators)}

      other ->
        analyze(other, :scaffold, mutators)
    end)
  end

  defp block_key?(key), do: key_atom(key) in @block_keys

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

  # === generated-name collision avoidance ====================================

  # The generated names this file provably never collides with: the private-function
  # prefix, and the dispatch variable. With the canonical `"__mutare_"` /
  # `mutare_active` a clash with hand-written code is near-impossible — but a single
  # clash is catastrophic (a duplicate `defp` sinks the *one* metamutant build; a
  # captured variable silently miscompiles a lifted clause — its gated head would
  # bind a user value instead of the active id). So we pick names the source provably
  # never uses, from one scan of every identifier it mentions (definitions *and*
  # variables). (`Mutare.Manifest` recognises a lifted mutant clause by its
  # `<active_var> === <id>` gate, not the name, so the salt is invisible to it.)
  defp generated_names(ast) do
    taken = taken_names(ast)
    prefix = Enum.find(prefix_candidates(), &free?(&1, taken))
    {prefix, active_var(taken)}
  end

  # The dispatch variable: the readable `mutare_active` unless the source already
  # uses that identifier, then `mutare_active_0`, `mutare_active_1`, … until free.
  # A numeric suffix (not the `__mutare_` prefix) keeps it a normal, non-underscore
  # name — a leading-underscore variable that's then *read* warns ("used after being
  # set"). The candidate family is infinite and `taken` finite, so this terminates.
  defp active_var(taken) do
    canonical = Recorder.var_name()

    if MapSet.member?(taken, Atom.to_string(canonical)) do
      Stream.iterate(0, &(&1 + 1))
      |> Stream.map(&:"#{canonical}_#{&1}")
      |> Enum.find(&(not MapSet.member?(taken, Atom.to_string(&1))))
    else
      canonical
    end
  end

  # `"__mutare_"`, then `"__mutare_0_"`, `"__mutare_1_"`, … — a lazily-grown
  # family, all sharing the `"__mutare_"` stem. Only finitely many can be "taken"
  # (one per colliding source name), so `Enum.find/2` always terminates.
  defp prefix_candidates do
    Stream.concat(
      [@base_prefix],
      Stream.map(Stream.iterate(0, &(&1 + 1)), &"#{@base_prefix}#{&1}_")
    )
  end

  # A prefix is free when no identifier the source mentions begins with it: then no
  # `<prefix>…` name we generate (a private function, or `<prefix>active`) can equal
  # one already in scope.
  defp free?(prefix, taken), do: not Enum.any?(taken, &String.starts_with?(&1, prefix))

  # Every identifier the source mentions: names defined by a def-like form
  # (functions, macros, guards, delegates) a generated `defp` could duplicate, *and*
  # every variable/bare-name node the dispatch variable could capture or be captured
  # by. Over-collecting (e.g. a name inside a quoted macro body) is safe — it can
  # only make us salt a name we'd otherwise have kept.
  defp taken_names(ast) do
    {_ast, names} =
      Macro.prewalk(ast, MapSet.new(), fn
        {form, _meta, [head | _]} = node, acc when form in @def_forms ->
          case def_name(head) do
            nil -> {node, acc}
            name -> {node, MapSet.put(acc, Atom.to_string(name))}
          end

        # A variable (or bare zero-arg name): `context` is its hygiene context
        # (`nil`/a module), never the arg list a call carries.
        {name, _meta, context} = node, acc when is_atom(name) and is_atom(context) ->
          {node, MapSet.put(acc, Atom.to_string(name))}

        node, acc ->
          {node, acc}
      end)

    names
  end

  defp def_name({:when, _meta, [call | _guards]}), do: def_name(call)
  defp def_name({name, _meta, _args}) when is_atom(name), do: name
  defp def_name(_), do: nil

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
    |> annotate(ctx.mutators)
    |> emit(ctx)
  end

  # --- analyze: classify context positively, attach candidates -----------------

  # A syntax-directed walk that *names the context* of each position as it
  # descends, rather than subtracting a blacklist from "everything is a runtime
  # body". Routing is positional, so child → context is a pattern match — which a
  # single `Macro.traverse` accumulator can't express (it can't send the spec
  # side of a `::` one way and the value side another). Four contexts are threaded:
  #
  #   * `:runtime` — mutate in place. A node a mutator recognises gets a
  #     `Candidate.InPlace` attached to its own metadata; the candidate is built
  #     from the *raw* node (un-annotated children — what the report renders)
  #     before we descend.
  #   * `:pattern` — never mutate, but keep descending so nested runtime escapes
  #     (default-argument values, `size(...)` args) are still reached.
  #   * `:owned` — a call argument a mutator has *claimed* (its optional
  #     `owned_args/2`): like `:pattern` it never mutates in place but keeps
  #     descending. Routed by `recurse_runtime/3` so a leaf the claimant already
  #     covers via the whole call (a ModeSwap unit/mode atom) isn't *also* mutated
  #     in place by another mutator (AtomLiteral → a redundant, raising `:mutare`).
  #   * `:scaffold` — a module-level non-clause statement entered from
  #     `transform_statement/2`. Like `:pattern` it never mutates in place and keeps
  #     descending — the module body runs once, at compile time, with mutant 0
  #     active, so a selector spliced into the statement's own expressions (an `if`
  #     condition, a `for` generator, an unquoted generated head pattern, or any
  #     other bare module-body calculation) could never activate — but the one
  #     runtime escape it reaches is an explicit `def`/`defp` body (the def clause
  #     flips it back to `:runtime`). `body_context/1` propagates `:scaffold`
  #     through `case`/`cond`/… arms so nested scaffolds stay inert too.
  #
  # The remaining contexts are recognised positively and realised as pruned
  # subtrees or dedicated helpers (named here, matched in the clauses below):
  #
  #   * `:compile_time` — module-attribute values (`@x <expr>`), macro bodies
  #     (`defmacro`/`defmacrop`), `quote` blocks (AST construction), and lexical
  #     directives (`import`/`alias`/`require`/`use`, whose args must be
  #     compile-time literals). Frozen at compile / macro-expansion time, so a
  #     runtime selector there can never activate — and inside a directive arg, or
  #     a quoted pattern/guard, would not even be legal. Pruned whole.
  #   * `:spec` — the type-specifier side of a bitstring `::` segment. A `case`
  #     is illegal there and a swapped `-` separator is an illegal specifier;
  #     only `size(expr)` args are a genuine runtime sub-position (`analyze_spec/3`).
  #   * `:guard` — `when` guards, owned by the lift path (a `case` can't live in a
  #     guard). Pruned here; `FunctionPlan` mutates them by lifting instead.
  #   * `:capture_arity` — the `/` in `&fun/arity`, an arity separator not
  #     division. Pruned; real division (`& &1 / 2`) still mutates.
  #
  # On top of the node-level operator candidates, the `def`/`defp` clause is *also*
  # a structural site: the tail of each of its return-path blocks (`:do`, and each
  # `rescue`/`catch`/`else` clause body) is a return-value position
  # (`annotate_returns/3`), where a `Candidate.Return` constant is appended to the
  # tail node's own metadata — delivered by the same in-place selector, on the same
  # node, as any operator candidate there.
  #
  # Ids are *not* assigned here; emission does that bottom-up to keep post-order
  # id ordering.
  defp annotate(node, mutators), do: analyze(node, :runtime, mutators)

  # `when` guard (position-independent: also covers case/fn clause guards): the
  # lift path owns guard mutation, so the in-place walk never touches one.
  defp analyze({:when, _meta, [_call | guards]} = node, _context, _mutators)
       when guards != [],
       do: node

  # module attribute `@x <value>`: compile-time, pruned whole. A bare `@x` read
  # has an atom context (not a single-value list) and falls through to runtime.
  defp analyze({:@, _meta, [{_name, _am, [_value]}]} = node, _context, _mutators), do: node

  # `defmacro`/`defmacrop`: compile-time / macro-generated, pruned whole.
  defp analyze({vis, _meta, _args} = node, _context, _mutators)
       when vis in [:defmacro, :defmacrop],
       do: node

  # `import`/`alias`/`require`/`use`: lexical directives resolved at compile time.
  # Their arguments are not a runtime position — an `import`'s `only:`/`except:`
  # must be a *literal* keyword list, an `alias`'s `as:` a literal atom, a `use`'s
  # options are handed to a macro at expansion — so a runtime selector there is at
  # best inert and at worst illegal (it makes the single build fail). Pruned whole;
  # the directive rides through untouched and in position.
  defp analyze({form, _meta, args} = node, _context, _mutators)
       when form in [:import, :alias, :require, :use] and is_list(args),
       do: node

  # `defprotocol`/`defdelegate`: pure compile-time module references with no runtime
  # body to mutate — `defprotocol` declares signatures, `defdelegate` forwards to a
  # `to:` module. A selector spliced into the protocol name / delegation target would
  # not compile (it expects a literal module), so prune whole. (Relevant once an alias
  # mutator can match the module references they carry.)
  defp analyze({form, _meta, _args} = node, _context, _mutators)
       when form in [:defprotocol, :defdelegate],
       do: node

  # `defimpl`: the protocol alias and the `for:` type are compile-time module
  # references (a selector there won't compile), but the `do:` block *is* runtime —
  # its implementation defs must still mutate. Analyze only the `do:` value, passing
  # the protocol-alias arg and every non-`do:` keyword entry (notably `for:`) through
  # raw. This handles both the block form (`for:`/`do:` in separate args) and the
  # inline form (folded into one keyword).
  defp analyze({:defimpl, meta, args}, _context, mutators) when is_list(args) do
    {:defimpl, meta, Enum.map(args, &analyze_defimpl_arg(&1, mutators))}
  end

  # `quote`: its body is compile-time AST *construction*, not runtime code. The
  # literals there become part of the code the quote *generates* — instrumenting
  # which is out of scope (PHILOSOPHY: "macro-generated code is a different tool"),
  # exactly like a `defmacro` body. Worse, a selector `case` spliced into a quoted
  # pattern or guard (e.g. `quote do: (case x do "" -> … end)`) is valid *as a
  # quote* but illegal where the AST is later compiled — a poison the pre-filter
  # can't see, because the metamutant itself compiles. Pruned whole. (This also
  # prunes any `unquote(expr)` runtime sub-positions inside; mutating those is
  # deferred — see NOTES — and losing them is acceptable per the philosophy above.)
  defp analyze({:quote, _meta, args} = node, _context, _mutators)
       when is_list(args),
       do: node

  # `&fun/arity` capture: the `/` is arity, not division — pruned. Anything else
  # under `&` (e.g. `& &1 / 2`) keeps mutating.
  defp analyze({:&, _meta, [{:/, _smeta, [left, right]}]} = node, context, mutators) do
    if function_ref?(left) and integer_literal?(right),
      do: node,
      else: recurse(node, context, mutators)
  end

  # A `def`/`defp` clause reaching the in-place path (one that did not lift, or the
  # *original* clause of a lifted group): the head is a pattern, the body keyword is
  # runtime, and the `:do` block's *tail expression* is additionally a return-value
  # position (only the transform knows where a clause returns — see
  # `annotate_returns/3`).
  defp analyze({vis, meta, [head, body_kw]}, _context, mutators)
       when vis in [:def, :defp] and is_list(body_kw) do
    head = analyze(head, :pattern, mutators)
    analyzed_kw = analyze_do_blocks(body_kw, mutators)
    {vis, meta, [head, annotate_returns(analyzed_kw, body_kw, mutators)]}
  end

  # bitstring: each segment's value keeps the surrounding context; the spec side
  # is excluded except for `size(expr)` args (`analyze_segment/3`). In a runtime
  # body the `<<…>>` node is *also* offered to mutators (BitstringLiteral collapses
  # it to `<<>>`) — built from the raw node so the diff renders the author's
  # literal, with the analyzed segments kept underneath so their own selectors stay
  # reachable. In a pattern (or any non-runtime context) it is only descended.
  defp analyze({:<<>>, meta, segments} = node, :runtime, mutators) do
    analyzed = {:<<>>, meta, Enum.map(segments, &analyze_segment(&1, :runtime, mutators))}

    case Mutator.mutations(node, mutators) do
      [] -> analyzed
      muts -> put_candidates(analyzed, build_candidates(node, muts))
    end
  end

  defp analyze({:<<>>, meta, segments}, context, mutators) do
    {:<<>>, meta, Enum.map(segments, &analyze_segment(&1, context, mutators))}
  end

  # `%Struct{…}`: the inner `%{…}` is the struct's *field map*, not a standalone
  # map literal — collapsing it to `%{}` (MapLiteral) would drop required fields /
  # change the struct, not shrink "the same" value. Descend into the field map's
  # contents (so each field *value* still mutates, keys stay protected) but never
  # offer the `%{}` wrapper itself to a mutator. The alias rides through untouched.
  defp analyze({:%, meta, [aliases, {:%{}, mmeta, pairs}]}, context, mutators)
       when is_list(pairs) do
    {:%, meta, [aliases, {:%{}, mmeta, Enum.map(pairs, &analyze(&1, context, mutators))}]}
  end

  # match `=`: the left side is a pattern, the right keeps the context.
  defp analyze({:=, meta, [lhs, rhs]}, context, mutators) do
    {:=, meta, [analyze(lhs, :pattern, mutators), analyze(rhs, context, mutators)]}
  end

  # `<-` generator/with-clause: the left is a pattern (matched against each value
  # in `for x <- …`, or the right's result in `with {:ok, x} <- …`), the right keeps
  # the context. Mirrors `=` — without it a literal in the LHS would be mutated.
  defp analyze({:<-, meta, [lhs, rhs]}, context, mutators) do
    {:<-, meta, [analyze(lhs, :pattern, mutators), analyze(rhs, context, mutators)]}
  end

  # `match?(pattern, expr)`: a macro whose *first* argument is a match context, not
  # a runtime value — it expands to `case expr do pattern -> true; _ -> false end`.
  # So route it like `=`: the pattern side is `:pattern` (never mutated in place — a
  # selector `case` spliced there is "case not allowed in matches", and a literal
  # swap rewrites a pattern, not a value), the matched expression keeps the context.
  # Without this, mutating a string/tuple/atom literal inside the pattern poisons the
  # single build. Matches only the bare `match?/2` call (how it is always written);
  # a qualified `Kernel.match?/2` is rare enough to leave to the poison fallback.
  defp analyze({:match?, meta, [pattern, expr]}, context, mutators) do
    {:match?, meta, [analyze(pattern, :pattern, mutators), analyze(expr, context, mutators)]}
  end

  # `cond`: the one `->` construct whose clause *left* is a runtime condition, not
  # a pattern — so it stays mutatable. Analyze its clauses keeping both sides
  # runtime, intercepting them before the generic `->` clause (below) would wrongly
  # pattern-route the conditions. The `:do` block key is protected by the
  # keyword-pair clause.
  defp analyze({:cond, meta, [blocks]}, context, mutators) when is_list(blocks) do
    body_ctx = body_context(context)
    {:cond, meta, [Enum.map(blocks, &analyze_cond_block(&1, body_ctx, mutators))]}
  end

  # `if`/`unless`: the condition is an ordinary runtime expression *and* the one
  # position `Mutare.Mutators.IfCondition` targets — it forces the condition to
  # `true`/`false` (the "remove the decision" mutation) for the conditions a value
  # family can't reach (a bare predicate call, `is_*`, a remote boolean), the
  # boolean-operator ones being left to `Conditional`. So the condition is analyzed
  # as runtime, then has its IfCondition candidate appended (`attach_if_condition/3`);
  # the body keyword (`do:`/`else:` values) is analyzed exactly as the generic
  # runtime clause would, and the whole node is still offered to mutators for parity
  # (a custom mutator matching an `if`; the built-ins match none). Only `:runtime` —
  # a module-level (`:scaffold`) `if` runs once at compile time, so its condition is
  # inert and falls through to the non-mutating catch-all.
  defp analyze({form, meta, [condition, body_kw]} = node, :runtime, mutators)
       when form in [:if, :unless] and is_list(body_kw) do
    analyzed_condition =
      condition
      |> analyze(:runtime, mutators)
      |> attach_if_condition(condition, mutators)

    rebuilt = {form, meta, [analyzed_condition, analyze(body_kw, :runtime, mutators)]}

    case Mutator.mutations(node, mutators) do
      [] -> rebuilt
      muts -> put_candidates(rebuilt, build_candidates(node, muts))
    end
  end

  # `case`/`receive`/`fn`: runtime expressions whose *clause patterns* are additionally
  # mutatable by the structural pattern families (`PatternSwap`/`PatternWildcard`). None can
  # host a selector inside a pattern, and none is a liftable function clause group, so each
  # pattern mutant is delivered by wrapping the **whole** construct in an in-place selector
  # whose mutant branch is a copy with one clause's pattern restructured — sound because the
  # clause bindings of all three are local to a clause body and never escape. Each is still
  # analyzed normally (subject/bodies mutate; the `->` routing keeps patterns in `:pattern`),
  # and the `Candidate.CasePattern`s are attached so emission hosts them in the same selector.
  # The three differ only in *where the clauses live* and *how to rebuild the whole node*,
  # captured by the clause list + `rebuild_fn` passed to `attach_clause_pattern_candidates/4`.
  defp analyze({:case, meta, [subject, [{do_key, clauses}]]} = node, :runtime, mutators)
       when is_list(clauses) do
    rebuild = fn new -> {:case, meta, [subject, [{do_key, new}]]} end
    attach_clause_pattern_candidates(node, clauses, rebuild, mutators)
  end

  defp analyze({:receive, meta, [blocks]} = node, :runtime, mutators) when is_list(blocks) do
    {clauses, rebuild} = receive_do_clauses(blocks, meta)
    attach_clause_pattern_candidates(node, clauses, rebuild, mutators)
  end

  defp analyze({:fn, meta, clauses} = node, :runtime, mutators) when is_list(clauses) do
    rebuild = fn new -> {:fn, meta, new} end
    attach_clause_pattern_candidates(node, clauses, rebuild, mutators)
  end

  # A `->` clause in a pattern-matching construct (`case`/`fn`/`receive`/`with` else/
  # a `try` block outside a def head/`for` reduce): the left is a pattern (never
  # mutated — a selector `case` is illegal in a pattern and would poison the single
  # build), the body inherits the construct's liveness (`body_context/1`): `:runtime`
  # normally, `:scaffold` when this construct itself wraps a metaprogrammed `def` at
  # module level (so the arm's own code is left compile-time-inert). `cond` is
  # excepted above; a `when` guard among the patterns is returned whole by the
  # `:when` clause, so guards stay untouched.
  defp analyze({:->, meta, [patterns, body]}, context, mutators) when is_list(patterns) do
    {:->, meta,
     [
       Enum.map(patterns, &analyze(&1, :pattern, mutators)),
       analyze(body, body_context(context), mutators)
     ]}
  end

  # default argument inside a pattern (`x \\ expr`): the variable is a pattern,
  # but the default runs at call time → runtime (don't regress its mutation).
  defp analyze({:\\, meta, [var, default]}, :pattern, mutators) do
    {:\\, meta, [analyze(var, :pattern, mutators), analyze(default, :runtime, mutators)]}
  end

  # `|>` pipe: the right side is a call whose *effective* first argument is the piped
  # left side — which is the `|>` node's LHS, **not** present in the call's own args.
  # So a pipe stage carries one fewer argument than the source reads, which makes a
  # node-local mutator misjudge its arity. Route the RHS through `analyze_pipe_stage/2`
  # so an arity-changing mutator (`CollectionArity`) is offered the node *as piped*
  # and sees the true arity; the LHS is an ordinary runtime expression. (Arity-blind
  # mutators are unaffected — they ignore the flag.)
  defp analyze({:|>, meta, [lhs, rhs]}, :runtime, mutators) do
    {:|>, meta, [analyze(lhs, :runtime, mutators), analyze_pipe_stage(rhs, mutators)]}
  end

  # `for` comprehension: its generators (`<-`), filters, `:into`/`:reduce` options
  # and `:do`/`:reduce` body all descend as ordinary runtime, but the **`:uniq`**
  # option must be a *literal boolean* — the `for` special form rejects any
  # non-literal there (`:uniq option for comprehensions only accepts a boolean`),
  # so a selector `case` spliced into its value (Literal/Conditional firing on the
  # `true`/`false`) would poison the single build. The `:uniq` value alone is held
  # back from mutators (`analyze_for_arg/2`); the node itself is still offered for
  # parity with the generic clause (no built-in matches `for`).
  defp analyze({:for, _meta, args} = node, :runtime, mutators) when is_list(args) do
    offered =
      case Mutator.mutations(node, mutators) do
        [] -> node
        muts -> put_candidates(node, build_candidates(node, muts))
      end

    {:for, meta, args} = offered
    {:for, meta, Enum.map(args, &analyze_for_arg(&1, mutators))}
  end

  # `not in`: `x not in y` parses as `not(x in y)` — a `:not` wrapping an `:in`.
  # Both nodes are boolean-valued, so the inner `in` would otherwise be offered to
  # mutators and produce only *redundant* mutants: Conditional forcing it to
  # `true`/`false` yields `not true`/`not false`, exactly the outer `not` forced to
  # `false`/`true`; and Relational's `in` → `not in` yields `not(x not in y)` ≡
  # `x in y`, exactly Logical's strip of the outer `not`. So the inner `in` node is
  # not offered to any mutator (only its operands descend); the outer `not` is
  # offered normally (Logical strips it → `x in y`, the strongest membership
  # mutation, and Conditional forces it `true`/`false`). The only families matching
  # an `in` node are Conditional and Relational — both redundant under a `not` — so
  # this drops exactly the redundant mutants and nothing of value.
  defp analyze({:not, meta, [{:in, in_meta, [left, right]}]} = node, :runtime, mutators) do
    inner =
      {:in, in_meta, [analyze(left, :runtime, mutators), analyze(right, :runtime, mutators)]}

    rebuilt = {:not, meta, [inner]}

    case Mutator.mutations(node, mutators) do
      [] -> rebuilt
      muts -> put_candidates(rebuilt, build_candidates(node, muts))
    end
  end

  # a generic runtime node: build the candidate from the raw node (so `original`
  # keeps un-annotated children), then descend into the children. A sigil is offered
  # as a whole (so the sigil mutators — Regex/Charlist/DateTime — match it), then
  # descended *surgically* via `descend_sigil/2`: its content `<<>>` segments are
  # analyzed (so an interpolated expression `~r/a#{b}c/` still mutates `b`), but the
  # content `<<>>` *wrapper* itself is never offered — collapsing a sigil's content
  # (BitstringLiteral) or splicing a selector into it is illegal.
  defp analyze({form, _meta, _args} = node, :runtime, mutators) do
    node =
      case Mutator.mutations(node, mutators) do
        [] -> node
        muts -> put_candidates(node, build_candidates(node, muts))
      end

    if sigil?(form),
      do: descend_sigil(node, mutators),
      else: recurse_runtime(node, mutators, false)
  end

  # A keyword/block pair (`key: value`, `%{a: …}`, a `do:`/`else:`/`rescue:`/
  # `catch:`/`after:` block). The *key* is a structural label, never a runtime
  # value, so it is not offered to a mutator — a selector spliced into a key
  # position is malformed (it would not even render). Only the value is analyzed,
  # in the surrounding context. A 2-tuple like `{:ok, x}` is *not* this — its `:ok`
  # is a real runtime value — so `label_key?/1` admits only inline-keyword keys
  # (the `format: :keyword` marker) or a block-key atom, and a tuple tag falls
  # through to `recurse` and stays mutatable.
  defp analyze({key, value} = pair, context, mutators) do
    if label_key?(key),
      do: {key, analyze(value, context, mutators)},
      else: recurse(pair, context, mutators)
  end

  # anything else — a node in a non-runtime context, or a container/leaf:
  # descend without mutating so boundary forms (`\\`, `<<>>`) still fire on
  # children, but attach no candidate here.
  defp analyze(node, context, mutators), do: recurse(node, context, mutators)

  # The right side of a `|>` (see the `:|>` clause of `analyze/3`): offer it to
  # mutators *as piped* (so an arity-changing mutator sees the effective arity =
  # visible args + 1), then descend its arguments as ordinary runtime. Mirrors the
  # generic runtime clause (a pipe stage is never a sigil). The resulting candidate
  # is a normal `Candidate.InPlace`, so emission wraps it in a selector and
  # `hoist_pipe/1` lifts the pipe in — a mutated 0-arg `Enum.reverse()` stage becomes
  # `lhs |> Enum.reverse()`. A non-call RHS (rare) is analyzed normally.
  defp analyze_pipe_stage({_form, _meta, args} = node, mutators) when is_list(args) do
    node =
      case Mutator.mutations(node, mutators, %{piped: true}) do
        [] -> node
        muts -> put_candidates(node, build_candidates(node, muts))
      end

    recurse_runtime(node, mutators, true)
  end

  defp analyze_pipe_stage(other, mutators), do: analyze(other, :runtime, mutators)

  # One argument of a `for`: a generator/filter is descended as ordinary runtime,
  # while the trailing options/body keyword list keeps its `:uniq` value untouched
  # (a `for`-special-form literal-boolean slot — see the `for` analyze clause).
  # Every other option (`:into`/`:reduce`) and the `:do`/`:reduce` body descend as
  # before via the generic keyword-pair clause.
  defp analyze_for_arg(opts, mutators) when is_list(opts) do
    Enum.map(opts, fn
      {key, _value} = pair ->
        if key_atom(key) == :uniq, do: pair, else: analyze(pair, :runtime, mutators)

      other ->
        analyze(other, :runtime, mutators)
    end)
  end

  defp analyze_for_arg(arg, mutators), do: analyze(arg, :runtime, mutators)

  # Recurse a runtime call's arguments, but route any positions a mutator has *claimed*
  # (its optional `owned_args/2`) through the non-mutating `:owned` context — so a leaf
  # the claimant already covers via the *whole call* (a ModeSwap unit/mode atom) isn't
  # *also* offered to another mutator in place (AtomLiteral turning `:second` into a
  # redundant, always-raising `:mutare`). With no claimant the owned set is empty and
  # this is exactly `recurse(node, :runtime, …)` — so non-owning calls are unaffected.
  # `piped?` is threaded because ownership, like arity, depends on the pipe position.
  defp recurse_runtime({form, meta, args} = node, mutators, piped?) when is_list(args) do
    case owned_arg_indices(node, mutators, %{piped: piped?}) do
      [] ->
        recurse(node, :runtime, mutators)

      owned ->
        args =
          args
          |> Enum.with_index()
          |> Enum.map(fn {arg, i} ->
            analyze(arg, if(i in owned, do: :owned, else: :runtime), mutators)
          end)

        {form, meta, args}
    end
  end

  defp recurse_runtime(node, mutators, _piped?), do: recurse(node, :runtime, mutators)

  # The visible argument indices some active mutator claims exclusive ownership of at this
  # call (via the optional `owned_args/2` callback), unioned. Cheap when nobody implements
  # it — the `function_exported?/2` filter short-circuits before any call.
  defp owned_arg_indices(node, mutators, context) do
    for mutator <- mutators,
        function_exported?(mutator, :owned_args, 2),
        i <- mutator.owned_args(node, context),
        uniq: true,
        do: i
  end

  # Generic structural descent over every Sourceror node shape, re-analyzing the
  # children in the same context.
  defp recurse({form, meta, args}, context, mutators) when is_list(args),
    do: {form, meta, Enum.map(args, &analyze(&1, context, mutators))}

  defp recurse({form, meta, arg}, _context, _mutators), do: {form, meta, arg}

  defp recurse({left, right}, context, mutators),
    do: {analyze(left, context, mutators), analyze(right, context, mutators)}

  defp recurse(list, context, mutators) when is_list(list),
    do: Enum.map(list, &analyze(&1, context, mutators))

  defp recurse(other, _context, _mutators), do: other

  # The body keyword of a clause (`[do: …, rescue: …, catch: …, else: …,
  # after: …]`, possibly with Sourceror's `{:__block__, _, [:do]}` keys). `:do`
  # and `:after` are ordinary runtime bodies. `:rescue`/`:catch`/`:else` are
  # *clause lists* whose left side is a match, not runtime code, so each clause's
  # patterns are analyzed in `:pattern` (never mutated — a selector `case` spliced
  # into a rescue/else pattern is illegal Elixir and would poison the single
  # build) and only its body in `:runtime`. (`cond`, whose clause left *is*
  # runtime, is handled generically; here the routing is unambiguous because these
  # blocks always pattern-match.)
  defp analyze_do_blocks(body_kw, mutators) do
    Enum.map(body_kw, fn {key, value} ->
      if clause_block_key?(key) and is_list(value),
        do: {key, Enum.map(value, &analyze_try_clause(&1, mutators))},
        else: {key, analyze(value, :runtime, mutators)}
    end)
  end

  # One `rescue`/`catch`/`else` clause: its patterns are matches (`:pattern`), its
  # body is runtime. A `when` guard among the patterns is returned whole by the
  # `:when` clause of `analyze/3` (guard mutation in a try clause isn't supported).
  defp analyze_try_clause({:->, meta, [patterns, body]}, mutators) when is_list(patterns) do
    patterns = Enum.map(patterns, &analyze(&1, :pattern, mutators))
    {:->, meta, [patterns, analyze(body, :runtime, mutators)]}
  end

  defp analyze_try_clause(other, mutators), do: analyze(other, :runtime, mutators)

  # One `cond` do-block: a `{key, clauses}` pair whose key is the `:do` label (kept
  # raw, never mutated) and whose clauses each keep *both* sides in `context` — a cond
  # clause's left is a condition, not a pattern. `context` is the construct's liveness
  # (`:runtime` for an ordinary cond; `:scaffold` for a module-level cond that wraps a
  # metaprogrammed `def`, keeping its conditions compile-time-inert). Anything
  # unexpected falls back to a plain descent in that context.
  defp analyze_cond_block({key, clauses}, context, mutators) when is_list(clauses),
    do: {key, Enum.map(clauses, &analyze_cond_clause(&1, context, mutators))}

  defp analyze_cond_block(other, context, mutators), do: analyze(other, context, mutators)

  defp analyze_cond_clause({:->, meta, [conds, body]}, context, mutators) when is_list(conds) do
    analyzed_conds =
      Enum.map(conds, fn cond_node ->
        analyzed = analyze(cond_node, context, mutators)

        # Force the condition to true/false (IfCondition) only when it is live —
        # a `:scaffold` cond (module-level metaprogramming) runs once at compile
        # time with mutant 0, so a selector on its condition could never activate.
        if context == :runtime,
          do: attach_if_condition(analyzed, cond_node, mutators),
          else: analyzed
      end)

    {:->, meta, [analyzed_conds, analyze(body, context, mutators)]}
  end

  defp analyze_cond_clause(other, context, mutators), do: analyze(other, context, mutators)

  # One argument of a `defimpl`: a keyword list holding the `do:` block (its body is
  # runtime — analyze it) alongside compile-time entries like `for:` (pass raw). The
  # leading protocol-alias argument is not a list, so it passes through untouched.
  defp analyze_defimpl_arg(kw, mutators) when is_list(kw) do
    Enum.map(kw, fn
      {key, value} = pair ->
        if do_key?(key), do: {key, analyze(value, :runtime, mutators)}, else: pair

      other ->
        other
    end)
  end

  defp analyze_defimpl_arg(other, _mutators), do: other

  # === clause-list pattern structure mutation (case / receive / fn) ==========

  # Analyze the construct normally (bodies/subject mutate), then attach the structural
  # clause-pattern candidates so emission hosts them in the same in-place selector that
  # wraps the whole node. `clauses` is the construct's `->` clause list; `rebuild_fn`
  # rebuilds the whole node from a mutated clause list (the only thing that differs across
  # case/receive/fn). The node-level mutator offer is preserved for parity with the generic
  # runtime clause (a custom mutator matching the whole node; built-ins match none).
  defp attach_clause_pattern_candidates(node, clauses, rebuild_fn, mutators) do
    analyzed = recurse(node, :runtime, mutators)

    candidates =
      build_candidates(node, Mutator.mutations(node, mutators)) ++
        clause_list_candidates(clauses, rebuild_fn, PatternStructure.mutators(mutators))

    case candidates do
      [] -> analyzed
      _ -> put_candidates(analyzed, candidates)
    end
  end

  # The receive's `do` clauses plus a rebuilder that swaps them back into `blocks`
  # (preserving an `after` block). An absent `do` (shouldn't happen) → no clauses and an
  # identity rebuild, so the construct is still analyzed but offers no pattern mutants.
  defp receive_do_clauses(blocks, meta) do
    case Enum.find(blocks, fn {key, _value} -> key_atom(key) == :do end) do
      {_do_key, clauses} when is_list(clauses) ->
        rebuild = fn new ->
          new_blocks =
            Enum.map(blocks, fn {key, value} ->
              if key_atom(key) == :do, do: {key, new}, else: {key, value}
            end)

          {:receive, meta, [new_blocks]}
        end

        {clauses, rebuild}

      _ ->
        {[], fn _new -> {:receive, meta, [blocks]} end}
    end
  end

  # For each clause and each *pattern position* in its head, run the structural mutators and
  # build a `Candidate.CasePattern` whose `replacement` is the whole construct with just that
  # one position restructured (raw clauses → first-order, no nested selectors, like a lifted
  # mutant clause). The diff stays focused on the single changed pattern (always rangeable —
  # Sourceror block-wraps a clause pattern).
  defp clause_list_candidates(_clauses, _rebuild_fn, []), do: []

  defp clause_list_candidates(clauses, rebuild_fn, structural) do
    clauses
    |> Enum.with_index()
    |> Enum.flat_map(fn {clause, index} ->
      replace_clause = fn new_clause ->
        rebuild_fn.(List.replace_at(clauses, index, new_clause))
      end

      clause_pattern_candidates(clause, replace_clause, structural)
    end)
  end

  defp clause_pattern_candidates(clause, replace_clause, structural) do
    case clause_patterns(clause) do
      nil ->
        []

      {patterns, used} ->
        patterns
        |> Enum.with_index()
        |> Enum.flat_map(&position_candidates(&1, clause, replace_clause, used, structural))
    end
  end

  defp position_candidates({pattern, pos}, clause, replace_clause, used, structural) do
    case Sourceror.get_range(pattern) do
      %{} = range ->
        pattern
        |> PatternStructure.node_mutations(used, structural)
        |> Enum.map(fn {mutator, mutated} ->
          %Candidate.CasePattern{
            mutator: mutator,
            original: pattern,
            mutated: mutated,
            replacement: replace_clause.(put_clause_pattern_at(clause, pos, mutated)),
            range: range
          }
        end)

      _ ->
        []
    end
  end

  # A clause's pattern positions plus the names read in its guard/body (the `used_outside`
  # set the wildcard family needs). A guard wraps *all* patterns: `[{:when, _, [p1, …, pN,
  # guard]}]`. Unguarded, the LHS list *is* the patterns (one for case/receive, N for fn).
  # Anything else (a malformed/guard-only LHS) → `nil` (skip). Each pattern is mutated
  # independently, so a duplicate variable *across* fn arguments (`fn x, x -> …`) isn't seen
  # — rare, and within-argument duplicates (`fn {x, x} -> …`) still are.
  defp clause_patterns({:->, _meta, [[{:when, _wm, when_args}], body]})
       when length(when_args) >= 2 do
    {patterns, [guard]} = Enum.split(when_args, -1)
    {patterns, PatternStructure.used_names([guard, body])}
  end

  defp clause_patterns({:->, _meta, [lhs_list, body]}) when is_list(lhs_list) do
    if Enum.any?(lhs_list, &match?({:when, _, _}, &1)),
      do: nil,
      else: {lhs_list, PatternStructure.used_names([body])}
  end

  defp clause_patterns(_clause), do: nil

  # Replace pattern position `pos` of a clause's head with `mutated`, re-wrapping a `when`
  # guard if present (the guard is always the last `when` arg).
  defp put_clause_pattern_at({:->, meta, [[{:when, wm, when_args}], body]}, pos, mutated)
       when length(when_args) >= 2 do
    {patterns, [guard]} = Enum.split(when_args, -1)
    {:->, meta, [[{:when, wm, List.replace_at(patterns, pos, mutated) ++ [guard]}], body]}
  end

  defp put_clause_pattern_at({:->, meta, [lhs_list, body]}, pos, mutated) do
    {:->, meta, [List.replace_at(lhs_list, pos, mutated), body]}
  end

  # === return-value mutation =================================================

  # Attach return-value candidates to the *tail expression(s)* of the clause's
  # return-path blocks — the positions a `def`/`defp` clause returns from. This is
  # structural (a tail is a position no node-level mutator can match), so it runs
  # only when the `Mutare.Mutators.ReturnValue` family is enabled. The `:do` block
  # returns from its body tail; a `rescue`/`catch`/`else` block returns from
  # *every* clause body's tail (a rescued/caught error or an `else` match is a
  # return path too). `:after` is excluded — `try` discards its value.
  #
  # `analyzed_kw` carries the already-attached operator candidates; `raw_kw` is the
  # pre-analysis copy, used only to build each candidate's clean `original`/`range`
  # (so the diff renders the author's tail, un-annotated). The two are structurally
  # identical — analysis only adds metadata — so `map_tail/3` can navigate them in
  # lockstep to the same tail node. `ReturnValue.replacements/1` decides the
  # constant(s) (or that the tail is ineligible).
  defp annotate_returns(analyzed_kw, raw_kw, mutators) do
    if Mutare.Mutators.ReturnValue in mutators do
      [analyzed_kw, raw_kw]
      |> Enum.zip()
      |> Enum.map(fn {{key, analyzed_value}, {_key, raw_value}} ->
        {key, annotate_block_returns(key, analyzed_value, raw_value)}
      end)
    else
      analyzed_kw
    end
  end

  # Route one body block to its return path(s): the `:do` body tail, each
  # `rescue`/`catch`/`else` clause body tail, or — for `:after` (value discarded)
  # and any other key — nothing.
  defp annotate_block_returns(key, analyzed, raw) do
    cond do
      do_key?(key) -> attach_return(analyzed, raw)
      clause_block_key?(key) -> attach_clause_returns(analyzed, raw)
      true -> analyzed
    end
  end

  # rescue/catch/else: a list of `->` clauses; each clause body's tail is a return
  # path. Walk the analyzed and raw clause lists in lockstep (structurally
  # identical) and append a return candidate to each clause body's tail.
  defp attach_clause_returns(analyzed_clauses, raw_clauses)
       when is_list(analyzed_clauses) and is_list(raw_clauses) and
              length(analyzed_clauses) == length(raw_clauses) do
    [analyzed_clauses, raw_clauses]
    |> Enum.zip()
    |> Enum.map(fn {analyzed, raw} -> attach_clause_return(analyzed, raw) end)
  end

  defp attach_clause_returns(analyzed_clauses, _raw), do: analyzed_clauses

  defp attach_clause_return(
         {:->, meta, [patterns, analyzed_body]},
         {:->, _rmeta, [_raw_patterns, raw_body]}
       ) do
    {:->, meta, [patterns, attach_return(analyzed_body, raw_body)]}
  end

  defp attach_clause_return(analyzed, _raw), do: analyzed

  defp do_key?(key), do: key_atom(key) == :do
  defp clause_block_key?(key), do: key_atom(key) in @clause_block_keys

  # The bare keyword atom, whether plain (`:do`) or Sourceror-wrapped
  # (`{:__block__, _, [:do]}`).
  defp key_atom({:__block__, _meta, [atom]}) when is_atom(atom), do: atom
  defp key_atom(atom) when is_atom(atom), do: atom
  defp key_atom(_), do: nil

  # Is `key` the *label* side of a keyword/block pair (so never a runtime value)?
  # Two kinds, both wrapped `{:__block__, meta, [atom]}`: an inline keyword key
  # (`a:`, `timeout:`, `do:` written inline) carries `format: :keyword`; a block key
  # (the `do`/`else`/`rescue`/`catch`/`after` that renders a `do … end`) carries no
  # format marker, so it is recognised by its reserved atom. A plain atom literal in
  # value position (a tuple tag `{:ok, x}`, a `%{:a => …}` arrow key) is neither, so
  # it stays mutatable.
  defp label_key?({:__block__, meta, [atom]}) when is_atom(atom) and is_list(meta),
    do: Keyword.get(meta, :format) == :keyword or atom in @block_keys

  defp label_key?(_), do: false

  # Find the tail expression of a `:do` block (the last statement of a multi-
  # statement block, else the whole single-expression value) and append a
  # return-value candidate per `ReturnValue.replacement`. The candidates ride in
  # the tail node's own `meta[:mutare]` — *after* any operator candidates already
  # there — so emission builds one selector `case` hosting both an operator swap
  # and the return constant on the same node, ids in attachment order.
  defp attach_return(analyzed_value, raw_value) do
    map_tail(analyzed_value, raw_value, fn analyzed_tail, raw_tail ->
      case Mutare.Mutators.ReturnValue.replacements(raw_tail) do
        [] -> analyzed_tail
        replacements -> append_return_candidates(analyzed_tail, raw_tail, replacements)
      end
    end)
  end

  # Apply `fun` to the tail of a (possibly block) value, in lockstep on the
  # analyzed and raw copies. A statement sequence (`>= 2` statements) returns the
  # body with its last statement mapped; anything else is itself the tail. A
  # single-statement `:__block__` (a Sourceror-wrapped literal like `{:__block__,
  # _, [:ok]}`) is intentionally *not* unwrapped — the wrapping block is the node
  # we attach to.
  defp map_tail({:__block__, meta, a_stmts}, {:__block__, _rmeta, r_stmts}, fun)
       when length(a_stmts) >= 2 and length(a_stmts) == length(r_stmts) do
    {a_init, [a_last]} = Enum.split(a_stmts, -1)
    {_r_init, [r_last]} = Enum.split(r_stmts, -1)
    {:__block__, meta, a_init ++ [fun.(a_last, r_last)]}
  end

  defp map_tail(analyzed_value, raw_value, fun), do: fun.(analyzed_value, raw_value)

  # Append a `Candidate.Return` per replacement to the tail node's metadata,
  # preserving any operator candidates already there (so operator ids precede the
  # return id at a shared node). The candidate's `original`/`range` come from the
  # *raw* tail, so the diff is clean. A tail we can't annotate (a non-`{f,m,a}`
  # node, or one Sourceror can't range) gets no return mutant.
  defp append_return_candidates({form, meta, args} = node, raw_tail, replacements)
       when is_list(meta) do
    case Sourceror.get_range(raw_tail) do
      %{} = range ->
        candidates =
          Enum.map(replacements, fn replacement ->
            %Candidate.Return{original: raw_tail, mutated: replacement, range: range}
          end)

        existing = Keyword.get(meta, :mutare, [])
        {form, Keyword.put(meta, :mutare, existing ++ candidates), args}

      _ ->
        node
    end
  end

  defp append_return_candidates(node, _raw_tail, _replacements), do: node

  # Force an `if`/`unless`/`cond` *condition* to `true`/`false` via the in-place
  # selector. `IfCondition.replacements/1` returns the `[true, false]` pair (or `[]`
  # when the condition is a boolean operator `Conditional` already forces, a literal,
  # or a binding `x = …` whose un-binding would poison the body — see that module).
  # Gated on the family being enabled, like `annotate_returns/3`. The candidates are
  # appended to the *analyzed* condition node — after any operator candidate already
  # there, so one selector hosts both — with `original`/`range` taken from the *raw*
  # condition for a clean diff.
  defp attach_if_condition(analyzed_condition, raw_condition, mutators) do
    if Mutare.Mutators.IfCondition in mutators do
      case Mutare.Mutators.IfCondition.replacements(raw_condition) do
        [] ->
          analyzed_condition

        replacements ->
          append_condition_candidates(analyzed_condition, raw_condition, replacements)
      end
    else
      analyzed_condition
    end
  end

  # Append a `Candidate.InPlace` per replacement (`mutator` is the IfCondition
  # *module*, since `Site.in_place/6` calls `.name()` on it) to the condition node's
  # metadata, preserving any candidates already there. A condition we can't range
  # (Sourceror returns nil) or that is not a `{f, m, a}` node gets no mutant.
  defp append_condition_candidates({form, meta, args} = node, raw_condition, replacements)
       when is_list(meta) do
    case Sourceror.get_range(raw_condition) do
      %{} = range ->
        candidates =
          Enum.map(replacements, fn mutated ->
            %Candidate.InPlace{
              mutator: Mutare.Mutators.IfCondition,
              original: raw_condition,
              mutated: mutated,
              range: range
            }
          end)

        existing = Keyword.get(meta, :mutare, [])
        {form, Keyword.put(meta, :mutare, existing ++ candidates), args}

      _ ->
        node
    end
  end

  defp append_condition_candidates(node, _raw_condition, _replacements), do: node

  # A bitstring segment `<<value::spec>>`: the value keeps the surrounding
  # context; the spec side is excluded except for `size(expr)` args.
  defp analyze_segment({:"::", meta, [value, spec]}, context, mutators) do
    {:"::", meta, [analyze(value, context, mutators), analyze_spec(spec, context, mutators)]}
  end

  defp analyze_segment(segment, context, mutators), do: analyze(segment, context, mutators)

  # The type-specifier side of a bitstring segment. Separators (`-`), type atoms
  # and `unit(...)` stay raw — a swapped `-` is an illegal specifier and a `case`
  # is illegal in a spec. `size(expr)` is the one runtime sub-position: its arg is
  # recursed in the segment's context (mutated in a body, pruned in a pattern).
  defp analyze_spec({:-, meta, [left, right]}, context, mutators),
    do:
      {:-, meta, [analyze_spec(left, context, mutators), analyze_spec(right, context, mutators)]}

  defp analyze_spec({:size, meta, [arg]}, context, mutators),
    do: {:size, meta, [analyze(arg, context, mutators)]}

  defp analyze_spec(other, _context, _mutators), do: other

  # Is this node form a sigil (`~r`, `~D`, `~w`, a custom `~X`)? Sigils parse as
  # `{:sigil_<name>, _, [<<>>, modifiers]}`; the analyzer offers the whole node to
  # the sigil mutators and descends into its content via `descend_sigil/2`.
  defp sigil?(form) when is_atom(form) do
    case Atom.to_string(form) do
      "sigil_" <> _ -> true
      _ -> false
    end
  end

  defp sigil?(_), do: false

  # Descend into a sigil's content `<<>>` *segments* (so an interpolated expression
  # like `~r/a#{b}c/` still mutates `b` — a genuine runtime sub-position) without
  # ever offering the content `<<>>` *wrapper* to a mutator: a sigil's content is
  # not a user-written bitstring literal, so collapsing it (BitstringLiteral) or
  # splicing a selector into it would be illegal. The modifier list is left raw; the
  # sigil node itself was already offered to the sigil mutators by the caller. A
  # bare-binary segment (`~r/foo/`'s `"foo"`) is descended too but offers nothing.
  defp descend_sigil({sigil, meta, [{:<<>>, bmeta, segments}, modifiers]}, mutators) do
    content = {:<<>>, bmeta, Enum.map(segments, &analyze_segment(&1, :runtime, mutators))}
    {sigil, meta, [content, modifiers]}
  end

  defp descend_sigil(node, _mutators), do: node

  defp build_candidates(node, muts) do
    range = Sourceror.get_range(node)

    Enum.map(muts, fn {mutator, mutated} ->
      %Candidate.InPlace{mutator: mutator, original: node, mutated: mutated, range: range}
    end)
  end

  defp put_candidates({form, meta, args}, candidates),
    do: {form, [{:mutare, candidates} | meta], args}

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

  # === shared helpers ========================================================

  # The liveness a child *body* inherits from its construct. A `:scaffold`
  # (compile-time metaprogramming) parent keeps its child bodies compile-time too —
  # so a `case`/`cond`/`with`/`fn` that wraps a `def` at module level does not mutate
  # its own arms — while every other context yields an ordinary runtime body. The one
  # construct that flips a `:scaffold` descent back to `:runtime` is a `def`/`defp`
  # body, done explicitly in its own clause (a generated function's body *is* runtime).
  defp body_context(:scaffold), do: :scaffold
  defp body_context(_), do: :runtime

  defp function_ref?({name, _meta, context}) when is_atom(name) and is_atom(context), do: true
  defp function_ref?({{:., _, _}, _meta, args}) when is_list(args), do: true
  defp function_ref?(_), do: false

  defp integer_literal?(n) when is_integer(n), do: true
  defp integer_literal?({:__block__, _meta, [n]}) when is_integer(n), do: true
  defp integer_literal?(_), do: false
end
