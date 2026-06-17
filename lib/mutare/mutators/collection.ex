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
  collection code. It recognises `Enum`/`List` calls by their resolved module
  (`Mutare.Transform.Aliases`), so an aliased `E.filter` (`alias Enum, as: E`) is
  matched while a shadowing `alias MyApp.Enum` is correctly left alone.
  """
  @behaviour Mutare.Mutator

  alias Mutare.Transform.Aliases

  # {alias_path, function} => {alias_path, function}
  @swaps %{
    {[:Enum], :filter} => {[:Enum], :reject},
    {[:Enum], :reject} => {[:Enum], :filter},
    {[:Enum], :all?} => {[:Enum], :any?},
    {[:Enum], :any?} => {[:Enum], :all?},
    {[:Enum], :min} => {[:Enum], :max},
    {[:Enum], :max} => {[:Enum], :min},
    {[:Enum], :min_by} => {[:Enum], :max_by},
    {[:Enum], :max_by} => {[:Enum], :min_by},
    {[:Enum], :take} => {[:Enum], :drop},
    {[:Enum], :drop} => {[:Enum], :take},
    {[:Enum], :take_while} => {[:Enum], :drop_while},
    {[:Enum], :drop_while} => {[:Enum], :take_while},
    {[:Enum], :take_every} => {[:Enum], :drop_every},
    {[:Enum], :drop_every} => {[:Enum], :take_every},
    {[:Enum], :sum} => {[:Enum], :product},
    {[:Enum], :product} => {[:Enum], :sum},
    {[:List], :first} => {[:List], :last},
    {[:List], :last} => {[:List], :first},
    {[:List], :foldl} => {[:List], :foldr},
    {[:List], :foldr} => {[:List], :foldl}
  }

  @impl Mutare.Mutator
  def name, do: :collection

  @impl Mutare.Mutator
  def mutate(node) do
    with {module, fun, args, rebuild} <- Aliases.resolved_call(node),
         {:ok, {_new_mod, new_fun}} <- Map.fetch(@swaps, {module, fun}) do
      # `rebuild` reuses the written alias node, so an aliased `E.filter` mutates to
      # `E.reject` (the swap stays within the module).
      [rebuild.(new_fun, args)]
    else
      _ -> :skip
    end
  end
end
