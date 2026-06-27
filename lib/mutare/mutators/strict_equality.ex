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

  Filterable variants — qualify a `# mutare:ignore` filter with `:label` to
  suppress just one kind (`c:Mutare.Mutator.variants/0`): `==`, `!=`.
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

  # Variant labels for `# mutare:ignore[strict_equality:<op>]`: the relaxed operator
  # (`===` → `==`, `!==` → `!=`). Both sets derive from `@swaps` (the mutate table): the *result*
  # operators are the labels, and the classifier's operator set is sources + results together, so
  # the shared `op_swap_variant/3` (the one home for the operator-family `variant/2` shape) can map
  # a `===` → `==` pair to `"=="` just like the other operator families. Single-sourced from
  # `@swaps`, so vocabulary, classifier, and swaps can't drift.
  @result_ops Map.values(@swaps)
  @swap_ops Map.keys(@swaps) ++ @result_ops

  @impl Mutare.Mutator
  def variants, do: Enum.map(@result_ops, &to_string/1)

  @impl Mutare.Mutator
  def variant(original, mutated), do: Mutare.Mutator.op_swap_variant(original, mutated, @swap_ops)
end
