defmodule Mutare.Transform do
  @moduledoc """
  Source → metamutant transform, expressed as an explicit pipeline.

  Rather than walk every node and then *subtract* the positions that must not be
  mutated (the old blacklist), the transform classifies each node's context
  *positively* and routes it. One pipeline, run per subtree:

    1. **Analyze + classify** — `analyze/3` is one context-threaded recursive
       descent: it *names the context* of each position as it descends and, for
       every node a mutator recognises *in a mutating context*, attaches a typed
       `Candidate` to the node's own metadata (`meta[:mutare]`). Mutators run
       **once**, here. Routing is positional (the spec side of a `::` goes one
       way, the value side another), which is why it can't be a flat
       `Macro.traverse` accumulator. Two contexts are threaded — `:runtime`
       (mutate, → in-place; `:guard`/`:clause_drop` come from the lift path) and
       `:pattern` (don't mutate, but keep descending so default-arg values and
       `size()` args are reached); the rest (`:compile_time`, `:spec`, `:guard`,
       `:capture_arity`) are recognised and pruned, producing no candidate.
    3. **Assign** — `emit/2` walks the annotated tree bottom-up and hands each
       candidate the next mutant id. Ids are assigned in post-order DFS and the
       counter advances even for `:skip_ids`, so ids stay stable across the
       poison-recovery rebuilds the runner relies on.
    4. **Emit** — an in-place candidate becomes a tail-position selector `case`;
       a clause group with lifted candidates is duplicated into
       `__orig`/`__mut` copies behind a dispatcher.
    5. **Render** — annotations are stripped and the tree is rendered to source
       (with a Sourceror keyword-block workaround); `# mutare:ignore` directives
       (parsed by `Mutare.Ignore`) are applied to the recorded sites.

  Carrying the `Candidate` in the node's *own* metadata is what lets emission
  find "this exact node" without a fragile `{line, column}` identity: metadata is
  intrinsic to the node and rides through any `Macro` rebuild, so duplicate
  subtrees can never collide.

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
  """

  require Logger

  alias Mutare.Site
  alias Mutare.Transform.{Candidate, Ctx, Render}

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
    {transformed, ctx} = transform_node(parsed, ctx)

    metamutant = Render.to_source(transformed)

    # Reuse the AST we just parsed — its comment metadata is intact (transform
    # works on copies), so `Ignore` need not re-parse the source.
    ignored = Mutare.Ignore.ignored_lines_from_ast(parsed)
    sites = Enum.map(Enum.reverse(ctx.sites), &%{&1 | ignored: &1.line in ignored})

    {metamutant, sites, ctx.next_id}
  end

  # === module / statement structure =========================================

  # A module: transform the body of its do-block(s).
  defp transform_node({:defmodule, meta, [alias_node, do_keyword]}, ctx)
       when is_list(do_keyword) do
    {do_keyword, ctx} = transform_do_keyword(do_keyword, ctx)
    {{:defmodule, meta, [alias_node, do_keyword]}, ctx}
  end

  # A block: either a module body (contains clauses → group + lift) or an
  # ordinary sequence (recurse so nested modules are still reached).
  defp transform_node({:__block__, meta, statements}, ctx) do
    if Enum.any?(statements, &clause_signature/1) do
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

  defp transform_statements(statements, ctx) do
    chunks = chunk_clause_runs(statements)
    non_consecutive = non_consecutive_signatures(chunks)
    warn_non_consecutive(non_consecutive, ctx.file)

    {transformed, ctx} =
      Enum.flat_map_reduce(chunks, ctx, fn
        {:clauses, clauses}, ctx ->
          if clause_signature(hd(clauses)) in non_consecutive do
            # Non-consecutive heads can't be lifted (for now). A dispatcher is a
            # catch-all for the whole signature, so lifting one run would shadow
            # the others; and lifting every run as one unit relocates each
            # clause's body to the dispatcher's position — which silently changes
            # semantics when a compile-time `@attr` read between the heads resolves
            # differently there (`@a 1; def f(0), do: @a; @a 2; def f(1), do: @a`).
            # Fall back to in-place; guard/clause-drop mutants are simply not
            # offered for such functions.
            in_place_clauses(clauses, ctx)
          else
            transform_clause_group(clauses, ctx)
          end

        {:other, statement}, ctx ->
          {node, ctx} = transform_node(statement, ctx)
          {[node], ctx}
      end)

    {transformed, ctx}
  end

  # Signatures whose clauses are split across more than one consecutive run —
  # something (another definition, a module attribute) appears between them.
  # These are the functions Transform refuses to lift.
  defp non_consecutive_signatures(chunks) do
    chunks
    |> Enum.flat_map(fn
      {:clauses, clauses} -> [clause_signature(hd(clauses))]
      {:other, _statement} -> []
    end)
    |> Enum.frequencies()
    |> Enum.flat_map(fn
      {signature, count} when count > 1 -> [signature]
      {_signature, _count} -> []
    end)
    |> MapSet.new()
  end

  # Lifting is silently disabled for non-consecutive clauses, which costs that
  # function its guard and clause-drop mutants. Warn once per signature so the
  # gap is visible (and actionable — grouping the clauses restores lifting).
  defp warn_non_consecutive(signatures, file) do
    Enum.each(signatures, fn {_vis, name, arity} ->
      Logger.warning(
        "#{file}: clauses of #{name}/#{arity} are non-consecutive — not lifting " <>
          "(no guard or clause-drop mutants for it); group the clauses to enable lifting"
      )
    end)
  end

  # Group maximal runs of consecutive clauses that share {visibility, name, arity}.
  # A signature appearing in more than one run is "non-consecutive" (see
  # non_consecutive_signatures/1) and is never lifted.
  defp chunk_clause_runs(statements) do
    statements
    |> Enum.reduce([], fn statement, acc ->
      case {clause_signature(statement), acc} do
        {nil, acc} ->
          [{:other, statement} | acc]

        {sig, [{:clauses, sig, clauses} | rest]} ->
          [{:clauses, sig, [statement | clauses]} | rest]

        {sig, acc} ->
          [{:clauses, sig, [statement]} | acc]
      end
    end)
    |> Enum.map(fn
      {:clauses, _sig, clauses} -> {:clauses, Enum.reverse(clauses)}
      other -> other
    end)
    |> Enum.reverse()
  end

  # === clause groups: lift, or mutate bodies in place ========================

  # Transform a run of consecutive same-signature clauses that wasn't pre-grouped
  # for lifting (so its complete group stays in place). A run can still lift on
  # its own — recompute the plan against just these clauses.
  defp transform_clause_group(clauses, ctx) do
    case lift_plan(clauses, ctx.mutators) do
      {:lift, candidates} -> lift(clauses, candidates, ctx)
      :in_place -> in_place_clauses(clauses, ctx)
    end
  end

  # Transform each clause in place (body selectors only), preserving its position.
  defp in_place_clauses(clauses, ctx) do
    Enum.flat_map_reduce(clauses, ctx, fn clause, ctx ->
      {clause, ctx} = in_place(clause, ctx)
      {[clause], ctx}
    end)
  end

  # The lift decision, in one place. A clause group lifts when the mutators find
  # a guard swap (or there are droppable clauses) and the group can host a
  # dispatcher. Returns the candidates so callers lift without recomputing them.
  defp lift_plan(clauses, mutators) do
    {_vis, name, _arity} = clause_signature(hd(clauses))
    candidates = lifted_candidates(clauses, mutators)

    if candidates != [] and liftable?(name, clauses) do
      {:lift, candidates}
    else
      :in_place
    end
  end

  # All lifted candidates for a clause group: guard operator swaps + clause drops.
  defp lifted_candidates(clauses, mutators) do
    guard_candidates(clauses, mutators) ++ clause_drop_candidates(clauses)
  end

  # Drop one clause of a multi-clause function. Inputs the dropped clause handled
  # now fall to a later clause (or raise FunctionClauseError) — killed if tested.
  defp clause_drop_candidates(clauses) when length(clauses) < 2, do: []

  defp clause_drop_candidates(clauses) do
    clauses
    |> Enum.with_index()
    |> Enum.map(fn {clause, index} ->
      %Candidate{
        context: :clause_drop,
        kind: :lifted,
        operation: :delete,
        mutator: nil,
        original: clause,
        mutated: nil,
        range: Sourceror.get_range(clause),
        clause_index: index
      }
    end)
  end

  defp lift(clauses, candidates, ctx) do
    {vis, name, arity} = clause_signature(hd(clauses))
    group = ctx.group + 1
    ctx = %{ctx | group: group}
    base = base_name(name, arity, group)

    # The unchanged copy carries the in-place selectors (body mutations).
    {orig_clauses, ctx} = in_place_clauses(clauses, ctx)
    orig_defs = Enum.map(orig_clauses, &rename_clause(&1, :"#{base}_orig", :defp))

    # One private copy per lifted candidate (original bodies, one change applied).
    # A skipped (poisoned) id records its site but emits no copy/dispatcher clause.
    {mut_results, ctx} =
      Enum.flat_map_reduce(candidates, ctx, fn candidate, ctx ->
        claim_id(ctx, candidate, &lifted_site/3, fn id, candidate ->
          defs =
            candidate
            |> apply_lifted_candidate(clauses)
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

    catch_all = {:->, [], [[{:_, [], nil}], {:"#{base}_orig", [], args}]}
    body = {:case, [], [selector, [do: mut_clauses ++ [catch_all]]]}

    {vis, [], [{name, [], args}, [do: body]]}
  end

  defp dispatcher_args(0), do: []
  defp dispatcher_args(arity), do: Enum.map(1..arity, &{:"mutare_arg#{&1}", [], nil})

  # Private base name for a lifted group. The trailing `g<group>` keeps generated
  # names unique; `?`/`!` (valid only at the end of a function name) are replaced
  # so they can sit mid-identifier in `<base>_orig` / `<base>_m<id>`. The public
  # dispatcher keeps the real name (including any `?`/`!`).
  defp base_name(name, arity, group) do
    sanitized = name |> Atom.to_string() |> String.replace(["?", "!"], "_")
    "__mutare_#{sanitized}_#{arity}_g#{group}"
  end

  defp rename_clause({_vis, meta, [head | rest]}, new_name, new_vis) do
    {new_vis, meta, [rename_head(head, new_name) | rest]}
  end

  defp rename_head({:when, meta, [call | guards]}, new_name),
    do: {:when, meta, [rename_call(call, new_name) | guards]}

  defp rename_head(call, new_name), do: rename_call(call, new_name)

  defp rename_call({_name, meta, args}, new_name), do: {new_name, meta, args}

  # === lifted candidates: guard swaps & clause drops =========================

  # Every operator the mutators recognise, in every clause's guard, as a typed
  # `:guard` candidate. Delivered by lifting (a guard can't host a `case`), but
  # the mutation set is the same swap logic the in-place mutators use — and
  # operator swaps stay guard-safe. Each candidate carries the whole clause group
  # with that one guard already swapped (`mutated_clauses`), so emission never
  # re-finds the node: the target is tagged in metadata and replaced once, here.
  defp guard_candidates(clauses, mutators) do
    clauses
    |> Enum.with_index()
    |> Enum.flat_map(fn {clause, index} ->
      guard_candidates_for(clause, index, clauses, mutators)
    end)
  end

  defp guard_candidates_for(clause, index, clauses, mutators) do
    case guards_of(clause) do
      [] ->
        []

      guards ->
        {tagged_guards, {_next, targets}} =
          Enum.map_reduce(guards, {0, []}, fn guard, acc -> tag_targets(guard, acc, mutators) end)

        tagged_clause = put_guards(clause, tagged_guards)

        targets
        |> Enum.reverse()
        |> Enum.flat_map(fn {tag, original, muts} ->
          Enum.map(muts, fn {mutator, mutated} ->
            mutated_clause = replace_tag(tagged_clause, tag, mutated)

            %Candidate{
              context: :guard,
              kind: :lifted,
              operation: :replace,
              mutator: mutator,
              original: original,
              mutated: mutated,
              range: Sourceror.get_range(original),
              clause_index: index,
              mutated_clauses: List.replace_at(clauses, index, mutated_clause)
            }
          end)
        end)
    end
  end

  # Tag every mutatable operator in a guard with a unique `meta[:mutare_tag]`
  # (an explicit, collision-free reference — the replacement for `{line,
  # column}`), accumulating `{tag, original_node, mutations}`. Post-order DFS
  # (children before parents), matching the in-place emit ordering so guard ids
  # are assigned in the same order. `mutate/1` runs on the node as visited, and
  # a nested guard operator's child may already carry a `:mutare_tag` — harmless,
  # since tags don't affect ranges/rendering and are stripped before output.
  defp tag_targets(guard, acc, mutators) do
    Macro.postwalk(guard, acc, fn node, {next, targets} ->
      case mutations(node, mutators) do
        [] -> {node, {next, targets}}
        muts -> {put_tag(node, next), {next + 1, [{next, node, muts} | targets]}}
      end
    end)
  end

  defp put_tag({form, meta, args}, tag), do: {form, [{:mutare_tag, tag} | meta], args}

  defp replace_tag(ast, tag, replacement) do
    Macro.prewalk(ast, fn
      {_form, meta, _args} = node when is_list(meta) ->
        if Keyword.get(meta, :mutare_tag) == tag, do: replacement, else: node

      node ->
        node
    end)
  end

  defp guards_of({_vis, _meta, [{:when, _, [_call | guards]} | _rest]}), do: guards
  defp guards_of(_), do: []

  defp put_guards({vis, meta, [{:when, when_meta, [call | _guards]} | rest]}, new_guards),
    do: {vis, meta, [{:when, when_meta, [call | new_guards]} | rest]}

  # Materialise a lifted candidate into the mutated clause group.
  defp apply_lifted_candidate(%Candidate{context: :guard, mutated_clauses: clauses}, _clauses),
    do: clauses

  defp apply_lifted_candidate(%Candidate{context: :clause_drop, clause_index: index}, clauses),
    do: List.delete_at(clauses, index)

  # Build the %Site{} for one candidate. Transform owns the candidate's shape and
  # picks the constructor; Site owns the struct fields.
  defp in_place_site(id, %Candidate{} = c, file) do
    Site.in_place(id, file, c.range, c.original, c.mutated, c.mutator)
  end

  defp lifted_site(id, %Candidate{context: :guard} = c, file) do
    Site.lifted_guard(id, file, c.range, c.original, c.mutated, c.mutator)
  end

  defp lifted_site(id, %Candidate{context: :clause_drop} = c, file) do
    Site.clause_drop(id, file, c.range, c.original)
  end

  # === clause signatures & liftability ======================================

  defp clause_signature({vis, _meta, [head | _rest]}) when vis in [:def, :defp] do
    case name_arity(head) do
      {name, arity} -> {vis, name, arity}
      :error -> nil
    end
  end

  defp clause_signature(_), do: nil

  defp name_arity({:when, _, [call | _guards]}), do: name_arity(call)
  defp name_arity({name, _, args}) when is_atom(name) and is_list(args), do: {name, length(args)}
  defp name_arity({name, _, context}) when is_atom(name) and is_atom(context), do: {name, 0}
  defp name_arity(_), do: :error

  # We can only lift functions whose name is a plain identifier (operator names
  # like `<>` can't be spelled as `__mutare_<>_2_orig(...)`) and which have no
  # default arguments (those expand to multiple arities; normalize-then-lift is
  # later work). Such groups fall back to in-place only.
  defp liftable?(name, clauses) do
    Regex.match?(~r/\A[a-z_][a-zA-Z0-9_]*[?!]?\z/, Atom.to_string(name)) and
      not Enum.any?(clauses, &default_args?/1)
  end

  defp default_args?({_vis, _meta, [head | _rest]}) do
    head |> head_args() |> Enum.any?(&match?({:\\, _, _}, &1))
  end

  defp head_args({:when, _, [call | _guards]}), do: head_args(call)
  defp head_args({_name, _, args}) when is_list(args), do: args
  defp head_args(_), do: []

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
  #     `:runtime_body` candidate attached to its own metadata; the candidate is
  #     built from the *raw* node (un-annotated children — what the report
  #     renders) before we descend.
  #   * `:pattern` — never mutate, but keep descending so nested runtime escapes
  #     (default-argument values, `size(...)` args) are still reached.
  #
  # The remaining contexts are recognised positively and realised as pruned
  # subtrees or dedicated helpers (named here, matched in the clauses below):
  #
  #   * `:compile_time` — module-attribute values (`@x <expr>`) and macro bodies
  #     (`defmacro`/`defmacrop`). Frozen at compile time / macro-expansion time,
  #     so a runtime selector there can never activate. Pruned whole.
  #   * `:spec` — the type-specifier side of a bitstring `::` segment. A `case`
  #     is illegal there and a swapped `-` separator is an illegal specifier;
  #     only `size(expr)` args are a genuine runtime sub-position (`analyze_spec/3`).
  #   * `:guard` — `when` guards, owned by the lift path (a `case` can't live in a
  #     guard). Pruned here; `tag_targets/3` mutates them by lifting instead.
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
    case mutations(node, mutators) do
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
      %Candidate{
        context: :runtime_body,
        kind: :in_place,
        operation: :replace,
        mutator: mutator,
        original: node,
        mutated: mutated,
        range: range
      }
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
  # leans on. Both the in-place path (emit_site/3) and the lifted path (lift/3)
  # route every candidate through here, so ids advance identically — even for a
  # skipped (poisoned) id — and stay stable across rebuilds. Keeping this in one
  # place is what stops the two paths from drifting out of lockstep.
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
    catch_all = {:->, [], [[{:_, [], nil}], default_node]}
    case_node = {:case, [], [selector, [do: mutant_clauses ++ [catch_all]]]}
    Render.block_wrap(case_node)
  end

  # === shared helpers ========================================================

  defp function_ref?({name, _meta, context}) when is_atom(name) and is_atom(context), do: true
  defp function_ref?({{:., _, _}, _meta, args}) when is_list(args), do: true
  defp function_ref?(_), do: false

  defp integer_literal?(n) when is_integer(n), do: true
  defp integer_literal?({:__block__, _meta, [n]}) when is_integer(n), do: true
  defp integer_literal?(_), do: false

  defp mutations(node, mutators) do
    Enum.flat_map(mutators, fn mutator ->
      case mutator.mutate(node) do
        :skip -> []
        nodes when is_list(nodes) -> Enum.map(nodes, &{mutator, &1})
      end
    end)
  end
end
