defmodule Mutare.Transform.FnClauseEmit do
  @moduledoc false

  # One fn, with each mutant clause immediately before the original it replaces.
  # Both guards read the enclosing function's already-bound selector, captured by the
  # closure without changing its arity. Original clauses exclude only their own live ids,
  # so a non-matching mutant falls through in source order. Mutant bodies are raw;
  # original bodies retain their emitted selectors and invocation-time body coverage,
  # except while a head mutant is active, when the fallen-through original runs its raw
  # body (`ClauseVariants`), as whole-fn delivery did.
  #
  # Head/guard coverage remains at creation, once for the complete live id set. No new
  # binding or function boundary is introduced: binding/0 and macros inspecting the caller
  # see the same scope. Where that selector is not already bound (defaults, scaffold,
  # nested modules), keep whole-fn selection so raw mutant bodies gain no new binding.
  # The fallback is constructed only for live mutants, from the shared raw source AST.
  # Whole-node and fallback clause branches share one selector: nesting would expose an
  # outer catch-all's binding to the raw mutant bodies.

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

  @spec emit(Macro.t(), [Delivery.node_candidate()], Ctx.t()) ::
          {Macro.t(), Ctx.t()}
  def emit(node, candidates, ctx) do
    # Preserve the original interleaving: whole-node offers, then clause mutations,
    # then any return/condition candidates an enclosing construct appended to this fn.
    {claimed, ctx} =
      SelectorEmit.claim_items(candidates, ctx, {&Delivery.site/4, &Delivery.line/1}, fn id, c ->
        {id, c}
      end)

    deliver(Meta.strip_delivery(node), claimed, ctx)
  end

  defp deliver(node, [], ctx), do: {node, ctx}

  # The clause-head candidates are delivered by rewriting the `fn`'s clause list in place — which
  # needs the hoisted active-id variable in scope; without it every candidate takes the
  # whole-node selector.
  defp deliver({:fn, _meta, _clauses} = node, claimed, %Ctx{} = ctx) do
    if Scope.active_var_bound?(ctx.scope),
      do: rewrite_heads(node, claimed, ctx),
      else: select(node, claimed, ctx)
  end

  defp deliver(node, claimed, ctx), do: select(node, claimed, ctx)

  defp rewrite_heads({:fn, meta, clauses} = node, claimed, ctx) do
    var = ctx.config.active_var

    {heads, whole} =
      Enum.split_with(claimed, fn {_id, c} -> match?(%Candidate.FnClause{}, c) end)

    {default, ctx} =
      case heads do
        [] ->
          {node, ctx}

        [{_, %Candidate.FnClause{raw_fn: {:fn, _, raw_clauses}}} | _] ->
          rewritten = ClauseVariants.interleave(clauses, raw_clauses, heads, var)
          ids = Enum.map(heads, &elem(&1, 0))
          record = Recorder.record_ast(ids, var, ctx.config.runtime_namespace)

          # The interleaved clauses' gates and the creation-time record read the enclosing
          # binding directly, not through a selector subject.
          {{:__block__, [], [record, {:fn, meta, rewritten}]}, SelectorEmit.reference_active(ctx)}
      end

    select(default, whole, ctx)
  end

  defp select(node, [], ctx), do: {node, ctx}

  defp select(node, claimed, ctx) do
    branches =
      Enum.map(claimed, fn {id, c} ->
        branch = selector_branch(c) |> ImportWitness.wrap(ImportWitness.for_candidate(c))
        {:->, [], [[id], branch]}
      end)

    SelectorEmit.selector_case(node, branches, ctx)
  end

  defp selector_branch(%Candidate.FnClause{} = c) do
    {:fn, meta, clauses} = c.raw_fn
    {:fn, meta, List.replace_at(clauses, c.clause_index, c.mutant_clause)}
  end

  defp selector_branch(c), do: Delivery.selector_branch(c)
end
