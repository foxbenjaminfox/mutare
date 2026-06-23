defmodule Mutare.Mutators.Collection do
  @moduledoc """
  Swap complementary `Enum`/`List` calls for their opposite:

    * `Enum.filter` ↔ `Enum.reject`
    * `Enum.all?` ↔ `Enum.any?`
    * `Enum.min` ↔ `Enum.max`
    * `Enum.min_by` ↔ `Enum.max_by`
    * `Enum.take` ↔ `Enum.drop`
    * `Enum.take_while` ↔ `Enum.drop_while`
    * `Enum.take_every` ↔ `Enum.drop_every`
    * `Enum.sum` ↔ `Enum.product`
    * `List.first` ↔ `List.last`
    * `List.foldl` ↔ `List.foldr`

  …plus the lazy `Stream` twins of the `Enum` directional pairs (the functions
  `Stream` actually provides — its eager reducers like `all?`/`min`/`sum` have no
  lazy form, so only these four carry over):

    * `Stream.filter` ↔ `Stream.reject`
    * `Stream.take` ↔ `Stream.drop`
    * `Stream.take_while` ↔ `Stream.drop_while`
    * `Stream.take_every` ↔ `Stream.drop_every`

  The family is deliberately **arity-blind**: it only renames, never adds or drops
  an argument. An arity-*discriminating* swap (e.g. `Enum.sort`↔`Enum.reverse`,
  whose 2-arg forms diverge — `reverse/2` is `reverse(list, tail)`) is therefore
  not offered here.

  On by default — the Elixir-flavoured family, high signal on idiomatic collection
  code. Matches aliased and bare-imported calls too (`alias Enum, as: E; E.filter`,
  `import Enum; filter`), while a shadowing `alias MyApp.Enum` is left alone.
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
    {[:List], :first} => :last,
    {[:List], :last} => :first,
    {[:List], :foldl} => :foldr,
    {[:List], :foldr} => :foldl,
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
