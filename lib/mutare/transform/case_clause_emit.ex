defmodule Mutare.Transform.CaseClauseEmit do
  @moduledoc false

  # The **`case` tuple-the-scrutinee** rewrite — the per-clause delivery of
  # `Candidate.CaseClause` pattern/guard mutations. This module owns the orchestration
  # (claiming ids via `Ctx`, choosing the subject, preserving the all-poisoned fallback) and
  # the pure builders for each emitted `->` clause.
  #
  # The rewrite turns `case <subject> do …` into `case {<active>, <subject>} do …`, where each
  # mutant adds a clause `{<active>, <mut_pattern>} when <active> === <id> -> <raw_body>` before
  # its original `{<active>, <orig_pattern>} when <active> excludes <its ids> -> <body>`, so
  # exactly one wins per `(id, value)` — the per-clause (C+M) analogue of head lifting. The
  # subject is evaluated once before one shared coverage record: duplicating the full hosted
  # id list into every original clause would reintroduce C×M generated payload.

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
                var
              )

            Map.get(mutants, index, []) ++ [original]
          end)

        new_clauses =
          if exhaustive_clauses?(emitted_clauses, excluded),
            do: rewritten,
            else: rewritten ++ [unmatched_clause()]

        active = Recorder.catch_all_pattern(var)
        subject_var = {ctx.config.case_var, [], nil}
        tuple = {active, subject_var}

        # Evaluate both inputs before entering this generated-only clause. Bindings in the
        # source scrutinee therefore escape just as they did before, while the temporary is
        # invisible to source clause bodies, subsequent binding/0, and macros inspecting
        # __CALLER__. The tuple preserves selector-before-scrutinee evaluation in every scope.
        record_body = {:__block__, [], [Recorder.record_ast(all_ids, var), tuple]}
        record_clause = {:->, [], [[tuple], record_body]}

        subject =
          {:case, [], [{SelectorEmit.subject(ctx), emitted_subject}, [do: [record_clause]]]}

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
  One original clause: `{<active>, <orig_pattern>} when <active> excludes <its ids>
  [and <orig_guard>] -> <emitted_body>`. With no exclusions the tuple ignores its first
  element: neither the original guard nor body needs this clause-local dispatch binding.
  """
  @spec original_clause(Macro.t(), [non_neg_integer()], atom()) :: Macro.t()
  def original_clause(emitted_clause, excluded_ids, var) do
    {clause_meta, pattern, orig_guard, body} = emitted_clause_parts(emitted_clause)

    active_pattern =
      if excluded_ids == [], do: {:_, [], nil}, else: Recorder.catch_all_pattern(var)

    tuple = {active_pattern, pattern}
    guard = GuardBuild.merge(GuardBuild.exclusion(excluded_ids, var), orig_guard)
    head = if guard, do: {:when, [], [tuple, guard]}, else: tuple
    {:->, clause_meta, [[head], body]}
  end

  @doc """
  The trailing unmatched fallback for a non-exhaustive tupled `case`: `{_, mutare_unmatched}`
  re-raises the same `CaseClauseError` the original `case` did, on the original term. Coverage
  has already recorded the hosted ids, even when no original clause matches. `Elixir.Kernel.raise`
  and `Elixir.CaseClauseError` are both absolute so the raise is independent of the target's
  imports/aliases; `mutare_unmatched` is a case-clause-local pattern var, so a fixed name can't
  capture or collide.
  """
  @spec unmatched_clause() :: Macro.t()
  def unmatched_clause do
    unmatched = {:mutare_unmatched, [], nil}
    tuple = {{:_, [], nil}, unmatched}

    raise_node =
      AST.absolute_call([:Kernel], :raise, [
        AST.absolute_alias([:CaseClauseError]),
        [term: unmatched]
      ])

    {:->, [], [[tuple], raise_node]}
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
