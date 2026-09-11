defmodule Mutare.Sandbox.Command.Exit do
  @moduledoc """
  The exit codes a sandbox `mix` run can end with, and what each one means.

  A leaf on purpose: both halves of the exit-code contract read from here. The
  *producing* half is `Mutare.Sandbox.Command.Invocation` — its watcher ASTs embed
  `timeout/0` and `owner_lost/0` in the code the sandbox halts itself with — and the
  *decoding* half is `Mutare.Sandbox.Command` (`outcome/2`), which refines
  `decode/1` with the run's output. Keeping the codes below both means neither
  module needs the other to name a code.

  ## The contract

    * `0` (`success?/1`) — every test passed: the mutation survived.
    * `failure/0` — a test failed: the mutation was killed. A `mix test` exits with
      whatever `--exit-status` it was given *only* on the `failures > 0` path;
      every other failure (a compile error, a missing dependency, a broken
      `test_helper`) exits with `1` (or a signal code). So forcing a distinctive
      `--exit-status` is what separates a clean test failure from a harness error
      — they are no longer both "non-zero".
    * `timeout/0` (`timed_out?/1`) — an injected watcher self-halted a run that
      overran its cap: a `:timeout` for a mutant (counted as a kill); for the one
      compile or the coverage probe, the overrun their callers name specially.
    * `owner_lost/0` — the injected owner-death watcher self-halted a run whose
      spawning Mutare process died (`Mutare.Sandbox.Command.Invocation.owner_watch_ast/0`).
      Never *decoded*: by construction it is only ever exited with after the process
      that would read it is gone — it exists so the halt has a documented,
      recognisable code rather than an arbitrary one.
    * `sigkill/0` (`137` = `128 + 9`) — the OS killed the run with SIGKILL. A
      `:sigkilled`: a harness error by verdict (the suite never reached one), but
      recognised by code because its dominant real-world cause — the kernel OOM
      killer reaping a mutant whose mutation made it allocate unboundedly — must
      **not** be retried back-to-back the way a transient harness error is (see
      `Mutare.Runner`).
    * anything else — the suite never returned a verdict: a `:harness_error`, which
      says nothing about the mutation and is kept out of the score.

  `decode/1` is the single, total reading of the code alone. The two predicates exist
  for the sandbox runs that are *not* mutant runs — the one compile, the baseline, the
  coverage probe, the app-graph query — whose callers need only "did it succeed?" and
  "was it the cap?", never the mutant verdict vocabulary; they read the same constants,
  so the two readings cannot drift.
  """

  @success 0
  @timeout 124
  @failure 101
  @owner_lost 97
  @sigkill 137

  @typedoc "What an exit code alone says about a run (see `decode/1`)."
  @type decoded :: :passed | :failed | :timeout | :sigkilled | :harness_error

  @doc """
  Exit code a clean ExUnit test failure is forced to (via `mix test
  --exit-status`), so a killed mutant is distinguishable from a harness error.

  Chosen distinct from the codes a *harness* failure produces — `1` (a compile
  error, a missing dep, a broken helper, a no-tests-matched), `2` (ExUnit's
  default, were the flag ever dropped), `timeout/0`, and the `128 + signal`
  range — so only a genuine test failure ever lands on it.
  """
  @spec failure() :: non_neg_integer()
  def failure, do: @failure

  @doc "Exit code the self-halt watchers use, signalling a run that overran its cap."
  @spec timeout() :: non_neg_integer()
  def timeout, do: @timeout

  @doc """
  Exit code the owner-death watcher uses when a sandbox run halts itself because
  the Mutare process that spawned it died (its stdin pipe hit EOF).

  Nobody is left to decode it — the owner is gone — so unlike `timeout/0` it has
  no `decode/1` branch; it is reserved here so the halt is documented and
  distinguishable in e.g. a wrapper script's logs. Chosen outside the codes that
  carry meaning elsewhere in the contract: `0`, `1`/`2` (mix/ExUnit failures),
  `failure/0`, `timeout/0`, and the `128 + signal` range.
  """
  @spec owner_lost() :: non_neg_integer()
  def owner_lost, do: @owner_lost

  @doc """
  Exit code of a run the OS killed with SIGKILL (`137` = `128 + 9`).

  Unlike the other codes, nothing of Mutare's *produces* it — it is the kernel's,
  and its signature real-world producer is the OOM killer reaping a mutant whose
  mutation made it allocate without bound. Decoded to `:sigkilled` so the runner
  can refuse to retry it (a deterministic memory detonation re-detonates) and
  point at the mitigation (`:max_heap_mb`).
  """
  @spec sigkill() :: non_neg_integer()
  def sigkill, do: @sigkill

  @doc "Whether `status` is the clean-success exit code (`0`)."
  @spec success?(non_neg_integer()) :: boolean()
  def success?(status), do: status == @success

  @doc "Whether `status` is the code a self-halt watcher exits with past its cap."
  @spec timed_out?(non_neg_integer()) :: boolean()
  def timed_out?(status), do: status == @timeout

  @doc """
  Decode a mutant-run exit status by its code alone — the single, total reading of
  the contract in the moduledoc. `Mutare.Sandbox.Command.outcome/2` refines the
  `:harness_error` case with the run's output.
  """
  @spec decode(non_neg_integer()) :: decoded()
  def decode(status) when status == @success, do: :passed
  def decode(status) when status == @failure, do: :failed
  def decode(status) when status == @timeout, do: :timeout
  def decode(status) when status == @sigkill, do: :sigkilled
  def decode(_status), do: :harness_error
end
