defmodule Mutare.Transform.FunctionPlan do
  @moduledoc false

  # The plan for one *lifted* clause group: a function whose guard and/or
  # clause-structure mutations are delivered by duplicating the whole clause group
  # behind a dispatcher (a `case` can't live in a guard, and guards drive dispatch
  # *across* clauses, so neither can be mutated in place).
  #
  # This is the discovery half of lifting — pure, id-free. `Mutare.Transform`
  # owns the emission half (assigning ids, renaming copies, building the
  # dispatcher) because that shares the `Ctx` id-threading discipline with the
  # in-place path. What lives here is the *vocabulary*: which mutants a group
  # admits and how to materialize each one's clause copy.
  #
  # ## The shared tagged clause group
  #
  # Every guard candidate needs "the whole clause group with this one guard
  # operator swapped." The previous design stored that materialized group on each
  # candidate — N near-identical full copies for N guard mutants. Instead the plan
  # holds the group *once*, with every mutatable guard operator tagged by a unique
  # `meta[:mutare_tag]` (`tagged_clauses`); each `Candidate.Guard` carries only its
  # `tag` and the replacement node. `mutated_clauses/2` reconstructs a copy on
  # demand by replacing the tagged node. Tags are stripped before rendering, so a
  # leftover tag on a sibling operator is harmless.

  alias Mutare.Mutator
  alias Mutare.Transform.Candidate

  @type signature :: {:def | :defp, atom(), non_neg_integer()}

  @type t :: %__MODULE__{
          signature: signature(),
          clauses: [Macro.t()],
          tagged_clauses: [Macro.t()],
          guards: [Candidate.Guard.t()],
          drops: [Candidate.Drop.t()]
        }

  defstruct [:signature, :clauses, :tagged_clauses, :guards, :drops]

  @doc """
  Plan a consecutive same-signature clause group.

  Returns `{:lift, plan}` when the group both *admits* a lifted mutant (a guard
  swap or a droppable clause) and *can host* a dispatcher (`liftable?/2`), else
  `:in_place` — its clauses stay where they are and only their bodies mutate.
  """
  @spec plan(signature(), [Macro.t()], [module()]) :: {:lift, t()} | :in_place
  def plan({_vis, name, _arity} = signature, clauses, mutators) do
    {tagged_clauses, guards} = build_guards(clauses, mutators)
    drops = build_drops(clauses)

    if (guards != [] or drops != []) and liftable?(name, clauses) do
      plan = %__MODULE__{
        signature: signature,
        clauses: clauses,
        tagged_clauses: tagged_clauses,
        guards: guards,
        drops: drops
      }

      {:lift, plan}
    else
      :in_place
    end
  end

  @doc """
  The lifted candidates of this group, guard swaps first then clause drops.

  Emission walks these in order to assign ids and build one private `defp` copy
  per candidate, so the order fixes id assignment within a lifted function.
  """
  @spec candidates(t()) :: [Candidate.t()]
  def candidates(%__MODULE__{guards: guards, drops: drops}), do: guards ++ drops

  @doc """
  Materialize one candidate's mutated clause group — the bodies of its private copy.

  A `Candidate.Guard` replaces its tagged operator in the shared tagged group; a
  `Candidate.Drop` removes its clause from the original group.
  """
  @spec mutated_clauses(t(), Candidate.t()) :: [Macro.t()]
  def mutated_clauses(%__MODULE__{tagged_clauses: tagged}, %Candidate.Guard{
        tag: tag,
        mutated: mutated
      }),
      do: replace_tag(tagged, tag, mutated)

  def mutated_clauses(%__MODULE__{clauses: clauses}, %Candidate.Drop{clause_index: index}),
    do: List.delete_at(clauses, index)

  # === guard candidates ======================================================

  # Tag every mutatable guard operator across the group with a unique
  # `meta[:mutare_tag]`, returning the once-tagged clause group and a
  # `Candidate.Guard` per mutation. Clauses are visited in order and, within a
  # clause, targets in post-order DFS (matching the in-place emit ordering), so
  # ids land in source order. The tag counter is threaded across clauses so tags
  # are unique group-wide — that uniqueness is what lets the group be stored once.
  defp build_guards(clauses, mutators) do
    {tagged_rev, candidates, _next_tag} =
      Enum.reduce(clauses, {[], [], 0}, fn clause, {tagged_acc, cand_acc, next_tag} ->
        guard_candidates_for(clause, next_tag, tagged_acc, cand_acc, mutators)
      end)

    {Enum.reverse(tagged_rev), candidates}
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

  # === clause-drop candidates ================================================

  # Drop one clause of a multi-clause function. Inputs the dropped clause handled
  # now fall to a later clause (or raise FunctionClauseError) — killed if tested.
  defp build_drops(clauses) when length(clauses) < 2, do: []

  defp build_drops(clauses) do
    clauses
    |> Enum.with_index()
    |> Enum.map(fn {clause, index} ->
      %Candidate.Drop{clause_index: index, original: clause, range: Sourceror.get_range(clause)}
    end)
  end

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
end
