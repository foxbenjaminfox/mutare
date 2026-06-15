defmodule Mutare.Sandbox.Command.Result do
  @moduledoc """
  The typed outcome of one `mix test` mutant run.

  A raw exit status is ambiguous: a non-zero code can mean a test failed (the
  mutation was caught) *or* that the harness never reached a verdict at all (a
  compile error, a missing dependency, a filesystem race). Collapsing both into
  "non-zero ⇒ killed" silently inflates the score with infrastructure failures.

  So `Mutare.Sandbox.Command` decodes the exit status against the run-side
  contract it owns (`outcome/1`) and hands back this struct, whose `outcome`
  *names* what happened. The runner maps that name onto a `Mutare.Result.status`
  — and an `:harness_error` is kept out of the score's denominator, never
  miscounted as a kill. `exit_status` is retained for diagnostics.
  """

  alias Mutare.Sandbox.Command

  @type t :: %__MODULE__{
          outcome: Command.outcome(),
          exit_status: non_neg_integer(),
          output: String.t(),
          duration_ms: non_neg_integer() | nil
        }

  defstruct [:outcome, :exit_status, :output, :duration_ms]
end
