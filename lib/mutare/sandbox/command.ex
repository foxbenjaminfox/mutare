defmodule Mutare.Sandbox.Command do
  @moduledoc """
  Run `mix` against a materialised sandbox as a fresh OS process.

  Every mutant is exercised by its own `mix test` process: the sources never
  change between runs, so mix's incremental compiler finds nothing to rebuild
  and the per-mutant cost is process boot plus the suite. `MIX_ENV=test` and
  `MUTANT_UNDER_TEST=<mutant_id>` are always set; an optional `cap` (ms) bounds a
  run that overruns (a mutation can turn a terminating loop infinite).

  This module owns the *run side* of the exit-code contract — every code a mutant
  run can exit with, and what each one means:

    * `0` — every test passed: the mutation survived.
    * `failure_exit/0` — a test failed: the mutation was killed. A `mix test`
      exits with whatever `--exit-status` it was given *only* on the
      `failures > 0` path; every other failure (a compile error, a missing
      dependency, a broken `test_helper`) exits with `1` (or a signal code). So
      forcing a distinctive `--exit-status` is what separates a clean test
      failure from a harness error — they are no longer both "non-zero".
    * `timeout_exit/0` — the injected watcher self-halted a run that overran its
      cap: a `:timeout` (counted as a kill).
    * anything else — the suite never returned a verdict: a `:harness_error`,
      which says nothing about the mutation and is kept out of the score.

  `outcome/1` is the single, total decoder of that contract; `timed_test/4`
  applies the `--exit-status` flag and returns a typed `Mutare.Sandbox.Command.Result`.

  The timeout half also owns its env var (`timeout_env/0`) and the watcher that
  honours it as a dependency-free quoted AST (`watcher_ast/0`). The cap is not
  enforced by killing a process tree (which needs platform-specific signals);
  instead the watcher reads `timeout_env/0` and, after the deadline,
  `System.halt/1`s the run itself with `timeout_exit/0`. `Mutare.Sandbox` renders
  `watcher_ast/0` into the target's test bootstrap — the same way it renders
  `Mutare.Selector.bootstrap_ast/0`.
  """

  alias Mutare.Sandbox.Command.Result

  @timeout_env "MUTARE_TIMEOUT"
  @timeout_exit 124
  @failure_exit 101

  @typedoc """
  What a `mix test` mutant run did, decoded from its exit status:

    * `:passed` — exit `0`: every test passed despite the mutation.
    * `:failed` — exit `failure_exit/0`: a test failed (a clean ExUnit failure).
    * `:timeout` — exit `timeout_exit/0`: the watcher self-halted an overrun.
    * `:harness_error` — any other exit: the suite never ran to a verdict (a
      compile error, a missing dependency, a filesystem race, an OS signal). Not
      a statement about the mutation — the harness itself failed.
  """
  @type outcome :: :passed | :failed | :timeout | :harness_error

  @doc "Env var the runner sets to give a mutant run its wall-clock cap (ms)."
  @spec timeout_env() :: String.t()
  def timeout_env, do: @timeout_env

  @doc "Exit code the self-halt watcher uses, signalling a timed-out mutant."
  @spec timeout_exit() :: non_neg_integer()
  def timeout_exit, do: @timeout_exit

  @doc """
  Exit code a clean ExUnit test failure is forced to (via `mix test
  --exit-status`), so a killed mutant is distinguishable from a harness error.

  Chosen distinct from the codes a *harness* failure produces — `1` (a compile
  error, a missing dep, a broken helper, a no-tests-matched), `2` (ExUnit's
  default, were the flag ever dropped), `timeout_exit/0`, and the `128 + signal`
  range — so only a genuine test failure ever lands on it.
  """
  @spec failure_exit() :: non_neg_integer()
  def failure_exit, do: @failure_exit

  @doc """
  Decode a `mix test` mutant-run exit status into its `t:outcome/0` — the single,
  total reading of this module's exit-code contract (see the moduledoc).
  """
  @spec outcome(non_neg_integer()) :: outcome()
  def outcome(0), do: :passed
  def outcome(status) when status == @failure_exit, do: :failed
  def outcome(status) when status == @timeout_exit, do: :timeout
  def outcome(_status), do: :harness_error

  @doc """
  Dependency-free watcher that enforces a mutant run's wall-clock cap.

  Reads `timeout_env/0`: with no cap it is inert, otherwise it spawns a process
  that sleeps for the cap and then `System.halt/1`s the run with `timeout_exit/0`
  — so the run halts *itself* and there is no process tree to kill.
  `Mutare.Sandbox` renders this AST into the target project's test bootstrap,
  mirroring how it renders `Mutare.Selector.bootstrap_ast/0`, so the target needs
  nothing platform-specific and no dependency on Mutare.
  """
  @spec watcher_ast() :: Macro.t()
  def watcher_ast do
    timeout_env = @timeout_env
    timeout_exit = @timeout_exit

    quote do
      case System.get_env(unquote(timeout_env)) do
        nil ->
          :ok

        "" ->
          :ok

        raw ->
          spawn(fn ->
            Process.sleep(String.to_integer(raw))
            System.halt(unquote(timeout_exit))
          end)
      end
    end
  end

  @doc """
  Run `mix <args>` in `sandbox` as a fresh OS process, returning
  `{output, exit_status}`.

  `MIX_ENV=test` and `MUTANT_UNDER_TEST=<mutant_id>` are always set; `mutant_id`
  is the integer the metamutant switches on (`Mutare.Selector.baseline/0` for a
  baseline run), rendered into the env var here. `cap` (ms, or `nil`) is handed
  to the injected timeout watcher, which halts the run itself if it overruns — so
  there is no process tree to kill and nothing platform-specific. `extra_env` adds
  further variables (the coverage probe sets its capture flag this way).
  """
  @spec mix(Path.t(), [String.t()], non_neg_integer(), pos_integer() | nil, [
          {String.t(), String.t()}
        ]) ::
          {String.t(), non_neg_integer()}
  def mix(sandbox, args, mutant_id, cap \\ nil, extra_env \\ []) do
    env =
      [{"MIX_ENV", "test"}, {Mutare.Selector.env_var(), Integer.to_string(mutant_id)}]
      |> maybe_cap(cap)
      |> Kernel.++(extra_env)

    System.cmd("mix", args, cd: sandbox, stderr_to_stdout: true, env: env)
  end

  @doc """
  Like `mix/4`, but wall-clock-timed: returns `{elapsed_ms, output, exit_status}`.
  """
  @spec timed_mix(Path.t(), [String.t()], non_neg_integer(), pos_integer() | nil) ::
          {non_neg_integer(), String.t(), non_neg_integer()}
  def timed_mix(sandbox, args, mutant_id, cap \\ nil) do
    {micros, {output, status}} = :timer.tc(fn -> mix(sandbox, args, mutant_id, cap) end)
    {div(micros, 1000), output, status}
  end

  @doc """
  Run the suite against mutant `mutant_id`, wall-clock-timed, and return a typed
  `Mutare.Sandbox.Command.Result`.

  `test_args` are extra `mix test` arguments (`[]` = whole suite, file-granular
  args otherwise). `--exit-status #{@failure_exit}` is always injected so a clean
  test failure (the mutation was killed) is distinguishable from a harness error
  — see the moduledoc. `cap` (ms, or `nil`) bounds an overrun via the watcher.
  """
  @spec timed_test(Path.t(), [String.t()], non_neg_integer(), pos_integer() | nil) :: Result.t()
  def timed_test(sandbox, test_args, mutant_id, cap \\ nil) do
    args = ["test", "--exit-status", Integer.to_string(@failure_exit) | test_args]
    {ms, output, status} = timed_mix(sandbox, args, mutant_id, cap)

    %Result{
      outcome: outcome(status),
      exit_status: status,
      output: output,
      duration_ms: ms
    }
  end

  defp maybe_cap(env, nil), do: env
  defp maybe_cap(env, cap), do: [{@timeout_env, Integer.to_string(cap)} | env]
end
