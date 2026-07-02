defmodule Mutare.Mutators.MapKeyword do
  @moduledoc """
  Renames `Map` and `Keyword` writes according to how they handle present and absent keys:

  | function | key present | key absent |
  | --- | --- | --- |
  | `put` | overwrite | insert |
  | `put_new` | leave unchanged | insert |
  | `replace` | overwrite | ignore |
  | `replace!` | overwrite | raise |

  The following `/3` pairs are exchanged:

    * `put` ↔ `put_new`
    * `put` ↔ `replace`
    * `put_new` ↔ `replace`
    * `replace` ↔ `replace!`

  The same pairs apply to both `Map` and `Keyword`. Direct, aliased, and imported calls are supported; an alias that resolves to another module does not match.

  This family is enabled by default. Its family name is `map_keyword`.
  """
  @behaviour Mutare.Mutator

  alias Mutare.Mutators.Helpers

  # The conditional-write lattice as `{alias_path, function} => complementary functions`,
  # built once for both `Map` and `Keyword` (identical sets, so they can't drift) and keyed
  # by `{module, fun}` like the other swap-table families. `Helpers.swap_call/2` keeps the
  # written module, so a swap stays within `Map`/`Keyword`.
  @lattice %{
    put: [:put_new, :replace],
    put_new: [:put, :replace],
    replace: [:put, :put_new, :replace!],
    replace!: [:replace]
  }

  @swaps for module <- [[:Map], [:Keyword]],
             {fun, new_funs} <- @lattice,
             into: %{},
             do: {{module, fun}, new_funs}

  @impl Mutare.Mutator
  def name, do: :map_keyword

  @impl Mutare.Mutator
  def mutate(node), do: Helpers.swap_call(node, @swaps)
end
