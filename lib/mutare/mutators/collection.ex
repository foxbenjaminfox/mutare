defmodule Mutare.Mutators.Collection do
  @moduledoc """
  Renames collection calls to a complementary operation:

    * `Enum.filter` ↔ `Enum.reject`
    * `Enum.all?` ↔ `Enum.any?`
    * `Enum.min` ↔ `Enum.max`
    * `Enum.min_by` ↔ `Enum.max_by`
    * `Enum.take` ↔ `Enum.drop`
    * `Enum.take_while` ↔ `Enum.drop_while`
    * `Enum.take_every` ↔ `Enum.drop_every`
    * `Enum.sum` ↔ `Enum.product`
    * `Map.filter` ↔ `Map.reject`
    * `Map.take` ↔ `Map.drop`
    * `Keyword.filter` ↔ `Keyword.reject`
    * `Keyword.take` ↔ `Keyword.drop`
    * `List.first` ↔ `List.last`
    * `List.foldl` ↔ `List.foldr`
    * `MapSet.filter` ↔ `MapSet.reject`
    * `Stream.filter` ↔ `Stream.reject`
    * `Stream.take` ↔ `Stream.drop`
    * `Stream.take_while` ↔ `Stream.drop_while`
    * `Stream.take_every` ↔ `Stream.drop_every`

  The family only changes the function name; it does not add or remove arguments.
  Pairs whose same-arity forms have different meanings, such as `Enum.sort/2` and
  `Enum.reverse/2`, are therefore not included.

  Direct, aliased, and imported calls are supported. An alias that resolves to
  another module does not match. This family is enabled by default.
  """
  @behaviour Mutare.Mutator

  alias Mutare.Mutators.Helpers

  # {alias_path, function} => new_function (the swap stays within the module, so only
  # the new name is stored; `Helpers.swap_call/2` keeps the written module).
  @swaps %{
    {[:Enum], :filter} => :reject,
    {[:Enum], :reject} => :filter,
    {[:Enum], :all?} => :any?,
    {[:Enum], :any?} => :all?,
    {[:Enum], :min} => :max,
    {[:Enum], :max} => :min,
    {[:Enum], :min_by} => :max_by,
    {[:Enum], :max_by} => :min_by,
    {[:Enum], :take} => :drop,
    {[:Enum], :drop} => :take,
    {[:Enum], :take_while} => :drop_while,
    {[:Enum], :drop_while} => :take_while,
    {[:Enum], :take_every} => :drop_every,
    {[:Enum], :drop_every} => :take_every,
    {[:Enum], :sum} => :product,
    {[:Enum], :product} => :sum,
    {[:Map], :filter} => :reject,
    {[:Map], :reject} => :filter,
    {[:Map], :take} => :drop,
    {[:Map], :drop} => :take,
    {[:Keyword], :filter} => :reject,
    {[:Keyword], :reject} => :filter,
    {[:Keyword], :take} => :drop,
    {[:Keyword], :drop} => :take,
    {[:List], :first} => :last,
    {[:List], :last} => :first,
    {[:List], :foldl} => :foldr,
    {[:List], :foldr} => :foldl,
    {[:MapSet], :filter} => :reject,
    {[:MapSet], :reject} => :filter,
    # The lazy `Stream` twins — the directional pairs that exist in `Stream`.
    {[:Stream], :filter} => :reject,
    {[:Stream], :reject} => :filter,
    {[:Stream], :take} => :drop,
    {[:Stream], :drop} => :take,
    {[:Stream], :take_while} => :drop_while,
    {[:Stream], :drop_while} => :take_while,
    {[:Stream], :take_every} => :drop_every,
    {[:Stream], :drop_every} => :take_every
  }

  @impl Mutare.Mutator
  def name, do: :collection

  @impl Mutare.Mutator
  def mutate(node), do: Helpers.swap_call(node, @swaps)
end
