defmodule Mutare.Mutators.TupleLiteral do
  @moduledoc """
  Tuple-literal mutation: collapse a non-empty tuple literal to the empty tuple `{}`. Like the corresponding list and map mutations, this tests whether the suite depends on the tuple's structure or contents. A `{:ok, value}` that is built but never pattern-matched (or whose shape no test pins down) lets `{}` survive; anywhere the shape *is* used, the mutant is killed.

  Two AST shapes, because Elixir represents a 2-element tuple specially: a literal pair `{a, b}` parses as `{:__block__, _, [{a, b}]}` (the value is a raw 2-tuple), while `{}`, `{a}`, and `{a, b, c, …}` parse as `{:{}, _, elements}`. Both non-empty shapes collapse to `{:{}, [], []}` (`{}`); the empty tuple is left alone.

  A tuple in a *pattern* is left alone, so a match like `{:ok, v} = …` is not corrupted.
  """
  @behaviour Mutare.Mutator

  @empty {:{}, [], []}

  @impl Mutare.Mutator
  def name, do: :tuple

  @impl Mutare.Mutator
  # 2-tuple literal: the `{:__block__, _, [value]}` whose sole value is a 2-tuple.
  def mutate({:__block__, _meta, [tuple]}) when is_tuple(tuple) and tuple_size(tuple) == 2,
    do: [@empty]

  # 0/1/3+-arity tuple literal. A non-empty one collapses; `{}` is left alone.
  def mutate({:{}, _meta, elements}) when is_list(elements) and elements != [],
    do: [@empty]

  def mutate(_node), do: :skip
end
