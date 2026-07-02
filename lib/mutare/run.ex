defmodule Mutare.Run do
  @moduledoc """
  The completed result of a mutation-testing run.

  `Mutare.run/2` and `Mutare.Runner.run/2` return `{:ok, %__MODULE__{}}` once the sandbox has compiled, the baseline has passed, and the per-mutant phase has produced results. Error tuples are returned before a `Mutare.Run` exists.

  ## Fields

    * `:schema` — the `Mutare.Schema` that was compiled and run. It may differ from the initially-built schema when compile-poison recovery marked mutants as poisoned.
    * `:results` — the per-mutant `Mutare.Result` values that were evaluated and reported, in source order.
    * `:sandbox` — the sandbox path where the run was materialised. For default throwaway runs this path is informational: the directory is removed before the run is returned. It remains on disk only when the caller supplied `:sandbox` or `:keep_sandbox`.
    * `:baseline_ms` — the wall-clock duration, in milliseconds, of the green baseline test run used to derive per-mutant timeout caps.
    * `:stopped_early` — whether `:max_survivors` stopped the per-mutant phase before every mutant was evaluated. When true, `:results` is a deterministic source-order prefix, not the full schema.
  """

  alias Mutare.{Result, Schema}

  @enforce_keys [:schema, :results, :sandbox, :baseline_ms, :stopped_early]

  @type t :: %__MODULE__{
          schema: Schema.t(),
          results: [Result.t()],
          sandbox: Path.t(),
          baseline_ms: non_neg_integer(),
          stopped_early: boolean()
        }

  defstruct @enforce_keys
end
