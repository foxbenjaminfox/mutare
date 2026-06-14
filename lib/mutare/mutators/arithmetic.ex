defmodule Mutare.Mutators.Arithmetic do
  @moduledoc """
  Arithmetic operator swaps: `+`↔`-`, `*`↔`/`, `div`↔`rem`.

  In-place and compile-safe by construction — swapping one binary arithmetic
  operator for another always type-checks at compile time.
  """
  @behaviour Mutare.Mutator

  # original operator => replacement operators
  @swaps %{
    :+ => [:-],
    :- => [:+],
    :* => [:/],
    :/ => [:*],
    :div => [:rem],
    :rem => [:div]
  }

  @impl Mutare.Mutator
  def name, do: :arithmetic

  @impl Mutare.Mutator
  def kind, do: :in_place

  @impl Mutare.Mutator
  def mutate({op, meta, [left, right]}) do
    case Map.fetch(@swaps, op) do
      {:ok, replacements} -> Enum.map(replacements, &{&1, meta, [left, right]})
      :error -> :skip
    end
  end

  def mutate(_node), do: :skip
end
