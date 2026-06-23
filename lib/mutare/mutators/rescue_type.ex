defmodule Mutare.Mutators.RescueType do
  @moduledoc """
  Narrow a `rescue` clause's caught **exception types** — drop one type from a
  `var in [Type1, Type2, ...]` list, so the clause rescues one fewer kind. The
  question it asks: *does any test rely on each rescued exception actually being
  caught here?* If a type can be dropped and the suite stays green, nothing
  exercises that rescue path — a precisely located gap.

  ## What it drops (and what it leaves alone)

  A type list of **two or more** types is mutated — in either the bound
  `var in [A, B, ...]` or the bare `[A, B, ...]` form — dropping each type in turn
  (`[A, B]` → `[A]` and `[B]`; `[A, B, C]` → `[B, C]`, `[A, C]`, `[A, B]`). Every
  result is a non-empty exception list, so the metamutant always compiles. A single
  type (`var in A` / `rescue A`), a bare variable (`rescue e` — catches everything),
  and an empty drop (which would be `in []`, catching nothing) are left alone — none
  has a meaningful, compile-safe narrowing.

  ## Multi-branch rescues: drop a whole clause

  The idiomatic way to handle several exception types *differently* is one clause each:

      rescue
        e in ArgumentError -> handle_arg(e)
        e in RuntimeError  -> handle_run(e)

  Each branch catches a single type, so there is no list to narrow — but the same
  question ("is each rescued exception's handling actually relied on?") is asked one
  level up by **dropping a whole `rescue` branch**: drop the `ArgumentError` clause and
  that exception propagates while `RuntimeError` is still caught, and vice versa. This is
  the structural twin of list-narrowing, reusing the same "≥2, never to empty" invariant —
  a clause is dropped **only when the `rescue` has two or more clauses** (a `try` cannot
  carry an empty `rescue`), so every result compiles. The branch's head shape is irrelevant:
  a bare-variable catch-all clause among others is droppable too. Both operations are
  recorded under this one `:rescue_type` family.

  Both the **explicit `try`** and the **`def … rescue …` shorthand** are mutated.
  """
  @behaviour Mutare.Mutator

  @impl Mutare.Mutator
  def name, do: :rescue_type

  # Structural/positional, not node-level: a rescue clause's exception-type list is
  # special syntax the analyzer recognises by position (see the moduledoc), so this
  # never fires as a node mutator. `drops/1` is the real entry point, called by
  # `Mutare.Transform.Analyze` at each rescue clause.
  @impl Mutare.Mutator
  def mutate(_node), do: :skip

  @doc """
  The narrowed exception-type lists for a rescue clause's `in [t1, ..., tn]` list:
  each list with one type removed, **only** when ≥2 types are present (so the result
  is always non-empty — dropping the last would leave `in []`, which rescues
  nothing). Returns `[]` for a single type / bare alias / bare variable.
  """
  @spec drops([Macro.t()]) :: [[Macro.t()]]
  def drops(types) when is_list(types) and length(types) >= 2 do
    Enum.map(0..(length(types) - 1), &List.delete_at(types, &1))
  end

  def drops(_types), do: []
end
