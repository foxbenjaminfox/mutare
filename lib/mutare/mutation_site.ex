defmodule Mutare.MutationSite do
  @moduledoc """
  Stable public description of one generated mutant.

  `Mutare.Site` is Mutare's internal runner/report record. This struct is the public API shape
  returned from `Mutare.transform_string/2`: it keeps the fields useful to custom mutator and
  extension authors while leaving delivery, runner, and reporter internals free to change.
  """

  alias Mutare.Site

  @type position :: %{line: pos_integer(), column: pos_integer()}
  @type range :: %{start: position(), end: position()} | nil

  @type t :: %__MODULE__{
          id: pos_integer(),
          file: String.t(),
          line: pos_integer() | nil,
          column: pos_integer() | nil,
          range: range(),
          mutator: atom(),
          variant: [String.t()],
          operation: :replace | :delete,
          original_code: String.t() | nil,
          mutated_code: String.t() | nil,
          ignored: boolean(),
          ignore_reason: String.t() | nil,
          note: String.t() | nil,
          emitted: boolean()
        }

  @enforce_keys [
    :id,
    :file,
    :line,
    :column,
    :range,
    :mutator,
    :variant,
    :operation,
    :original_code,
    :mutated_code,
    :ignored,
    :ignore_reason,
    :note,
    :emitted
  ]
  defstruct @enforce_keys

  @doc false
  @spec from_site(Site.t()) :: t()
  def from_site(%Site{} = site) do
    %__MODULE__{
      id: site.id,
      file: site.file,
      line: site.line,
      column: site.column,
      range: range(site.range),
      mutator: site.mutator,
      variant: site.variant,
      operation: site.operation,
      original_code: site.original_code,
      mutated_code: site.mutated_code,
      ignored: site.ignored,
      ignore_reason: site.ignore_reason,
      note: site.note,
      emitted: not site.poisoned
    }
  end

  defp range(nil), do: nil

  defp range(%Sourceror.Range{start: start, end: finish}) do
    %{start: position(start), end: position(finish)}
  end

  defp position(pos), do: %{line: pos[:line], column: pos[:column]}
end
