defmodule Mutare.Transform.CaseClauseEmit do
  @moduledoc false

  # The **`case` tuple-the-scrutinee** rewrite — the per-clause delivery of
  # `Candidate.CaseClause` pattern/guard mutations. This module owns the orchestration
  # (claiming ids via `Ctx`, choosing the subject, preserving the all-poisoned fallback) and
  # the pure builders for each emitted `->` clause.
  #
  # The rewrite turns `case <subject> do …` into `case {<active>, <subject>} do …`, where each
  # mutant adds a clause `{<active>, <mut_pattern>} when <active> === <id> -> <raw_body>` before
  # its original `{<active>, <orig_pattern>} when <active> !== <its ids> -> <record>; <body>`, so
  # exactly one wins per `(id, value)` — the per-clause (C+M) analogue of head lifting.

  alias Mutare.AST
  alias Mutare.Coverage.Recorder
  alias Mutare.Transform.Candidate.Delivery
  alias Mutare.Transform.{Candidate, Ctx, GuardBuild, Meta, SelectorEmit}

  @doc """
  Rewrite a `case` with per-clause `Candidate.CaseClause`s by tupleing the scrutinee with
  the active mutant id.
  """
  @spec emit(Macro.t(), [Candidate.CaseClause.t()], Ctx.t()) :: {Macro.t(), Ctx.t()}
  def emit(node, candidates, ctx) do
    {:case, meta, [emitted_subject, [{do_key, emitted_clauses}]]} = Meta.strip_delivery(node)
    var = ctx.config.active_var

    {claimed, ctx} =
      SelectorEmit.claim_items(candidates, ctx, {&Delivery.site/4, &Delivery.line/1}, fn id,
                                                                                         candidate ->
        {id, candidate.clause_index, mutant_clause(id, candidate, var)}
      end)

    case claimed do
      [] ->
        {{:case, meta, [emitted_subject, [{do_key, emitted_clauses}]]}, ctx}

      _ ->
        all_ids = Enum.map(claimed, fn {id, _i, _c} -> id end)
        excluded = Enum.group_by(claimed, fn {_id, i, _c} -> i end, fn {id, _i, _c} -> id end)
        mutants = Enum.group_by(claimed, fn {_id, i, _c} -> i end, fn {_id, _i, c} -> c end)

        rewritten =
          emitted_clauses
          |> Enum.with_index()
          |> Enum.flat_map(fn {emitted_clause, index} ->
            original =
              original_clause(
                emitted_clause,
                Map.get(excluded, index, []),
                all_ids,
                var
              )

            Map.get(mutants, index, []) ++ [original]
          end)

        new_clauses =
          if exhaustive_clauses?(emitted_clauses, excluded),
            do: rewritten,
            else: rewritten ++ [unmatched_clause(all_ids, var)]

        subject = {SelectorEmit.subject(ctx), emitted_subject}
        {{:case, meta, [subject, [{do_key, new_clauses}]]}, ctx}
    end
  end

  @doc """
  One mutant clause: `{<active>, <mutant_pattern>} when <active> === <id> [and <mutant_guard>]
  -> <raw_body>`. The first tuple element binds the dispatch variable (used in the gate);
  `GuardBuild.and_into/2` ANDs the `=== <id>` gate into the clause's own (possibly `nil`) guard.
  """
  @spec mutant_clause(non_neg_integer(), Candidate.CaseClause.t(), atom()) :: Macro.t()
  def mutant_clause(id, %Candidate.CaseClause{} = c, var) do
    tuple = {Recorder.catch_all_pattern(var), c.mutant_pattern}
    head = {:when, [], [tuple, GuardBuild.and_into(GuardBuild.gate(id, var), c.mutant_guard)]}
    {:->, [], [[head], c.raw_body]}
  end

  @doc """
  One original clause: `{<active>, <orig_pattern>} when <active> !== <its ids> [and <orig_guard>]
  -> <record all ids>; <emitted_body>`. With no exclusions and no source guard the head is the
  bare tuple (the dispatch variable still used by the record). The record prepends the *full*
  id-set (see `emit/3`).
  """
  @spec original_clause(Macro.t(), [non_neg_integer()], [non_neg_integer()], atom()) :: Macro.t()
  def original_clause(emitted_clause, excluded_ids, all_ids, var) do
    {clause_meta, pattern, orig_guard, body} = emitted_clause_parts(emitted_clause)
    tuple = {Recorder.catch_all_pattern(var), pattern}
    guard = GuardBuild.merge(GuardBuild.exclusion(excluded_ids, var), orig_guard)
    head = if guard, do: {:when, [], [tuple, guard]}, else: tuple
    record_body = {:__block__, [], [Recorder.record_ast(all_ids, var), body]}
    {:->, clause_meta, [[head], record_body]}
  end

  @doc """
  The trailing unmatched fallback for a non-exhaustive tupled `case`: `{<active>,
  mutare_unmatched} -> <record all ids>; Elixir.Kernel.raise(Elixir.CaseClauseError, term:
  mutare_unmatched)`. The first tuple element binds the dispatch variable (used by the record)
  and `mutare_unmatched` binds the *bare* subject (used by the raise), so neither warns unused;
  it both attributes the hosted ids at baseline (else a value that matches no original clause
  falls through recording nothing, scoring a re-targeting mutant `:no_coverage`) and re-raises
  the same `CaseClauseError` the original `case` did, on the original term. `Elixir.Kernel.raise`
  and `Elixir.CaseClauseError` are both absolute so the raise is independent of the target's
  imports/aliases; `mutare_unmatched` is a case-clause-local pattern var, so a fixed name can't
  capture or collide.
  """
  @spec unmatched_clause([non_neg_integer()], atom()) :: Macro.t()
  def unmatched_clause(all_ids, var) do
    unmatched = {:mutare_unmatched, [], nil}
    tuple = {Recorder.catch_all_pattern(var), unmatched}

    raise_node =
      AST.absolute_call([:Kernel], :raise, [
        AST.absolute_alias([:CaseClauseError]),
        [term: unmatched]
      ])

    body = {:__block__, [], [Recorder.record_ast(all_ids, var), raise_node]}
    {:->, [], [[tuple], body]}
  end

  @doc """
  Whether the rewritten clause list already matches every subject — an original clause is an
  unconditional catch-all (an irrefutable pattern, no source guard) that the rewrite leaves
  ungated (no mutant excludes it). When so the subject can never fall through, so the unmatched
  fallback would be an unreachable clause (Elixir warns "cannot match"); otherwise the subject
  may fall through and the fallback is needed.
  """
  @spec exhaustive_clauses?([Macro.t()], %{optional(non_neg_integer()) => [non_neg_integer()]}) ::
          boolean()
  def exhaustive_clauses?(emitted_clauses, excluded) do
    emitted_clauses
    |> Enum.with_index()
    |> Enum.any?(fn {clause, index} ->
      {_meta, pattern, guard, _body} = emitted_clause_parts(clause)
      irrefutable_pattern?(pattern) and is_nil(guard) and Map.get(excluded, index, []) == []
    end)
  end

  # A pattern that matches any value: `_`, `_name`, or a plain variable — the only nodes shaped
  # `{atom_name, _meta, atom_context}`. Anything structured (a literal `{:__block__, _, […]}`, a
  # tuple/map/struct, a pin, a call) carries a *list* in that slot, so is refutable — *except* a
  # **match chain** `a = b = … = z` (`{:=, _, [lhs, rhs]}`, possibly nested), which is irrefutable
  # exactly when every operand is: `x = _ = y` binds three names and matches anything, but `x = {1,
  # 2}` (refutable rhs) or `^x = y` (a pin) is not. The `:=` node carries a *list* in its third
  # slot, so it falls past the variable clause to the recursive one.
  defp irrefutable_pattern?({name, _meta, ctx}) when is_atom(name) and is_atom(ctx), do: true

  defp irrefutable_pattern?({:=, _meta, [lhs, rhs]}),
    do: irrefutable_pattern?(lhs) and irrefutable_pattern?(rhs)

  defp irrefutable_pattern?(_), do: false

  # Deconstruct an (already-emitted) `case` clause into `{meta, pattern, guard | nil, body}`.
  # A `case` clause has a single pattern; its guard (if any) is the last `when` arg (patterns
  # aren't mutated in place and guards are pruned by the analyzer, so both are the originals).
  defp emitted_clause_parts({:->, meta, [[{:when, _wm, when_args}], body]})
       when length(when_args) >= 2 do
    {patterns, [guard]} = Enum.split(when_args, -1)
    {meta, hd(patterns), guard, body}
  end

  defp emitted_clause_parts({:->, meta, [[pattern], body]}), do: {meta, pattern, nil, body}
end
