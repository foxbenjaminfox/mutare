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
  # "ask the mutators, build `Candidate.InPlace`s with checked reports" operations the descent needs.

  alias Mutare.Mutator.Dispatch
  alias Mutare.Transform.Candidate.Report
  alias Mutare.Transform.{Candidate, Meta, NodeRange, Resolve, WrittenPipe}

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
  def offer(subject, raw, mutators, context \\ %{}) do
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
    # A prefix synthesized by flattening a grouped RHS has no standalone source span;
    # its whole-call replacements cover the enclosing group, including the remaining stages.
    range = node |> WrittenPipe.report_node() |> NodeRange.get()

    Enum.map(muts, fn %Dispatch.Result{} = result ->
      # A rebuilt call carries the offered call's route stamp, computed for another call;
      # route every call the mutant changed as the call it now is before anything reads it.
      mutated = Resolve.reroute(result.node, node)

      # A mutator's own attribution wins; failing one, a rewritten pipe stage's mutant is
      # reported at the stage the user wrote (`WrittenPipe.stage_attribution/2`) — and still
      # classified as the call the mutator was offered, never as that stage.
      stage = is_nil(result.attribution) && WrittenPipe.stage_attribution(node, mutated)

      report =
        Report.new(node, mutated, range, result.attribution || stage || nil, stage?: !!stage)

      %Candidate.InPlace{
        mutator: result.spec,
        original: node,
        mutated: mutated,
        report: report,
        note: result.note,
        variant: result.variant
      }
    end)
  end

  # Hosted fragments have foreign semantics: validate their report origins without
  # rerouting their replacement as Elixir. The same InPlace report machinery serves both
  # delivery paths; only HostedEmit decides how to weave these logical replacements.
  def hosted_candidates(original, results, range) do
    Enum.map(results, fn %Dispatch.Result{} = result ->
      %Candidate.InPlace{
        original: original,
        mutated: result.node,
        mutator: result.spec,
        report: Report.new(original, result.node, range, result.attribution),
        note: result.note,
        variant: result.variant
      }
    end)
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
