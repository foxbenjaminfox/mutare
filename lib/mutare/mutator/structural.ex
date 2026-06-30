defmodule Mutare.Mutator.Structural do
  @moduledoc """
  Behaviour for mutating positions that are larger than a single AST node: clause return values,
  `if`/`unless`/`cond` conditions, and function-head patterns.

  Declare both `Mutare.Mutator` and this behaviour, define `name/0`, then implement whichever
  structural callbacks you need. A structural mutator does not need `c:Mutare.Mutator.mutate/1`.

      defmodule MyApp.Mutators.AlwaysReturnNil do
        @behaviour Mutare.Mutator
        @behaviour Mutare.Mutator.Structural

        @impl Mutare.Mutator
        def name, do: :always_nil

        @impl Mutare.Mutator.Structural
        def return_replacements(_tail), do: [Mutare.AST.literal(nil)]
      end

  Each callback also has a context-taking arity for restricting mutations by the enclosing
  module's `@behaviour` set. Implement either the base arity or its context-taking counterpart.
  """

  @typedoc """
  Context passed to the behaviour-aware structural callbacks (`c:return_replacements/2`,
  `c:condition_replacements/2`, `c:pattern_mutations/3`). Carries the enclosing module's
  `:behaviours` — a `MapSet` of the behaviour modules it implements — so a structural mutator
  can gate on them exactly as `c:Mutare.Mutator.mutate/2` does.
  """
  @type context :: %{behaviours: MapSet.t(module())}

  @doc """
  Returns whole-head pattern replacements for a `def` or `defp` clause.

  `head_args` contains the clause argument patterns. `used_outside` contains
  variable names read by the guard or body. Each returned argument list must be a
  valid, compile-safe clause head.
  """
  @callback pattern_mutations(head_args :: [Macro.t()], used_outside :: MapSet.t()) ::
              [[Macro.t()]]

  @doc """
  Context-aware form of `pattern_mutations/2`.

  Implement this form to use the enclosing module's behaviours. When exported, it
  takes precedence over `pattern_mutations/2`.
  """
  @callback pattern_mutations(
              head_args :: [Macro.t()],
              used_outside :: MapSet.t(),
              context :: context()
            ) :: [[Macro.t()]]

  @doc """
  Returns replacements for a clause return expression.

  Each result must be clean-meta AST suitable for direct insertion. Return `[]`
  when the expression is not eligible.
  """
  @callback return_replacements(tail :: Macro.t()) :: [Macro.t()]

  @doc """
  Context-aware form of `return_replacements/1`.

  Implement this form to use the enclosing module's behaviours. When exported, it
  takes precedence over `return_replacements/1`.
  """
  @callback return_replacements(tail :: Macro.t(), context :: context()) ::
              [Macro.t()]

  @doc """
  Returns replacements for an `if`, `unless`, or `cond` condition.

  Return `[]` when the condition is not eligible.
  """
  @callback condition_replacements(condition :: Macro.t()) :: [Macro.t()]

  @doc """
  Context-aware form of `condition_replacements/1`.

  Implement this form to use the enclosing module's behaviours. When exported, it
  takes precedence over `condition_replacements/1`.
  """
  @callback condition_replacements(condition :: Macro.t(), context :: context()) ::
              [Macro.t()]

  @optional_callbacks pattern_mutations: 2,
                      pattern_mutations: 3,
                      return_replacements: 1,
                      return_replacements: 2,
                      condition_replacements: 1,
                      condition_replacements: 2
end
