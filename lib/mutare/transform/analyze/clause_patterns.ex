defmodule Mutare.Transform.Analyze.ClausePatterns do
  @moduledoc false

  # Clause-list pattern mutation for `case`, `receive`/`fn`, and `try`/`rescue`.
  # Split out of `Mutare.Transform.Analyze`: the main descent routes the three
  # constructs here to build their pattern/guard/structure candidates, which the
  # heavy `Tag` / `PatternStructure` machinery dominates. The dependency is one-way
  # (Analyze → ClausePatterns): the one place a construct is analyzed *normally* (a
  # `receive`/`fn`'s bodies before attaching clause candidates) re-enters the walk
  # through the **injected `descent`** (the `Mutare.Transform.Analyze` module, passed
  # in by the caller) rather than naming it statically — so this module is a
  # parametrized fragment of the walk, not a cycle. Candidate construction goes
  # through the dependency-neutral `Attach`.
  #
  # Entry points the descent calls (`Mutare.Transform.Analyze`):
  #   * case     → `case_clause_candidates/2` + `put_case_candidates/2`
  #   * receive  → `receive_do_clauses/2` + `attach_clause_pattern_candidates/5`
  #   * fn       → `attach_clause_pattern_candidates/5`
  #   * try      → `rescue_type_candidates/3`

  alias Mutare.AST
  alias Mutare.Mutator.Dispatch
  alias Mutare.Mutator.Spec
  alias Mutare.Transform.{Candidate, Meta, NodeRange, PatternStructure, Tag}
  alias Mutare.Transform.Analyze.Attach

  # A fresh `{tag_counter, targets}` accumulator for a single-node tag walk. The candidates
  # here are discovered one node at a time, each re-tagged from scratch, so the starting
  # counter is arbitrary (the returned next-counter is discarded) — any value hands out the
  # same unique tags. (Contrast `Mutare.Transform.FunctionPlan`, which threads one counter
  # group-wide.) Living in a module attribute also keeps the seed out of `:runtime` position,
  # so it isn't a (would-be-equivalent) Literal mutation site needing a `# mutare:ignore`.
  @fresh_tag_acc {0, []}

  # --- case: per-clause tuple-the-scrutinee (Candidate.CaseClause) -----------

  # One `Candidate.CaseClause` per {clause, mutation} for a `case`. A `case` clause has a
  # single pattern (one subject); each clause admits guard-operator swaps, pattern-literal
  # swaps, and structural pattern rewrites. The candidate carries the mutant clause's
  # *pattern* and *guard* (a literal/structure mutation mutates the pattern and keeps the
  # original guard; a guard mutation mutates the guard and keeps the original pattern) plus
  # the clause's *raw body* — everything `Mutare.Transform.CaseClauseEmit.emit/3` needs
  # to build the gated mutant clause. The originals come from the (already-analyzed) case
  # node at emit; only the mutants come from here.
  # NOTE (equivalent survivors): the `++` operand_swap mutants on the candidate-group
  # concatenations in this module (here and in `clause_pattern_candidates/3`,
  # `attach_clause_pattern_candidates/5`, `clause_guard_candidates/3`, `rescue_clause_candidates/3`)
  # only reorder the produced candidates — the *set* of mutants is unchanged, just their id
  # order — so no behaviour or test distinguishes them. Left as documented survivors rather than
  # `# mutare:ignore`d to keep them visible.
  def case_clause_candidates(clauses, mutators) do
    structural = PatternStructure.mutators(mutators)

    clauses
    |> Enum.with_index()
    |> Enum.flat_map(fn {clause, index} ->
      case case_clause_parts(clause) do
        nil ->
          []

        {pattern, guard, body, used} ->
          guard_clause_candidates(index, pattern, guard, body, mutators) ++
            literal_clause_candidates(index, pattern, guard, body, mutators) ++
            structural_clause_candidates(index, pattern, guard, body, used, structural)
      end
    end)
  end

  # --- the guarded-`->`-clause shape, decomposed/recomposed in one place ------

  # A `->` clause head split into `{patterns, guard | nil, body}` (or `nil` for a
  # malformed/guard-only LHS) — the one home for the fragile guarded-clause shape, so the
  # readers (`case_clause_parts`/`clause_patterns`/`clause_guard`) and the recomposer
  # (`put_clause_head`) below don't each re-derive the `Enum.split(when_args, -1)`. The guarded
  # form nests as `[{:when, _, [p1, …, pN, guard]}]` — the guard is the last `when` arg, the
  # rest are patterns (a `when a when b` OR-guard is a single nested `when` node, so there is
  # always exactly one trailing guard); the unguarded form's LHS list *is* the patterns.
  # NOTE (equivalent survivors): the `length(when_args) >= 2` guard is a defensive lower bound —
  # a `:when` node always has at least one pattern and a guard (≥2 args). So *loosening* it
  # (`>= 2` → `true`/`>= 0`/`>= 1`) is equivalent, while *tightening* it (`> 2`/`>= 3`/`<= 2`
  # for a single-pattern clause) is killed by the case/receive/fn clause tests.
  defp clause_head_parts({:->, _meta, [[{:when, _wm, when_args}], body]})
       when length(when_args) >= 2 do
    # `-1` peels the lone trailing guard; load-bearing now this is shared with multi-pattern
    # `fn` heads (where `Enum.split(_, -1) ≢ Enum.split(_, 1)`), so the swap is killed, not ignored.
    {patterns, [guard]} = Enum.split(when_args, -1)
    {patterns, guard, body}
  end

  # mutare:ignore[guard_drop] equivalent — a `->` clause's LHS is always a list, so the `is_list/1` guard never excludes a real clause.
  defp clause_head_parts({:->, _meta, [lhs_list, body]}) when is_list(lhs_list),
    do: {lhs_list, nil, body}

  # mutare:ignore[clause_drop] equivalent — every caller passes a real `->` clause, which matches one of the two heads above; this guard against malformed input is unreachable.
  defp clause_head_parts(_clause), do: nil

  # Recompose a `->` clause with new `patterns` and an optional `guard` (nil → strip the
  # `when`), preserving the clause meta, the body, and — when guarded — the `when` node's meta.
  defp put_clause_head({:->, meta, [head, body]}, patterns, guard) do
    lhs =
      case {guard, head} do
        {nil, _head} -> patterns
        {_guard, [{:when, wm, _args}]} -> [{:when, wm, patterns ++ [guard]}]
        # mutare:ignore[clause_drop] equivalent — a non-nil guard only ever arrives from a clause that was already guarded (head `[{:when, …}]`), so the branch above always matches first.
        {_guard, _head} -> [{:when, [], patterns ++ [guard]}]
      end

    {:->, meta, [lhs, body]}
  end

  # A `case` clause's single pattern, its guard (or `nil`), its body, and the names read in
  # guard+body (the wildcard family's `used_outside`). More than one pattern (not a `case`
  # clause) → `nil`.
  defp case_clause_parts(clause) do
    case clause_head_parts(clause) do
      {[pattern], guard, body} ->
        nodes = if guard, do: [guard, body], else: [body]
        {pattern, guard, body, PatternStructure.used_names(nodes)}

      _ ->
        nil
    end
  end

  # mutare:ignore[clause_drop] equivalent — dropping the `nil`-guard short-circuit leaves the general clause to run `Tag.guard_targets(nil, …)` (no targets) and `guard_drop_clause_candidate` on a synthetic `{:when, [], [pattern, nil]}` that Sourceror can't range, so it yields no candidate either way.
  defp guard_clause_candidates(_index, _pattern, nil, _body, _mutators), do: []

  defp guard_clause_candidates(index, pattern, guard, body, mutators) do
    {tagged_guard, {_next, targets}} = Tag.guard_targets(guard, @fresh_tag_acc, mutators)

    swaps =
      Tag.expand_targets(targets, fn tag, original, mutator, mutated, note, range ->
        %Candidate.CaseClause{
          clause_index: index,
          mutator: mutator,
          mutant_pattern: pattern,
          mutant_guard: Tag.replace_tag(tagged_guard, tag, mutated),
          raw_body: body,
          original: original,
          mutated: mutated,
          range: range,
          note: note
        }
      end)

    swaps ++ guard_drop_clause_candidate(index, pattern, guard, body, targets, mutators)
  end

  # A `case` clause's guard removed — a `CaseClause` carrying the original pattern with a
  # `nil` mutant guard (`CaseClauseEmit.emit/3` gates it only by `=== <id>`, so it
  # matches whenever the pattern does, the broadening the removal models). Offered only for
  # an **inert** guard (no other family touches it — `targets == []`) and when
  # `GuardDrop` is enabled. The Site diffs the clause's `pattern when guard` head to the
  # bare `pattern` (the `{:when, …}` LHS reconstructed for range/render), so just the
  # ` when guard` is dropped.
  # The shared precondition of the two guard-drop offers (`case` via `CaseClause`,
  # `receive`/`fn` via `CasePattern`): a guard is droppable only when it is **inert** (no other
  # family tagged it — `targets == []`) and `GuardDrop` is enabled. Returns the spec plus the
  # `{:when, pattern, guard}` node (reconstructed for the Site diff/range) and its range, or
  # `:error` when any precondition fails. Each caller supplies its own `pattern` and builds its
  # own struct.
  defp guard_drop_when_node(pattern, guard, targets, mutators) do
    with [] <- targets,
         %Spec{} = spec <- Spec.find(mutators, Mutare.Mutators.GuardDrop),
         when_node = {:when, [], [pattern, guard]},
         %{} = range <- NodeRange.get(when_node) do
      {:ok, spec, when_node, range}
    else
      _ -> :error
    end
  end

  defp guard_drop_clause_candidate(index, pattern, guard, body, targets, mutators) do
    case guard_drop_when_node(pattern, guard, targets, mutators) do
      {:ok, spec, when_node, range} ->
        [
          %Candidate.CaseClause{
            clause_index: index,
            mutator: spec,
            # The pattern is left exactly as written — only the guard is dropped. A binding
            # the guard alone read becomes unused (a harmless warning); we never rename it to
            # `_`, since a macro in the body can read a bound variable by name (`binding/0,1`
            # or any custom macro), undetectably from the source.
            mutant_pattern: pattern,
            mutant_guard: nil,
            raw_body: body,
            original: when_node,
            mutated: pattern,
            range: range
          }
        ]

      :error ->
        []
    end
  end

  defp literal_clause_candidates(index, pattern, guard, body, mutators) do
    {tagged_pattern, {_next, targets}} =
      Tag.pattern_literal_targets(pattern, @fresh_tag_acc, mutators)

    Tag.expand_targets(targets, fn tag, original, mutator, mutated, note, range ->
      %Candidate.CaseClause{
        clause_index: index,
        mutator: mutator,
        mutant_pattern: Tag.replace_tag(tagged_pattern, tag, mutated),
        mutant_guard: guard,
        raw_body: body,
        original: original,
        mutated: mutated,
        range: range,
        note: note
      }
    end)
  end

  # mutare:ignore[clause_drop] equivalent — dropping this empty-structural short-circuit leaves the general clause to run `PatternStructure.node_mutations(_, _, [])`, which returns `[]`; same result.
  defp structural_clause_candidates(_index, _pattern, _guard, _body, _used, []), do: []

  defp structural_clause_candidates(index, pattern, guard, body, used, structural) do
    structural_mutations(pattern, used, structural, fn mutator, mutated, range ->
      %Candidate.CaseClause{
        clause_index: index,
        mutator: mutator,
        mutant_pattern: mutated,
        mutant_guard: guard,
        raw_body: body,
        original: pattern,
        mutated: mutated,
        range: range
      }
    end)
  end

  # Run the structural (swap/wildcard) discovery on one clause pattern, skipping the
  # pattern when Sourceror can't range it (no focused diff possible — the same guard the
  # tagged path applies via `Tag.expand_targets/2`). Each `{mutator, mutated}` becomes a
  # candidate via `build.(mutator, mutated, range)`. Shared by the `case` (`CaseClause`)
  # and `receive`/`fn` (`CasePattern`) paths, which differ only in the struct they build.
  defp structural_mutations(pattern, used, structural, build) do
    case NodeRange.get(pattern) do
      %{} = range ->
        pattern
        |> PatternStructure.node_mutations(used, structural)
        |> Enum.map(fn {mutator, mutated} -> build.(mutator, mutated, range) end)

      _ ->
        []
    end
  end

  def put_case_candidates(node, candidates), do: Meta.put_candidates(node, :case, candidates)

  # --- receive / fn: whole-construct selector (Candidate.CasePattern) --------

  # Analyze the construct normally (bodies/subject mutate), then attach the clause-pattern
  # candidates so emission hosts them in the same in-place selector that wraps the whole
  # node. `clauses` is the construct's `->` clause list; `rebuild_fn` rebuilds the whole node
  # from a mutated clause list (the only thing that differs across receive/fn). The
  # node-level mutator offer is preserved for parity with the generic runtime clause (a
  # custom mutator matching the whole node; built-ins match none).
  def attach_clause_pattern_candidates(descent, node, clauses, rebuild_fn, mutators) do
    # mutare:ignore[atom] equivalent — the descent's `body_context/1` maps every non-`:scaffold` context (including a mutated `:mutare`) to `:runtime`, so the clause bodies mutate identically.
    analyzed = descent.recurse(node, :runtime, mutators)

    candidates =
      Attach.build_candidates(node, Dispatch.mutations(node, mutators)) ++
        clause_list_candidates(clauses, rebuild_fn, mutators)

    Attach.put_candidates_if_any(analyzed, candidates)
  end

  # The receive's `do` clauses plus a rebuilder that swaps them back into `blocks`
  # (preserving an `after` block). An absent `do` (shouldn't happen) → no clauses and an
  # identity rebuild, so the construct is still analyzed but offers no pattern mutants.
  def receive_do_clauses(blocks, meta) do
    # NOTE (equivalent survivor): forcing this finder's `== :do` to `true` is equivalent — the
    # `:do` block is always the first entry of a `receive`, so `Enum.find` returns it either
    # way; `== :do → false` (returns the `after` block / nil) is killed.
    case Enum.find(blocks, fn {key, _value} -> AST.key_atom(key) == :do end) do
      # mutare:ignore[guard_drop] equivalent — a `receive`'s `:do` value is always the clause list, so the `is_list/1` guard never excludes it.
      {_do_key, clauses} when is_list(clauses) ->
        rebuild = fn new ->
          new_blocks =
            Enum.map(blocks, fn {key, value} ->
              if AST.key_atom(key) == :do, do: {key, new}, else: {key, value}
            end)

          {:receive, meta, [new_blocks]}
        end

        {clauses, rebuild}

      _ ->
        {[], fn _new -> {:receive, meta, [blocks]} end}
    end
  end

  # For each clause: structural pattern rewrites + pattern-literal swaps at each pattern
  # position, plus guard-operator swaps. Each builds a `Candidate.CasePattern` whose
  # `replacement` is the whole construct with just that one clause's pattern/guard changed
  # (raw clauses → first-order, no nested selectors, like a lifted mutant clause). The diff
  # stays focused on the single changed pattern/literal/guard-operator (always rangeable).
  defp clause_list_candidates(clauses, rebuild_fn, mutators) do
    clauses
    |> Enum.with_index()
    |> Enum.flat_map(fn {clause, index} ->
      replace_clause = fn new_clause ->
        rebuild_fn.(List.replace_at(clauses, index, new_clause))
      end

      clause_pattern_candidates(clause, replace_clause, mutators)
    end)
  end

  defp clause_pattern_candidates(clause, replace_clause, mutators) do
    structural = PatternStructure.mutators(mutators)

    case clause_patterns(clause) do
      nil ->
        []

      {patterns, used} ->
        pattern_cands =
          patterns
          |> Enum.with_index()
          |> Enum.flat_map(
            &position_candidates(&1, clause, replace_clause, used, mutators, structural)
          )

        pattern_cands ++ clause_guard_candidates(clause, replace_clause, mutators)
    end
  end

  defp position_candidates({pattern, pos}, clause, replace_clause, used, mutators, structural) do
    structural_position_candidates(pattern, pos, clause, replace_clause, used, structural) ++
      literal_position_candidates(pattern, pos, clause, replace_clause, mutators)
  end

  defp structural_position_candidates(pattern, pos, clause, replace_clause, used, structural) do
    structural_mutations(pattern, used, structural, fn mutator, mutated, range ->
      %Candidate.CasePattern{
        mutator: mutator,
        original: pattern,
        mutated: mutated,
        replacement: replace_clause.(put_clause_pattern_at(clause, pos, mutated)),
        range: range
      }
    end)
  end

  defp literal_position_candidates(pattern, pos, clause, replace_clause, mutators) do
    {tagged_pattern, {_next, targets}} =
      Tag.pattern_literal_targets(pattern, @fresh_tag_acc, mutators)

    Tag.expand_targets(targets, fn tag, original, mutator, mutated, note, range ->
      mutated_pattern = Tag.replace_tag(tagged_pattern, tag, mutated)

      %Candidate.CasePattern{
        mutator: mutator,
        original: original,
        mutated: mutated,
        replacement: replace_clause.(put_clause_pattern_at(clause, pos, mutated_pattern)),
        range: range,
        note: note
      }
    end)
  end

  defp clause_guard_candidates(clause, replace_clause, mutators) do
    case clause_guard(clause) do
      nil ->
        []

      guard ->
        {tagged_guard, {_next, targets}} = Tag.guard_targets(guard, @fresh_tag_acc, mutators)

        swaps =
          Tag.expand_targets(targets, fn tag, original, mutator, mutated, note, range ->
            mutated_guard = Tag.replace_tag(tagged_guard, tag, mutated)

            %Candidate.CasePattern{
              mutator: mutator,
              original: original,
              mutated: mutated,
              replacement: replace_clause.(put_clause_guard(clause, mutated_guard)),
              range: range,
              note: note
            }
          end)

        swaps ++ guard_drop_clause_pattern(clause, guard, replace_clause, targets, mutators)
    end
  end

  # A `receive`/`fn` clause's guard removed — a `CasePattern` whose `replacement` is the
  # whole construct with this clause's `when` stripped (matching unconditionally for its
  # pattern). Offered only for an **inert** guard (`targets == []`), when `GuardDrop` is
  # enabled, and for a **single-pattern** clause: a multi-pattern `fn` head
  # (`fn x, y when … ->`) has no single `{:when, …}` node that renders cleanly in the diff,
  # so it is skipped (documented in NOTES). The Site diffs `pattern when guard` → `pattern`.
  defp guard_drop_clause_pattern(clause, guard, replace_clause, targets, mutators) do
    # The single-pattern gate is `CasePattern`-only: a multi-pattern `fn x, y when … ->` head has
    # no single `{:when, …}` node that renders cleanly in the diff, so it is skipped.
    with {[pattern], _used} <- clause_patterns(clause),
         {:ok, spec, when_node, range} <- guard_drop_when_node(pattern, guard, targets, mutators) do
      [
        %Candidate.CasePattern{
          mutator: spec,
          original: when_node,
          mutated: pattern,
          replacement: replace_clause.(strip_clause_guard(clause)),
          range: range
        }
      ]
    else
      _ -> []
    end
  end

  # A `->` clause with its whole `when` removed (a single-pattern clause; the guard wraps
  # the lone pattern). The bare patterns become the clause head, left exactly as written: a
  # binding the guard alone read becomes unused (a harmless warning), but we never rename it
  # to `_` — a macro in the body can read a bound variable by name, undetectably.
  defp strip_clause_guard(clause) do
    {patterns, _guard, _body} = clause_head_parts(clause)
    put_clause_head(clause, patterns, nil)
  end

  # A clause's pattern positions plus the names read in its guard/body (the `used_outside`
  # set the wildcard family needs). Each pattern is mutated independently, so a duplicate
  # variable *across* fn arguments (`fn x, x -> …`) isn't seen — rare, and within-argument
  # duplicates (`fn {x, x} -> …`) still are. A malformed/guard-only LHS → `nil` (skip).
  defp clause_patterns(clause) do
    case clause_head_parts(clause) do
      {patterns, nil, body} ->
        # NOTE (equivalent survivors): the `Enum.any?(...) → Enum.all?(...)` and the `if … →
        # false` mutants here are equivalent — a guarded clause is decomposed by the guarded
        # head of `clause_head_parts`, so an unguarded `patterns` list never contains a
        # `:when`; both the `any?`/`all?` predicate and the `if` are therefore always false.
        # (`if … → true`, which would drop every clause's patterns, is killed.)
        if Enum.any?(patterns, &match?({:when, _, _}, &1)),
          do: nil,
          else: {patterns, PatternStructure.used_names([body])}

      {patterns, guard, body} ->
        {patterns, PatternStructure.used_names([guard, body])}

      nil ->
        nil
    end
  end

  # The guard of a `->` clause (its last `when` arg), or `nil` when unguarded.
  defp clause_guard(clause) do
    case clause_head_parts(clause) do
      {_patterns, guard, _body} -> guard
      nil -> nil
    end
  end

  # Replace pattern position `pos` of a clause's head with `mutated`, preserving a `when`
  # guard if present (the guard is always the last `when` arg).
  defp put_clause_pattern_at(clause, pos, mutated) do
    {patterns, guard, _body} = clause_head_parts(clause)
    put_clause_head(clause, List.replace_at(patterns, pos, mutated), guard)
  end

  # Replace a guarded `->` clause's guard (the last `when` arg) with `new_guard`.
  defp put_clause_guard(clause, new_guard) do
    {patterns, _guard, _body} = clause_head_parts(clause)
    put_clause_head(clause, patterns, new_guard)
  end

  # --- try: rescue narrowing + clause drop (CasePattern / RescueDrop) ---------

  # The `rescue` mutations: per-clause type-list narrowings (`Candidate.CasePattern`, each
  # `replacement` the whole `try` with one clause's list shrunk) plus whole-clause drops
  # (`Candidate.RescueDrop`, the `try` with one clause removed). Gated on
  # `Mutare.Mutators.RescueType` being enabled.
  def rescue_type_candidates(blocks, meta, mutators) do
    case Spec.find(mutators, Mutare.Mutators.RescueType) do
      nil -> []
      spec -> rescue_clause_candidates(blocks, meta, spec)
    end
  end

  defp rescue_clause_candidates(blocks, meta, spec) do
    case Enum.find(blocks, fn {key, _v} -> AST.key_atom(key) == :rescue end) do
      # mutare:ignore[guard_drop] equivalent — a `rescue` block's value is always the clause list, so the `is_list/1` guard never excludes it.
      {_rescue_key, clauses} when is_list(clauses) ->
        rebuild_try = fn new_clauses ->
          new_blocks =
            Enum.map(blocks, fn {key, v} ->
              if AST.key_atom(key) == :rescue, do: {key, new_clauses}, else: {key, v}
            end)

          {:try, meta, [new_blocks]}
        end

        narrowings =
          clauses
          |> Enum.with_index()
          |> Enum.flat_map(&rescue_type_drops(&1, clauses, rebuild_try, spec))

        narrowings ++ rescue_clause_drops(clauses, rebuild_try, spec)

      _ ->
        []
    end
  end

  # The whole-clause counterpart of `rescue_type_drops/4`: drop each `rescue` branch in turn,
  # `replacement` being the `try` with that one clause removed. This covers the idiomatic
  # multi-branch shape `rescue e in A -> …; e in B -> …` — where each branch catches a single
  # type, so there is no list for `rescue_type_drops` to narrow — by asking the same question one
  # level up (is each branch's handling relied on?). Offered **only when ≥2 clauses are present**
  # (a `try` can't carry an empty `rescue`), so every result still compiles; the head shape is
  # irrelevant (a bare-variable catch-all clause is droppable too). The diff is a `:delete` of the
  # dropped clause (`Candidate.RescueDrop`).
  defp rescue_clause_drops(clauses, rebuild_try, spec) when length(clauses) >= 2 do
    clauses
    |> Enum.with_index()
    |> Enum.flat_map(fn {clause, index} ->
      case NodeRange.get(clause) do
        %{} = range ->
          [
            %Candidate.RescueDrop{
              mutator: spec,
              dropped: clause,
              replacement: rebuild_try.(List.delete_at(clauses, index)),
              range: range
            }
          ]

        _ ->
          []
      end
    end)
  end

  defp rescue_clause_drops(_clauses, _rebuild_try, _spec), do: []

  # One rescue clause — a `CasePattern` per type-drop, whose `replacement` is the whole `try`
  # rebuilt with this clause's exception-type list narrowed. Both list-bearing shapes are
  # mutated: `var in [t1, ..., tn]` (bound) and a bare `[t1, ..., tn]` head (no binding) —
  # `narrowable_types/1` returns the type list and a head-rebuilder for each. The diff
  # (`original`/`mutated`/`range`) is the clause **head** before/after, so the bound form shows
  # `var in [A, B]`→`var in [A]` and the bare form `[A, B]`→`[A]`. The non-list shapes (`var`,
  # `Type`, `var in Single`) yield nothing.
  defp rescue_type_drops({{:->, cmeta, [[head], body]}, index}, clauses, rebuild_try, spec) do
    with {types, rebuild_head} <- narrowable_types(head),
         %{} = range <- NodeRange.get(head) do
      types
      |> Mutare.Mutators.RescueType.drops()
      |> Enum.map(fn kept ->
        mutated_head = rebuild_head.(kept)
        mutated_clause = {:->, cmeta, [[mutated_head], body]}

        %Candidate.CasePattern{
          mutator: spec,
          original: head,
          mutated: mutated_head,
          replacement: rebuild_try.(List.replace_at(clauses, index, mutated_clause)),
          range: range
        }
      end)
    else
      _ -> []
    end
  end

  # mutare:ignore[clause_drop] equivalent — a `rescue` clause is always `{:->, _, [[head], body]}`, so the head above always matches; this fallback is unreachable for valid input.
  defp rescue_type_drops(_clause_indexed, _clauses, _rebuild_try, _spec), do: []

  # A rescue clause head's exception-type list plus a closure to rebuild the head from a
  # narrowed list, or `nil` when the head holds no mutatable list. Two list-bearing shapes:
  # `var in [t1, ..., tn]` (keep the `in` binding) and a bare `[t1, ..., tn]` head (a valid
  # rescue form with no binding — narrow the list directly). `rescue_types/1` does the list
  # extraction (and `:__block__`-aware rebuild) for both, returning `nil` for a single alias
  # (`var in Single` / `Type`) or a bare variable, so those fall through to no mutation.
  defp narrowable_types({:in, imeta, [var, types_node]}) do
    case rescue_types(types_node) do
      {wrap, types} -> {types, fn kept -> {:in, imeta, [var, wrap.(kept)]} end}
      nil -> nil
    end
  end

  defp narrowable_types(types_node) do
    case rescue_types(types_node) do
      {wrap, types} -> {types, wrap}
      nil -> nil
    end
  end

  # The exception-type list inside a rescue head's list node, plus a closure to rebuild the
  # node from a narrowed list. Sourceror wraps the list literal in a `:__block__` (preserved so
  # the mutant renders cleanly); a bare list is handled too. A non-list (a single alias) → `nil`.
  # mutare:ignore[guard_drop] equivalent — the `:__block__` always wraps a list literal here, so the `is_list/1` guard never excludes a real type list.
  defp rescue_types({:__block__, bmeta, [list]}) when is_list(list),
    do: {fn new -> {:__block__, bmeta, [new]} end, list}

  # mutare:ignore[guard_drop, clause_drop] equivalent — Sourceror always `:__block__`-wraps a list literal (matched above), so this bare-list clause (and its guard) is never reached for real input; it is defensive only.
  defp rescue_types(list) when is_list(list), do: {fn new -> new end, list}
  defp rescue_types(_node), do: nil
end
