defmodule Mutare.Transform.HostedEmit do
  @moduledoc false

  # Hosted DSL-fragment delivery for `Candidate.Hosted`: the hosting mutator supplies logical
  # fragment mutants plus `wrap`/`splice`; core claims ids, builds the selector, records Sites,
  # and asks the target to weave the selector into the macro node. Several hosts may target one
  # fragment; their mutants then share a selector where the scope allows it (`extend/4`, NOTES
  # "Hosts on one target share a selector"). Any ordinary whole-node candidates on that same
  # node are delivered afterwards through the callback supplied by `Mutare.Transform`, because
  # ordinary selector delivery owns the piped-value binding and pinned cases.

  alias Mutare.Mutator.Dispatch.Result
  alias Mutare.Site
  alias Mutare.Transform.{Candidate, Ctx, Meta, NodeRange, SelectorEmit}

  @type emit_inplace :: (Macro.t(), [Candidate.t()], Ctx.t() -> {Macro.t(), Ctx.t()})

  defmodule Woven do
    @moduledoc false

    # The selector core wove for one target, kept as the parts core assembled it from. A later
    # host on the same target extends these parts. Nothing is read back out of a `case` node, so
    # only clauses core built itself can ever be joined — never syntax a host produced that
    # happens to look like a selector.
    #
    #   * `read`, `subject` — the scrutinee and what it reads (`SelectorEmit.subject_read/1`);
    #   * `clauses` — the `<id> -> wrap(mutant)` clauses in id order, each under its own host's
    #     `wrap`;
    #   * `fallback` — what runs when none of them is active; the catch-all prepends the
    #     coverage record for `clauses`' ids to it.
    @type t :: %__MODULE__{
            read: Mutare.Transform.SelectorEmit.read(),
            subject: Macro.t(),
            clauses: [Macro.t(), ...],
            fallback: Macro.t()
          }

    @enforce_keys [:read, :subject, :clauses, :fallback]
    defstruct @enforce_keys
  end

  @doc """
  Weave hosted selectors into `node`, then deliver any leftover whole-node candidates.
  """
  @spec emit(Macro.t(), [Candidate.Hosted.t()], [Candidate.t()], Ctx.t(), emit_inplace()) ::
          {Macro.t(), Ctx.t()}
  def emit(node, hosted, inplace, ctx, emit_inplace) when is_function(emit_inplace, 3) do
    base = Meta.strip_delivery(node)

    {spliced, ctx, _woven} =
      Enum.reduce(hosted, {base, ctx, %{}}, fn candidate, {node, ctx, woven} ->
        key = target_key(candidate)
        {node, ctx, selector} = weave_target(node, candidate, Map.get(woven, key), ctx)
        woven = if selector, do: Map.put(woven, key, selector), else: woven
        {node, ctx, woven}
      end)

    emit_inplace.(spliced, inplace, ctx)
  end

  # Weave one host target's selector into `node`. Claim an id per logical mutant, build a
  # mutant clause `<id> -> wrap(mutant)` for each, combine them with whatever an earlier host
  # wove for this target (`prior`, see `extend/4`), and hand the assembled case to the
  # target's `splice`. Returns the target's selector parts, `nil` when no mutant was delivered
  # (the earlier host's selector, if any, stays where its splice put it).
  defp weave_target(node, %Candidate.Hosted{} = cand, prior, ctx) do
    # Each claimed item pairs the target with one of its `%Dispatch.Result{}` mutants. The result
    # already carries everything the Site needs: its `spec` is the recording family (the relayed
    # producer for a sub-contracted mutant, else the host itself), and its `variant` the label a
    # `variants/0`-declaring host may have tagged via `Mutation.tagged/2` (usually `nil` — a host
    # fragment has foreign semantics and no vocabulary), gated at the Site by `Dispatch.variant/4`.
    carriers = Enum.map(cand.mutants, &{cand, &1})

    {clauses, ctx} =
      SelectorEmit.claim_items(carriers, ctx, {&hosted_site/4, &hosted_line/1}, fn id,
                                                                                   {_cand, result} ->
        {:->, [], [[id], cand.wrap.(result.node)]}
      end)

    case clauses do
      [] ->
        {node, ctx, nil}

      _ ->
        {woven, ctx} = extend(prior, clauses, cand, ctx)
        {case_node, ctx} = selector(woven, ctx)
        {cand.splice.(node, case_node), ctx, woven}
    end
  end

  # The first host on a target: its selector runs the wrapped original when no mutant is active.
  defp extend(nil, clauses, cand, ctx) do
    {read, subject, ctx} = SelectorEmit.subject_read(ctx)
    fallback = cand.wrap.(cand.original)
    {%Woven{read: read, subject: subject, clauses: clauses, fallback: fallback}, ctx}
  end

  # A later host, over a selector that reads the scope's binding. Its own selector would switch
  # on that same immutable value, with nothing but the earlier coverage record between the two,
  # so its clauses join the earlier ones: one selector, one record covering every id, the first
  # host's wrapped original still the fallback. This host's splice then puts that selector where
  # the earlier splice put the narrower one. It is the same selector site, so the subject is
  # kept rather than read (and counted, `Scope.active_references`) a second time.
  defp extend(%Woven{read: :binding} = prior, clauses, _cand, ctx),
    do: {%{prior | clauses: prior.clauses ++ clauses}, ctx}

  # A later host, over a selector that makes its own `:persistent_term` read: this host's
  # selector makes another, so the two are not known to switch on one value. They stay nested —
  # the earlier selector is the later one's fallback, which keeps its ids executable once this
  # host's splice replaces it.
  defp extend(%Woven{read: :inline} = prior, clauses, _cand, ctx) do
    {fallback, ctx} = selector(prior, ctx)
    {read, subject, ctx} = SelectorEmit.subject_read(ctx)
    {%Woven{read: read, subject: subject, clauses: clauses, fallback: fallback}, ctx}
  end

  defp selector(%Woven{subject: subject, clauses: clauses, fallback: fallback}, ctx) do
    ids = SelectorEmit.ids_from_clauses(clauses)
    {catch_all, ctx} = SelectorEmit.catch_all_clause(ids, fallback, ctx)
    {SelectorEmit.raw_case_over(subject, clauses, catch_all), ctx}
  end

  # Hosts independently describe logical targets, so two modules targeting the same source
  # fragment carry separate splice closures, and a later splice replaces what an earlier one
  # put at that position. Key by the source fragment's own stable range plus logical original,
  # not by the Site/report range a host may customize, so the later host finds the earlier
  # selector (`extend/4`) instead of reverting to the raw original and erasing the earlier ids.
  defp target_key(%Candidate.Hosted{range: report_range, original: original}),
    do: {NodeRange.get(original) || report_range, original}

  # The `Mutare.Site` for one hosted mutant: an `:in_place` replacement showing the logical
  # fragment swap, not the `wrap`/`splice`/selector scaffolding. The result's optional note rides
  # onto the Site for the report, and its optional variant label onto the Site for
  # `# mutare:ignore` filtering (`nil` for the common untagged fragment); its `spec` is the
  # recording family. `flags` is the `{render?, summary?}` pair (the scan's diff-deferral flag +
  # the live-summary flag).
  # The line `hosted_site/4` records, for the count pass's `--line` test (see
  # `Mutare.Transform.Candidate.Delivery.line/1`): the hosted fragment's own report range, not
  # the selector scaffolding woven around it.
  defp hosted_line({%Candidate.Hosted{range: range}, _result}),
    do: if(range, do: range.start[:line])

  defp hosted_site(id, {cand, %Result{} = result}, file, {render?, summary?}),
    do:
      Site.in_place(id, file, cand.range, cand.original, result.node, result.spec,
        note: result.note,
        variant: result.variant,
        render?: render?,
        summary?: summary?
      )
end
