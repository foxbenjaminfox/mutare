defmodule Mutare.Transform do
  @moduledoc """
  Source → metamutant transform, expressed as an explicit pipeline.

  Rather than walk every node and then *subtract* the positions that must not be
  mutated (the old blacklist), the transform classifies each node's context
  *positively* and routes it. One pipeline, run per subtree:

    1. **Analyze** — `annotate/2` walks the AST and, for every node a mutator
       recognises *in a mutating context*, attaches a typed `Candidate` to the
       node's own metadata (`meta[:mutare]`). Mutators run **once**, here.
    2. **Classify** — the analyzer carries a `skip` depth so it can name each
       context as it descends. Mutating contexts (`:runtime_body` →
       in-place, `:guard`/`:clause_drop` → lifted) become candidates; the
       excluded contexts (`:pattern`, `:compile_time`, `:capture_arity`) are
       skipped wholesale — no candidate is ever produced there.
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

  alias Mutare.Site
  alias Mutare.Transform.{Candidate, Ctx, Render}

  @default_mutators [Mutare.Mutators.Arithmetic, Mutare.Mutators.Relational]

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
    complete_groups = complete_lift_groups(statements, ctx.mutators)

    {transformed, {ctx, _emitted}} =
      statements
      |> chunk_clause_runs()
      |> Enum.flat_map_reduce({ctx, MapSet.new()}, fn
        {:clauses, clauses}, {ctx, emitted} ->
          signature = clause_signature(hd(clauses))

          case Map.fetch(complete_groups, signature) do
            {:ok, {complete_clauses, candidates}} ->
              if signature in emitted do
                {[], {ctx, emitted}}
              else
                {nodes, ctx} = lift(complete_clauses, candidates, ctx)
                {nodes, {ctx, MapSet.put(emitted, signature)}}
              end

            :error ->
              {nodes, ctx} = transform_clause_group(clauses, ctx)
              {nodes, {ctx, emitted}}
          end

        {:other, statement}, {ctx, emitted} ->
          {node, ctx} = transform_node(statement, ctx)
          {[node], {ctx, emitted}}
      end)

    {transformed, ctx}
  end

  # A lifted dispatcher is a catch-all for its public signature, so it must own
  # every clause of that function even when another definition appears between
  # clauses. Otherwise the dispatcher makes later clauses unreachable.
  #
  # Only pre-group signatures that will actually lift. Each entry carries the
  # plan's candidates alongside the clauses, so `transform_statements/2` lifts
  # straight from here without recomputing them — the guard mutators run once
  # per signature. Non-lifted definitions keep their original statement positions.
  defp complete_lift_groups(statements, mutators) do
    statements
    |> Enum.filter(&clause_signature/1)
    |> Enum.group_by(&clause_signature/1)
    |> Enum.reduce(%{}, fn {signature, clauses}, groups ->
      case lift_plan(clauses, mutators) do
        {:lift, candidates} -> Map.put(groups, signature, {clauses, candidates})
        :in_place -> groups
      end
    end)
  end

  # Group maximal runs of consecutive clauses that share {visibility, name, arity}.
  # Complete liftable functions are joined across these runs by
  # complete_lift_groups/2.
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
      {:lift, candidates} ->
        lift(clauses, candidates, ctx)

      :in_place ->
        Enum.flat_map_reduce(clauses, ctx, fn clause, ctx ->
          {clause, ctx} = in_place(clause, ctx)
          {[clause], ctx}
        end)
    end
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
    {orig_clauses, ctx} =
      Enum.flat_map_reduce(clauses, ctx, fn clause, ctx ->
        {clause, ctx} = in_place(clause, ctx)
        {[clause], ctx}
      end)

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

  # --- analyze: classify context, attach candidates (mutators run once here) --

  # Walk the subtree carrying a `skip` depth. Entering an excluded context
  # (`skip_node?/1`) raises the depth so its whole subtree is skipped; outside
  # any such context, a node a mutator recognises gets a `:runtime_body`
  # candidate attached to its own metadata. Nodes are visited pre-order, so a
  # tagged node still holds its original (un-annotated) children — exactly what
  # the report wants to render. Ids are *not* assigned here; emission does that
  # bottom-up to keep post-order id ordering.
  defp annotate(node, mutators) do
    {annotated, _skip} =
      Macro.traverse(
        node,
        0,
        fn current, skip -> enter_annotate(current, skip, mutators) end,
        &leave_annotate/2
      )

    annotated
  end

  defp enter_annotate(node, skip, mutators) do
    cond do
      skip_node?(node) ->
        {node, skip + 1}

      skip > 0 ->
        {node, skip}

      true ->
        case mutations(node, mutators) do
          [] -> {node, skip}
          muts -> {put_candidates(node, build_candidates(node, muts)), skip}
        end
    end
  end

  defp leave_annotate(node, skip) do
    if skip_node?(node), do: {node, skip - 1}, else: {node, skip}
  end

  # The excluded contexts, recognised positively (this is what replaces the old
  # `unsafe_keys`/`guard_keys`/`capture_arity_keys` blacklist):
  #
  #   * `:when` guards — a `case` can't live in a guard; guard mutations are
  #     lifted instead. Skipping the whole `when` also skips the head patterns
  #     (`:pattern` — never a mutating context anyway).
  #   * module-attribute *definitions* (`@x <expr>`) — `:compile_time`. The
  #     value is frozen at compile time, so a selector there is inert. (A bare
  #     attribute *read*, `@x`, has no value list and is not skipped.)
  #   * the `/` in a `&fun/arity` capture — `:capture_arity`, an arity separator,
  #     not division. `& &1 / 2` (real division) does not match and is mutated.
  defp skip_node?({:when, _meta, [_call | guards]}) when guards != [], do: true
  defp skip_node?({:@, _meta, [{_name, _attr_meta, [_value]}]}), do: true

  defp skip_node?({:&, _meta, [{:/, _smeta, [left, right]}]}),
    do: function_ref?(left) and integer_literal?(right)

  defp skip_node?(_), do: false

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
