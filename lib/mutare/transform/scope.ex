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
  #   * `block_macro` — the `{name, nid}` identity of the *unknown* module-level block macro
  #     (`custom_dsl do … end`) whose `do` body the emit walk is currently inside, or `nil`.
  #     `Mutare.Transform.emit_block_macro/2` binds it for the body's emit and restores it after;
  #     `Mutare.Transform.ClaimState.claim/6` stamps it onto every `Mutare.Site` claimed
  #     meanwhile (`Site.block_macro`), so poison recovery can skip the whole invocation at once.
  #   * `active_referenced` — whether the emit has referenced the hoisted `active_var` binding
  #     since the flag was last reset: a selector read it as its subject
  #     (`Mutare.Transform.SelectorEmit.subject/1`), or a per-clause delivery read it directly in
  #     a gate or a creation-time coverage record (`SelectorEmit.reference_active/1`). The reader
  #     that must decide whether the binding exists at all resets it first and reads it after the
  #     enclosed emit: `Mutare.Transform.emit_clause_body/3` for a non-lifted `:do` block's
  #     prologue (an unreferenced binding would warn "unused"), `emit_function_plan/2` for whether
  #     a group with no lifted mutant still needs its dispatcher. Meaningful only between such a
  #     reset and its read; a nested module scope never sets it (its selectors use the inline
  #     read, `module_depth`), so a reference there never adds an outer prologue.

  @type t :: %__MODULE__{
          active_bound: boolean(),
          module_depth: non_neg_integer(),
          behaviours: MapSet.t(module()),
          analysis_mutators: [Mutare.Mutator.Spec.t()],
          module: Mutare.Lifting.enclosing(),
          block_macro: {atom(), non_neg_integer()} | nil,
          active_referenced: boolean()
        }

  defstruct active_bound: false,
            module_depth: 0,
            behaviours: MapSet.new(),
            analysis_mutators: [],
            module: nil,
            block_macro: nil,
            active_referenced: false

  @doc """
  Whether a selector emitted in this scope can read the hoisted active-id variable directly:
  the variable is bound (`active_bound`) *and* the walk is not inside a runtime nested module
  (`module_depth == 0`), whose function bodies can't see the outer binding. The one definition
  every emit path consults before choosing the hoisted form over the self-contained read.
  Emitted code that reads the variable must record the reference
  (`Mutare.Transform.SelectorEmit.reference_active/1`), or the enclosing clause may not bind it.
  """
  @spec active_var_bound?(t()) :: boolean()
  def active_var_bound?(%__MODULE__{active_bound: bound, module_depth: depth}),
    do: bound and depth == 0
end
