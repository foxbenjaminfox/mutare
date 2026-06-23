defmodule Mutare.Mutators.StrictEquality do
  @moduledoc """
  Relax strict equality to value equality, **one direction only**:

    * `a === b` → `a == b`
    * `a !== b` → `a != b`

  The bet is asymmetric on purpose. `===`/`!==` distinguish `1` from `1.0` (and an
  integer-keyed term from its float-keyed twin); `==`/`!=` don't. Writing the strict
  form is a claim that the distinction matters — so the *useful* mutant relaxes it and
  asks the suite to prove the claim. If `a == b` passes every test, the `===` was
  unjustified. The reverse (`==` → `===`) is **not** produced: tightening an already-
  loose comparison rarely changes behaviour the suite exercises, so it would mostly mint
  equivalent survivors. (`==`/`!=` polarity is `Mutare.Mutators.Relational`'s job.)

  Guard-legal, so a swap inside a `when` guard is mutated too.

  ## Relation to `Mutare.Mutators.Relational`

  `Relational` flips an equality operator's *polarity* (`===` → `!==`, `==` → `!=`); this
  family changes its *strictness* (`===` → `==`). The two are orthogonal — a strictness
  relaxation is never a polarity complement — so they never produce the same mutant, and
  both fire on a bare `a === b`.

  Under a negation (`not (a === b)` / `!(a === b)`) Relational's flip is redundant
  (`not (a !== b)` ≡ `a === b`, which Logical already produces) and is suppressed, but
  this family's relaxation is **not** its polarity complement (`not (a == b)` ≢ `a === b`),
  so it is kept.
  """
  @behaviour Mutare.Mutator

  # One-direction relaxation only: strict → loose. The loose operators (`==`/`!=`) are
  # deliberately absent — they are never tightened here.
  @swaps %{
    :=== => :==,
    :!== => :!=
  }

  @impl Mutare.Mutator
  def name, do: :strict_equality

  @impl Mutare.Mutator
  def mutate({op, meta, [left, right]}) when is_map_key(@swaps, op) do
    [{Map.fetch!(@swaps, op), meta, [left, right]}]
  end

  def mutate(_node), do: :skip
end
