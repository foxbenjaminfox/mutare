defmodule Mutare.Mutators.IfCondition do
  @moduledoc """
  Force an `if`/`unless`/`cond` **condition** to the constants `true` and `false` —
  the "remove the decision" mutation, asked of every branch the suite gates: *is
  each side of this condition actually exercised?* A condition pinned to one
  constant that no test notices is a precisely located gap.

  ## Why this is structural, not a node-level `mutate/1`

  This is the positional sibling of `Mutare.Mutators.Conditional`. Conditional
  rewrites a node *wherever it occurs*, so it can only fire where the node itself
  proves it is boolean-valued — a comparison/membership/logical operator. A *bare*
  condition (`if user`, `if valid?(x)`, `if is_nil(v)`, `if Map.has_key?(m, k)`)
  carries no such proof at the node, yet positionally it **is** a boolean decision.
  Only the transform knows a node sits in a condition slot, so — exactly like
  `Mutare.Mutators.ReturnValue` — `mutate/1` is `:skip` and the real work lives in the
  structural `c:Mutare.Mutator.condition_replacements/1` hook, which `Mutare.Transform`
  discovers by export and calls at each `if`/`unless`/`cond` condition it finds (a custom
  mutator implementing the same hook participates identically). The module still implements the behaviour so it sits in
  the `Mutare.Mutators` registry: on by default, named in reports, selectable via
  `:mutators`, and filterable by `# mutare:ignore[if_condition]`, like every family.

  Delivery is the in-place selector (a condition is a body position, so a `case` is
  legal there), wrapping just the condition — the diff stays `if foo?(x)` → `if true`.

  ## What it deliberately leaves alone (no redundant or unsafe mutant)

    * **Boolean-operator conditions** — a comparison / membership / `and`/`or` /
      `&&`/`||` / `not`/`!`. `Conditional` already forces these to `true`/`false`
      *at the operator node*, so a condition mutant here would just duplicate it.
      (Detected via `Conditional.boolean_op?/1`, the shared definition of
      "boolean-valued op" — the same reuse `ReturnValue` makes.) This is why
      `&&`/`||` need no special handling: they are boolean ops, already covered.
    * **A literal `true`/`false`/`nil` condition** — forcing `if true` to `true` is
      a no-op and to `false` is dead-code removal; both are degenerate, low signal.
    * **A binding condition** — `if user = fetch()` (or a parenthesised
      `(x = a; cond)` sequence). The `if` condition's bindings *leak* into the body,
      so wrapping the condition in a selector would scope them to a branch — `use(user)`
      would reference an unbound variable and the single build would not compile. So
      this hook declines them at the node level (and the transform's condition pruning,
      `Mutare.Transform.Analyze`, governs the same for `Conditional`/`Relational` on a
      binding nested under an operator). For an `if`/`unless`, though, the transform
      then *hoists* the binding out — lifting it into a preceding statement so the
      now-binding-free condition can carry the decision after all (the diff still names
      the original condition). `cond` can't hoist (its clauses short-circuit in order),
      so a `cond` binding condition stays pruned. Either way the mutator is compile-safe
      by construction, not leaning on poison recovery.

  Compile-safety of the rest is free: the surviving conditions bind nothing, a bare
  `true`/`false` is legal in any condition slot, and the original condition is kept
  in the selector's catch-all, so any variable it *reads* stays referenced.
  """
  @behaviour Mutare.Mutator

  alias Mutare.AST
  alias Mutare.Mutators.Conditional

  @impl Mutare.Mutator
  def name, do: :if_condition

  # Structural, not node-level: a condition slot is invisible to a node mutator, so
  # this never fires here. `replacements/1` is the real entry point, driven by the
  # transform at each `if`/`unless`/`cond` condition. See the moduledoc.
  @impl Mutare.Mutator
  def mutate(_node), do: :skip

  @doc """
  The constant replacements for one `if`/`unless`/`cond` condition, as clean-meta
  AST nodes ready to splice into a selector clause: the pair `[true, false]`, or
  `[]` when the condition should get no mutant (a boolean operator `Conditional`
  already covers, a literal `true`/`false`/`nil`, or a binding `x = …` whose
  un-binding would poison the body). See the moduledoc for the rules.

  This is the `c:Mutare.Mutator.condition_replacements/1` hook: the transform discovers
  it by export and calls it at each `if`/`unless`/`cond` condition.
  """
  @impl Mutare.Mutator
  @spec condition_replacements(Macro.t()) :: [Macro.t()]
  def condition_replacements(condition) do
    if skip?(condition), do: [], else: [AST.literal(true), AST.literal(false)]
  end

  # --- eligibility ----------------------------------------------------------

  # A match `x = expr`: the binding leaks into the `if`/`cond`-clause body, so
  # forcing the condition to a constant would strand an unbound variable there.
  defp skip?({:=, _meta, _args}), do: true

  # A literal `true`/`false`/`nil` — degenerate, no signal (Sourceror wraps it).
  defp skip?({:__block__, _meta, [literal]}) when literal in [true, false, nil], do: true

  # A parenthesised statement *sequence* (`(a; b)`) — a leak risk like `=` and low
  # signal. A single-child `:__block__` is a literal wrapper, handled above/below.
  defp skip?({:__block__, _meta, stmts}) when length(stmts) != 1, do: true

  # A boolean-valued operator: `Conditional` already forces it to true/false at the
  # node, so a condition mutant here is pure duplication. (Covers `and`/`or`/`&&`/
  # `||`/`not`/`!` and the comparisons/membership.)
  defp skip?({op, _meta, args}) when is_atom(op) and is_list(args),
    do: Conditional.boolean_op?(op)

  # Bare (un-wrapped) literal `true`/`false`/`nil`, defensively.
  defp skip?(literal) when literal in [true, false, nil], do: true

  defp skip?(_), do: false
end
