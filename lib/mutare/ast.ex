defmodule Mutare.AST do
  @moduledoc false

  # Small shared constructors over the Sourceror AST representation, so the rules
  # about *how* a node must be built live in one place rather than re-derived in
  # every mutator.

  @doc """
  A scalar-literal node with clean (fresh) metadata.

  Sourceror parses a literal as `{:__block__, meta, [value]}` and renders it from a
  `:token` string cached in `meta`. Reusing a node's *original* meta would therefore
  render the *original* text even after the value changed — a silent equivalent
  no-op. So a mutator that emits a new literal value must give it fresh metadata,
  which is what this builds.

  A **string** value additionally needs a `delimiter` in its metadata, or Sourceror
  renders a printable binary as a charlist (`~c"…"`); this adds the double-quote
  delimiter automatically, so callers never have to remember the distinction.

      iex> Mutare.AST.literal(0)
      {:__block__, [], [0]}
      iex> Mutare.AST.literal("mutare")
      {:__block__, [delimiter: ~s(")], ["mutare"]}
  """
  @spec literal(term()) :: Macro.t()
  def literal(value) when is_binary(value), do: {:__block__, [delimiter: ~s(")], [value]}
  def literal(value), do: {:__block__, [], [value]}
end
