defmodule Mutare.Transform.Candidate.Delivery do
  @moduledoc false

  # The delivery table for candidate variants: which emit path consumes them, which
  # `Mutare.Site` constructor records them, and what value an ordinary selector branch
  # should run. `Mutare.Transform` still owns id threading and AST assembly; this module
  # owns the candidate-variant mapping so those axes cannot drift independently.

  alias Mutare.Site
  alias Mutare.Transform.Candidate

  @type route :: :in_place | :case_clause | :match_pattern | :macro_pattern | :lifted | :hosted
  @type routed :: :none | {route(), [Candidate.t()]}

  @doc "Classify a homogeneous candidate list by the emit route that should consume it."
  @spec classify([Candidate.t()]) :: routed()
  def classify([]), do: :none

  def classify([candidate | _] = candidates) do
    route = route_for(candidate)
    assert_homogeneous!(route, candidates)
    {route, candidates}
  end

  @doc "Build the recorded `Mutare.Site` for a claimed candidate id."
  @spec site(pos_integer(), Candidate.t(), String.t()) :: Site.t()
  def site(id, %Candidate.InPlace{} = candidate, file), do: plain_site(id, candidate, file)
  def site(id, %Candidate.CasePattern{} = candidate, file), do: plain_site(id, candidate, file)
  def site(id, %Candidate.CaseClause{} = candidate, file), do: plain_site(id, candidate, file)
  def site(id, %Candidate.MatchPattern{} = candidate, file), do: plain_site(id, candidate, file)
  def site(id, %Candidate.MacroPattern{} = candidate, file), do: plain_site(id, candidate, file)

  def site(id, %Candidate.Lifted{} = candidate, file), do: lifted_site(id, candidate, file)

  def site(id, %Candidate.PatternStructure{} = candidate, file),
    do: lifted_site(id, candidate, file)

  def site(id, %Candidate.GuardDrop{} = candidate, file), do: lifted_site(id, candidate, file)

  def site(id, %Candidate.Return{} = candidate, file),
    do:
      Site.return_value(
        id,
        file,
        candidate.range,
        candidate.original,
        candidate.mutated,
        candidate.mutator
      )

  def site(id, %Candidate.RescueDrop{} = candidate, file),
    do: Site.in_place_drop(id, file, candidate.range, candidate.dropped, candidate.mutator)

  def site(id, %Candidate.Drop{} = candidate, file),
    do: Site.clause_drop(id, file, candidate.range, candidate.original)

  @doc "The body expression for an ordinary in-place selector's mutant branch."
  @spec selector_branch(Candidate.t()) :: Macro.t()
  def selector_branch(%Candidate.InPlace{mutated: mutated}), do: mutated
  def selector_branch(%Candidate.Return{mutated: mutated}), do: mutated
  def selector_branch(%Candidate.CasePattern{replacement: replacement}), do: replacement
  def selector_branch(%Candidate.RescueDrop{replacement: replacement}), do: replacement

  defp plain_site(id, candidate, file) do
    Site.in_place(
      id,
      file,
      candidate.range,
      candidate.original,
      candidate.mutated,
      candidate.mutator,
      note(candidate)
    )
  end

  defp lifted_site(id, candidate, file) do
    Site.lifted_replace(
      id,
      file,
      candidate.range,
      candidate.original,
      candidate.mutated,
      candidate.mutator,
      note(candidate)
    )
  end

  # The optional per-mutant advisory a producing mutator attached. Read by field, not by
  # struct: any future note-bearing candidate is covered as soon as it carries the field.
  defp note(%{note: note}), do: note
  defp note(_candidate), do: nil

  defp route_for(%Candidate.InPlace{}), do: :in_place
  defp route_for(%Candidate.Return{}), do: :in_place
  defp route_for(%Candidate.CasePattern{}), do: :in_place
  defp route_for(%Candidate.RescueDrop{}), do: :in_place
  defp route_for(%Candidate.CaseClause{}), do: :case_clause
  defp route_for(%Candidate.MatchPattern{}), do: :match_pattern
  defp route_for(%Candidate.MacroPattern{}), do: :macro_pattern
  defp route_for(%Candidate.Lifted{}), do: :lifted
  defp route_for(%Candidate.PatternStructure{}), do: :lifted
  defp route_for(%Candidate.GuardDrop{}), do: :lifted
  defp route_for(%Candidate.Drop{}), do: :lifted
  defp route_for(%Candidate.Hosted{}), do: :hosted

  defp assert_homogeneous!(route, candidates) do
    case Enum.find(candidates, &(route_for(&1) != route)) do
      nil ->
        :ok

      candidate ->
        raise "candidate delivery route mismatch: expected #{inspect(route)}, " <>
                "got #{inspect(route_for(candidate))} for #{inspect(candidate.__struct__)}"
    end
  end
end
