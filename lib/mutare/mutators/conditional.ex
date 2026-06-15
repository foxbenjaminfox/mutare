defmodule Mutare.Mutators.Conditional do
  @moduledoc """
  Replace a boolean-valued expression with the constants `true` and `false` —
  the "remove conditionals" mutation. Forcing a decision to one side checks that
  *both* branches it guards are actually exercised by the suite.

  Applies to the nodes that are guaranteed boolean-typed: the comparison and
  membership operators (`>`, `>=`, `<`, `<=`, `==`, `!=`, `===`, `!==`, `in`) and
  the logical connectives (`and`, `or`, `&&`, `||`, `not`, `!`). Substituting a
  literal `true`/`false` for one of these is always compile-safe (it stays a
  boolean) and guard-safe (a bare boolean is legal in a `when`).

  On by default. It overlaps the relational/logical swaps and roughly doubles the
  mutants at every condition, but the extra signal — proving each branch is
  actually exercised — is worth the volume.
  """
  @behaviour Mutare.Mutator

  @boolean_ops [
    :>,
    :>=,
    :<,
    :<=,
    :==,
    :!=,
    :===,
    :!==,
    :in,
    :and,
    :or,
    :&&,
    :||,
    :not,
    :!
  ]

  @impl Mutare.Mutator
  def name, do: :conditional

  @impl Mutare.Mutator
  def mutate({op, _meta, args}) when op in @boolean_ops and is_list(args) do
    [{:__block__, [], [true]}, {:__block__, [], [false]}]
  end

  def mutate(_node), do: :skip
end
