defmodule Mutare.Run do
  @moduledoc """
  The completed result of a mutation-testing run.

  `Mutare.run/2` and `Mutare.Runner.run/2` return `{:ok, %__MODULE__{}}` once the sandbox has compiled, the baseline has passed, and the per-mutant phase has produced results. Error tuples are returned before a `Mutare.Run` exists.

  ## Fields

    * `:schema` — the `Mutare.Schema` that was compiled and run. It may differ from the initially-built schema when compile-poison recovery marked mutants as poisoned.
    * `:results` — the per-mutant `Mutare.Result` values that were evaluated and reported, in source order.
    * `:sandbox` — the sandbox path where the run was materialised. For default throwaway runs this path is informational: the directory is removed before the run is returned. It remains on disk only when the caller supplied `:sandbox` or `:keep_sandbox`.
    * `:baseline_ms` — the wall-clock duration, in milliseconds, of the green baseline test run used to derive per-mutant timeout caps.
    * `:stopped_early` — whether an early-stop condition (`:max_survivors` or `:time_budget`) stopped the per-mutant phase before every mutant was evaluated, or prevented a provisional timeout from being confirmed. When true, `:results` is usually a source-order prefix rather than the full schema; if every mutant launched before the time budget elapsed, the full set may be present with one or more timeout results left unconfirmed. A survivor stop is deterministic (the first N survivors); a time-budget stop depends on how far the run got before the budget elapsed.
    * `:recovery` — a `t:recovery/0` summary when the one compile needed compile-poison recovery (some mutation would not compile, so it was dropped and the metamutant rebuilt), or `nil` when it compiled clean on the first attempt. It records how many rebuild rounds it took, which mutant ids were dropped, and any unknown block macros that were escalated (skipped wholesale). The Mix task turns the escalations into a copy-pasteable `:macro_routes` suggestion so a second run needn't rediscover the same poison — see `Mutare.Poison.Hint`.
  """

  alias Mutare.{Result, Schema}

  @typedoc """
  One unknown block macro escalated during compile-poison recovery — skipped wholesale
  because its `do` body could not host the injected selector. `:macro` is the macro
  name, `:file`/`:line` locate the invocation (`:line` is the block's first mutant line,
  or `nil`), and `:count` is how many mutants in it were dropped.
  """
  @type escalation :: %{
          macro: atom(),
          file: String.t(),
          line: pos_integer() | nil,
          count: non_neg_integer()
        }

  @typedoc """
  A compile-poison recovery summary: the number of rebuild `:rounds`, the set of
  `:dropped` mutant ids, and the `:escalated` unknown block macros.
  """
  @type recovery :: %{
          rounds: pos_integer(),
          dropped: MapSet.t(pos_integer()),
          escalated: [escalation()]
        }

  @enforce_keys [:schema, :results, :sandbox, :baseline_ms, :stopped_early]

  @type t :: %__MODULE__{
          schema: Schema.t(),
          results: [Result.t()],
          sandbox: Path.t(),
          baseline_ms: non_neg_integer(),
          stopped_early: boolean(),
          recovery: recovery() | nil
        }

  defstruct @enforce_keys ++ [recovery: nil]
end
