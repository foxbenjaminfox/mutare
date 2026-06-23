defmodule Mutare.Mutators.MapKeyword do
  @moduledoc """
  Swap a `Map`/`Keyword` write for a complement along the **conditional-write**
  axis — does the call insert new keys, overwrite existing ones, or raise on a
  missing key? The four operations form a small lattice, identical for `Map` and
  `Keyword`, all `/3`:

      | function   | writes if key present | writes if key absent |
      |------------|-----------------------|----------------------|
      | put        | yes (overwrite)       | yes (insert)         |
      | put_new    | no                    | yes (insert)         |
      | replace    | yes (overwrite)       | no (ignored)         |
      | replace!   | yes (overwrite)       | no — raises          |

  Swaps (each bidirectional, isolating one distinction):

    * `put` ↔ `put_new`      — does overwriting an existing key matter?
    * `put` ↔ `replace`      — does inserting a *new* key matter?
    * `put_new` ↔ `replace`  — the present/absent condition, fully inverted
    * `replace` ↔ `replace!` — silently ignore a missing key, or raise?

  High signal: the conditional-write distinctions are classic untested edges (the
  already-present and still-absent paths a happy-path test never hits).

  On by default. Matches aliased and bare-imported calls too, while a shadowing
  `alias MyApp.Map` is left alone. The family atom is `:map_keyword` (`:map` is
  `MapLiteral`).
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
