defmodule Mutare.Site do
  @moduledoc """
  One mutant: a single mutation applied at a single source location.

  A "site" in the source (e.g. one `>=` occurrence) may yield several `Site`
  structs — one per mutation the mutators emit there — each with its own `id`.
  The `id` is what the metamutant switches on at runtime (`0` = baseline).
  """

  @type t :: %__MODULE__{
          id: pos_integer(),
          file: String.t(),
          line: pos_integer() | nil,
          column: pos_integer() | nil,
          range: map() | nil,
          mutator: atom(),
          kind: :in_place | :lifted,
          operation: :replace | :delete,
          original_op: atom() | nil,
          mutated_op: atom() | nil,
          original_code: String.t(),
          mutated_code: String.t(),
          original_node: Macro.t(),
          mutated_node: Macro.t() | nil
        }

  defstruct [
    :id,
    :file,
    :line,
    :column,
    :range,
    :mutator,
    :kind,
    :original_op,
    :mutated_op,
    :original_code,
    :mutated_code,
    :original_node,
    :mutated_node,
    operation: :replace
  ]

  @doc "Human-readable one-liner, e.g. `relational  >= → >` or `clause_drop  (drop) <clause>`."
  @spec describe(t()) :: String.t()
  def describe(%__MODULE__{operation: :delete} = site) do
    "#{site.mutator}  (drop) #{site.original_code}"
  end

  def describe(%__MODULE__{} = site) do
    "#{site.mutator}  #{site.original_code} → #{site.mutated_code}"
  end
end
