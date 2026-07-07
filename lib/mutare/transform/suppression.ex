defmodule Mutare.Transform.Suppression do
  @moduledoc false
  # Equivalent-mutant suppression predicates, shared by the two paths that drop a redundant
  # mutation: the in-place **body** path (`Mutare.Transform.Analyze`, which drops
  # `%Candidate.InPlace{}` candidates) and the lifted **guard** path (`Mutare.Transform.Tag`,
  # which rejects `%Mutare.Mutator.Dispatch.Result{}` mutations). Both reduce to the
  # same question asked of a *mutated node* — "is this the redundant sibling of a mutation
  # another family already produces?" — so the recognition rules live here once; each caller
  # unwraps its own candidate/mutation shape down to the bare node before asking. (Before this module the two
  # carried character-for-character copies of these predicates, including two `@equality_complements`
  # maps that had to be kept in lockstep by hand — see NOTES "equivalent-sibling suppression".)
  #
  # The rules, and where each path implements its descent (the call sites carry the
  # surrounding why). Both paths walk the same four shared shapes; the *structural* clauses
  # stay in each module because the two deliver differently — the body path attaches
  # `%Candidate.InPlace{}` to node meta while threading only `mutators`, the guard path
  # accumulates `{tag, original, [%Mutare.Mutator.Dispatch.Result{}]}` targets while threading a tag
  # counter — so a single walk would need a four-callback strategy that obscures the
  # node-level reasoning. What *is* centralized here is the **vocabulary** (which
  # operators trigger each rule, as `defguard`s usable in both paths' `when` clauses)
  # and the **predicates** (which mutant is the redundant sibling). A literal operator
  # list in one path can no longer silently drift from its twin in the other.
  #
  #   | rule                       | body (Analyze)              | guard (Tag)              |
  #   |----------------------------|-----------------------------|--------------------------|
  #   | double negation `not not`  | `is_negation_op/1` clause   | literal `:not` clause    |
  #   | negation over `in`         | `is_negation_op/1` clause   | literal `:not` clause    |
  #   | negation over equality op  | `is_negation_op` + `is_equality_op` | `is_equality_op/1` clause |
  #   | short-circuit connective   | `is_body_connective/1`      | `is_guard_connective/1`  |
  #
  # `Tag` additionally suppresses an empty collection literal on the RHS of guard `in`.
  # There is deliberately no body twin: emptying only the RHS still evaluates the left
  # operand, while replacing the whole body expression with `false` skips it.
  #
  # The body path admits `!`/`&&`/`||` (`is_negation_op`/`is_body_connective` carry the
  # extra operators); the guard path can't (they are guard-illegal), so it matches the
  # subset (`is_guard_connective`, and a bare `:not` head with no `!`). That body ⊇ guard
  # relationship is the reason the two sets are *named here together* rather than written
  # as independent literals — a reader sees both at once.

  alias Mutare.Mutators.Conditional

  # === operator vocabulary (shared by both suppression paths' `when` clauses) =========
  #
  # `defguard`s, not plain functions or module attributes, because the structural callers
  # use these in *guard* position (`when is_equality_op(op)`) — and a guard can neither
  # call a remote function nor read a remote attribute, but it *can* use an imported guard
  # macro. So this is the single source of truth for "which operators trigger suppression"
  # that a `when` clause can actually reference.

  @doc "The equality operators whose polarity complement re-negates to the source (both paths)."
  defguard is_equality_op(op) when op in [:==, :!=, :===, :!==]

  @doc "The boolean negations the body path suppresses under (`!` is guard-illegal, so guard-only `:not`)."
  defguard is_negation_op(op) when op in [:not, :!]

  @doc "Short-circuit connectives in a runtime **body** (`&&`/`||` included)."
  defguard is_body_connective(op) when op in [:and, :&&, :or, :||]

  @doc "Short-circuit connectives legal in a **guard** (`&&`/`||` excluded) — the subset of `is_body_connective/1`."
  defguard is_guard_connective(op) when op in [:and, :or]

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
