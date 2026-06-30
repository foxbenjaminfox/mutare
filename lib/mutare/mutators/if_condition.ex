defmodule Mutare.Mutators.IfCondition do
  @moduledoc """
  Replaces each eligible `if`, `unless`, and `cond` condition with `true` and
  `false`.

  This family handles conditions whose boolean role comes from their position, such
  as `if user`, `if valid?(value)`, or `if Map.has_key?(map, key)`. Boolean
  operators are excluded because `Mutare.Mutators.Conditional` already produces the
  same constant replacements.

  Literal `true`, `false`, and `nil` conditions are also excluded.

  A binding condition requires special handling because its bindings may be used in
  the branch body. Bindings in `if` and `unless` conditions are hoisted before the
  condition is mutated. A binding condition in `cond` is not mutated.

  This family is enabled by default and uses the `if_condition` ignore name.
  """
  @behaviour Mutare.Mutator
  @behaviour Mutare.Mutator.Structural

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

  This is the `c:Mutare.Mutator.Structural.condition_replacements/1` hook: the transform discovers
  it by export and calls it at each `if`/`unless`/`cond` condition.
  """
  @impl Mutare.Mutator.Structural
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
