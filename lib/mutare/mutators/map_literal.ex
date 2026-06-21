defmodule Mutare.Mutators.MapLiteral do
  @moduledoc """
  Map-literal mutation: collapse a non-empty map literal `%{…}` to the empty map
  `%{}`. The map counterpart of `Mutare.Mutators.List`'s non-empty-list collapse —
  it asks "does anything depend on this map's contents?". A weak suite that builds
  a map but never reads a key it carries lets the empty map survive.

  In-place and compile-safe — `%{}` is legal wherever a map literal was.

  ## What is *not* mutated

    * **The empty map `%{}`** — collapsing it to itself is a no-op.
    * **A map update `%{m | …}`** — that is not a literal; `%{}` would drop the
      base map `m` (a different operation, not a smaller version of the same one).
    * **A struct's field map** (`%User{…}`) — `Mutare.Transform` does not offer the
      `%{}` *inside* a `%Struct{}` to a mutator (emptying it would drop required
      fields / change the struct), though the struct's field *values* still mutate.
      So this module only ever sees standalone map literals.
    * **The RHS of `in`** (`x in %{…}`) — `x in %{}` ≡ `false`, which
      `Mutare.Mutators.Conditional` already produces on the `in` node, so `Transform`
      drops it there (shared with the other collection-emptying families via
      `Mutare.AST.empty_collection_literal?/1`). See NOTES "Equivalent-sibling
      suppression, generalized".
  """
  @behaviour Mutare.Mutator

  @impl Mutare.Mutator
  def name, do: :map

  @impl Mutare.Mutator
  # A map update (`%{m | …}`) is a single `{:|, _, _}` arg — not a literal.
  def mutate({:%{}, _meta, [{:|, _, _}]}), do: :skip

  def mutate({:%{}, _meta, pairs}) when is_list(pairs) and pairs != [],
    do: [{:%{}, [], []}]

  def mutate(_node), do: :skip
end
