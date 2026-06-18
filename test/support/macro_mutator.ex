defmodule Mutare.Test.QueryDSL do
  @moduledoc """
  A tiny fake query DSL used in tests: a `query/1` macro whose keyword argument is
  an opaque DSL body (the analog of `Ecto.Query.from`). It is a real, loadable
  macro so a whole `import Mutare.Test.QueryDSL` resolves by reflection, exercising
  the bare-call known-macro path end to end.
  """

  @doc "Expand to the clause list verbatim — enough that a metamutant using it compiles."
  defmacro query(clauses) do
    quote do: unquote(clauses)
  end

  @doc """
  A pipeable stage (`query |> where(condition)`) — the query-builder shape, where the
  piped value is the first effective argument and the condition is an opaque DSL body.
  """
  defmacro where(query, _condition) do
    quote do: unquote(query)
  end
end

defmodule Mutare.Test.QueryMutator do
  @moduledoc """
  A reference **macro-aware** custom mutator, used in tests to exercise the
  `c:Mutare.Mutator.macros/0` extension point and the `:skip` argument treatment.

  It registers `Mutare.Test.QueryDSL.query/1` as a known macro whose argument is
  `:skip`ped — so Mutare core never mutates the DSL body — and mutates the query
  itself with DSL knowledge: dropping the last clause (the analog of removing a
  `where`). One module carries both the registration and the mutation, so a project
  enables it with a single `:mutators` entry and core stays DSL-agnostic.
  """
  @behaviour Mutare.Mutator

  @impl Mutare.Mutator
  def name, do: :query_dsl

  @impl Mutare.Mutator
  def macros, do: [{Mutare.Test.QueryDSL, :query, 1, :skip}]

  @impl Mutare.Mutator
  # A `query([clause, clause, ...])` with more than one clause — drop the last one.
  # Reuses the surviving clause AST, so the mutant is compile-safe.
  def mutate({:query, meta, [clauses]}) when is_list(clauses) and length(clauses) > 1 do
    {_dropped, kept} = List.pop_at(clauses, -1)
    [{:query, meta, [kept]}]
  end

  def mutate(_node), do: :skip
end
