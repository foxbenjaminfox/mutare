defmodule Mutare.Test.CollectionMutator do
  @moduledoc """
  A custom mutator that collapses a `MapSet.new([…])` to the empty `MapSet.new([])` —
  a **non-standard** empty enumerable (a call, not one of core's recognised `[]`/`%{}`/
  `~w()`/`~c""` literals). It exercises the optional `c:Mutare.Mutator.empty_collection?/1`
  hook: on the right of `in`, `x in MapSet.new([])` is constantly `false`, so by declaring
  the collapse empty the mutator gets the in-RHS redundancy suppression — the same drop the
  built-in collection families get — for its own shape.

  A real, loadable module so the metamutant it produces compiles (`MapSet` is stdlib).
  """
  @behaviour Mutare.Mutator

  alias Mutare.AST

  @impl Mutare.Mutator
  def name, do: :collection

  # `MapSet.new([…])` → `MapSet.new([])` (the empty set), reusing the call's form.
  @impl Mutare.Mutator
  def mutate({{:., dot, [{:__aliases__, am, [:MapSet]}, :new]}, meta, [arg]}) do
    case arg do
      {:__block__, _m, [list]} when is_list(list) and list != [] ->
        [{{:., dot, [{:__aliases__, am, [:MapSet]}, :new]}, meta, [AST.literal([])]}]

      _other ->
        :skip
    end
  end

  def mutate(_node), do: :skip

  # Declare the collapse's result an empty enumerable: `MapSet.new(<empty list>)`. Reuses
  # the core list/map/sigil recogniser on the argument, so the "what is empty" knowledge
  # is not re-derived.
  @impl Mutare.Mutator
  def empty_collection?({{:., _, [{:__aliases__, _, [:MapSet]}, :new]}, _, [arg]}),
    do: AST.empty_collection_literal?(arg)

  def empty_collection?(_node), do: false
end
