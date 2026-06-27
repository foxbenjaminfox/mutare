defmodule Mutare.Transform.Candidate.Delivery do
  @moduledoc false

  # Shared delivery vocabulary for candidate variants: which `Mutare.Site` constructor
  # records them, what value an ordinary selector branch should run, and which node-local
  # emit path consumes candidates attached to AST metadata. Lifted candidates are consumed
  # from `FunctionPlan`; hosted candidates are consumed from their own metadata by
  # `HostedEmit`, so neither belongs to the node-local classifier.

  alias Mutare.Site
  alias Mutare.Transform.Candidate

  @type node_candidate ::
          Candidate.InPlace.t()
          | Candidate.Return.t()
          | Candidate.CasePattern.t()
          | Candidate.RescueDrop.t()
          | Candidate.CaseClause.t()
          | Candidate.MatchPattern.t()
          | Candidate.MacroPattern.t()
  @type node_route :: :in_place | :case_clause | :match_pattern | :macro_pattern
  @type routed_node_candidates :: :none | {node_route(), [node_candidate()]}

  @doc "Classify homogeneous AST-node candidates by their node-local emit route."
  @spec classify_node_candidates([node_candidate()]) :: routed_node_candidates()
  def classify_node_candidates([]), do: :none

  def classify_node_candidates([candidate | _] = candidates) do
    route = node_route_for(candidate)
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

  defp node_route_for(%Candidate.InPlace{}), do: :in_place
  defp node_route_for(%Candidate.Return{}), do: :in_place
  defp node_route_for(%Candidate.CasePattern{}), do: :in_place
  defp node_route_for(%Candidate.RescueDrop{}), do: :in_place
  defp node_route_for(%Candidate.CaseClause{}), do: :case_clause
  defp node_route_for(%Candidate.MatchPattern{}), do: :match_pattern
  defp node_route_for(%Candidate.MacroPattern{}), do: :macro_pattern

  defp node_route_for(candidate) do
    raise ArgumentError,
          "#{inspect(candidate.__struct__)} is not a node-local candidate; " <>
            "lifted and hosted candidates use their dedicated emit paths"
  end

  defp assert_homogeneous!(route, candidates) do
    case Enum.find(candidates, &(node_route_for(&1) != route)) do
      nil ->
        :ok

      candidate ->
        raise "candidate delivery route mismatch: expected #{inspect(route)}, " <>
                "got #{inspect(node_route_for(candidate))} for #{inspect(candidate.__struct__)}"
    end
  end
end
