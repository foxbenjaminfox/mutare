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
          ignored: boolean(),
          ignore_reason: String.t() | nil,
          poisoned: boolean(),
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
    operation: :replace,
    ignored: false,
    ignore_reason: nil,
    poisoned: false
  ]

  # === construction ==========================================================
  #
  # Named constructors own the struct's shape — how each field is derived from
  # the mutation (op extraction, code rendering, location). `Mutare.Transform`
  # decides *which* one to call from a node's position; it never stuffs fields.

  @doc """
  An in-place mutation: an operator swapped behind a selector `case` in a
  function body. `range` locates the original node; `mutator` is the module
  that produced `mutated_node`.
  """
  @spec in_place(pos_integer(), String.t(), map(), Macro.t(), Macro.t(), module()) :: t()
  def in_place(id, file, range, original_node, mutated_node, mutator) do
    replace(id, file, range, original_node, mutated_node, mutator, :in_place)
  end

  @doc """
  A guard mutation, delivered by lifting (a `case` can't live in a `when`). Same
  operator-swap shape as `in_place/6`, recorded as `:lifted`.
  """
  @spec lifted_guard(pos_integer(), String.t(), map(), Macro.t(), Macro.t(), module()) :: t()
  def lifted_guard(id, file, range, original_node, mutated_node, mutator) do
    replace(id, file, range, original_node, mutated_node, mutator, :lifted)
  end

  @doc """
  A dropped function clause — a `:lifted`, `:delete` mutation. The clause is
  removed entirely, so there is no mutated node, op, or code.
  """
  @spec clause_drop(pos_integer(), String.t(), map(), Macro.t()) :: t()
  def clause_drop(id, file, range, clause_node) do
    %__MODULE__{
      id: id,
      file: file,
      line: range.start[:line],
      column: range.start[:column],
      range: range,
      mutator: :clause_drop,
      kind: :lifted,
      operation: :delete,
      original_op: nil,
      mutated_op: nil,
      original_code: Sourceror.to_string(clause_node),
      mutated_code: "",
      original_node: clause_node,
      mutated_node: nil
    }
  end

  @doc """
  A return-value mutation: a function clause's tail expression replaced with a
  constant (`nil`/`0`/`""`/`[]`) behind an in-place selector `case`. Structural
  (the transform names the tail; there is no node-level mutator), so the recorded
  `mutator` is the fixed `:return_value` and there are no operator atoms — but it
  *is* `:in_place` (a tail is a body position), with the original tail and the
  replacement constant kept for the diff.
  """
  @spec return_value(pos_integer(), String.t(), map(), Macro.t(), Macro.t()) :: t()
  def return_value(id, file, range, original_node, mutated_node) do
    %__MODULE__{
      id: id,
      file: file,
      line: range.start[:line],
      column: range.start[:column],
      range: range,
      mutator: :return_value,
      kind: :in_place,
      operation: :replace,
      original_op: nil,
      mutated_op: nil,
      original_code: Sourceror.to_string(original_node),
      mutated_code: Sourceror.to_string(mutated_node),
      original_node: original_node,
      mutated_node: mutated_node
    }
  end

  # In-place and lifted-guard sites differ only in `kind`: both are an operator
  # swap recorded with the original/mutated nodes, their ops, and rendered code.
  defp replace(id, file, range, original_node, mutated_node, mutator, kind) do
    %__MODULE__{
      id: id,
      file: file,
      line: range.start[:line],
      column: range.start[:column],
      range: range,
      mutator: mutator.name(),
      kind: kind,
      original_op: elem(original_node, 0),
      mutated_op: elem(mutated_node, 0),
      original_code: Sourceror.to_string(original_node),
      mutated_code: Sourceror.to_string(mutated_node),
      original_node: original_node,
      mutated_node: mutated_node
    }
  end

  @doc "Human-readable one-liner, e.g. `relational  >= → >` or `clause_drop  (drop) <clause>`."
  @spec describe(t()) :: String.t()
  def describe(%__MODULE__{operation: :delete} = site) do
    "#{site.mutator}  (drop) #{site.original_code}"
  end

  def describe(%__MODULE__{} = site) do
    "#{site.mutator}  #{site.original_code} → #{site.mutated_code}"
  end
end
