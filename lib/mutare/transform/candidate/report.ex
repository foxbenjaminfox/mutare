defmodule Mutare.Transform.Candidate.Report do
  @moduledoc false

  # The reporting description of an attached mutation, independent of its executable
  # replacement. The constructor checks an adapter's attribution once and falls back to
  # the offered edit if it cannot place it. Consumers never reconstruct a range.
  #
  # Classification is explicit: a written pipe stage is reported as written but classified
  # as the complete call the mutator saw. Deletions never ask a replacement classifier.
  alias Mutare.Mutator.Mutation
  alias Mutare.Mutator.Mutation.Attribution
  alias Mutare.Transform.{Diagnostics, NodeRange, WrittenPipe}

  @enforce_keys [:edit, :range, :position, :classification]
  defstruct @enforce_keys

  @type edit :: {:replace, Macro.t(), Macro.t()} | {:delete, Macro.t()}
  @type t :: %__MODULE__{
          edit: edit(),
          range: Sourceror.Range.t(),
          position: keyword(),
          classification: {:replace, Macro.t(), Macro.t()} | :delete
        }

  @spec new(Macro.t(), Macro.t(), Sourceror.Range.t(), Attribution.t() | nil, keyword()) :: t()
  def new(original, mutated, range, attribution \\ nil, opts \\ []) do
    true = valid_range?(range)
    stage? = Keyword.get(opts, :stage?, false)

    case checked_attribution(attribution, original, range) do
      nil ->
        replace(
          original,
          mutated,
          range,
          WrittenPipe.stage_position(original) || range.start,
          {original, mutated}
        )

      {%Attribution{operation: :replace} = at, checked} ->
        position =
          at.position || (stage? && WrittenPipe.stage_position(original)) || checked.start

        classified = if stage?, do: {original, mutated}, else: {at.original, at.mutated}
        replace(at.original, at.mutated, checked, position, classified)

      {%Attribution{operation: :delete} = at, checked} ->
        %__MODULE__{
          edit: {:delete, at.original},
          range: checked,
          position: at.position || checked.start,
          classification: :delete
        }
    end
  end

  defp replace(original, mutated, range, position, {classified, classified_as}) do
    %__MODULE__{
      edit: {:replace, original, mutated},
      range: range,
      position: position,
      classification: {:replace, classified, classified_as}
    }
  end

  # Collection relays a checked report through the public mutation boundary. A host may
  # enlarge its carrier, so attachment checks containment again in that new carrier.
  @spec attribution(t()) :: Attribution.t()
  def attribution(%__MODULE__{} = report) do
    at =
      case report.edit do
        {:replace, original, mutated} -> Mutation.at(original, mutated)
        {:delete, original} -> Mutation.at_drop(original)
      end

    %{at | range: report.range, position: report.position}
  end

  defp checked_attribution(nil, _original, _range), do: nil

  defp checked_attribution(%Attribution{} = at, original, range) do
    inner = at.range || safe_range(at.original)

    cond do
      not valid_range?(inner) ->
        warn(original, "its clause is not rangeable")
        nil

      pos(inner.start) < pos(range.start) or pos(inner.end) > pos(range.end) ->
        warn(original, "its clause escapes the mutated node's span")
        nil

      true ->
        {at, inner}
    end
  end

  # Sourceror can raise as well as return nil for synthetic, unlocated adapter ASTs.
  defp safe_range(node) do
    NodeRange.get(node)
  rescue
    _ -> nil
  end

  defp valid_range?(%{start: start, end: finish}) do
    valid_position?(start) and valid_position?(finish) and pos(start) <= pos(finish)
  end

  defp valid_range?(_), do: false

  defp valid_position?(position) when is_list(position) do
    is_integer(position[:line]) and position[:line] > 0 and
      is_integer(position[:column]) and position[:column] > 0
  end

  defp valid_position?(_), do: false
  defp pos(position), do: {position[:line], position[:column]}

  defp warn(original, why) do
    Diagnostics.warn(fn ->
      "ignoring a mutation :attribution because #{why}; the site will be reported at " <>
        "`#{Macro.to_string(original)}` instead. Point Mutation.at/2 (or at_drop/1) at a " <>
        "clause inside the returned node."
    end)
  end
end
