defmodule Mutare.Transform.Scope do
  @moduledoc false

  # The **mutable lexical/emission scope** of a transform pass — the part of the threading
  # context that changes as the walk descends and is saved/restored at scope boundaries:
  #
  #   * `active_bound` — whether `Config.active_var` is already bound as a variable in the
  #     current emit scope, so an in-place selector can read it directly (`case mutare_active
  #     do …`) instead of re-reading `:persistent_term.get(...)` per site (the "hoisted
  #     active-id read"). True inside a lifted base clause (the dispatcher threads it as the
  #     first parameter) and inside a non-lifted function's `:do` block (a prologue binds it
  #     once); false at the module/scaffold level and in a head's default-value position (run
  #     in a generated head clause where no binding is in scope), where the self-contained
  #     `:persistent_term` read is kept. `Mutare.Transform.SelectorEmit.subject/1` reads this.
  #   * `module_depth` — how many nested **module** scopes (`defmodule`/`defimpl`/`defprotocol`)
  #     the emit walk is currently inside. A runtime `defmodule` in a function body is walked in
  #     place, but its inner `def` bodies are a *new* scope that can't see the outer function's
  #     hoisted `active_var` binding — so a selector emitted there must fall back to the
  #     self-contained read (`SelectorEmit.subject/1` gates the hoisted form on `module_depth
  #     == 0`). `Mutare.Transform.emit/2` increments on entering such a node, decrements on
  #     leaving; 0 at the top of every function body.
  #   * `behaviours` — the `@behaviour` set of the module the walk is currently inside (direct
  #     `@behaviour Foo` plus `use`-injected behaviours, gathered by `Mutare.Transform.Behaviours`
  #     and stamped on each `defmodule` node's meta). `Mutare.Transform` save/restores it per
  #     `defmodule` (behaviours don't inherit into nested modules) and folds it onto each spec
  #     (cached in `analysis_mutators`) so it reaches a behaviour-aware mutator's `mutate/2` /
  #     structural callbacks via the context map's `:behaviours` key. Empty outside any module.
  #   * `analysis_mutators` — `Config.mutators` folded with the current module's `behaviours`,
  #     the value the analyze/plan call sites read. Since `behaviours` changes only at a
  #     `defmodule` boundary, `Mutare.Transform` caches the enriched list here once per module
  #     scope (recomputed on entry, restored on exit) rather than recomputing it per
  #     clause/statement. `[]` is a safe default; the sole constructor primes it.
  #   * `module` — the module currently being transformed, for user options keyed
  #     by fully-qualified `{Module, function, arity}`. `nil` at file top level;
  #     `Mutare.Lifting.unresolved/0` inside a module whose `defmodule` head was dynamic
  #     (`defmodule Module.concat(...)`) — distinct values, because a module nested under
  #     an unresolvable parent must never resolve with the top-level rules (it could match
  #     an unrelated module's `:skip_lifting` entry).

  @type t :: %__MODULE__{
          active_bound: boolean(),
          module_depth: non_neg_integer(),
          behaviours: MapSet.t(module()),
          analysis_mutators: [Mutare.Mutator.Spec.t()],
          module: Mutare.Lifting.enclosing()
        }

  defstruct active_bound: false,
            module_depth: 0,
            behaviours: MapSet.new(),
            analysis_mutators: [],
            module: nil
end
