defmodule Mutare.Mutators.BooleanLiteral do
  @moduledoc """
  Boolean-literal mutation: `true` ↔ `false`.

  Only literals in *runtime* positions are mutated, never pattern literals. A flip that would
  reproduce the original value is impossible, so every eligible boolean yields exactly one mutant.

  This is the boolean flip that used to be the second arm of the old `literal` family (whose integer
  arm is now `Mutare.Mutators.IntegerLiteral`). It owns `true`/`false` the way
  `Mutare.Mutators.AtomLiteral` defers them here rather than treating them as ordinary atoms. Distinct
  from `Mutare.Mutators.Conditional`, which forces boolean-valued *operator* expressions (`a > b`,
  `a and b`) to a constant — it never fires on a bare literal.

  Filterable variants — qualify a `# mutare:ignore` filter with `:label` to suppress the one kind
  (`c:Mutare.Mutator.variants/0`): `negate`.
  """
  @behaviour Mutare.Mutator

  alias Mutare.AST
  alias Mutare.Mutator.Mutation

  @impl Mutare.Mutator
  def name, do: :boolean

  @impl Mutare.Mutator
  def mutate({:__block__, _meta, [b]}) when is_boolean(b),
    do: [Mutation.tagged(AST.literal(not b), "negate")]

  def mutate(_node), do: :skip

  # Variant vocabulary for `# mutare:ignore[boolean:<label>]`: `negate` = the `true`↔`false` flip,
  # tagged on the single `Mutare.Mutator.Mutation` at production above.
  @impl Mutare.Mutator
  def variants, do: ~w(negate)
end
