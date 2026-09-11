defmodule Mutare.Transform.HostedEmit do
  @moduledoc false

  # Hosted DSL-fragment delivery for `Candidate.Hosted`: the hosting mutator supplies logical
  # fragment mutants plus `wrap`/`splice`; core claims ids, builds the selector, records Sites,
  # and asks the target to weave the selector into the macro node. Any ordinary whole-node
  # candidates on that same node are delivered afterwards through the callback supplied by
  # `Mutare.Transform`, because ordinary selector delivery owns pipe hoisting and pinned cases.

  alias Mutare.Mutator.Dispatch.Result
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
        ids = SelectorEmit.ids_from_clauses(clauses)

        catch_all =
          SelectorEmit.catch_all_clause(
            ids,
            fallback,
            ctx.config.active_var,
            ctx.config.runtime_namespace
          )

        {case_node, ctx} = SelectorEmit.raw_case(clauses, catch_all, ctx)
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
