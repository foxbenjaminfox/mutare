defmodule Mutare.Transform.Candidate.Delivery do
  @moduledoc false

  # Single source of truth for how each `Mutare.Transform.Candidate` variant is *delivered*:
  # its node-local emit route, how its `Mutare.Site` is recorded, and — for the
  # selector-delivered kinds — the struct field holding an ordinary in-place selector's mutant
  # branch body. `site/4`, `route/1`, and `selector_branch/1` all read the one per-variant
  # `profile/1` table below, so the three facets can't drift apart: this collapses the manual
  # mirror (one struct re-listed in three separate dispatch functions, where adding a variant
  # meant remembering to touch each). Adding a candidate is one new `profile/1` clause, and the
  # routed emit in `Mutare.Transform` then follows.
  #
  # What a Site records about the mutation — edit, range, position, classification, note,
  # variant tag — is the candidate's `Candidate.Report`, built when the candidate was; the
  # profile adds only how it was delivered (`:in_place` or `:lifted`, or a return constant).
  # Which candidates reach here at all is `Candidate.Eligibility`'s decision.
  #
  # Three groups of variant, by *who consumes them*:
  #
  #   * node-local — carried on a node's `meta[:mutare]` / `:mutare_case` and dispatched by
  #     `Mutare.Transform` off `route/1` (`:in_place` / `:case_clause` / `:fn_clause` /
  #     `:receive_clause` / `:clause_guard` / `:match_pattern` / `:macro_pattern`).
  #     `classify_node_candidates/1` admits exactly these.
  #   * lifted (`Lifted` / `PatternStructure` / `GuardDrop` / `Drop`) — consumed from
  #     `Mutare.Transform.FunctionPlan`, never node-local; `route/1` reports `:lifted` and
  #     `classify_node_candidates/1` rejects them.
  #   * hosted (`Hosted`) — consumed from its own metadata by `Mutare.Transform.HostedEmit`,
  #     which records its Sites *per logical mutant* there, not through `site/4`. `route/1`
  #     reports `:hosted` (so `classify_node_candidates/1` rejects it); `site/4` is never called
  #     on it.

  alias Mutare.Site
  alias Mutare.Transform.Candidate
  alias Mutare.Transform.Candidate.Report

  @type node_candidate ::
          Candidate.InPlace.t()
          | Candidate.Return.t()
          | Candidate.RescueNarrow.t()
          | Candidate.RescueDrop.t()
          | Candidate.CaseClause.t()
          | Candidate.FnClause.t()
          | Candidate.ReceiveClause.t()
          | Candidate.ClauseGuard.t()
          | Candidate.MatchPattern.t()
          | Candidate.MacroPattern.t()
  @type node_route ::
          :in_place
          | :case_clause
          | :fn_clause
          | :receive_clause
          | :clause_guard
          | :match_pattern
          | :macro_pattern
  @type routed_node_candidates :: :none | {node_route(), [node_candidate()]}

  # The routes `classify_node_candidates/1` admits — the node-local ones. The lifted / hosted
  # candidates report `:lifted` / `:hosted` and are routed by their dedicated emit paths.
  @node_routes [
    :in_place,
    :case_clause,
    :fn_clause,
    :receive_clause,
    :clause_guard,
    :match_pattern,
    :macro_pattern
  ]

  @doc """
  Classify AST-node candidates by their node-local emit route.

  A fn or receive keeps its clause candidates alongside whole-node in-place candidates,
  preserving discovery order (including later return/condition appends). Its emitter
  claims the entire list in that order, then interleaves clauses inside the whole-node selector
  in bound scopes, or combines all branches in one selector in unbound scopes.
  Every other route requires a homogeneous list.
  """
  @spec classify_node_candidates([node_candidate()]) :: routed_node_candidates()
  def classify_node_candidates([]), do: :none

  def classify_node_candidates([candidate | _] = candidates) do
    route = Enum.find_value(candidates, &clause_list_route/1) || node_route!(candidate)

    assert_compatible_routes!(route, candidates)
    {route, candidates}
  end

  defp clause_list_route(%Candidate.FnClause{}), do: :fn_clause
  defp clause_list_route(%Candidate.ReceiveClause{}), do: :receive_clause
  defp clause_list_route(%Candidate.ClauseGuard{}), do: :clause_guard
  defp clause_list_route(_), do: nil

  @doc """
  The `{line, column}` `site/4` would record, without building the `Mutare.Site`.

  `Mutare.Transform.ClaimState` uses it during the **count** pass to test a candidate against a
  `--line`/`--since` selection. The count sink builds no `Site`: building one would call the
  producing mutator's `c:Mutare.Mutator.variant/2` callback a second time just to check a
  location.
  """
  @spec position(Candidate.t()) :: {pos_integer(), pos_integer()}
  def position(%{report: %Report{position: position}}),
    do: {position[:line], position[:column]}

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
  The `{site/4, position/1}` pair `Mutare.Transform.SelectorEmit.claim_items/4` takes for
  claiming candidates.
  """
  @spec site_fns() ::
          {(pos_integer(), Candidate.t(), String.t(), {boolean(), boolean()} -> Site.t()),
           (Candidate.t() -> {pos_integer(), pos_integer()})}
  def site_fns, do: {&site/4, &position/1}

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
  #   * `site_kind`    — how the delivery is recorded: `:in_place` or `:lifted` (`Site.kind`), or
  #                      `:return_value`, an in-place constant recorded with no AST forms.
  #   * `branch_field` — the struct field `selector_branch/1` reads for an in-place selector's
  #                      mutant body; `nil` for kinds never delivered that way (a lifted / hosted
  #                      candidate, or a node-local one whose route is not `:in_place`).
  @spec profile(Candidate.t()) ::
          {node_route() | :lifted | :hosted, :in_place | :lifted | :return_value | :hosted,
           atom() | nil}
  defp profile(%Candidate.InPlace{}), do: {:in_place, :in_place, :mutated}
  defp profile(%Candidate.Return{}), do: {:in_place, :return_value, :mutated}
  defp profile(%Candidate.RescueNarrow{}), do: {:in_place, :in_place, :replacement}
  defp profile(%Candidate.RescueDrop{}), do: {:in_place, :in_place, :replacement}
  defp profile(%Candidate.CaseClause{}), do: {:case_clause, :in_place, nil}
  defp profile(%Candidate.FnClause{}), do: {:fn_clause, :in_place, nil}
  defp profile(%Candidate.ReceiveClause{}), do: {:receive_clause, :in_place, nil}
  defp profile(%Candidate.ClauseGuard{}), do: {:clause_guard, :in_place, nil}
  defp profile(%Candidate.MatchPattern{}), do: {:match_pattern, :in_place, nil}
  defp profile(%Candidate.MacroPattern{}), do: {:macro_pattern, :in_place, nil}
  defp profile(%Candidate.Lifted{}), do: {:lifted, :lifted, nil}
  defp profile(%Candidate.LiftedGuard{}), do: {:lifted, :lifted, nil}
  defp profile(%Candidate.PatternStructure{}), do: {:lifted, :lifted, nil}
  defp profile(%Candidate.GuardDrop{}), do: {:lifted, :lifted, nil}
  defp profile(%Candidate.Drop{}), do: {:lifted, :lifted, nil}
  defp profile(%Candidate.Hosted{}), do: {:hosted, :hosted, nil}

  # `Hosted` records its Sites per logical mutant in `HostedEmit`, never through `site/4`; the
  # clause exists so a stray call fails loudly rather than as a `FunctionClauseError`.
  defp build_site(:hosted, _id, c, _file, _flags),
    do:
      raise(ArgumentError, "#{inspect(c.__struct__)} records its Sites per mutant in HostedEmit")

  # A return constant carries no producer labels and records no AST forms.
  defp build_site(
         :return_value,
         id,
         %{report: %Report{edit: {:replace, original, mutated}, range: range}} = c,
         file,
         {render?, summary?}
       ),
       do:
         Site.return_value(id, file, range, original, mutated, c.mutator,
           render?: render?,
           summary?: summary?
         )

  # A lifted deletion is a whole function clause dropped, recorded under `clause_drop` with no
  # producing spec of its own.
  defp build_site(
         :lifted,
         id,
         %{report: %Report{edit: {:delete, clause}, range: range}},
         file,
         {render?, summary?}
       ),
       do: Site.clause_drop(id, file, range, clause, render?: render?, summary?: summary?)

  # `flags` is the `{render?, summary?}` pair, forwarded as the two render opts.
  defp build_site(site_kind, id, c, file, {render?, summary?}) do
    %Report{range: range} = report = c.report

    opts = [
      note: report.note,
      variant: report.variant,
      position: report.position,
      render?: render?,
      summary?: summary?
    ]

    case {site_kind, report.edit, report.classification} do
      {:in_place, {:delete, original}, :delete} ->
        Site.in_place_drop(id, file, range, original, c.mutator, opts)

      {:in_place, {:replace, original, mutated}, {:replace, classified, classified_as}} ->
        opts = Keyword.put(opts, :classified, {classified, classified_as})
        Site.in_place(id, file, range, original, mutated, c.mutator, opts)

      {:lifted, {:replace, original, mutated}, {:replace, classified, classified_as}} ->
        opts = Keyword.put(opts, :classified, {classified, classified_as})
        Site.lifted_replace(id, file, range, original, mutated, c.mutator, opts)
    end
  end

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

  defp assert_compatible_routes!(route, candidates) do
    allowed =
      if route in [:fn_clause, :receive_clause, :clause_guard],
        do: [route, :in_place],
        else: [route]

    case Enum.find(candidates, &(node_route!(&1) not in allowed)) do
      nil ->
        :ok

      candidate ->
        raise "candidate delivery route mismatch: expected #{inspect(route)}, " <>
                "got #{inspect(node_route!(candidate))} for #{inspect(candidate.__struct__)}"
    end
  end
end
