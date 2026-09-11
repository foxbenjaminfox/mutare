defmodule Mutare.Transform.ReceiveClauseEmit do
  @moduledoc false

  # One native receive, with the same message order and a single after block. Each
  # message is tested against interleaved mutant/original clauses in source order;
  # no generated catch-all consumes unmatched messages and nothing requeues them.
  #
  # The already-bound selector stays fixed throughout the wait. Record all live head/
  # guard ids once on entry, before evaluating the timeout, even if the receive times
  # out or its timeout expression raises. Body/after coverage stays in the reached body.
  # Mutant clauses carry raw bodies. Originals and the after block retain their emitted
  # bodies, whose other ids cannot activate while a head mutant is selected — but while
  # one *is* selected, the original a message falls through to and the after block run
  # their raw bodies (`ClauseVariants`), as whole-receive delivery did.
  #
  # With no existing selector binding, retain whole-receive selection. Introducing a
  # binding in those scopes would change the environment visible to raw-body macros.
  # Fallback copies are rebuilt only for live mutants from the shared normalized AST.
  # Whole-node and fallback clause branches share one selector so an outer catch-all
  # cannot introduce a binding into the raw mutant bodies.

  alias Mutare.AST
  alias Mutare.Coverage.Recorder

  alias Mutare.Transform.{
    Candidate,
    ClauseVariants,
    Ctx,
    ImportWitness,
    Meta,
    Scope,
    SelectorEmit
  }

  alias Mutare.Transform.Candidate.Delivery

  @spec emit(Macro.t(), [Delivery.node_candidate()], Ctx.t()) :: {Macro.t(), Ctx.t()}
  def emit(node, candidates, ctx) do
    # Claim in discovery order, including whole-node custom offers and any enclosing
    # condition/return candidates. Split only after reserving the original ids.
    {claimed, ctx} =
      SelectorEmit.claim_items(candidates, ctx, {&Delivery.site/4, &Delivery.line/1}, fn id, c ->
        {id, c}
      end)

    {deliver(Meta.strip_delivery(node), claimed, ctx), ctx}
  end

  defp deliver(node, [], _ctx), do: node

  # The clause-head candidates are delivered by rewriting the `receive`'s clause lists in place —
  # which needs the hoisted active-id variable in scope; without it every candidate takes the
  # whole-node selector.
  defp deliver(node, claimed, %Ctx{} = ctx) do
    if Scope.active_var_bound?(ctx.scope),
      do: rewrite_heads(node, claimed, ctx),
      else: select(node, claimed, ctx)
  end

  defp rewrite_heads(node, claimed, ctx) do
    var = ctx.config.active_var

    {heads, whole} =
      Enum.split_with(claimed, fn {_id, c} -> match?(%Candidate.ReceiveClause{}, c) end)

    default =
      case heads do
        [] ->
          node

        [{_, %Candidate.ReceiveClause{raw_receive: {:receive, _, [raw_blocks]}}} | _] ->
          ids = Enum.map(heads, &elem(&1, 0))

          rewritten =
            map_blocks(node, fn
              :do, clauses ->
                ClauseVariants.interleave(clauses, block(raw_blocks, :do), heads, var)

              :after, clauses ->
                ClauseVariants.share_bodies(clauses, block(raw_blocks, :after), ids, var)
            end)

          {:__block__, [],
           [Recorder.record_ast(ids, var, ctx.config.runtime_namespace), rewritten]}
      end

    select(default, whole, ctx)
  end

  defp select(node, [], _ctx), do: node

  defp select(node, claimed, ctx) do
    branches =
      Enum.map(claimed, fn {id, c} ->
        branch = selector_branch(c) |> ImportWitness.wrap(ImportWitness.for_candidate(c))
        {:->, [], [[id], branch]}
      end)

    SelectorEmit.selector_case(node, branches, ctx)
  end

  defp selector_branch(%Candidate.ReceiveClause{} = c),
    do: map_message_clauses(c.raw_receive, &List.replace_at(&1, c.clause_index, c.mutant_clause))

  defp selector_branch(c), do: Delivery.selector_branch(c)

  # The analyzer normalized keyword-form clause lists before emission. Only `do` is
  # rewritten; the timeout expression and after body remain at their original position.
  defp map_message_clauses(node, fun) do
    map_blocks(node, fn
      :do, clauses -> fun.(clauses)
      _key, value -> value
    end)
  end

  # Rewrite each block's clause list by its key atom, keeping block order and position.
  defp map_blocks({:receive, meta, [blocks]}, fun) do
    blocks = Enum.map(blocks, fn {key, value} -> {key, fun.(AST.key_atom(key), value)} end)
    {:receive, meta, [blocks]}
  end

  defp block(blocks, name) do
    Enum.find_value(blocks, [], fn {key, value} ->
      if AST.key_atom(key) == name, do: value
    end)
  end
end
