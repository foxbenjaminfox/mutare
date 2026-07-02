defmodule Mutare.Mutators.Conditional do
  @moduledoc """
  Replace a boolean-valued expression with the constants `true` and `false` — the "remove conditionals" mutation. Forcing a decision to one side checks that *both* branches it guards are actually exercised by the suite.

  Applies to the nodes that are guaranteed boolean-typed: the comparison and membership operators (`>`, `>=`, `<`, `<=`, `==`, `!=`, `===`, `!==`, `in`) and the logical connectives (`and`, `or`, `&&`, `||`, `not`, `!`). Guard-safe — a bare boolean is legal in a `when`.

  On by default. It overlaps the relational/logical swaps and roughly doubles the mutants at every condition, but the extra signal — proving each branch is actually exercised — is worth the volume. (On a short-circuit `and`/`or` whose left operand is itself a boolean op, the redundant whole-node constant is dropped, since forcing the left operand already covers it.)

  Filterable variants — qualify a `# mutare:ignore` filter with `:label` to suppress just one kind (`c:Mutare.Mutator.variants/0`): `true`, `false`.
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

  # Variant labels for `# mutare:ignore[conditional:<label>]`: which constant the condition
  # was forced to — `true` or `false`.
  @impl Mutare.Mutator
  def variants, do: ~w(true false)

  @impl Mutare.Mutator
  def variant(_original, {:__block__, _meta, [bool]}) when is_boolean(bool), do: to_string(bool)
  def variant(_original, _mutated), do: nil

  @doc """
  Whether `op` is one of the boolean-valued operators this mutator forces to
  `true`/`false` — the comparison/membership/logical connectives.

  `Mutare.Mutators.ReturnValue` and `Mutare.Mutators.IfCondition` reuse it to skip a boolean
  tail/condition rather than emit a mutant that would just duplicate this family's `true`/`false`;
  a **custom** mutator that forces values boolean can use it the same way, to avoid producing
  redundant mutants on a node Conditional already covers.
  """
  @spec boolean_op?(atom()) :: boolean()
  def boolean_op?(op) when is_atom(op), do: op in @boolean_ops
  def boolean_op?(_), do: false
end
