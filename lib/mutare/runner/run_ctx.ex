defmodule Mutare.Runner.RunCtx do
  @moduledoc false
  # The per-mutant phase's invariants, assembled once by `Mutare.Runner` after the baseline and
  # coverage probe, and threaded whole to the streaming pass (`Mutare.Runner.Stream`) and every
  # mutant's run (`Mutare.Runner.MutantRun`). Everything those two need beyond the site itself
  # lives here, so each takes `(ctx, site)` / `(ctx, results)` rather than a positional list —
  # and configuration is read from `options` (`harness_retries`, `kill_runs`, `max_heap_mb`,
  # `workers`, `max_survivors`, `confirm_timeouts`), never copied into a second field that could
  # drift.
  #
  #   * `options` — the run's validated `Mutare.Options`.
  #   * `sandbox` — the compiled sandbox every `mix test` runs in.
  #   * `selection` — the coverage probe's test selection (`Mutare.Runner.CoverageProbe.run/4`).
  #   * `cap` — the per-mutant wall-clock cap in ms.
  #   * `scopes` — the umbrella narrowing map (`Mutare.Project.app_test_scopes/3`), `%{}` otherwise.
  #   * `partitions` — the per-worker partition pool (`Mutare.Runner.Partitions`), `:disabled`
  #     when `:partition_env` is unset.
  #   * `deadline` — the monotonic instant the `:time_budget` expires, or `nil` (`Stream.deadline/1`).
  #   * `hydrate` — the deferred-diff hydrator (`Mutare.Runner.Hydrate`), or `nil` for the eager
  #     path; it fills a displayed survivor's diff code in just before it reaches the reporter.
  #   * `on_start` / `reporter` / `on_phase` — the live-progress hooks, already resolved to a
  #     no-op when unset (`Mutare.Run.Context.hook/2`).

  alias Mutare.Options

  @type t :: %__MODULE__{
          options: Options.t(),
          sandbox: Path.t(),
          selection: Mutare.Runner.CoverageProbe.selection(),
          cap: pos_integer(),
          scopes: %{optional(atom()) => [String.t()]},
          partitions: term(),
          deadline: integer() | nil,
          hydrate: %Mutare.Runner.Hydrate{} | nil,
          on_start: (term() -> any()),
          reporter: (term() -> any()),
          on_phase: (term() -> any())
        }

  @enforce_keys [
    :options,
    :sandbox,
    :selection,
    :cap,
    :scopes,
    :partitions,
    :deadline,
    :on_start,
    :reporter,
    :on_phase
  ]
  defstruct @enforce_keys ++ [hydrate: nil]
end
