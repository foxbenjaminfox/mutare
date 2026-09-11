defmodule Mutare.Transform.Analyze.Env do
  @moduledoc false

  # The analyze pass's environment: what `Mutare.Transform.Analyze` carries unchanged to every
  # node of one descent, alongside the liveness `context` (`:runtime`/`:pattern`/`:scaffold`/…)
  # it threads positionally.
  #
  #   * `mutators` — the resolved, behaviour-enriched `Mutare.Mutator.Spec`s each node is offered
  #     to. `Mutare.Transform.Scope.analysis_env` caches the per-module enrichment.
  #   * `cond_var` — the file's collision-free temp for a *refutable* `if`/`unless` condition
  #     hoist (`Mutare.Transform.Names`, pinned as `Config.cond_var`), so
  #     `Mutare.Transform.Analyze.Conditions` spells the hoisted binding directly. `nil` when no
  #     such name is available — collect mode (`Mutare.Analyze.expression_mutations/3`) — in
  #     which case only bare-variable hoists, which reuse their own name, are possible.
  #
  # Dispatch-only leaves (`Attach`, `Captures`, `Returns`, `Tag`, `PatternStructure`) take the
  # bare `mutators` list; only the modules that re-enter the descent take the env.

  @type t :: %__MODULE__{
          mutators: [Mutare.Mutator.Spec.t()],
          cond_var: atom() | nil
        }

  defstruct mutators: [], cond_var: nil
end
