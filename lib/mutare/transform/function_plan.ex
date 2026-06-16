defmodule Mutare.Transform.FunctionPlan do
  @moduledoc false

  # The plan for one *lifted* clause group: a function whose guard, head-pattern
  # literal, and/or clause-structure mutations are delivered by duplicating the
  # whole clause group behind a dispatcher. A `case` can't live in a guard or a
  # pattern, and guards drive dispatch *across* clauses, so none of these can be
  # mutated in place — duplicating the group and switching copies by id is the only
  # way.
  #
  # This is the discovery half of lifting — pure, id-free. `Mutare.Transform`
  # owns the emission half (assigning ids, renaming copies, building the
  # dispatcher) because that shares the `Ctx` id-threading discipline with the
  # in-place path. What lives here is the *vocabulary*: which mutants a group
  # admits and how to materialize each one's clause copy.
  #
  # ## The shared tagged clause group
  #
  # Every guard / pattern candidate needs "the whole clause group with this one
  # node swapped." The previous design stored that materialized group on each
  # candidate — N near-identical full copies for N mutants. Instead the plan holds
  # the group *once*, with every mutatable guard operator *and* head-pattern literal
  # tagged by a unique `meta[:mutare_tag]` (`tagged_clauses`); each `Candidate.Guard`
  # / `Candidate.Pattern` carries only its `tag` and the replacement node.
  # `mutated_clauses/2` reconstructs a copy on demand by replacing the tagged node.
  # Tags are stripped before rendering, so a leftover tag on a sibling node is
  # harmless. Guards and pattern literals share one tag counter (`build_lifted/2`)
  # so their tags are unique group-wide.
  #
  # ## Why only literals in a head
  #
  # A head is a pattern, so only a *literal* replacement is legal there (a swapped
  # operator or a selector `case` is not). `tag_pattern_targets/3` therefore offers
  # a node to the mutators only when it is a scalar literal and keeps only the
  # mutations whose replacement is *also* a literal — which selects exactly the
  # literal families (and any future literal mutator) and guarantees the `__mut`
  # copy compiles. Bitstring type specifiers and keyword/map *keys* are skipped
  # (a `unit(0)` would not compile; a key is a label, not a value), mirroring the
  # in-place `:pattern` routing in `Mutare.Transform`.

  alias Mutare.Mutator
  alias Mutare.Transform.{Candidate, PatternStructure}

  @type signature :: {:def | :defp, atom(), non_neg_integer()}

  @type t :: %__MODULE__{
          signature: signature(),
          clauses: [Macro.t()],
          tagged_clauses: [Macro.t()],
          guards: [Candidate.Guard.t()],
          patterns: [Candidate.Pattern.t()],
          pattern_structures: [Candidate.PatternStructure.t()],
          drops: [Candidate.Drop.t()]
        }

  defstruct [
    :signature,
    :clauses,
    :tagged_clauses,
    :guards,
    :patterns,
    :pattern_structures,
    :drops
  ]

  @doc """
  Plan a consecutive same-signature clause group.

  Returns `{:lift, plan}` when the group both *admits* a lifted mutant (a guard
  swap, a head-pattern literal swap, or a droppable clause) and *can host* a
  dispatcher (`liftable?/2`), else `:in_place` — its clauses stay where they are
  and only their bodies mutate.
  """
  @spec plan(signature(), [Macro.t()], [module()]) :: {:lift, t()} | :in_place
  def plan({_vis, name, _arity} = signature, clauses, mutators) do
    {tagged_clauses, guards, patterns} = build_lifted(clauses, mutators)
    pattern_structures = build_pattern_structures(clauses, mutators)
    drops = build_drops(clauses)

    if (guards != [] or patterns != [] or pattern_structures != [] or drops != []) and
         liftable?(name, clauses) do
      plan = %__MODULE__{
        signature: signature,
        clauses: clauses,
        tagged_clauses: tagged_clauses,
        guards: guards,
        patterns: patterns,
        pattern_structures: pattern_structures,
        drops: drops
      }

      {:lift, plan}
    else
      :in_place
    end
  end

  @doc """
  The lifted candidates of this group: guard swaps, then head-pattern literal
  swaps, then head-pattern structure rewrites (variable swaps / wildcards), then
  clause drops.

  Emission walks these in order to assign ids and build one private `defp` copy
  per candidate, so the order fixes id assignment within a lifted function.
  """
  @spec candidates(t()) :: [Candidate.t()]
  def candidates(%__MODULE__{
        guards: guards,
        patterns: patterns,
        pattern_structures: pattern_structures,
        drops: drops
      }),
      do: guards ++ patterns ++ pattern_structures ++ drops

  @doc """
  Materialize one candidate's mutated clause group — the bodies of its private copy.

  A `Candidate.Guard` / `Candidate.Pattern` replaces its tagged node (a guard
  operator / a head literal) in the shared tagged group; a `Candidate.Drop` removes
  its clause from the original group.
  """
  @spec mutated_clauses(t(), Candidate.t()) :: [Macro.t()]
  def mutated_clauses(%__MODULE__{tagged_clauses: tagged}, %Candidate.Guard{
        tag: tag,
        mutated: mutated
      }),
      do: replace_tag(tagged, tag, mutated)

  def mutated_clauses(%__MODULE__{tagged_clauses: tagged}, %Candidate.Pattern{
        tag: tag,
        mutated: mutated
      }),
      do: replace_tag(tagged, tag, mutated)

  def mutated_clauses(%__MODULE__{clauses: clauses}, %Candidate.PatternStructure{
        clause_index: index,
        mutated_args: mutated_args
      }) do
    clause = Enum.at(clauses, index)
    List.replace_at(clauses, index, put_head_args(clause, mutated_args))
  end

  def mutated_clauses(%__MODULE__{clauses: clauses}, %Candidate.Drop{clause_index: index}),
    do: List.delete_at(clauses, index)

  # === lifted candidates (guards + head-pattern literals) ====================

  # Discover both head-resident lifted kinds over one shared tagged clause group,
  # threading a single tag counter so guard and pattern tags never collide. Guards
  # are tagged first (so their tags — and the ids derived from them — are unchanged
  # by adding pattern literals), then head-pattern literals on the already-tagged
  # clauses. The two passes touch disjoint parts of a clause — its `when` vs its
  # head args — so neither disturbs the other's tags.
  defp build_lifted(clauses, mutators) do
    {guard_tagged, guards, next_tag} = build_guards(clauses, mutators, 0)
    {tagged, patterns, _next_tag} = build_pattern_literals(guard_tagged, mutators, next_tag)
    {tagged, guards, patterns}
  end

  # === guard candidates ======================================================

  # Tag every mutatable guard operator across the group with a unique
  # `meta[:mutare_tag]`, returning the once-tagged clause group, a `Candidate.Guard`
  # per mutation, and the next free tag. Clauses are visited in order and, within a
  # clause, targets in post-order DFS (matching the in-place emit ordering), so ids
  # land in source order. The tag counter is threaded across clauses (from
  # `start_tag`) so tags are unique group-wide — that uniqueness is what lets the
  # group be stored once.
  defp build_guards(clauses, mutators, start_tag) do
    {tagged_rev, candidates, next_tag} =
      Enum.reduce(clauses, {[], [], start_tag}, fn clause, {tagged_acc, cand_acc, next_tag} ->
        guard_candidates_for(clause, next_tag, tagged_acc, cand_acc, mutators)
      end)

    {Enum.reverse(tagged_rev), candidates, next_tag}
  end

  defp guard_candidates_for(clause, next_tag, tagged_acc, cand_acc, mutators) do
    case guards_of(clause) do
      [] ->
        {[clause | tagged_acc], cand_acc, next_tag}

      guards ->
        {tagged_guards, {next_tag, targets}} =
          Enum.map_reduce(guards, {next_tag, []}, fn guard, acc ->
            tag_targets(guard, acc, mutators)
          end)

        tagged_clause = put_guards(clause, tagged_guards)

        new_candidates =
          targets
          |> Enum.reverse()
          |> Enum.flat_map(fn {tag, original, muts} ->
            Enum.map(muts, fn {mutator, mutated} ->
              %Candidate.Guard{
                tag: tag,
                mutator: mutator,
                original: original,
                mutated: mutated,
                range: Sourceror.get_range(original)
              }
            end)
          end)

        {[tagged_clause | tagged_acc], cand_acc ++ new_candidates, next_tag}
    end
  end

  # Tag every mutatable operator in one guard, accumulating `{tag, original, muts}`.
  # Post-order DFS so children are tagged before parents. A nested operator's child
  # may already carry a `:mutare_tag` — harmless, since tags don't affect
  # ranges/rendering and are stripped before output.
  defp tag_targets(guard, acc, mutators) do
    Macro.postwalk(guard, acc, fn node, {next, targets} ->
      case Mutator.mutations(node, mutators) do
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

  # === head-pattern literal candidates =======================================

  # Tag every mutatable literal in each clause *head* with a unique
  # `meta[:mutare_tag]`, returning the (further) tagged clause group, a
  # `Candidate.Pattern` per mutation, and the next free tag. Mirrors `build_guards/3`
  # but walks head args (the patterns) rather than guards, and only literal-valued
  # mutations survive (`tag_pattern_targets/3`). The tag counter continues from
  # `start_tag` so pattern tags never collide with guard tags.
  defp build_pattern_literals(clauses, mutators, start_tag) do
    {tagged_rev, candidates, next_tag} =
      Enum.reduce(clauses, {[], [], start_tag}, fn clause, {tagged_acc, cand_acc, next_tag} ->
        {tagged_clause, new_cands, next_tag} = pattern_candidates_for(clause, next_tag, mutators)
        {[tagged_clause | tagged_acc], cand_acc ++ new_cands, next_tag}
      end)

    {Enum.reverse(tagged_rev), candidates, next_tag}
  end

  defp pattern_candidates_for(clause, next_tag, mutators) do
    {tagged_args, {next_tag, targets}} =
      clause
      |> clause_head_args()
      |> Enum.map_reduce({next_tag, []}, &tag_pattern_targets(&1, &2, mutators))

    case targets do
      # No literal in this head (or a 0-arity head): leave the clause untouched —
      # in particular don't rebuild a `nil`-context head into an empty arg list.
      [] -> {clause, [], next_tag}
      _ -> {put_head_args(clause, tagged_args), build_pattern_candidates(targets), next_tag}
    end
  end

  # `targets` arrives in reverse post-order; reverse to source order. One literal
  # can admit several mutations (an integer → `n+1`, `n-1`, `0`), each a separate
  # `Candidate.Pattern` sharing the tag but carrying its own replacement.
  defp build_pattern_candidates(targets) do
    targets
    |> Enum.reverse()
    |> Enum.flat_map(fn {tag, original, muts} ->
      Enum.map(muts, fn {mutator, mutated} ->
        %Candidate.Pattern{
          tag: tag,
          mutator: mutator,
          original: original,
          mutated: mutated,
          range: Sourceror.get_range(original)
        }
      end)
    end)
  end

  # A context-aware descent over one head pattern, threading `{next_tag, targets}`.
  # Unlike the guard tagger's context-free `Macro.postwalk`, a pattern walk must
  # not offer keyword/map *keys* (labels, not values) or bitstring type specifiers
  # (a `unit(0)` swap would not compile) to a mutator — so it descends explicitly,
  # tagging only scalar literals that admit a literal replacement
  # (`literal_pattern_mutations/2`). `targets` accumulates `{tag, raw_node, muts}` in
  # reverse post-order; the raw (pre-tag) node is kept for the candidate's
  # `original`/`range`.

  # A scalar literal — the only thing mutated in a pattern. No children to descend.
  defp tag_pattern_targets({:__block__, _meta, [value]} = node, {next, targets}, mutators)
       when is_integer(value) or is_float(value) or is_binary(value) or is_atom(value) do
    case literal_pattern_mutations(node, mutators) do
      [] -> {node, {next, targets}}
      muts -> {put_tag(node, next), {next + 1, [{next, node, muts} | targets]}}
    end
  end

  # A bitstring segment `value :: spec`: descend the value, keep the spec raw — a
  # spec is not a runtime value and a `size`/`unit` literal swap risks an illegal
  # specifier (`unit(0)`) that would compile-poison the single build.
  defp tag_pattern_targets({:"::", meta, [value, spec]}, acc, mutators) do
    {value, acc} = tag_pattern_targets(value, acc, mutators)
    {{:"::", meta, [value, spec]}, acc}
  end

  # A map pattern. A key literal that mutated to *another key's* value would make a
  # **duplicate map key** — a compile error — so each key's mutations are filtered
  # against the map's other keys (`map_key_values/1`) before tagging, catching the
  # `%{1 => a, 0 => b}` collision directly instead of leaving it to poison recovery.
  # Values mutate normally (duplicate values are legal). A mutation never reproduces
  # the original key value, so a replacement clashes with a sibling key iff it is in
  # the full key-value set — no per-key bookkeeping needed. (A non-scalar key, e.g.
  # `%{{1, 2} => v}`, descends generically and stays poison-backstopped.)
  defp tag_pattern_targets({:%{}, meta, pairs}, acc, mutators) when is_list(pairs) do
    key_values = map_key_values(pairs)
    {pairs, acc} = Enum.map_reduce(pairs, acc, &tag_map_pair(&1, key_values, &2, mutators))
    {{:%{}, meta, pairs}, acc}
  end

  # A keyword/map-key pair: skip the key (a structural label), descend only the
  # value. A non-label pair — a tuple `{1, 2}` or an arrow entry `1 => 2` — has no
  # `format: :keyword` key, so both sides descend and both literals mutate.
  defp tag_pattern_targets({key, value}, acc, mutators) do
    if label_key?(key) do
      {value, acc} = tag_pattern_targets(value, acc, mutators)
      {{key, value}, acc}
    else
      {key, acc} = tag_pattern_targets(key, acc, mutators)
      {value, acc} = tag_pattern_targets(value, acc, mutators)
      {{key, value}, acc}
    end
  end

  # Structural descent over an n-ary node (lists, tuples, maps, structs, nested
  # patterns): re-tag every child in order.
  defp tag_pattern_targets({form, meta, args}, acc, mutators) when is_list(args) do
    {args, acc} = Enum.map_reduce(args, acc, &tag_pattern_targets(&1, &2, mutators))
    {{form, meta, args}, acc}
  end

  defp tag_pattern_targets(list, acc, mutators) when is_list(list),
    do: Enum.map_reduce(list, acc, &tag_pattern_targets(&1, &2, mutators))

  # A var (`{:x, _, nil}`), a bare leaf, or anything else: no literal to tag.
  defp tag_pattern_targets(other, acc, _mutators), do: {other, acc}

  # The literal-valued mutations a node admits — `Mutator.mutations/2` filtered to
  # those whose replacement is itself a scalar literal. A literal is legal in any
  # pattern sub-position, so this both selects the literal families (no other
  # built-in matches a scalar-literal node) and fences out a custom mutator that
  # would emit a pattern-illegal replacement.
  defp literal_pattern_mutations(node, mutators) do
    node
    |> Mutator.mutations(mutators)
    |> Enum.filter(fn {_mutator, mutated} -> literal_node?(mutated) end)
  end

  defp literal_node?({:__block__, _meta, [value]}),
    do: is_integer(value) or is_float(value) or is_binary(value) or is_atom(value)

  defp literal_node?(_), do: false

  # === map-key collision avoidance ===========================================

  # One pair of a map pattern. A label key (`a:`) is left raw; a value-position key
  # (an arrow literal `1 =>`) is tagged with its mutations filtered so none equals a
  # sibling key. The value always descends normally.
  defp tag_map_pair({key, value}, key_values, acc, mutators) do
    {key, acc} =
      if label_key?(key), do: {key, acc}, else: tag_pattern_key(key, key_values, acc, mutators)

    {value, acc} = tag_pattern_targets(value, acc, mutators)
    {{key, value}, acc}
  end

  # Any non-pair map arg (no valid head-pattern map has one, but stay total):
  # descend generically without collision filtering.
  defp tag_map_pair(other, _key_values, acc, mutators),
    do: tag_pattern_targets(other, acc, mutators)

  # A scalar-literal map key, tagged only with collision-free mutations. A
  # structured key (`{1, 2}`, `[1]`) descends generically — its collisions are rarer
  # and stay poison-backstopped.
  defp tag_pattern_key({:__block__, _meta, [value]} = node, key_values, {next, targets}, mutators)
       when is_integer(value) or is_float(value) or is_binary(value) or is_atom(value) do
    case key_pattern_mutations(node, key_values, mutators) do
      [] -> {node, {next, targets}}
      muts -> {put_tag(node, next), {next + 1, [{next, node, muts} | targets]}}
    end
  end

  defp tag_pattern_key(other, _key_values, acc, mutators),
    do: tag_pattern_targets(other, acc, mutators)

  # Literal key mutations minus any whose replacement value already names a key in
  # the same map (which would compile-error on the duplicate). The original value is
  # never re-emitted, so membership in the full key-value set means "equals a *sibling*".
  defp key_pattern_mutations(node, key_values, mutators) do
    node
    |> literal_pattern_mutations(mutators)
    |> Enum.reject(fn {_mutator, mutated} -> literal_value_in?(mutated, key_values) end)
  end

  defp literal_value_in?({:__block__, _meta, [value]}, key_values),
    do: MapSet.member?(key_values, value)

  defp literal_value_in?(_node, _key_values), do: false

  # The set of scalar-literal key *values* of a map pattern — covering both arrow
  # keys (`1 =>`, `:a =>`) and keyword keys (`a:`, themselves `:a`), since a mutated
  # arrow key colliding with a keyword key is just as illegal. Non-literal keys
  # (`^pin`, a structured key) contribute nothing and are not protected here.
  defp map_key_values(pairs) do
    for {{:__block__, _meta, [value]}, _v} <- pairs,
        is_integer(value) or is_float(value) or is_binary(value) or is_atom(value),
        into: MapSet.new(),
        do: value
  end

  # A keyword/map *key* (`format: :keyword`) — a structural label, never offered to
  # a mutator. Block keys (`do:` …) can't appear in a head, so the value-side
  # `@block_keys` check in `Mutare.Transform.label_key?/1` isn't needed here.
  defp label_key?({:__block__, meta, [atom]}) when is_atom(atom) and is_list(meta),
    do: Keyword.get(meta, :format) == :keyword

  defp label_key?(_), do: false

  # === head-pattern structure candidates =====================================

  # Discover whole-head pattern restructurings (variable swaps, duplicate-variable
  # wildcards) for each clause. Unlike guards/literals these don't tag a single node:
  # the rewrite spans sibling positions or repeated variables (and a 2-tuple/list has
  # no taggable meta), so each candidate carries the mutated head args and is applied by
  # whole-clause replacement (`mutated_clauses/2`, like a `Drop`). A clause is indexed
  # so the replacement targets the right one.
  #
  # The participating mutators are the enabled ones exporting `pattern_mutations/2`
  # (`PatternSwap`/`PatternWildcard`, or any custom mutator), so this needs no hard-coded
  # list — toggling them off via `:mutators` simply drops them from `mutators`.
  defp build_pattern_structures(clauses, mutators) do
    case PatternStructure.mutators(mutators) do
      [] ->
        []

      structural ->
        clauses
        |> Enum.with_index()
        |> Enum.flat_map(&pattern_structures_for(&1, structural))
    end
  end

  defp pattern_structures_for({clause, index}, structural) do
    case clause_head_args(clause) do
      [] ->
        []

      args ->
        call = clause_head_call(clause)

        # A head with no rangeable call can't be diffed; skip rather than emit a site
        # the report would crash on (mirrors the return-value `get_range` guard).
        case Sourceror.get_range(call) do
          %{} = range ->
            used = clause_used_outside(clause)

            Enum.flat_map(structural, fn mutator ->
              args
              |> mutator.pattern_mutations(used)
              |> Enum.map(fn mutated_args ->
                %Candidate.PatternStructure{
                  clause_index: index,
                  mutator: mutator,
                  mutated_args: mutated_args,
                  original: call,
                  mutated: put_call_args(call, mutated_args),
                  range: range
                }
              end)
            end)

          _ ->
            []
        end
    end
  end

  # The variable names read in a clause's guard(s) and body — the `used_outside` set a
  # structural pattern mutator needs to know a variable stays bound after wildcarding.
  defp clause_used_outside({_vis, _meta, [head | rest]}) do
    guards =
      case head do
        {:when, _, [_call | gs]} -> gs
        _ -> []
      end

    PatternStructure.used_names(guards ++ rest)
  end

  # The clause's head *call* node (`{name, meta, args}`), peeling any `when` — the node
  # the report ranges and renders (`f(x, x)` → `f(_, x)`), guard left intact.
  defp clause_head_call({_vis, _meta, [head | _rest]}), do: head_call(head)

  defp head_call({:when, _meta, [call | _guards]}), do: call
  defp head_call(call), do: call

  # === clause-drop candidates ================================================

  # Drop one clause of a multi-clause function. Inputs the dropped clause handled
  # now fall to a later clause (or raise FunctionClauseError) — killed if tested.
  #
  # Only *body-bearing* clauses are droppable, and at least two must remain in play:
  # a **bodiless head** (`def f(a, b)` with no `do` — a header declaration, e.g. for
  # default args or docs) is not a clause to drop. Dropping it is a no-op, and
  # dropping the implementation while a header remains leaves a `defp …(args)` with
  # no body → "implementation not provided" (a poison). The `clause_index` stays the
  # position in the *full* clause list (what `drop_clause/2` deletes by), so the
  # header is simply never offered as a drop and never left as the lone clause.
  defp build_drops(clauses) do
    droppable =
      for {clause, index} <- Enum.with_index(clauses), body_bearing?(clause), do: {clause, index}

    if length(droppable) < 2 do
      []
    else
      Enum.map(droppable, fn {clause, index} ->
        %Candidate.Drop{clause_index: index, original: clause, range: Sourceror.get_range(clause)}
      end)
    end
  end

  # A real clause carries a body keyword (`[head, [do: …]]`); a bodiless head is just
  # `[head]`. (A `when` guard lives *inside* the head, so a guarded clause with a body
  # is still `[head_with_when, body_kw]` — two elements — and counts as body-bearing.)
  defp body_bearing?({_vis, _meta, [_head, _body | _]}), do: true
  defp body_bearing?(_), do: false

  # === liftability ===========================================================

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

  # === head args (shared by guard-liftability and pattern tagging) ===========

  # The pattern args of a *clause* (peeling the clause wrapper, then any `when`).
  # `[]` for a 0-arity head, whose call carries a `nil` context rather than an arg
  # list — so the pattern pass finds nothing to tag.
  defp clause_head_args({_vis, _meta, [head | _rest]}), do: head_args(head)
  defp clause_head_args(_), do: []

  # Replace a clause's head pattern args with `new_args` (the tagged copies),
  # peeling and restoring a `when` guard. Only called when there was at least one
  # tagged arg, so the head always has an arg list to overwrite.
  defp put_head_args({vis, meta, [head | rest]}, new_args),
    do: {vis, meta, [put_call_args(head, new_args) | rest]}

  defp put_call_args({:when, when_meta, [call | guards]}, new_args),
    do: {:when, when_meta, [put_call_args(call, new_args) | guards]}

  defp put_call_args({name, meta, _args}, new_args), do: {name, meta, new_args}
end
