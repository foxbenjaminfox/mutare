defmodule Mutare.Mutators.List do
  @moduledoc """
  List operator and literal mutations:

    * `++` ↔ `--` (list concatenation ↔ difference)
    * a non-empty list literal → `[]`

  In-place and compile-safe — the operator swap reuses both operands, and an
  empty list is legal wherever a list literal was. `++`/`--` are not guard-legal,
  so the compiler guarantees a source guard never contains one; the literal
  collapse to `[]` is a constant and stays guard-safe.

  One redundancy `Mutare.Transform` resolves on this family's behalf: on the **RHS of
  `in`** (`x in [a, b]`) the `[]` collapse yields `x in []` ≡ `false`, a mutant
  `Mutare.Mutators.Conditional` already produces on the `in` node — so it is dropped there
  (its elements still mutate). The drop is shared with the other collection-emptying
  families via `Mutare.AST.empty_collection_literal?/1`. See NOTES "Equivalent-sibling
  suppression, generalized".
  """
  @behaviour Mutare.Mutator

  alias Mutare.AST

  @impl Mutare.Mutator
  def name, do: :list

  @impl Mutare.Mutator
  def mutate({:++, meta, [left, right]}), do: [{:--, meta, [left, right]}]
  def mutate({:--, meta, [left, right]}), do: [{:++, meta, [left, right]}]

  # A list literal parses as `{:__block__, meta, [[elem, ...]]}`; collapse a
  # non-empty one to `[]`. The empty list is left alone (mutating it to itself
  # is a no-op).
  def mutate({:__block__, _meta, [elements]}) when is_list(elements) and elements != [] do
    [AST.literal([])]
  end

  def mutate(_node), do: :skip
end
