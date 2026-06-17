defmodule Mutare.Mutators.Collection do
  @moduledoc """
  Swap complementary `Enum`/`List` calls for their opposite:

    * `Enum.filter` ↔ `Enum.reject`
    * `Enum.all?` ↔ `Enum.any?`
    * `Enum.min` ↔ `Enum.max`
    * `Enum.min_by` ↔ `Enum.max_by`
    * `Enum.take` ↔ `Enum.drop`
    * `Enum.take_while` ↔ `Enum.drop_while`
    * `Enum.sum` ↔ `Enum.product`
    * `List.first` ↔ `List.last`
    * `List.foldl` ↔ `List.foldr`

  Each pair shares the same arities, so swapping the function name while keeping
  the argument list always compiles. These are remote calls — never legal in a
  guard — so guard-safety is automatic.

  On by default — the Elixir-flavoured family. High signal on idiomatic
  collection code. It recognises only unaliased `Enum`/`List` calls by name, so a
  shadowing alias simply isn't matched (no false mutation).
  """
  @behaviour Mutare.Mutator

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
  def mutate({{:., dot_meta, [{:__aliases__, alias_meta, mod}, fun]}, call_meta, args})
      when is_list(args) do
    case Map.fetch(@swaps, {mod, fun}) do
      {:ok, {new_mod, new_fun}} ->
        [{{:., dot_meta, [{:__aliases__, alias_meta, new_mod}, new_fun]}, call_meta, args}]

      :error ->
        :skip
    end
  end

  def mutate(_node), do: :skip
end
