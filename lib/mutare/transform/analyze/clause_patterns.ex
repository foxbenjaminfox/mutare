defmodule Mutare.Transform.Analyze.ClausePatterns do
  @moduledoc false

  # Clause-list pattern mutation for `case`, `receive`/`fn`, and `try`/`rescue`.
  # Split out of `Mutare.Transform.Analyze`: the main descent routes the three
  # constructs here to build their pattern/guard/structure candidates, which the
  # heavy `Tag` / `PatternStructure` machinery dominates. The dependency is almost
  # entirely one-way (Analyze → ClausePatterns); the only callbacks back into the
  # descent are the three sub-walk helpers `Analyze.recurse/3`,
  # `Analyze.build_candidates/2`, and `Analyze.put_candidates/2`, used to analyze a
  # `receive`/`fn`/`try` node normally before attaching its clause candidates.
  #
  # Entry points the descent calls (`Mutare.Transform.Analyze`):
  #   * case     → `case_clause_candidates/2` + `put_case_candidates/2`
  #   * receive  → `receive_do_clauses/2` + `attach_clause_pattern_candidates/4`
  #   * fn       → `attach_clause_pattern_candidates/4`
  #   * try      → `rescue_type_candidates/3`

  alias Mutare.AST
  alias Mutare.Mutator
  alias Mutare.Mutator.Spec
  alias Mutare.Transform.{Candidate, NodeRange, PatternStructure, Tag}
  alias Mutare.Transform.Analyze

  # --- case: per-clause tuple-the-scrutinee (Candidate.CaseClause) -----------

  # One `Candidate.CaseClause` per {clause, mutation} for a `case`. A `case` clause has a
  # single pattern (one subject); each clause admits guard-operator swaps, pattern-literal
  # swaps, and structural pattern rewrites. The candidate carries the mutant clause's
  # *pattern* and *guard* (a literal/structure mutation mutates the pattern and keeps the
  # original guard; a guard mutation mutates the guard and keeps the original pattern) plus
  # the clause's *raw body* — everything `Mutare.Transform.emit_case_pattern_site/3` needs
  # to build the gated mutant clause. The originals come from the (already-analyzed) case
  # node at emit; only the mutants come from here.
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

  # A `case` clause's single pattern, its guard (or `nil`), its body, and the names read in
  # guard+body (the wildcard family's `used_outside`). Handles the guarded form (the guard
  # is the last `when` arg; a `when a when b` OR-guard is a single nested `when` node) and
  # the unguarded form. Anything with more than one pattern (not a `case` clause) → `nil`.
  defp case_clause_parts({:->, _meta, [[{:when, _wm, when_args}], body]})
       when length(when_args) >= 2 do
    case Enum.split(when_args, -1) do
      {[pattern], [guard]} -> {pattern, guard, body, PatternStructure.used_names([guard, body])}
      _ -> nil
    end
  end

  defp case_clause_parts({:->, _meta, [[pattern], body]}),
    do: {pattern, nil, body, PatternStructure.used_names([body])}

  defp case_clause_parts(_clause), do: nil

  defp guard_clause_candidates(_index, _pattern, nil, _body, _mutators), do: []

  defp guard_clause_candidates(index, pattern, guard, body, mutators) do
    {tagged_guard, {_next, targets}} = Tag.guard_targets(guard, {0, []}, mutators)

    swaps =
      Tag.expand_targets(targets, fn tag, original, mutator, mutated, range ->
        %Candidate.CaseClause{
          clause_index: index,
          mutator: mutator,
          mutant_pattern: pattern,
          mutant_guard: Tag.replace_tag(tagged_guard, tag, mutated),
          raw_body: body,
          original: original,
          mutated: mutated,
          range: range
        }
      end)

    swaps ++ guard_drop_clause_candidate(index, pattern, guard, body, targets, mutators)
  end

  # A `case` clause's guard removed — a `CaseClause` carrying the original pattern with a
  # `nil` mutant guard (`emit_case_pattern_site/3` gates it only by `=== <id>`, so it
  # matches whenever the pattern does, the broadening the removal models). Offered only for
  # an **inert** guard (no other family touches it — `targets == []`) and when
  # `GuardDrop` is enabled. The Site diffs the clause's `pattern when guard` head to the
  # bare `pattern` (the `{:when, …}` LHS reconstructed for range/render), so just the
  # ` when guard` is dropped.
  defp guard_drop_clause_candidate(index, pattern, guard, body, targets, mutators) do
    with [] <- targets,
         %Spec{} = spec <- Spec.find(mutators, Mutare.Mutators.GuardDrop),
         when_node = {:when, [], [pattern, guard]},
         %{} = range <- NodeRange.get(when_node) do
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
    else
      _ -> []
    end
  end

  defp literal_clause_candidates(index, pattern, guard, body, mutators) do
    {tagged_pattern, {_next, targets}} = Tag.pattern_literal_targets(pattern, {0, []}, mutators)

    Tag.expand_targets(targets, fn tag, original, mutator, mutated, range ->
      %Candidate.CaseClause{
        clause_index: index,
        mutator: mutator,
        mutant_pattern: Tag.replace_tag(tagged_pattern, tag, mutated),
        mutant_guard: guard,
        raw_body: body,
        original: original,
        mutated: mutated,
        range: range
      }
    end)
  end

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

  def put_case_candidates({form, meta, args}, candidates),
    do: {form, [{:mutare_case, candidates} | meta], args}

  # --- receive / fn: whole-construct selector (Candidate.CasePattern) --------

  # Analyze the construct normally (bodies/subject mutate), then attach the clause-pattern
  # candidates so emission hosts them in the same in-place selector that wraps the whole
  # node. `clauses` is the construct's `->` clause list; `rebuild_fn` rebuilds the whole node
  # from a mutated clause list (the only thing that differs across receive/fn). The
  # node-level mutator offer is preserved for parity with the generic runtime clause (a
  # custom mutator matching the whole node; built-ins match none).
  def attach_clause_pattern_candidates(node, clauses, rebuild_fn, mutators) do
    analyzed = Analyze.recurse(node, :runtime, mutators)

    candidates =
      Analyze.build_candidates(node, Mutator.mutations(node, mutators)) ++
        clause_list_candidates(clauses, rebuild_fn, mutators)

    case candidates do
      [] -> analyzed
      _ -> Analyze.put_candidates(analyzed, candidates)
    end
  end

  # The receive's `do` clauses plus a rebuilder that swaps them back into `blocks`
  # (preserving an `after` block). An absent `do` (shouldn't happen) → no clauses and an
  # identity rebuild, so the construct is still analyzed but offers no pattern mutants.
  def receive_do_clauses(blocks, meta) do
    case Enum.find(blocks, fn {key, _value} -> AST.key_atom(key) == :do end) do
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
    {tagged_pattern, {_next, targets}} = Tag.pattern_literal_targets(pattern, {0, []}, mutators)

    Tag.expand_targets(targets, fn tag, original, mutator, mutated, range ->
      mutated_pattern = Tag.replace_tag(tagged_pattern, tag, mutated)

      %Candidate.CasePattern{
        mutator: mutator,
        original: original,
        mutated: mutated,
        replacement: replace_clause.(put_clause_pattern_at(clause, pos, mutated_pattern)),
        range: range
      }
    end)
  end

  defp clause_guard_candidates(clause, replace_clause, mutators) do
    case clause_guard(clause) do
      nil ->
        []

      guard ->
        {tagged_guard, {_next, targets}} = Tag.guard_targets(guard, {0, []}, mutators)

        swaps =
          Tag.expand_targets(targets, fn tag, original, mutator, mutated, range ->
            mutated_guard = Tag.replace_tag(tagged_guard, tag, mutated)

            %Candidate.CasePattern{
              mutator: mutator,
              original: original,
              mutated: mutated,
              replacement: replace_clause.(put_clause_guard(clause, mutated_guard)),
              range: range
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
    with [] <- targets,
         %Spec{} = spec <- Spec.find(mutators, Mutare.Mutators.GuardDrop),
         {[pattern], _used} <- clause_patterns(clause),
         when_node = {:when, [], [pattern, guard]},
         %{} = range <- NodeRange.get(when_node) do
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
  defp strip_clause_guard({:->, meta, [[{:when, _wm, when_args}], body]})
       when length(when_args) >= 2 do
    {patterns, [_guard]} = Enum.split(when_args, -1)
    {:->, meta, [patterns, body]}
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

  # The guard of a `->` clause (its last `when` arg), or `nil` when unguarded.
  defp clause_guard({:->, _meta, [[{:when, _wm, when_args}], _body]})
       when length(when_args) >= 2,
       do: List.last(when_args)

  defp clause_guard(_clause), do: nil

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

  # Replace a guarded `->` clause's guard (the last `when` arg) with `new_guard`.
  defp put_clause_guard({:->, meta, [[{:when, wm, when_args}], body]}, new_guard)
       when length(when_args) >= 2 do
    {patterns, [_guard]} = Enum.split(when_args, -1)
    {:->, meta, [[{:when, wm, patterns ++ [new_guard]}], body]}
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
  defp rescue_types({:__block__, bmeta, [list]}) when is_list(list),
    do: {fn new -> {:__block__, bmeta, [new]} end, list}

  defp rescue_types(list) when is_list(list), do: {fn new -> new end, list}
  defp rescue_types(_node), do: nil
end
