defmodule Mutare.Mutators.ClauseDrop do
  @moduledoc """
  Removes one clause of a multi-clause function, so inputs it handled fall through to a later clause (or raise `FunctionClauseError`):

      def f(0), do: :zero      →      def f(n), do: n + 1
      def f(n), do: n + 1

  Each body-bearing clause of a `def`/`defp` group is offered in turn. It asks directly whether any test pins the clause's own behaviour, rather than the behaviour of whatever it shadows.

  Two conditions narrow it:

    * At least two body-bearing clauses must remain in play — a single-clause function has nothing to fall through to.
    * A **bodiless head** (`def f(a, b)` with no `do`, declaring default arguments or carrying docs) is never dropped. It is not a clause, so dropping it is a no-op, and dropping the implementation while the header remains leaves a `defp` with no body — "implementation not provided", a compile error that would poison the build.

  `rescue` clause removal is a separate concern and belongs to the `rescue_type` family.

  This family is enabled by default and uses the `clause_drop` ignore name.
  """

  # A **transform-managed** family (`Mutare.Mutators.transform_managed/0`): its mutation logic
  # lives in `Mutare.Transform` (`FunctionPlan.build_drops/2`), not in a `Mutare.Mutator`
  # producing callback — a dropped clause is a *whole-clause* structural edit delivered by
  # lifting, decided over a clause group rather than at any single node, so there is no
  # `node -> [mutation]` shape to implement. Like `GuardDrop` and `RescueType`, this module
  # deliberately does **not** implement `Mutare.Mutator` (`implemented_by?/1` is false for it);
  # it is just the family's name + enablement token: registered in `Mutare.Mutators`,
  # discovered by module identity (`Spec.find/2`), and named for reports and
  # `# mutare:ignore[clause_drop]`.
  def name, do: :clause_drop
end
