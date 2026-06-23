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

  One self-overlap `Mutare.Transform` resolves on this family's behalf: on a
  short-circuit connective whose **left** operand is itself a boolean op, forcing the
  whole node to one constant duplicates forcing the left operand to it — `(L and R) →
  false` ≡ `L → false` and `(L or R) → true` ≡ `L → true` (the left short-circuits the
  node, evaluating neither operand in either mutant). So the connective-node constant is
  dropped (the operand keeps its precise diff); the *other* constant and Logical's
  `and`↔`or` stay. A non-boolean-op left (`is_binary(a) and R`) has no subsuming sibling,
  so both constants are kept there. See NOTES "Equivalent-sibling suppression, generalized".
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
  `true`/`false` — the comparison/membership/logical connectives.

  The single definition of "boolean-valued operator". `Mutare.Mutators.ReturnValue` and
  `Mutare.Mutators.IfCondition` reuse it to skip a boolean tail/condition rather than emit a
  mutant that would just duplicate this family's `true`/`false`; a **custom** mutator that
  forces values boolean can use it the same way, to avoid producing redundant mutants on a
  node Conditional already covers.
  """
  @spec boolean_op?(atom()) :: boolean()
  def boolean_op?(op) when is_atom(op), do: op in @boolean_ops
  def boolean_op?(_), do: false
end
