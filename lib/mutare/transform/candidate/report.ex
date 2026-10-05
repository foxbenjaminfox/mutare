defmodule Mutare.Transform.Candidate.Report do
  @moduledoc false

  # The reporting description every candidate carries, built once where the candidate is
  # constructed and independent of how the candidate executes: the textual edit, the source
  # range it patches, the position its Site is keyed at, the pair its variant label is
  # classified from, and the producer's optional note and production-time variant tag.
  # `Candidate.Delivery.site/4` reads the mutation from here alone, so a candidate's struct
  # holds only what its delivery executes. Consumers never reconstruct a range.
  #
  # Two ways in. `replace/4` and `delete/3` describe an edit the constructing walk located
  # itself — a tagged guard operator, a clause pattern, a dropped clause: it is reported where
  # its range starts and classified as written. `new/5` describes a mutator's result: it checks
  # an adapter's attribution once and falls back to the offered edit if it cannot place it, and
  # a written pipe stage is reported as written but classified as the complete call the mutator
  # saw. Deletions never ask a replacement classifier.
  alias Mutare.Mutator.Mutation
  alias Mutare.Mutator.Mutation.Attribution
  alias Mutare.Transform.{Diagnostics, NodeRange, WrittenPipe}

  @enforce_keys [:edit, :range, :position, :classification]
  defstruct @enforce_keys ++ [note: nil, variant: nil]

  @type edit :: {:replace, Macro.t(), Macro.t()} | {:delete, Macro.t()}
  @type t :: %__MODULE__{
          edit: edit(),
          range: Sourceror.Range.t(),
          position: keyword(),
          classification: {:replace, Macro.t(), Macro.t()} | :delete,
          note: String.t() | nil,
          variant: Mutation.variant()
        }

  @typedoc "The producer's `:note` and production-time `:variant` tag, both optional."
  @type labels :: [note: String.t() | nil, variant: Mutation.variant()]

  @doc "An edit replacing `original` (spanning `range`) with `mutated`, reported where it starts."
  @spec replace(Macro.t(), Macro.t(), Sourceror.Range.t(), labels()) :: t()
  def replace(original, mutated, range, labels \\ []) do
    true = valid_range?(range)
    replace(original, mutated, range, range.start, {original, mutated}, labels)
  end

  @doc "An edit deleting `original` (spanning `range`), reported where it starts."
  @spec delete(Macro.t(), Sourceror.Range.t(), labels()) :: t()
  def delete(original, range, labels \\ []) do
    true = valid_range?(range)
    delete(original, range, range.start, labels)
  end

  @doc """
  A mutator's replacement of the offered `original` (spanning `range`) with `mutated`,
  reported at its `attribution` when that is placeable inside `range`. `opts` carries the
  `t:labels/0` and `:stage?`, set when the attribution is the written pipe stage core
  derived rather than one the mutator supplied.
  """
  @spec new(Macro.t(), Macro.t(), Sourceror.Range.t(), Attribution.t() | nil, keyword()) :: t()
  def new(original, mutated, range, attribution \\ nil, opts \\ []) do
    true = valid_range?(range)
    {stage?, labels} = Keyword.pop(opts, :stage?, false)

    case checked_attribution(attribution, original, range) do
      nil ->
        replace(
          original,
          mutated,
          range,
          WrittenPipe.stage_position(original) || range.start,
          {original, mutated},
          labels
        )

      {%Attribution{operation: :replace} = at, checked} ->
        position =
          at.position || (stage? && WrittenPipe.stage_position(original)) || checked.start

        classified = if stage?, do: {original, mutated}, else: {at.original, at.mutated}
        replace(at.original, at.mutated, checked, position, classified, labels)

      {%Attribution{operation: :delete} = at, checked} ->
        delete(at.original, checked, at.position || checked.start, labels)
    end
  end

  @doc "The source nodes the edit names: the original and its replacement, or the deleted node."
  @spec nodes(t()) :: [Macro.t()]
  def nodes(%__MODULE__{edit: {:replace, original, mutated}}), do: [original, mutated]
  def nodes(%__MODULE__{edit: {:delete, original}}), do: [original]

  defp replace(original, mutated, range, position, {classified, classified_as}, labels) do
    %__MODULE__{
      edit: {:replace, original, mutated},
      range: range,
      position: position,
      classification: {:replace, classified, classified_as},
      note: labels[:note],
      variant: labels[:variant]
    }
  end

  defp delete(original, range, position, labels) do
    %__MODULE__{
      edit: {:delete, original},
      range: range,
      position: position,
      classification: :delete,
      note: labels[:note],
      variant: labels[:variant]
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
