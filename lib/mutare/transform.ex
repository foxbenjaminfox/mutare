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
      candidates (`Candidate.Guard` / `Candidate.Drop`) it admits.
    * `Mutare.Transform.Candidate.{InPlace,Guard,Drop}` — the typed, pre-id
      description of a single mutant. One struct per legal kind, so the redundant
      `context`/`kind`/`operation` triple (and its illegal combinations) is gone.

  The stages, run per subtree:

    1. **Analyze + classify** — `analyze/3` is one context-threaded recursive
       descent: it *names the context* of each position as it descends and, for
       every node a mutator recognises *in a mutating context*, attaches a typed
       `Candidate.InPlace` to the node's own metadata (`meta[:mutare]`). Mutators
       run **once**, here. Routing is positional (the spec side of a `::` goes one
       way, the value side another), which is why it can't be a flat
       `Macro.traverse` accumulator. Two contexts are threaded — `:runtime`
       (mutate, → in-place; `:guard`/`:clause_drop` come from the lift path) and
       `:pattern` (don't mutate, but keep descending so default-arg values and
       `size()` args are reached); the rest (`:compile_time`, `:spec`, `:guard`,
       `:capture_arity`) are recognised and pruned, producing no candidate.
    2. **Plan** — a statement sequence is grouped into a `ModulePlan`; each
       liftable clause group becomes a `FunctionPlan` carrying its lifted
       candidates. No ids are assigned yet.
    3. **Assign** — emission walks the plan and the annotated tree bottom-up and
       hands each candidate the next mutant id. Ids are assigned in post-order DFS
       and the counter advances even for `:skip_ids`, so ids stay stable across
       the poison-recovery rebuilds the runner relies on.
    4. **Emit** — an in-place candidate becomes a tail-position selector `case`; a
       `FunctionPlan` is duplicated into `__orig`/`__mut` copies behind a dispatcher.
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

  ## Function lifting + dispatcher (guards, dispatch)

  A `case` is illegal in a `when` guard, and guards drive dispatch *across*
  clauses, so guard mutations cannot be done in place. Instead every clause for
  the function signature is duplicated — once unchanged (`__orig`), once per
  mutation (`__mut`) — and a bare catch-all dispatcher forwards args to the
  active copy by id:

      def f(a) do
        case :persistent_term.get(:mutare_active, 0) do
          5 -> __mutare_f_1_m5(a)     # guard mutated in this copy
          _ -> __mutare_f_1_orig(a)
        end
      end
      defp __mutare_f_1_orig(a) when a >= 1, do: ...   # in-place applies here
      defp __mutare_f_1_m5(a) when a > 1, do: ...       # one guard changed

  In-place selectors live only in `__orig` (and in non-lifted code); the `__mut`
  copies reuse the original bodies — sound because exactly one mutant is ever
  active. The public `f/arity` is unchanged at the module boundary.

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
  alias Mutare.Transform.{Candidate, Ctx, FunctionPlan, ModulePlan, Render}

  # The default set is the built-in catalog's `all/0` — one source of truth, so a
  # family registered in `Mutare.Mutators` is part of the default automatically.
  @default_mutators Mutare.Mutators.all()

  # The canonical prefix for generated private (lifted) names. `generated_prefix/1`
  # derives a per-file, collision-free variant of it (see that function).
  @base_prefix "__mutare_"

  # def-like forms whose names a generated private `defp` could duplicate — the
  # set `generated_prefix/1` scans the source for.
  @def_forms ~w(def defp defmacro defmacrop defguard defguardp defdelegate)a

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
    # Pin a generated-name prefix this source provably never collides with before
    # any lifting assigns private names (see `generated_prefix/1`).
    ctx = %{ctx | prefix: generated_prefix(parsed)}
    {transformed, ctx} = transform_node(parsed, ctx)

    metamutant = Render.to_source(transformed)

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
        {node, ctx} = transform_node(statement, ctx)
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

  # Emit a lifted clause group: the `__orig` copies (carrying in-place body
  # selectors), one private `__mut` copy per lifted candidate, and the public
  # dispatcher. In-place body ids are claimed first (in the `__orig` copies), then
  # the lifted candidates in `FunctionPlan.candidates/1` order — preserving id
  # ordering. A skipped (poisoned) id records its site but emits no copy/clause.
  defp emit_function_plan(%FunctionPlan{signature: {vis, name, arity}} = plan, ctx) do
    group = ctx.group + 1
    ctx = %{ctx | group: group}
    base = base_name(name, arity, group, ctx.prefix)

    {orig_clauses, ctx} = in_place_clauses(plan.clauses, ctx)
    orig_defs = Enum.map(orig_clauses, &rename_clause(&1, :"#{base}_orig", :defp))

    {mut_results, ctx} =
      Enum.flat_map_reduce(FunctionPlan.candidates(plan), ctx, fn candidate, ctx ->
        claim_id(ctx, candidate, &lifted_site/3, fn id, candidate ->
          defs =
            plan
            |> FunctionPlan.mutated_clauses(candidate)
            |> Enum.map(&rename_clause(&1, :"#{base}_m#{id}", :defp))

          {id, defs}
        end)
      end)

    mut_ids = Enum.map(mut_results, &elem(&1, 0))
    mut_defs = Enum.flat_map(mut_results, &elem(&1, 1))
    dispatcher = build_dispatcher(vis, name, arity, mut_ids, base)

    {[dispatcher | orig_defs] ++ mut_defs, ctx}
  end

  # def f(mutare_arg1, ...) do
  #   case :persistent_term.get(:mutare_active, 0) do
  #     <id> -> <base>_m<id>(mutare_arg1, ...) ; _ -> <base>_orig(mutare_arg1, ...)
  #   end
  # end
  defp build_dispatcher(vis, name, arity, mut_ids, base) do
    args = dispatcher_args(arity)
    selector = Mutare.Metamutant.subject_ast()

    mut_clauses =
      Enum.map(mut_ids, fn id -> {:->, [], [[id], {:"#{base}_m#{id}", [], args}]} end)

    catch_all = catch_all_clause(mut_ids, {:"#{base}_orig", [], args})
    body = {:case, [], [selector, [do: mut_clauses ++ [catch_all]]]}

    {vis, [], [{name, [], args}, [do: body]]}
  end

  defp dispatcher_args(0), do: []
  defp dispatcher_args(arity), do: Enum.map(1..arity, &{:"mutare_arg#{&1}", [], nil})

  # Private base name for a lifted group. `prefix` is the file's collision-free
  # generated-name prefix (`Ctx.prefix`, normally `"__mutare_"`); the trailing
  # `g<group>` keeps generated names unique across groups; `?`/`!` (valid only at
  # the end of a function name) are replaced so they can sit mid-identifier in
  # `<base>_orig` / `<base>_m<id>`. The public dispatcher keeps the real name
  # (including any `?`/`!`).
  defp base_name(name, arity, group, prefix) do
    sanitized = name |> Atom.to_string() |> String.replace(["?", "!"], "_")
    "#{prefix}#{sanitized}_#{arity}_g#{group}"
  end

  # === generated-name collision avoidance ====================================

  # The prefix for this file's generated private (lifted) names. With the
  # canonical `"__mutare_"` a clash with a hand-written target definition is
  # near-impossible — but a single clash is catastrophic (a duplicate `defp`
  # sinks the *one* metamutant build with a cryptic compile error), so we pick a
  # prefix the source provably never collides with. Every candidate still starts
  # with `"__mutare_"`, so `Mutare.Manifest`'s `__mutare_…_m<id>` recogniser keeps
  # working unchanged.
  defp generated_prefix(ast) do
    names = defined_names(ast)
    Enum.find(prefix_candidates(), &free?(&1, names))
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

  # A prefix is free when no source definition name begins with it: then no
  # `<prefix>…` name we generate can equal an existing one.
  defp free?(prefix, names), do: not Enum.any?(names, &String.starts_with?(&1, prefix))

  # Every name defined by a def-like form anywhere in the source (functions,
  # macros, guards, delegates) — the names a generated private `defp` could
  # duplicate. Over-collecting (e.g. a name inside a quoted macro body) is safe:
  # it can only make us salt a prefix we'd otherwise have kept.
  defp defined_names(ast) do
    {_ast, names} =
      Macro.prewalk(ast, MapSet.new(), fn
        {form, _meta, [head | _]} = node, acc when form in @def_forms ->
          case def_name(head) do
            nil -> {node, acc}
            name -> {node, MapSet.put(acc, Atom.to_string(name))}
          end

        node, acc ->
          {node, acc}
      end)

    names
  end

  defp def_name({:when, _meta, [call | _guards]}), do: def_name(call)
  defp def_name({name, _meta, _args}) when is_atom(name), do: name
  defp def_name(_), do: nil

  defp rename_clause({_vis, meta, [head | rest]}, new_name, new_vis) do
    {new_vis, meta, [rename_head(head, new_name) | rest]}
  end

  defp rename_head({:when, meta, [call | guards]}, new_name),
    do: {:when, meta, [rename_call(call, new_name) | guards]}

  defp rename_head(call, new_name), do: rename_call(call, new_name)

  defp rename_call({_name, meta, args}, new_name), do: {new_name, meta, args}

  # === sites: pick the constructor from the candidate variant =================

  # Transform owns which constructor each candidate maps to; `Mutare.Site` owns
  # the struct's fields. The candidate's *type* (not a stored `kind`/`operation`)
  # selects the shape.
  defp in_place_site(id, %Candidate.InPlace{} = c, file) do
    Site.in_place(id, file, c.range, c.original, c.mutated, c.mutator)
  end

  defp lifted_site(id, %Candidate.Guard{} = c, file) do
    Site.lifted_guard(id, file, c.range, c.original, c.mutated, c.mutator)
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
  # side of a `::` one way and the value side another). Two contexts are threaded:
  #
  #   * `:runtime` — mutate in place. A node a mutator recognises gets a
  #     `Candidate.InPlace` attached to its own metadata; the candidate is built
  #     from the *raw* node (un-annotated children — what the report renders)
  #     before we descend.
  #   * `:pattern` — never mutate, but keep descending so nested runtime escapes
  #     (default-argument values, `size(...)` args) are still reached.
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

  # A `def`/`defp` clause reaching the in-place path (one that did not lift): the
  # head is a pattern, the body keyword is runtime.
  defp analyze({vis, meta, [head, body_kw]}, _context, mutators)
       when vis in [:def, :defp] and is_list(body_kw) do
    {vis, meta, [analyze(head, :pattern, mutators), analyze_do_blocks(body_kw, mutators)]}
  end

  # bitstring: each segment's value keeps the surrounding context; the spec side
  # is excluded except for `size(expr)` args (`analyze_segment/3`).
  defp analyze({:<<>>, meta, segments}, context, mutators) do
    {:<<>>, meta, Enum.map(segments, &analyze_segment(&1, context, mutators))}
  end

  # match `=`: the left side is a pattern, the right keeps the context.
  defp analyze({:=, meta, [lhs, rhs]}, context, mutators) do
    {:=, meta, [analyze(lhs, :pattern, mutators), analyze(rhs, context, mutators)]}
  end

  # default argument inside a pattern (`x \\ expr`): the variable is a pattern,
  # but the default runs at call time → runtime (don't regress its mutation).
  defp analyze({:\\, meta, [var, default]}, :pattern, mutators) do
    {:\\, meta, [analyze(var, :pattern, mutators), analyze(default, :runtime, mutators)]}
  end

  # a generic runtime node: build the candidate from the raw node (so `original`
  # keeps un-annotated children), then descend into the children.
  defp analyze({_form, _meta, _args} = node, :runtime, mutators) do
    case Mutator.mutations(node, mutators) do
      [] ->
        recurse(node, :runtime, mutators)

      muts ->
        node
        |> put_candidates(build_candidates(node, muts))
        |> recurse(:runtime, mutators)
    end
  end

  # anything else — a node in a non-runtime context, or a container/leaf:
  # descend without mutating so boundary forms (`\\`, `<<>>`) still fire on
  # children, but attach no candidate here.
  defp analyze(node, context, mutators), do: recurse(node, context, mutators)

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

  # The body keyword of a clause (`[do: …, rescue: …, after: …]`, possibly with
  # Sourceror's `{:__block__, _, [:do]}` keys): every block value is runtime.
  defp analyze_do_blocks(body_kw, mutators) do
    Enum.map(body_kw, fn {key, value} -> {key, analyze(value, :runtime, mutators)} end)
  end

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
        [] -> {current, ctx}
        candidates -> emit_site(current, candidates, ctx)
      end
    end)
  end

  defp emit_site(node, candidates, ctx) do
    {clauses, ctx} =
      Enum.flat_map_reduce(candidates, ctx, fn candidate, ctx ->
        claim_id(ctx, candidate, &in_place_site/3, fn id, candidate ->
          {:->, [], [[id], candidate.mutated]}
        end)
      end)

    default = strip_candidates(node)

    # All mutations here skipped → no selector; emit the node unchanged.
    case clauses do
      [] -> {default, ctx}
      _ -> {build_case(default, clauses), ctx}
    end
  end

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
  defp build_case(default_node, mutant_clauses) do
    selector = Mutare.Metamutant.subject_ast()
    ids = for {:->, _, [[id], _]} <- mutant_clauses, do: id
    catch_all = catch_all_clause(ids, default_node)
    case_node = {:case, [], [selector, [do: mutant_clauses ++ [catch_all]]]}
    Render.block_wrap(case_node)
  end

  # The selector catch-all (`mutare_active -> …`): the baseline + every-inactive-
  # mutant branch. It carries the coverage record (inert outside the probe, see
  # `Mutare.Coverage.Recorder`) *before* the original, so the original stays the
  # clause's last expression — preserving tail position / LCO in the dispatcher.
  # With no ids to attribute (an all-poisoned lifted group) there is nothing to
  # record, so the plain `_ ->` is emitted unchanged.
  defp catch_all_clause([], default_node), do: {:->, [], [[{:_, [], nil}], default_node]}

  defp catch_all_clause(ids, default_node) do
    body = {:__block__, [], [Recorder.record_ast(ids), default_node]}
    {:->, [], [[Recorder.catch_all_pattern()], body]}
  end

  # === shared helpers ========================================================

  defp function_ref?({name, _meta, context}) when is_atom(name) and is_atom(context), do: true
  defp function_ref?({{:., _, _}, _meta, args}) when is_list(args), do: true
  defp function_ref?(_), do: false

  defp integer_literal?(n) when is_integer(n), do: true
  defp integer_literal?({:__block__, _meta, [n]}) when is_integer(n), do: true
  defp integer_literal?(_), do: false
end
