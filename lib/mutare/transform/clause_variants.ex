defmodule Mutare.Transform.ClauseVariants do
  @moduledoc false

  # Interleave one raw mutant arrow clause per id before the emitted original it replaces.
  # Shared by fn and receive delivery: neither changes the source head's argument/pattern
  # shape. Original clauses exclude only their own live ids, preserving source precedence.
  # This module handles only clauses; selector binding, coverage timing and the receive's
  # after block belong to the construct's emitter.
  # Each mutant body carries its original/replacement import witnesses, keeping any
  # hidden import conflict inside the clause range attributed to that mutant's id.
  #
  # A head mutant that does not match falls through to a later original clause, so that
  # clause's body still runs while the mutant is active. The emitted body may differ from
  # the source: a mutated pipe stage is hoisted into a closure whose parameter macros in
  # the stage observe through `Macro.Env.vars/1`. Whole-construct delivery ran the raw
  # source there; keep that. Where the raw and emitted bodies differ, the original clause
  # body selects between them on the already-bound active variable — the emitted body for
  # everything but the live head ids, the raw body for them — adding no binding to either
  # (the `RescueEmit` raw/instrumented split). Equal bodies are shared directly.

  alias Mutare.Coverage.Recorder
  alias Mutare.Transform.{Candidate, GuardBuild, ImportWitness, Render}

  @type claimed :: [{pos_integer(), Candidate.FnClause.t() | Candidate.ReceiveClause.t()}]

  @spec interleave([Macro.t()], [Macro.t()], claimed(), atom()) :: [Macro.t()]
  def interleave(clauses, raw_clauses, claimed, var) do
    by_clause = Enum.group_by(claimed, fn {_id, c} -> c.clause_index end)
    live = Enum.map(claimed, &elem(&1, 0))

    clauses
    |> share_bodies(raw_clauses, live, var)
    |> Enum.with_index()
    |> Enum.flat_map(fn {clause, index} ->
      variants = Map.get(by_clause, index, [])
      ids = Enum.map(variants, &elem(&1, 0))

      mutants =
        Enum.map(variants, fn {id, c} ->
          {:->, meta, [head, body]} = guard_clause(c.mutant_clause, GuardBuild.gate(id, var))
          body = ImportWitness.wrap(body, ImportWitness.for_candidate(c))
          {:->, meta, [head, body]}
        end)

      mutants ++ [guard_clause(clause, GuardBuild.exclusion(ids, var))]
    end)
  end

  @doc """
  Pair each emitted arrow clause with its raw source twin and, where their bodies differ,
  run the raw body whenever one of `live` is the active mutant. Heads are untouched.
  """
  @spec share_bodies([Macro.t()], [Macro.t()], [pos_integer()], atom()) :: [Macro.t()]
  def share_bodies(clauses, raw_clauses, live, var) do
    exclusion = GuardBuild.exclusion(live, var)

    Enum.zip_with(clauses, raw_clauses, fn {:->, meta, [head, emitted]}, {:->, _, [_, raw]} ->
      {:->, meta, [head, share_body(emitted, raw, exclusion, var)]}
    end)
  end

  defp share_body(body, body, _exclusion, _var), do: body
  defp share_body(emitted, _raw, nil, _var), do: emitted

  defp share_body(emitted, raw, exclusion, var) do
    original = {:->, [], [[{:when, [], [{:_, [], nil}, exclusion]}], emitted]}
    mutant = {:->, [], [[{:_, [], nil}], raw]}
    Render.selector_case(Recorder.catch_all_pattern(var), [original, mutant])
  end

  # Every pattern precedes one trailing guard in a guarded arrow head. GuardBuild
  # distributes the activation/exclusion gate across alternative `when` guards.
  defp guard_clause(clause, nil), do: clause

  defp guard_clause({:->, meta, [[{:when, wm, args}], body]}, gate) do
    {patterns, [guard]} = Enum.split(args, -1)
    head = {:when, wm, patterns ++ [GuardBuild.and_into(gate, guard)]}
    {:->, meta, [[head], body]}
  end

  defp guard_clause({:->, meta, [patterns, body]}, gate),
    do: {:->, meta, [[{:when, [], patterns ++ [gate]}], body]}
end
