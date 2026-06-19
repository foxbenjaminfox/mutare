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

  Each pair shares the same arities, so swapping the function name while keeping
  the argument list always compiles. These are remote calls — never legal in a
  guard — so guard-safety is automatic.

  Note the family is deliberately **arity-blind**: it only renames, never adds or
  drops an argument. That is what keeps it correct in a pipe, where the stage's
  node has one fewer argument than the source reads (the piped value is the `|>`
  LHS, not in the call) — a rename valid at every arity stays valid there. An
  arity-*discriminating* swap (e.g. `Enum.sort`↔`Enum.reverse`, whose 2-arg forms
  diverge — `reverse/2` is `reverse(list, tail)`) can't be expressed here, because
  a pipe stage's node arity is ambiguous and off-by-one. See `NOTES.md`.

  On by default — the Elixir-flavoured family. High signal on idiomatic
  collection code. It recognises `Enum`/`List`/`Stream` calls by their resolved
  module (`Mutare.Transform.Calls`), so an aliased `E.filter` (`alias Enum, as: E`)
  and a bare imported `filter` (`import Enum`) are both matched, while a shadowing
  `alias MyApp.Enum` is correctly left alone.
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
