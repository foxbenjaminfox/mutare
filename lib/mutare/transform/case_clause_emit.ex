defmodule Mutare.Transform.CaseClauseEmit do
  @moduledoc false

  # The clause builders for the **`case` tuple-the-scrutinee** rewrite — the per-clause delivery
  # of `Candidate.CaseClause` pattern/guard mutations. Pure: each builds one `->` clause from
  # plain data (an id, the candidate, the dispatch variable). `Mutare.Transform.emit_case_pattern_site/3`
  # owns the stateful orchestration (claiming ids via `Ctx`, choosing the subject) and calls
  # into here.
  #
  # The rewrite turns `case <subject> do …` into `case {<active>, <subject>} do …`, where each
  # mutant adds a clause `{<active>, <mut_pattern>} when <active> === <id> -> <raw_body>` before
  # its original `{<active>, <orig_pattern>} when <active> !== <its ids> -> <record>; <body>`, so
  # exactly one wins per `(id, value)` — the per-clause (C+M) analogue of head lifting.

  alias Mutare.Coverage.Recorder
  alias Mutare.Transform.{Candidate, GuardBuild}

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
  id-set (see `Mutare.Transform.emit_case_pattern_site/3`).
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
    raise_fun = {:., [], [{:__aliases__, [], [:"Elixir", :Kernel]}, :raise]}
    case_clause_error = {:__aliases__, [], [:"Elixir", :CaseClauseError]}
    raise_node = {raise_fun, [], [case_clause_error, [term: unmatched]]}
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
