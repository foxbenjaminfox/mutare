defmodule Mutare.Mutators.IfCondition do
  @moduledoc """
  Force an `if`/`unless`/`cond` **condition** to the constants `true` and `false` —
  the "remove the decision" mutation, asked of every branch the suite gates: *is
  each side of this condition actually exercised?* A condition pinned to one
  constant that no test notices is a precisely located gap.

  This is the positional sibling of `Mutare.Mutators.Conditional`: where that family
  fires only where a node *proves* it is boolean-valued (a comparison/membership/
  logical operator), this fires on a **bare** condition (`if user`, `if valid?(x)`,
  `if is_nil(v)`, `if Map.has_key?(m, k)`) that is positionally a boolean decision.
  On by default, named in reports, selectable via `:mutators`, and filterable by
  `# mutare:ignore[if_condition]`, like every family.

  ## Deliberately left alone

    * **Boolean-operator conditions** — a comparison / membership / `and`/`or` /
      `&&`/`||` / `not`/`!`. `Conditional` already forces these to `true`/`false`,
      so a condition mutant here would just duplicate it.
    * **A literal `true`/`false`/`nil` condition** — forcing `if true` to `true` is
      a no-op and to `false` is dead-code removal; both are degenerate, low signal.
    * **A binding condition** — `if user = fetch()`. The condition's bindings leak
      into the body, so the decision can't simply be replaced in place. (For an
      `if`/`unless` the transform hoists the binding out and mutates the condition
      anyway; a `cond` binding condition is left unmutated.)
  """
  @behaviour Mutare.Mutator

  alias Mutare.AST
  alias Mutare.Mutators.Conditional

  @impl Mutare.Mutator
  def name, do: :if_condition

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
