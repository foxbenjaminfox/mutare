defmodule Mutare.Transform.FunctionPlan do
  @moduledoc false

  # The plan for one *lifted* clause group: a function whose guard, head-pattern
  # literal, and/or clause-structure mutations are delivered behind a dispatcher. A
  # `case` can't live in a guard or a pattern, and guards drive dispatch *across*
  # clauses, so none of these can be mutated in place — gating clauses by the active
  # id is the only way.
  #
  # This is the discovery half of lifting — pure, id-free. `Mutare.Transform` owns
  # the emission half (assigning ids, building the dispatcher and the gated
  # clauses) because that shares the `Ctx` id-threading discipline with the in-place
  # path. What lives here is the *vocabulary*: which mutants a group admits, and —
  # per candidate — *which one clause* it mutates and *how* (`mutated_clause/2`).
  #
  # ## The shared tagged clause group
  #
  # Each guard / pattern candidate is "this one clause with this one node swapped."
  # An earlier design stored that materialized clause group on each candidate — N
  # near-identical copies for N mutants. Instead the plan holds the group *once*,
  # with every mutatable guard operator *and* head-pattern literal tagged by a
  # unique `meta[:mutare_tag]` (`tagged_clauses`); each `Candidate.Lifted` carries
  # only its `tag`, its `clause_index`, and the replacement node (a guard operator
  # and a head literal are the same shape here, so one struct serves both).
  # `mutated_clause/2` reconstructs *just the one tagged clause*
  # on demand by replacing the tagged node. Tags are stripped before rendering, so a
  # leftover tag on a sibling node is harmless. Guards and pattern literals share one
  # tag counter (`build_lifted/2`) so their tags are unique group-wide.
  #
  # ## Why only literals in a head
  #
  # A head is a pattern, so only a *literal* replacement is legal there (a swapped
  # operator or a selector `case` is not). `tag_pattern_targets/3` therefore offers
  # a node to the mutators only when it is a scalar literal and keeps only the
  # mutations whose replacement is *also* a literal — which selects exactly the
  # literal families (and any future literal mutator) and guarantees the mutant
  # clause compiles. Bitstring type specifiers and keyword/map *keys* are skipped
  # (a `unit(0)` would not compile; a key is a label, not a value), mirroring the
  # in-place `:pattern` routing in `Mutare.Transform`.

  alias Mutare.Mutator
  alias Mutare.Mutator.Spec
  alias Mutare.Transform.{Candidate, ClauseAST, NodeRange, PatternStructure, Tag}

  # A plain-identifier function name (the only kind that can be spelled as a lifted base name
  # `__mutare_<name>_…`). Compiled once at module load, not per `liftable?/1` call.
  @liftable_name_regex ~r/\A[a-z_][a-zA-Z0-9_]*[?!]?\z/

  @type signature :: {:def | :defp, atom(), non_neg_integer()}

  @type t :: %__MODULE__{
          signature: signature(),
          clauses: [Macro.t()],
          tagged_clauses: [Macro.t()],
          lifted: [Candidate.Lifted.t()],
          pattern_structures: [Candidate.PatternStructure.t()],
          guard_drops: [Candidate.GuardDrop.t()],
          drops: [Candidate.Drop.t()]
        }

  defstruct [
    :signature,
    :clauses,
    :tagged_clauses,
    :lifted,
    :pattern_structures,
    :guard_drops,
    :drops
  ]

  @doc """
  Plan a consecutive same-signature clause group.

  Returns `{:lift, plan}` when the group both *admits* a lifted mutant (a guard
  swap, a head-pattern literal swap, or a droppable clause) and *can host* a
  dispatcher (`liftable?/2`), else `:in_place` — its clauses stay where they are
  and only their bodies mutate.
  """
  @spec plan(signature(), [Macro.t()], [Mutator.Spec.t()]) :: {:lift, t()} | :in_place
  def plan({_vis, name, _arity} = signature, clauses, mutators) do
    {tagged_clauses, lifted, inert_guards} = build_lifted(clauses, mutators)
    pattern_structures = build_pattern_structures(clauses, mutators)
    guard_drops = build_guard_drops(clauses, inert_guards, mutators)
    drops = build_drops(clauses)

    if (lifted != [] or pattern_structures != [] or guard_drops != [] or drops != []) and
         liftable?(name) do
      plan = %__MODULE__{
        signature: signature,
        clauses: clauses,
        tagged_clauses: tagged_clauses,
        lifted: lifted,
        pattern_structures: pattern_structures,
        guard_drops: guard_drops,
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
  guard removals, then clause drops.

  Emission walks these in order to assign ids and build one gated `defp` clause
  per candidate, so the order fixes id assignment within a lifted function.
  """
  @spec candidates(t()) :: [Candidate.t()]
  def candidates(%__MODULE__{
        lifted: lifted,
        pattern_structures: pattern_structures,
        guard_drops: guard_drops,
        drops: drops
      }),
      do: lifted ++ pattern_structures ++ guard_drops ++ drops

  @doc """
  Materialize the *single* clause a candidate mutates, with its position.

  Returns `{clause_index, mutated_clause | :drop}`. Each lifted candidate touches
  exactly one source clause — a guard/head-literal swap rewrites that clause's
  head, a structure rewrite replaces its head args, a drop removes it — so emission
  needs only the one affected clause, not a full copy of the group. The returned
  clause carries a **raw body** (no in-place selectors); `Mutare.Transform`
  assembles it into the shared lifted function as a guarded mutant clause, while
  the *unchanged* clauses are emitted once as the lifted function's originals.

    * `Candidate.Lifted` — the tagged clause at `clause_index` with the tagged node
      (guard operator or head literal) replaced by `mutated`.
    * `Candidate.PatternStructure` — the clause at `clause_index` with its head args
      replaced by `mutated_args`.
    * `Candidate.Drop` — `:drop`; no clause, the original is simply gated off when
      this mutant is active.
  """
  @spec mutated_clause(t(), Candidate.t()) :: {non_neg_integer(), Macro.t() | :drop}
  def mutated_clause(%__MODULE__{tagged_clauses: tagged}, %Candidate.Lifted{
        clause_index: index,
        tag: tag,
        mutated: mutated
      }),
      do: {index, Tag.replace_tag(Enum.at(tagged, index), tag, mutated)}

  def mutated_clause(%__MODULE__{clauses: clauses}, %Candidate.PatternStructure{
        clause_index: index,
        mutated_args: mutated_args
      }),
      do: {index, ClauseAST.put_head_args(Enum.at(clauses, index), mutated_args)}

  # A guard removal — the clause with its `when` stripped, so the lifted mutant
  # clause is gated only by `mutare_active === <id>` (no source guard) and matches
  # unconditionally when active. Raw body, like every lifted mutant.
  def mutated_clause(%__MODULE__{clauses: clauses}, %Candidate.GuardDrop{clause_index: index}),
    do: {index, ClauseAST.drop_clause_guard(Enum.at(clauses, index))}

  def mutated_clause(%__MODULE__{}, %Candidate.Drop{clause_index: index}), do: {index, :drop}

  # === lifted candidates (guards + head-pattern literals) ====================

  # Discover both head-resident lifted kinds over one shared tagged clause group,
  # threading a single tag counter so guard and pattern tags never collide. Guards
  # are tagged first (so their tags — and the ids derived from them — are unchanged
  # by adding pattern literals), then head-pattern literals on the already-tagged
  # clauses. The two passes touch disjoint parts of a clause — its `when` vs its
  # head args — so neither disturbs the other's tags.
  #
  # The guard pass also reports the **inert-guard set** (clause indices whose guard
  # produced no target), so `build_guard_drops/3` learns which guards are removable
  # without re-walking them (the guard tagger ran here already).
  defp build_lifted(clauses, mutators) do
    {guard_tagged, guards, next_tag, inert_guards} = build_guards(clauses, mutators, 0)
    {tagged, patterns, _next_tag} = build_pattern_literals(guard_tagged, mutators, next_tag)
    {tagged, guards ++ patterns, inert_guards}
  end

  # === guard candidates ======================================================

  # Tag every mutatable guard operator across the group with a unique
  # `meta[:mutare_tag]`, returning the once-tagged clause group, a `Candidate.Lifted`
  # per mutation, the next free tag, and the inert-guard set (clause indices whose
  # guard produced no target — fed to `build_guard_drops/3`). Clauses are visited in
  # order and, within a clause, targets in post-order DFS (matching the in-place emit
  # ordering), so ids land in source order. The tag counter is threaded across clauses
  # (from `start_tag`) so tags are unique group-wide — that uniqueness is what lets the
  # group be stored once.
  defp build_guards(clauses, mutators, start_tag) do
    {tagged_rev, cand_groups_rev, next_tag, inert_guards} =
      clauses
      |> Enum.with_index()
      |> Enum.reduce({[], [], start_tag, MapSet.new()}, fn {clause, index},
                                                           {tagged_acc, cand_acc, next_tag, inert} ->
        {tagged_clause, new_cands, next_tag, inert?} =
          guard_candidates_for(clause, index, next_tag, mutators)

        inert = if inert?, do: MapSet.put(inert, index), else: inert
        {[tagged_clause | tagged_acc], [new_cands | cand_acc], next_tag, inert}
      end)

    {Enum.reverse(tagged_rev), concat_groups(cand_groups_rev), next_tag, inert_guards}
  end

  # Transform one clause: returns its tagged copy, its guard candidates, the advanced
  # tag, and whether its guard is **inert** (it has a `when` but no mutator targeted
  # any alternative). A guardless clause is `inert?: false` — only a present-but-inert
  # guard is removable, which `build_guard_drops/3` re-confirms via `clause_when/1`.
  defp guard_candidates_for(clause, index, next_tag, mutators) do
    case ClauseAST.guards(clause) do
      [] ->
        {clause, [], next_tag, false}

      guards ->
        {tagged_guards, {next_tag, targets}} =
          Enum.map_reduce(guards, {next_tag, []}, fn guard, acc ->
            Tag.guard_targets(guard, acc, mutators)
          end)

        tagged_clause = ClauseAST.put_guards(clause, tagged_guards)
        {tagged_clause, lifted_candidates(targets, index), next_tag, targets == []}
    end
  end

  # Guard-operator tagging (the explicit-descent walk that keeps a remote call's
  # *form* opaque and a bitstring spec raw) lives in `Mutare.Transform.Tag` — shared
  # with the `case`/`receive`/`fn` clause-guard discovery in `Mutare.Transform.Analyze`.
  # The clause-shape navigation (`ClauseAST.guards/1`/`put_guards/2`) lives in
  # `Mutare.Transform.ClauseAST`.

  # === head-pattern literal candidates =======================================

  # Tag every mutatable literal in each clause *head* with a unique
  # `meta[:mutare_tag]`, returning the (further) tagged clause group, a
  # `Candidate.Lifted` per mutation, and the next free tag. Mirrors `build_guards/3`
  # but walks head args (the patterns) rather than guards, and only literal-valued
  # mutations survive (`tag_pattern_targets/3`). The tag counter continues from
  # `start_tag` so pattern tags never collide with guard tags.
  defp build_pattern_literals(clauses, mutators, start_tag) do
    {tagged_rev, cand_groups_rev, next_tag} =
      clauses
      |> Enum.with_index()
      |> Enum.reduce({[], [], start_tag}, fn {clause, index}, {tagged_acc, cand_acc, next_tag} ->
        {tagged_clause, new_cands, next_tag} =
          pattern_candidates_for(clause, index, next_tag, mutators)

        {[tagged_clause | tagged_acc], [new_cands | cand_acc], next_tag}
      end)

    {Enum.reverse(tagged_rev), concat_groups(cand_groups_rev), next_tag}
  end

  defp pattern_candidates_for(clause, index, next_tag, mutators) do
    {tagged_args, {next_tag, targets}} =
      clause
      |> ClauseAST.head_args()
      |> Enum.map_reduce({next_tag, []}, &Tag.pattern_literal_targets(&1, &2, mutators))

    case targets do
      # No literal in this head (or a 0-arity head): leave the clause untouched —
      # in particular don't rebuild a `nil`-context head into an empty arg list.
      [] ->
        {clause, [], next_tag}

      _ ->
        {ClauseAST.put_head_args(clause, tagged_args), lifted_candidates(targets, index),
         next_tag}
    end
  end

  # Expand a clause's tagged guard / head-literal `targets` into `Candidate.Lifted`s,
  # one per `{mutator, mutated, note}` (a literal can admit several — an integer → `n+1`,
  # `n-1`, `0`). Guard and head-literal targets build the *same* candidate (both are a
  # tagged-node replacement in one lifted clause), so this serves `build_guards` and
  # `build_pattern_literals` alike; `Tag.expand_targets/2` owns the source-order +
  # range-skip contract.
  defp lifted_candidates(targets, index) do
    Tag.expand_targets(targets, fn tag, original, mutator, mutated, note, range ->
      %Candidate.Lifted{
        tag: tag,
        clause_index: index,
        mutator: mutator,
        original: original,
        mutated: mutated,
        range: range,
        note: note
      }
    end)
  end

  # Pattern-literal tagging (the explicit-descent walk that skips keyword/map keys
  # and bitstring specs, with map-key-collision filtering) lives in
  # `Mutare.Transform.Tag` — shared with the `case`/`receive`/`fn` clause-pattern
  # discovery in `Mutare.Transform.Analyze`.

  # Flatten per-clause candidate groups accumulated newest-first (prepended in the
  # fold to keep accumulation O(n) rather than O(n²) with `++`) back into one
  # source-order list: reverse to clause order, then concat one level.
  defp concat_groups(groups_rev), do: groups_rev |> Enum.reverse() |> Enum.concat()

  # === head-pattern structure candidates =====================================

  # Discover whole-head pattern restructurings (variable swaps, duplicate-variable
  # wildcards) for each clause. Unlike guards/literals these don't tag a single node:
  # the rewrite spans sibling positions or repeated variables (and a 2-tuple/list has
  # no taggable meta), so each candidate carries the mutated head args and is applied by
  # whole-clause rebuild (`mutated_clause/2`, like a `Drop`). A clause is indexed
  # so the rebuild targets the right one.
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
    case ClauseAST.head_args(clause) do
      [] ->
        []

      raw_args ->
        call = ClauseAST.clause_head_call(clause)

        # A default arg `pattern \\ default` is offered as just its `pattern`: the
        # default is not part of the match, and swapping/wildcarding *across* it
        # (or treating `\\` as a swappable container) would be illegal. Strip
        # before the mutators run, then re-attach each `\\ default` to its (same)
        # position afterwards — swaps/wildcards never move top-level args, so the
        # default lands back where it belongs and the base clause (which strips
        # `\\` anyway) and the diff both stay correct.
        args = strip_defaults(raw_args)

        # A head with no rangeable call can't be diffed; skip rather than emit a site
        # the report would crash on (mirrors the return-value `get_range` guard).
        case NodeRange.get(call) do
          %{} = range ->
            used = clause_used_outside(clause)
            original = ClauseAST.put_call_args(call, raw_args)

            Enum.flat_map(structural, fn mutator ->
              mutator
              |> Mutare.Mutator.pattern_mutations(args, used)
              |> Enum.map(fn mutated_args ->
                mutated_args = reattach_defaults(mutated_args, raw_args)

                %Candidate.PatternStructure{
                  clause_index: index,
                  mutator: mutator,
                  mutated_args: mutated_args,
                  original: original,
                  mutated: ClauseAST.put_call_args(call, mutated_args),
                  range: range
                }
              end)
            end)

          _ ->
            []
        end
    end
  end

  # Drop each arg's `\\ default` down to its bare pattern (a no-op for a plain arg).
  defp strip_defaults(args), do: Enum.map(args, &strip_default/1)
  defp strip_default({:\\, _meta, [pattern, _default]}), do: pattern
  defp strip_default(arg), do: arg

  # Re-wrap the positions that originally carried a default. A structural mutation
  # never changes the arg-list length or reorders top-level positions, so a
  # positional zip restores `\\ default` exactly where the source had it.
  defp reattach_defaults(mutated_args, raw_args) do
    Enum.zip_with(mutated_args, raw_args, fn
      pattern, {:\\, meta, [_pattern, default]} -> {:\\, meta, [pattern, default]}
      pattern, _raw -> pattern
    end)
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

  # === guard-removal candidates ==============================================

  # Offer to drop a clause's whole `when` guard, but only for an **inert** guard —
  # one no *other* enabled mutator already mutates. The guard tagger
  # (`Tag.guard_targets/3`) reports every mutatable guard node; an empty result
  # means the guard is untouched by every family (`is_binary(x)`, `x`, a custom
  # `defguard`), so removing it is the only signal there. A guard with any target
  # (`x > 0`, `Integer.is_even(x)`, `a and b`) is already covered, so no removal is
  # offered — keeping guard swaps and guard removals mutually exclusive per clause.
  #
  # The inert set is computed by `build_guards/3` (which already walked every guard
  # to find swap targets), so this pass just consults it — no second guard walk.
  # Gated on `Mutare.Mutators.GuardDrop` being enabled.
  defp build_guard_drops(clauses, inert_guards, mutators) do
    case Spec.find(mutators, Mutare.Mutators.GuardDrop) do
      nil ->
        []

      spec ->
        clauses
        |> Enum.with_index()
        |> Enum.flat_map(&guard_drop_for(&1, spec, inert_guards))
    end
  end

  defp guard_drop_for({clause, index}, spec, inert_guards) do
    with true <- MapSet.member?(inert_guards, index),
         {:when, _wm, [call | _guards]} = when_node <- ClauseAST.clause_when(clause),
         %{} = range <- NodeRange.get(when_node) do
      [
        %Candidate.GuardDrop{
          clause_index: index,
          mutator: spec,
          original: when_node,
          mutated: call,
          range: range
        }
      ]
    else
      _ -> []
    end
  end

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
      for {clause, index} <- Enum.with_index(clauses),
          ClauseAST.body_bearing?(clause),
          do: {clause, index}

    if length(droppable) < 2 do
      []
    else
      Enum.map(droppable, fn {clause, index} ->
        %Candidate.Drop{clause_index: index, original: clause, range: NodeRange.get(clause)}
      end)
    end
  end

  # === liftability ===========================================================

  # We can only lift functions whose name is a plain identifier (operator names
  # like `<>` can't be spelled as `__mutare_<>_2_g1(...)`). Default arguments are
  # supported: their `\\ default` annotations ride on the public dispatcher (which
  # keeps the original multi-arity contract), while the lifted base function takes
  # the full arity with the defaults stripped — see `Mutare.Transform`.
  defp liftable?(name) do
    Regex.match?(@liftable_name_regex, Atom.to_string(name))
  end
end
