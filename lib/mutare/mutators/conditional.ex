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

  alias Mutare.AST

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
    [AST.literal(true), AST.literal(false)]
  end

  def mutate(_node), do: :skip

  @doc """
  Whether `op` is one of the boolean-valued operators this mutator forces to
  `true`/`false`. The single definition of "boolean-valued operator", shared with
  `Mutare.Mutators.ReturnValue` so it can skip a boolean tail rather than emit a
  return mutant that would just duplicate this family's `true`/`false`.
  """
  @spec boolean_op?(atom()) :: boolean()
  def boolean_op?(op) when is_atom(op), do: op in @boolean_ops
  def boolean_op?(_), do: false
end
