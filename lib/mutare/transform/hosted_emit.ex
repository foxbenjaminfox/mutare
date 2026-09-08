defmodule Mutare.Transform.HostedEmit do
  @moduledoc false

  # Hosted DSL-fragment delivery for `Candidate.Hosted`: the hosting mutator supplies logical
  # fragment mutants plus `wrap`/`splice`; core claims ids, builds the selector, records Sites,
  # and asks the target to weave the selector into the macro node. Any ordinary whole-node
  # candidates on that same node are delivered afterwards through the callback supplied by
  # `Mutare.Transform`, because ordinary selector delivery owns pipe hoisting and pinned cases.

  alias Mutare.Site
  alias Mutare.Transform.{Candidate, Ctx, Meta, NodeRange, SelectorEmit}

  @type emit_inplace :: (Macro.t(), [Candidate.t()], Ctx.t() -> {Macro.t(), Ctx.t()})

  @doc """
  Weave hosted selectors into `node`, then deliver any leftover whole-node candidates.
  """
  @spec emit(Macro.t(), [Candidate.Hosted.t()], [Candidate.t()], Ctx.t(), emit_inplace()) ::
          {Macro.t(), Ctx.t()}
  def emit(node, hosted, inplace, ctx, emit_inplace) when is_function(emit_inplace, 3) do
    base = Meta.strip_delivery(node)

    {spliced, ctx, _selectors} =
      Enum.reduce(hosted, {base, ctx, %{}}, fn candidate, {node, ctx, selectors} ->
        key = target_key(candidate)
        fallback = Map.get_lazy(selectors, key, fn -> candidate.wrap.(candidate.original) end)
        {node, ctx, selector} = weave_target(node, candidate, fallback, ctx)
        selectors = if selector, do: Map.put(selectors, key, selector), else: selectors
        {node, ctx, selectors}
      end)

    emit_inplace.(spliced, inplace, ctx)
  end

  # Weave one host target's selector into `node`. Claim an id per logical mutant, build a
  # mutant clause `<id> -> wrap(mutant)` for each, then a coverage catch-all running
  # `wrap(original)`, and hand the assembled case to the target's `splice`.
  defp weave_target(node, %Candidate.Hosted{} = cand, fallback, ctx) do
    # A host fragment usually carries no variant tag (foreign semantics, no vocabulary). But a
    # hosting mutator that declares `variants/0` *may* tag a `host/2` mutant via `Mutation.tagged/2`
    # — `Mutare.Mutator.Dispatch.normalize_target/1` preserves it as the third tuple element — so
    # carry it onto the carrier and through to the Site, where `Dispatch.variant/4` gates it on
    # `opted_in?/1` (an untagged or non-opted-in fragment still records `variant: []`).
    #
    # `producer` (the fourth element) is the sub-contract attribution: a mutant the host relayed
    # from a core family (`Mutare.Analyze.expression_mutations/3` inside `host/2`) carries that
    # family's spec, so its Site — and the vocabulary its variant gates against — belongs to the
    # producer, not the host. `nil` (every host-authored mutant) keeps the host's own spec.
    carriers =
      Enum.map(cand.mutants, fn {mutated, note, variant, producer} ->
        %{
          candidate: cand,
          mutated: mutated,
          note: note,
          variant: variant,
          mutator: producer || cand.mutator
        }
      end)

    {clauses, ctx} =
      SelectorEmit.claim_items(carriers, ctx, {&hosted_site/4, &hosted_line/1}, fn id, carrier ->
        {:->, [], [[id], cand.wrap.(carrier.mutated)]}
      end)

    case clauses do
      [] ->
        {node, ctx, nil}

      _ ->
        ids = SelectorEmit.ids_from_clauses(clauses)

        catch_all =
          SelectorEmit.catch_all_clause(
            ids,
            fallback,
            ctx.config.active_var,
            ctx.config.runtime_namespace
          )

        case_node = SelectorEmit.raw_case(clauses, catch_all, ctx)
        {cand.splice.(node, case_node), ctx, case_node}
    end
  end

  # Hosts independently describe logical targets, so two modules targeting the same source
  # fragment carry separate splice closures. Key by the source fragment's own stable range plus
  # logical original, not by the Site/report range a host may customize; when a later splice
  # replaces that position, its catch-all runs the selector already woven by the earlier host
  # instead of reverting to the raw original and erasing the earlier ids.
  defp target_key(%Candidate.Hosted{range: report_range, original: original}),
    do: {NodeRange.get(original) || report_range, original}

  # The `Mutare.Site` for one hosted mutant: an `:in_place` replacement showing the logical
  # fragment swap, not the `wrap`/`splice`/selector scaffolding. The optional note rides onto
  # the Site for the report, and the optional variant label onto the Site for `# mutare:ignore`
  # filtering (`nil` for the common untagged fragment). The carrier's `mutator` is the recording
  # spec — the relayed mutant's producer, or the hosting mutator itself. `flags` is the
  # `{render?, summary?}` pair (the scan's diff-deferral flag + the live-summary flag).
  # The line `hosted_site/4` records, for the count pass's `--line` test (see
  # `Mutare.Transform.Candidate.Delivery.line/1`): the hosted fragment's own report range, not
  # the selector scaffolding woven around it.
  defp hosted_line(%{candidate: %Candidate.Hosted{range: range}}),
    do: if(range, do: range.start[:line])

  defp hosted_site(
         id,
         %{candidate: cand, mutated: mutated, note: note, variant: variant, mutator: mutator},
         file,
         {render?, summary?}
       ),
       do:
         Site.in_place(id, file, cand.range, cand.original, mutated, mutator,
           note: note,
           variant: variant,
           render?: render?,
           summary?: summary?
         )
end
