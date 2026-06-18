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

  All share arity (`/3`), so swapping the function name keeps the argument list and
  always compiles — an arity-blind rename like `Mutare.Mutators.Collection`, correct
  in a pipe for free. These are remote calls, never legal in a guard, so guard-safety
  is automatic. High signal: the conditional-write distinctions are classic untested
  edges (the already-present and still-absent paths a happy-path test never hits).

  On by default. Recognises `Map`/`Keyword` by their resolved module
  (`Mutare.Transform.Calls`), so an aliased or bare-imported call is matched while a shadowing
  `alias MyApp.Map` is left alone. The family atom is `:map_keyword` (`:map` is
  `MapLiteral`).
  """
  @behaviour Mutare.Mutator

  alias Mutare.Transform.Calls

  # The conditional-write lattice (function => complementary functions). Applied to
  # both Map and Keyword, which expose the identical set — defined once so the two
  # can't drift.
  @swaps %{
    put: [:put_new, :replace],
    put_new: [:put, :replace],
    replace: [:put, :put_new, :replace!],
    replace!: [:replace]
  }

  @modules [[:Map], [:Keyword]]

  @impl Mutare.Mutator
  def name, do: :map_keyword

  @impl Mutare.Mutator
  def mutate(node) do
    with {module, fun, args, rebuild} <- Calls.resolved_call(node),
         true <- module in @modules,
         {:ok, new_funs} <- Map.fetch(@swaps, fun) do
      # `rebuild` reuses the written alias node (the swap stays within `Map`/`Keyword`).
      Enum.map(new_funs, &rebuild.(&1, args))
    else
      _ -> :skip
    end
  end
end
