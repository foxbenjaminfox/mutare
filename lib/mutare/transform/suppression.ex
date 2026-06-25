defmodule Mutare.Transform.Suppression do
  @moduledoc false
  # Equivalent-mutant suppression predicates, shared by the two paths that drop a redundant
  # mutation: the in-place **body** path (`Mutare.Transform.Analyze`, which drops
  # `%Candidate.InPlace{}` candidates) and the lifted **guard** path (`Mutare.Transform.Tag`,
  # which rejects `{spec, mutated}` mutation tuples). Both reduce to the same question asked of a
  # *mutated node* — "is this the redundant sibling of a mutation another family already
  # produces?" — so the recognition rules live here once; each caller unwraps its own
  # candidate/mutation shape down to the bare node before asking. (Before this module the two
  # carried character-for-character copies of these predicates, including two `@equality_complements`
  # maps that had to be kept in lockstep by hand — see NOTES "equivalent-sibling suppression".)
  #
  # The rules (the call sites carry the surrounding why):
  #   * a short-circuit connective (`and`/`&&`/`or`/`||`): Conditional's constant on the *left*
  #     operand duplicates the whole-node short-circuit value (`boolean_op_node?/1` gates it,
  #     `redundant_constant/1` is the value);
  #   * an equality op *directly under a negation*: its polarity complement (Relational's flip ≡
  #     the outer `not`'s strip) and `true`/`false` (Conditional) re-negate to the source
  #     (`negation_redundant?/2`), while a strictness relaxation (`===`→`==`) is kept.

  alias Mutare.Mutators.Conditional

  # The polarity complement of each equality operator — the swap that, *under a negation*,
  # re-negates to the operator itself (`not (a !== b)` ≡ `a === b`). Exactly Relational's
  # equality flip; a strictness relaxation (`===` → `==`) is `:==`, never `===`'s complement
  # `:!==`, so it is correctly *not* redundant.
  @equality_complements %{:== => :!=, :!= => :==, :=== => :!==, :!== => :===}

  @doc """
  Whether `mutated` re-negates to its source under an outer `not` — a `true`/`false` constant
  (Conditional, ≡ the outer's) or the polarity complement of equality operator `op` (Relational's
  flip ≡ Logical's strip). A strictness relaxation (`===` → `==`) is neither, so it survives.
  """
  @spec negation_redundant?(Macro.t(), atom()) :: boolean()
  def negation_redundant?(mutated, op),
    do:
      boolean_literal?(mutated, true) or boolean_literal?(mutated, false) or
        polarity_complement?(mutated, op)

  @doc """
  Whether `mutated` is the polarity complement of equality operator `op` — `{complement, _, _}`,
  the flip that re-negates to `op` under a `not`. A relaxation (`===` → `==`) is `{:==, _, _}`,
  never the complement of `===` (`:!==`), so it is correctly *not* redundant.
  """
  @spec polarity_complement?(Macro.t(), atom()) :: boolean()
  def polarity_complement?({mop, _meta, _args}, op),
    do: mop == Map.get(@equality_complements, op)

  def polarity_complement?(_node, _op), do: false

  @doc """
  Whether `mutated` is the literal boolean `bool` (`AST.literal/1`'s `{:__block__, _, [bool]}`
  or a bare `bool`) — identifying Conditional's `true`/`false` mutant. On a connective node only
  Conditional yields a bare boolean (Logical yields the swapped operator), so this uniquely
  selects the redundant constant without keying on the producing module.
  """
  @spec boolean_literal?(Macro.t(), boolean()) :: boolean()
  def boolean_literal?({:__block__, _meta, [b]}, b) when is_boolean(b), do: true
  def boolean_literal?(b, b) when is_boolean(b), do: true
  def boolean_literal?(_node, _bool), do: false

  @doc """
  Whether `node` is an n-ary node whose head is a Conditional-eligible boolean operator — i.e.
  Conditional fires on it, so a short-circuit connective's redundant constant has a subsuming
  sibling.
  """
  @spec boolean_op_node?(Macro.t()) :: boolean()
  def boolean_op_node?({op, _meta, args}) when is_atom(op) and is_list(args),
    do: Conditional.boolean_op?(op)

  def boolean_op_node?(_node), do: false

  @doc """
  The constant a short-circuit connective's Conditional mutant duplicates on its left operand:
  `false` for `and`/`&&` (a false left short-circuits the whole node to false), `true` for
  `or`/`||` (a true left short-circuits to true). The guard path only ever passes `and`/`or`
  (`&&`/`||` are guard-illegal), so those two arms are unreachable there but kept for the body path.
  """
  @spec redundant_constant(atom()) :: boolean()
  def redundant_constant(op) when op in [:and, :&&], do: false
  def redundant_constant(op) when op in [:or, :||], do: true
end
