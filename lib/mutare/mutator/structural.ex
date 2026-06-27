defmodule Mutare.Mutator.Structural do
  @moduledoc """
  Behaviour for a **structural mutator** — one whose target is a *position* no single AST node
  identifies: a `def`/`defp` clause **return tail**, an `if`/`unless`/`cond` **condition**, or a
  `def`/`defp` **head pattern** as a whole.

  A node-level `Mutare.Mutator` matches a node with `c:Mutare.Mutator.mutate/1` and rewrites it.
  A structural mutator can't — the thing it mutates is not a node a `mutate/1` clause could
  pattern-match (a return position is a clause's tail wherever it sits; a head pattern spans
  sibling argument positions). So the transform *names* each such position as it descends and asks
  every enabled mutator implementing the matching callback here, discovered by export
  (`Mutare.Mutator.Dispatch.implementing/3`) rather than hardcoded. Each result is delivered by the
  transform — **in place** for return/condition, by **lifting** for head patterns — and recorded
  under the mutator's own `c:Mutare.Mutator.name/0`. The built-in `Mutare.Mutators.ReturnValue` /
  `Mutare.Mutators.IfCondition` / `Mutare.Mutators.PatternSwap` / `Mutare.Mutators.PatternWildcard`
  participate exactly as a custom mutator does.

  A structural mutator is still a `Mutare.Mutator` (it needs `name/0`); declare **both**:

      defmodule MyApp.Mutators.AlwaysReturnNil do
        @behaviour Mutare.Mutator
        @behaviour Mutare.Mutator.Structural

        @impl Mutare.Mutator
        def name, do: :always_nil

        @impl Mutare.Mutator.Structural
        def return_replacements(_tail), do: [Mutare.AST.literal(nil)]
      end

  `test/support/structural_mutator.ex` is a working example.

  ## Behaviour-aware variants

  Each callback has a `+1`-arity variant taking the structural `t:context/0` — the enclosing
  module's `@behaviour` set — so a structural mutator can gate on it (a GenServer return-tuple
  mutator that rewrites a `handle_call` tail only under `@behaviour GenServer`). Implement *either*
  the base arity *or* the context arity; the transform prefers the context arity when exported. The
  behaviour set is gathered by `Mutare.Transform.Behaviours` from direct `@behaviour Foo` and
  `use`-injected ones, exactly as `c:Mutare.Mutator.mutate/2` receives it under `context.behaviours`.
  """

  @typedoc """
  Context threaded to the behaviour-aware structural callbacks
  (`c:return_replacements/2`, `c:condition_replacements/2`, `c:pattern_mutations/3`). Carries the
  enclosing module's `:behaviours` set (a `MapSet` of module atoms), so a structural mutator can
  gate on the module's behaviours exactly as `c:Mutare.Mutator.mutate/2` does. (A structural
  position has no pipe context and structural mutators take no `opts`, so this is the lone key — the
  transform may add more in future.)
  """
  @type context :: %{behaviours: MapSet.t(module())}

  @doc """
  Optional structural hook for mutating a `def`/`defp` clause **head pattern** as a
  whole — restructurings that `c:Mutare.Mutator.mutate/1` can't express because they span sibling
  positions or repeated variables (variable swaps, duplicate-variable wildcarding).

  Given a clause's head argument patterns and `used_outside` (the set of variable names
  read in the clause body/guard), it returns a list of mutated argument lists, one per
  mutant. `Mutare.Transform.FunctionPlan` discovers implementers by
  `function_exported?(mod, :pattern_mutations, 2)` and delivers each by lifting (a
  selector `case` is illegal in a pattern), so an implementer must return only
  *pattern-legal*, compile-safe argument lists. See `Mutare.Mutators.PatternSwap` and
  `Mutare.Mutators.PatternWildcard`. A mutator without this callback simply takes no
  part in head-pattern restructuring.
  """
  @callback pattern_mutations(head_args :: [Macro.t()], used_outside :: MapSet.t()) ::
              [[Macro.t()]]

  @doc """
  Behaviour-aware variant of `c:pattern_mutations/2`, taking the structural `t:context/0`
  (`%{behaviours: …}`). Implement *this* arity instead of `/2` to gate head-pattern
  mutations on the enclosing module's behaviours. The transform prefers `/3` when
  exported, falling back to `/2`; a mutator need implement only one.
  """
  @callback pattern_mutations(
              head_args :: [Macro.t()],
              used_outside :: MapSet.t(),
              context :: context()
            ) :: [[Macro.t()]]

  @doc """
  Optional structural hook for mutating a **clause return tail** — the expression a
  `def`/`defp` clause (or a `rescue`/`catch`/`else` clause) returns. Given the raw tail
  node, return the replacement nodes (one per mutant), as clean-meta AST ready to splice.

  Like `c:pattern_mutations/2` this is *structural* — a return position is not a node any
  `c:Mutare.Mutator.mutate/1` could match, so the transform names the position and asks every
  enabled mutator implementing this callback (discovered by
  `function_exported?(mod, :return_replacements, 1)`), delivering each replacement by the in-place
  selector. `Mutare.Mutators.ReturnValue` is the built-in; a custom mutator implementing it
  participates at the same positions, its name recorded on the site. Return `[]` for a tail that
  should get no mutant.
  """
  @callback return_replacements(tail :: Macro.t()) :: [Macro.t()]

  @doc """
  Behaviour-aware variant of `c:return_replacements/1`, taking the structural `t:context/0`
  (`%{behaviours: …}`). Implement *this* arity instead of `/1` to gate return-tail
  mutations on the enclosing module's behaviours — the motivating GenServer case (swap a
  `handle_call` `{:reply, r, s}` tail to `{:noreply, s}` only when the module implements
  `GenServer`). The transform prefers `/2` when exported, falling back to `/1`.
  """
  @callback return_replacements(tail :: Macro.t(), context :: context()) ::
              [Macro.t()]

  @doc """
  Optional structural hook for mutating an **`if`/`unless`/`cond` condition**. Given the raw
  condition node, return the replacement nodes (one per mutant). The condition-position twin
  of `c:return_replacements/1`: structural, discovered by
  `function_exported?(mod, :condition_replacements, 1)`, delivered in place.
  `Mutare.Mutators.IfCondition` is the built-in (forcing the condition `true`/`false`); a
  custom mutator implementing it participates at the same positions. Return `[]` to skip.
  """
  @callback condition_replacements(condition :: Macro.t()) :: [Macro.t()]

  @doc """
  Behaviour-aware variant of `c:condition_replacements/1`, taking the structural `t:context/0`
  (`%{behaviours: …}`). Implement *this* arity instead of `/1` to gate condition mutations
  on the enclosing module's behaviours. The transform prefers `/2` when exported, falling
  back to `/1`.
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
