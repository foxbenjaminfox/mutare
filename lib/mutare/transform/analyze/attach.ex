defmodule Mutare.Transform.Analyze.Attach do
  @moduledoc false

  # The analyze pass's candidate-construction layer: the leaf helpers that turn a mutator's
  # output into a node's in-place candidates, built **on top of** `Mutare.Transform.Meta` (the
  # raw `:mutare_*` read/write surface) and with **no dependency on the descent**. The dispatch
  # (`Mutare.Transform.Analyze`) and every handler submodule
  # (`Captures`/`ClausePatterns`/`Conditions`/`Returns`/`MatchPatterns`/`Routed`/`DefClause`)
  # build and attach candidates through here, so the attachment vocabulary is one
  # dependency-neutral leaf rather than a back-edge into `Analyze`:
  #
  #   * `offer/3,4`               — offer a node to the mutators and attach what fires (the
  #                                 in-place candidate creator the dispatch leans on)
  #   * `build_candidates/2`      — `Candidate.InPlace`s from a node + a mutator result list
  #   * `put_candidates/2`        — set a node's in-place candidates (`Meta.put_candidates/3`)
  #   * `put_candidates_if_any/2` — `put_candidates/2` guarded on a non-empty list
  #   * `append_candidates/3`     — append in-place candidates from a range-built list,
  #                                 preserving any already there
  #   * `ranged_candidates/2`     — build candidates from a raw node's range (`[]` if unrangeable)
  #
  # `Meta` owns the raw key access (keyed by logical kind); `Attach` owns the higher-level
  # "ask the mutators, build `Candidate.InPlace`s, range them" operations the descent needs.

  alias Mutare.Mutator.Dispatch
  alias Mutare.Mutator.Mutation.Attribution
  alias Mutare.Transform.{Candidate, Meta, NodeRange}

  # Offer `raw` to the mutators; if any fire, attach their candidates — built from
  # `raw`, so the diff renders the author's node — to `subject`, the already-analyzed
  # node whose children carry their own selectors. `subject` *is* `raw` at most sites;
  # the `<<>>`/`if`/`not in` clauses pass an analyzed/rebuilt subject distinct from the
  # raw node the candidate records. `context` carries the pipe flag (`Dispatch.mutations`).
  # `Mutare.Transform.Analyze.Routed` offers a known-macro node through here
  # (`offer(node, node, mutators, context)`).
  #
  # A leaf return tail of a **unit-returning** function (`Meta.unit_tail?/1`, stamped by
  # `Mutare.Transform.UnitReturns`) is not a value position — the `:ok`/`nil` there is the
  # spelling of "nothing", not data — so it is never offered, the way a block key or a
  # macro-routed `:skip` argument never is. Transform-enforced, deliberately not a mark: marks are
  # shared vocabulary each family reads by choice (NOTES "The `:structural` shared mark"), whereas
  # this is the transform's own return-path classification.
  def offer(subject, raw, mutators, context \\ %{pipe_mode: :unpiped}) do
    if Meta.unit_tail?(raw) do
      subject
    else
      # `Meta.context_with_marks/2` surfaces any position marks stamped on `raw` (by
      # `Mutare.Transform.Resolve.ArgumentMarks`, at a position some mutator asked to mark) to the
      # mutators as `context.marks` — the same enrichment the tag-based path applies (`Mutare.Transform.Tag`).
      case Dispatch.mutations(raw, mutators, Meta.context_with_marks(context, raw)) do
        [] -> subject
        muts -> put_candidates(subject, build_candidates(raw, muts))
      end
    end
  end

  # Build node-level `Candidate.InPlace`s from a node and a mutator result list — the raw
  # material both `offer/4` and the clause-pattern builders attach as in-place candidates.
  def build_candidates(node, muts) do
    range = NodeRange.get(node)

    Enum.map(muts, fn %Dispatch.Result{} = result ->
      {attribution, attribution_range} = checked_attribution(result.attribution, node, range)

      %Candidate.InPlace{
        mutator: result.spec,
        original: node,
        mutated: result.node,
        range: range,
        note: result.note,
        variant: result.variant,
        attribution: attribution,
        attribution_range: attribution_range
      }
    end)
  end

  # A whole-node rewrite's `:attribution` (from `Mutare.Mutator.Mutation.at/2` / `at_drop/1`) moves
  # the site's location and diff off the offered node onto an inner clause (`Candidate.Delivery`
  # honours it; the metamutant is still built from the offered node's `mutated`). Core can't prove
  # the plugin pointed it at a clause *inside* the rewrite, but it can catch the two ways it would
  # mislocate a site: a clause that isn't rangeable (no `Mutare.Site` could be built from it) or one
  # whose span escapes the offered node's footprint. Either is a mutator bug; warn and fall back to
  # attributing the site to the offered node (the pre-attribution behaviour) rather than emit a diff
  # pointing at unrelated source or crash on a nil range. The clause's range is carried with the
  # candidate, so delivery does not recompute it. `nil` (no attribution) is the common path.
  defp checked_attribution(nil, _offered_node, _offered_range), do: {nil, nil}

  defp checked_attribution(
         %Attribution{original: clause} = attribution,
         offered_node,
         offered_range
       ) do
    case safe_range(clause) do
      nil ->
        warn_attribution(offered_node, "its clause is not rangeable")
        {nil, nil}

      clause_range ->
        if within?(clause_range, offered_range) do
          {attribution, clause_range}
        else
          warn_attribution(offered_node, "its clause escapes the mutated node's span")
          {nil, nil}
        end
    end
  end

  # `Mutare.Transform.NodeRange.get/1` returns `nil` for some unrangeable nodes but *raises*
  # (Sourceror's range arithmetic hits a `nil` line) for a synthesized node with no source meta —
  # exactly what a mis-built attribution points at. Both mean "core can't place this clause", so
  # collapse them to `nil` here rather than let a mutator bug crash the whole transform.
  defp safe_range(node) do
    NodeRange.get(node)
  rescue
    _ -> nil
  end

  defp within?(inner, outer) do
    pos(inner.start) >= pos(outer.start) and pos(inner.end) <= pos(outer.end)
  end

  defp pos(loc), do: {loc[:line], loc[:column]}

  defp warn_attribution(offered_node, why) do
    IO.warn(
      "ignoring a mutation :attribution because #{why}; the site will be reported at " <>
        "`#{Macro.to_string(offered_node)}` instead. Point Mutation.at/2 (or at_drop/1) at a " <>
        "clause inside the returned node.",
      []
    )
  end

  # Set a node's in-place candidate list (replacing any present; an empty list removes the key).
  def put_candidates(node, candidates), do: Meta.put_candidates(node, :in_place, candidates)

  @doc """
  `put_candidates/2` guarded on a non-empty list: attach the in-place candidates when some fired,
  else return the node untouched (no empty key). The shared shape of the "offer a position to the
  structural families, attach only if any produced a candidate" attach helpers
  (`MatchPattern`/`MacroPattern`/clause-pattern/`try`-rescue).
  """
  @spec put_candidates_if_any(Macro.t(), [struct()]) :: Macro.t()
  def put_candidates_if_any(node, []), do: node
  def put_candidates_if_any(node, candidates), do: put_candidates(node, candidates)

  @doc """
  Append in-place candidates to a node, **preserving** any already there (so an operator candidate
  keeps its id before a condition one at a shared node). The candidate list is built from `raw`
  by `ranged_candidates/2`; the node is returned unchanged when `raw` can't be ranged (no mutant
  recorded). `Analyze.Conditions`' condition attachment.
  """
  @spec append_candidates(Macro.t(), Macro.t(), (map() -> [struct()])) :: Macro.t()
  def append_candidates(node, raw, build_fun) do
    case ranged_candidates(raw, build_fun) do
      [] -> node
      candidates -> Meta.append_candidates(node, :in_place, candidates)
    end
  end

  @doc """
  The candidates `build_fun.(range)` builds from `raw`'s source range, or `[]` when `raw` can't
  be ranged (no mutant recorded). `build_fun` stays at the call site because the condition and
  return-tail attachments build different `Candidate` structs. The shared range step of
  `append_candidates/3` and `Analyze.Returns`, which builds on the raw tree and delivers to the
  analyzed one by node identity.
  """
  @spec ranged_candidates(Macro.t(), (map() -> [struct()])) :: [struct()]
  def ranged_candidates(raw, build_fun) do
    case NodeRange.get(raw) do
      %{} = range -> build_fun.(range)
      _ -> []
    end
  end
end
