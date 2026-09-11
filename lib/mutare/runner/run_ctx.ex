defmodule Mutare.Runner.RunCtx do
  @moduledoc false
  # The per-run invariants threaded to every mutant's `Mutare.Runner.MutantRun.classify/3` and the
  # streaming pass (`Mutare.Runner.Stream`): the one `sandbox`, the coverage `selection`, the timeout
  # `cap`, the umbrella `scopes`, and the initial `retries` budget. Bundled so those functions take
  # this plus the per-task `site`/`env` rather than a long positional list — and so the general
  # `retries` budget rides a *named* field where the public `MutantRun.classify/3` first supplies the
  # two budgets (`ctx.retries` and the boot-failure budget), which can't then be confused.
  @enforce_keys [:sandbox, :selection, :cap, :scopes, :retries, :kill_runs]
  # `hydrate` is the deferred-diff hydrator (`Mutare.Runner.Hydrate`), or `nil` for the eager
  # path; it fills a displayed survivor's diff code in just before it reaches the reporter.
  # `max_heap_mb` is the `:max_heap_mb` heap cap (`nil` when off) every per-mutant run is
  # invoked with — the per-task `partition` carries only the partition slot, so the cap
  # rides here with the other per-run invariants.
  defstruct @enforce_keys ++ [hydrate: nil, max_heap_mb: nil]
end
