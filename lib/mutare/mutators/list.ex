defmodule Mutare.Mutators.List do
  @moduledoc """
  List operator and literal mutations:

    * `++` ↔ `--` (list concatenation ↔ difference)
    * a non-empty list literal → `[]`

  Not mutated: on the RHS of a guard `in` (`when x in [a, b]`) the `[]` collapse yields `x in []` ≡ `false`, which `Mutare.Mutators.Conditional` already produces — so it is dropped there (the list's elements still mutate). Body `in` expressions keep the collapse because left-side evaluation is observable.

  Filterable variants — qualify a `# mutare:ignore` filter with `:label` to suppress just one kind (`c:Mutare.Mutator.variants/0`): `++`, `--`, `empty`.
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

  # Variant labels for `# mutare:ignore[list:<label>]`: the resulting operator of a
  # concat/diff swap (`++`/`--`, single-sourced with the classifier via `@swap_ops`), or `empty`
  # for the list-literal collapse to `[]` (named `empty`, not `[]`, since `]` can't appear in a
  # wire-safe label).
  @swap_ops [:++, :--]

  @impl Mutare.Mutator
  def variants, do: Enum.map(@swap_ops, &to_string/1) ++ ~w(empty)

  @impl Mutare.Mutator
  def variant({:__block__, _m, [orig]}, {:__block__, _m2, [[]]}) when is_list(orig), do: "empty"
  def variant(original, mutated), do: Mutare.Mutator.op_swap_variant(original, mutated, @swap_ops)
end
