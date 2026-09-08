defmodule Mutare.Transform.ClauseVariants do
  @moduledoc false

  # Interleave one raw mutant arrow clause per id before the emitted original it replaces.
  # Shared by fn and receive delivery: neither changes the source head's argument/pattern
  # shape. Original clauses exclude only their own live ids, preserving source precedence.
  # This module handles only clauses; selector binding, coverage timing and the receive's
  # after block belong to the construct's emitter.
  # Each mutant body carries its original/replacement import witnesses, keeping any
  # hidden import conflict inside the clause range attributed to that mutant's id.

  alias Mutare.Transform.{Candidate, GuardBuild, ImportWitness}

  @spec interleave(
          [Macro.t()],
          [{pos_integer(), Candidate.FnClause.t() | Candidate.ReceiveClause.t()}],
          atom()
        ) :: [Macro.t()]
  def interleave(clauses, claimed, var) do
    by_clause = Enum.group_by(claimed, fn {_id, c} -> c.clause_index end)

    clauses
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
