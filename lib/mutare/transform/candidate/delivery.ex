defmodule Mutare.Transform.Candidate.Delivery do
  @moduledoc false

  # Single source of truth for how each `Mutare.Transform.Candidate` variant is *delivered*:
  # its node-local emit route, the `Mutare.Site` constructor that records it, and — for the
  # selector-delivered kinds — the struct field holding an ordinary in-place selector's mutant
  # branch body. `site/4`, `route/1`, and `selector_branch/1` all read the one per-variant
  # `profile/1` table below, so the three facets can't drift apart: this collapses the manual
  # mirror (one struct re-listed in three separate dispatch functions, where adding a variant
  # meant remembering to touch each). Adding a candidate is one new `profile/1` clause — the
  # matching `build_site/4` arm and the routed emit in `Mutare.Transform` then follow.
  #
  # Three groups of variant, by *who consumes them*:
  #
  #   * node-local — carried on a node's `meta[:mutare]` / `:mutare_case` and dispatched by
  #     `Mutare.Transform` off `route/1` (`:in_place` / `:case_clause` / `:match_pattern` /
  #     `:macro_pattern`). `classify_node_candidates/1` admits exactly these.
  #   * lifted (`Lifted` / `PatternStructure` / `GuardDrop` / `Drop`) — consumed from
  #     `Mutare.Transform.FunctionPlan`, never node-local; `route/1` reports `:lifted` and
  #     `classify_node_candidates/1` rejects them.
  #   * hosted (`Hosted`) — consumed from its own metadata by `Mutare.Transform.HostedEmit`,
  #     which records its Sites *per logical mutant* there, not through `site/4`. `route/1`
  #     reports `:hosted` (so `classify_node_candidates/1` rejects it); `site/4` is never called
  #     on it.

  alias Mutare.Site
  alias Mutare.Transform.Candidate

  @type node_candidate ::
          Candidate.InPlace.t()
          | Candidate.Return.t()
          | Candidate.CasePattern.t()
          | Candidate.RescueDrop.t()
          | Candidate.CaseClause.t()
          | Candidate.MatchPattern.t()
          | Candidate.MacroPattern.t()
  @type node_route :: :in_place | :case_clause | :match_pattern | :macro_pattern
  @type routed_node_candidates :: :none | {node_route(), [node_candidate()]}

  # The routes `classify_node_candidates/1` admits — the node-local ones. The lifted / hosted
  # candidates report `:lifted` / `:hosted` and are routed by their dedicated emit paths.
  @node_routes [:in_place, :case_clause, :match_pattern, :macro_pattern]

  @doc "Classify homogeneous AST-node candidates by their node-local emit route."
  @spec classify_node_candidates([node_candidate()]) :: routed_node_candidates()
  def classify_node_candidates([]), do: :none

  def classify_node_candidates([candidate | _] = candidates) do
    route = node_route!(candidate)
    assert_homogeneous!(route, candidates)
    {route, candidates}
  end

  @doc """
  Build the recorded `Mutare.Site` for a claimed candidate id.

  `flags` is the `{render?, summary?}` pair carried from `Mutare.Transform.Config`: `render?` is
  the scan's diff-deferral flag (`false` defers the per-site `Sourceror` `*_code` render) and
  `summary?` builds the cheap `Macro` live one-liner (`true` only when a live reporter will show
  it — off under `--quiet`). Both are forwarded verbatim to the `Mutare.Site` constructor.
  """
  @spec site(pos_integer(), Candidate.t(), String.t(), {boolean(), boolean()}) :: Site.t()
  def site(id, candidate, file, flags) do
    {_route, site_kind, _branch_field} = profile(candidate)
    build_site(site_kind, id, candidate, file, flags)
  end

  @doc """
  A candidate's delivery route: a node-local `t:node_route/0`, or `:lifted` / `:hosted` for the
  candidates delivered by their dedicated (non-node-local) emit paths.
  """
  @spec route(Candidate.t()) :: node_route() | :lifted | :hosted
  def route(candidate), do: elem(profile(candidate), 0)

  @doc """
  The body expression for an ordinary in-place selector's mutant branch. Only meaningful for an
  `:in_place`-routed candidate (the only context that builds such a selector); on any other kind
  it raises (`branch_field` is `nil`).
  """
  @spec selector_branch(Candidate.t()) :: Macro.t()
  def selector_branch(candidate) do
    {_route, _site_kind, branch_field} = profile(candidate)
    Map.fetch!(candidate, branch_field)
  end

  # The single per-variant delivery table: `{route, site_kind, branch_field}`.
  #
  #   * `route`        — `t:node_route/0`, or `:lifted` / `:hosted` for the candidates routed by
  #                      `FunctionPlan` / `HostedEmit`.
  #   * `site_kind`    — selects the `build_site/4` arm (which `Mutare.Site` constructor, and
  #                      which of the candidate's fields it reads).
  #   * `branch_field` — the struct field `selector_branch/1` reads for an in-place selector's
  #                      mutant body; `nil` for kinds never delivered that way (a lifted / hosted
  #                      candidate, or a node-local one whose route is not `:in_place`).
  @spec profile(Candidate.t()) :: {node_route() | :lifted | :hosted, atom(), atom() | nil}
  defp profile(%Candidate.InPlace{}), do: {:in_place, :in_place, :mutated}
  defp profile(%Candidate.Return{}), do: {:in_place, :return_value, :mutated}
  defp profile(%Candidate.CasePattern{}), do: {:in_place, :in_place, :replacement}
  defp profile(%Candidate.RescueDrop{}), do: {:in_place, :in_place_drop, :replacement}
  defp profile(%Candidate.CaseClause{}), do: {:case_clause, :in_place, nil}
  defp profile(%Candidate.MatchPattern{}), do: {:match_pattern, :in_place, nil}
  defp profile(%Candidate.MacroPattern{}), do: {:macro_pattern, :in_place, nil}
  defp profile(%Candidate.Lifted{}), do: {:lifted, :lifted_replace, nil}
  defp profile(%Candidate.PatternStructure{}), do: {:lifted, :lifted_replace, nil}
  defp profile(%Candidate.GuardDrop{}), do: {:lifted, :lifted_replace, nil}
  defp profile(%Candidate.Drop{}), do: {:lifted, :clause_drop, nil}
  defp profile(%Candidate.Hosted{}), do: {:hosted, :hosted, nil}

  # Each `site_kind` knows which `Mutare.Site` constructor to call and which candidate fields it
  # reads (the constructors differ in arity and in which fields they record). `flags` is the
  # `{render?, summary?}` pair, forwarded as the two render opts.
  defp build_site(:in_place, id, c, file, {render?, summary?}),
    do:
      Site.in_place(id, file, c.range, c.original, c.mutated, c.mutator,
        note: note(c),
        variant: variant(c),
        render?: render?,
        summary?: summary?
      )

  defp build_site(:lifted_replace, id, c, file, {render?, summary?}),
    do:
      Site.lifted_replace(id, file, c.range, c.original, c.mutated, c.mutator,
        note: note(c),
        variant: variant(c),
        render?: render?,
        summary?: summary?
      )

  defp build_site(:return_value, id, c, file, {render?, summary?}),
    do:
      Site.return_value(id, file, c.range, c.original, c.mutated, c.mutator,
        render?: render?,
        summary?: summary?
      )

  defp build_site(:in_place_drop, id, c, file, {render?, summary?}),
    do:
      Site.in_place_drop(id, file, c.range, c.dropped, c.mutator,
        render?: render?,
        summary?: summary?
      )

  defp build_site(:clause_drop, id, c, file, {render?, summary?}),
    do: Site.clause_drop(id, file, c.range, c.original, render?: render?, summary?: summary?)

  # `Hosted` records its Sites per logical mutant in `HostedEmit`, never through `site/4`; the
  # clause exists so a stray call fails loudly rather than as a `FunctionClauseError`.
  defp build_site(:hosted, _id, c, _file, _flags),
    do:
      raise(ArgumentError, "#{inspect(c.__struct__)} records its Sites per mutant in HostedEmit")

  # The optional per-mutant advisory a producing mutator attached. Read by field, not by
  # struct: any future note-bearing candidate is covered as soon as it carries the field.
  defp note(%{note: note}), do: note
  defp note(_candidate), do: nil

  # The production-time `# mutare:ignore` variant tag a value family attached. Read by field
  # (like `note/1`), so a candidate without the field (a pattern/case kind) resolves to `nil` —
  # `Site` then derives the label via `c:Mutare.Mutator.variant/2`.
  defp variant(%{variant: variant}), do: variant
  defp variant(_candidate), do: nil

  # A candidate's node-local route, raising for the lifted / hosted kinds that have no place in
  # the node-local classifier (matching `classify_node_candidates/1`'s contract).
  defp node_route!(candidate) do
    route = route(candidate)

    if route in @node_routes do
      route
    else
      raise ArgumentError,
            "#{inspect(candidate.__struct__)} is not a node-local candidate; " <>
              "lifted and hosted candidates use their dedicated emit paths"
    end
  end

  defp assert_homogeneous!(route, candidates) do
    case Enum.find(candidates, &(node_route!(&1) != route)) do
      nil ->
        :ok

      candidate ->
        raise "candidate delivery route mismatch: expected #{inspect(route)}, " <>
                "got #{inspect(node_route!(candidate))} for #{inspect(candidate.__struct__)}"
    end
  end
end
