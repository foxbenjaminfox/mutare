defmodule Mutare.Mutator.Structural do
  @moduledoc """
  Behaviour for a **structural mutator** — one whose target is a *position* rather than a
  single AST node: a `def`/`defp` clause **return value**, an `if`/`unless`/`cond`
  **condition**, or a `def`/`defp` **head pattern** as a whole.

  A plain `Mutare.Mutator` matches a node with `c:Mutare.Mutator.mutate/1` and rewrites it.
  Some targets aren't a node you can pattern-match: a return value is whatever sits in a
  clause's tail, wherever that falls; a head pattern spans several argument positions at once.
  For those you implement one of the callbacks below, and the transform applies it at every
  matching position, recording each mutant under your `c:Mutare.Mutator.name/0`. The built-in
  `Mutare.Mutators.ReturnValue`, `Mutare.Mutators.IfCondition`, `Mutare.Mutators.PatternSwap`,
  and `Mutare.Mutators.PatternWildcard` are structural mutators — yours participates exactly
  as they do.

  A structural mutator is still a `Mutare.Mutator`, so declare **both** behaviours and a
  `name/0`. There's no `c:Mutare.Mutator.mutate/1` to write — the structural callback *is* the
  mutation producer:

      defmodule MyApp.Mutators.AlwaysReturnNil do
        @behaviour Mutare.Mutator
        @behaviour Mutare.Mutator.Structural

        @impl Mutare.Mutator
        def name, do: :always_nil

        @impl Mutare.Mutator.Structural
        def return_replacements(_tail), do: [Mutare.AST.literal(nil)]
      end

  The three callbacks are independent — implement whichever positions you want to target:

    * `c:return_replacements/1` — replace a clause's return value;
    * `c:condition_replacements/1` — replace an `if`/`unless`/`cond` condition;
    * `c:pattern_mutations/2` — restructure a `def`/`defp` head's patterns.

  Build replacement literals with `Mutare.AST.literal/1` rather than by hand.
  `test/support/structural_mutator.ex` is a working example.

  ## Behaviour-aware variants

  Each callback has a `+1`-arity variant that also receives the enclosing module's
  `@behaviour` set (a `t:context/0`), so a mutator can fire only inside modules that implement
  a given behaviour — say a GenServer return-tuple mutator that rewrites a `handle_call` tail
  only under `@behaviour GenServer`. Implement *either* the base arity *or* the context arity;
  the transform uses the context arity whenever you provide it. The behaviour set covers both
  direct `@behaviour Foo` and `use`-injected behaviours, exactly as `c:Mutare.Mutator.mutate/2`
  receives it under `context.behaviours`.
  """

  @typedoc """
  Context passed to the behaviour-aware structural callbacks (`c:return_replacements/2`,
  `c:condition_replacements/2`, `c:pattern_mutations/3`). Carries the enclosing module's
  `:behaviours` — a `MapSet` of the behaviour modules it implements — so a structural mutator
  can gate on them exactly as `c:Mutare.Mutator.mutate/2` does.
  """
  @type context :: %{behaviours: MapSet.t(module())}

  @doc """
  Optional hook for restructuring a `def`/`defp` clause **head pattern** as a whole —
  mutations that `c:Mutare.Mutator.mutate/1` can't express because they span sibling argument
  positions or repeated variables (variable swaps, duplicate-variable wildcarding).

  Called with the clause's head argument patterns and `used_outside` (the set of variable
  names the clause body and guard read). Return a list of mutated argument lists, one per
  mutant. Every list you return must be a **pattern-legal, compile-safe** head — the transform
  splices it back as a clause head. See `Mutare.Mutators.PatternSwap` and
  `Mutare.Mutators.PatternWildcard`.
  """
  @callback pattern_mutations(head_args :: [Macro.t()], used_outside :: MapSet.t()) ::
              [[Macro.t()]]

  @doc """
  Behaviour-aware variant of `c:pattern_mutations/2`, also receiving the `t:context/0`
  (`%{behaviours: …}`) so head-pattern mutations can gate on the enclosing module's
  behaviours. Implement *this* arity instead of `/2`; the transform uses it when you provide
  it, otherwise `/2`.
  """
  @callback pattern_mutations(
              head_args :: [Macro.t()],
              used_outside :: MapSet.t(),
              context :: context()
            ) :: [[Macro.t()]]

  @doc """
  Optional hook for mutating a **clause return value** — the expression a `def`/`defp` clause
  (or a `rescue`/`catch`/`else` clause) returns. Called with the tail node; return the
  replacement nodes (one per mutant) as clean-meta AST ready to splice (see
  `Mutare.AST.literal/1`). `Mutare.Mutators.ReturnValue` is the built-in. Return `[]` for a
  tail you don't want to mutate.
  """
  @callback return_replacements(tail :: Macro.t()) :: [Macro.t()]

  @doc """
  Behaviour-aware variant of `c:return_replacements/1`, also receiving the `t:context/0`
  (`%{behaviours: …}`). Implement *this* arity to gate return-value mutations on the enclosing
  module's behaviours — for example a GenServer mutator that swaps a `handle_call`
  `{:reply, r, s}` tail to `{:noreply, s}` only when the module implements `GenServer`. The
  transform uses `/2` when you provide it, otherwise `/1`.
  """
  @callback return_replacements(tail :: Macro.t(), context :: context()) ::
              [Macro.t()]

  @doc """
  Optional hook for mutating an **`if`/`unless`/`cond` condition**. Called with the condition
  node; return the replacement nodes (one per mutant). The condition-position twin of
  `c:return_replacements/1`. `Mutare.Mutators.IfCondition` is the built-in (it forces the
  condition to `true`/`false`). Return `[]` to skip.
  """
  @callback condition_replacements(condition :: Macro.t()) :: [Macro.t()]

  @doc """
  Behaviour-aware variant of `c:condition_replacements/1`, also receiving the `t:context/0`
  (`%{behaviours: …}`). Implement *this* arity to gate condition mutations on the enclosing
  module's behaviours. The transform uses `/2` when you provide it, otherwise `/1`.
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
