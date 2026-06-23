defmodule Mutare.Mutators.List do
  @moduledoc """
  List operator and literal mutations:

    * `++` ↔ `--` (list concatenation ↔ difference)
    * a non-empty list literal → `[]`

  Not mutated: on the **RHS of `in`** (`x in [a, b]`) the `[]` collapse yields
  `x in []` ≡ `false`, which `Mutare.Mutators.Conditional` already produces — so it
  is dropped there (the list's elements still mutate).
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
