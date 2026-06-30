defmodule Mutare.Mutators.GuardDrop do
  @moduledoc """
  Removes a clause guard so the clause matches without its `when` condition:

      def f(x) when is_binary(x), do: value  →  def f(x), do: value
      case value do x when is_atom(x) -> x end  →  case value do x -> x end

  Guards on `def`, `defp`, `case`, `receive`, and `fn` clauses are eligible. A
  multi-pattern anonymous-function clause is skipped because its guardless head
  cannot be rendered as a clean report diff.

  A guard is removed only when no other enabled mutator produces a mutation inside
  it. This avoids duplicating mutations such as:

    * `x > 0`, already covered by relational and conditional mutations
    * `Integer.is_even(x)`, covered by the Integer family
    * `abs(x) > 0`, covered by relational and call-removal mutations

  Guards such as `is_binary(x)`, a bare value, or an otherwise untouched custom
  guard remain eligible. This check uses the active mutator set: disabling the
  family that covers a guard can make guard removal available.

  This family is enabled by default and uses the `guard_drop` ignore name.
  """

  # A **transform-managed** family (`Mutare.Mutators.transform_managed/0`): its mutation logic
  # lives in `Mutare.Transform` (`FunctionPlan.build_guard_drops/2` for `def`/`defp` heads,
  # `Analyze`/`ClausePatterns` for `case`/`receive`/`fn`), not in a `Mutare.Mutator` producing
  # callback — the "inert guard" rule above is decided relative to the *whole enabled mutator
  # set*, which only the transform can see. So this module deliberately does **not** implement
  # `Mutare.Mutator` (`implemented_by?/1` is false for it); it is just the family's name +
  # enablement token: registered in `Mutare.Mutators`, discovered by module identity
  # (`Spec.find/2`), and named for reports and `# mutare:ignore[guard_drop]`.
  def name, do: :guard_drop
end
