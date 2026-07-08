defmodule Mutare.Mutators.MapLiteral do
  @moduledoc """
  Map-literal mutation: collapse a non-empty map literal `%{…}` to the empty map `%{}`. The map counterpart of `Mutare.Mutators.List`'s non-empty-list collapse — it asks "does anything depend on this map's contents?". A weak suite that builds a map but never reads a key it carries lets the empty map survive.

  ## What is *not* mutated

    * The empty map `%{}` — collapsing it to itself is a no-op.
    * A map update `%{m | …}` — not a literal; `%{}` would drop the base map `m` (a different operation, not a smaller version of the same one).
    * A struct's field map (`%User{…}`) — emptying it would drop required fields, so the inner `%{}` is left alone (the struct's field *values* still mutate).
    * The RHS of a guard `in` (`when x in %{…}`) — `x in %{}` ≡ `false`, which `Mutare.Mutators.Conditional` already produces. Body `in` expressions keep the collapse because left-side evaluation is observable.
  """
  @behaviour Mutare.Mutator
  use Mutare.Mutator.SkipArguments

  @impl Mutare.Mutator
  def name, do: :map

  @impl Mutare.Mutator
  # A map update (`%{m | …}`) is a single `{:|, _, _}` arg — not a literal.
  def mutate({:%{}, _meta, [{:|, _, _}]}), do: :skip

  def mutate({:%{}, _meta, pairs}) when is_list(pairs) and pairs != [],
    do: [{:%{}, [], []}]

  def mutate(_node), do: :skip
end
