defmodule Mutare.Sandbox.Command do
  @moduledoc """
  Run `mix` against a materialised sandbox as a fresh OS process.

  Every mutant is exercised by its own `mix test` process: the sources never
  change between runs, so mix's incremental compiler finds nothing to rebuild
  and the per-mutant cost is process boot plus the suite. `MIX_ENV=test` and
  `MUTANT_UNDER_TEST=<mutant_id>` are always set; an optional `cap` (ms) bounds a
  run that overruns (a mutation can turn a terminating loop infinite).

  This module owns the *run side* of the timeout contract, all three pieces side
  by side: the env var the cap travels in (`timeout_env/0`), the exit code a
  timeout is signalled with (`timeout_exit/0`), and the watcher that honours them
  as a dependency-free quoted AST (`watcher_ast/0`). The cap is not enforced by
  killing a process tree (which needs platform-specific signals); instead the
  watcher reads `timeout_env/0` and, after the deadline, `System.halt/1`s the run
  itself with `timeout_exit/0`. `Mutare.Sandbox` renders `watcher_ast/0` into the
  target's test bootstrap — the same way it renders `Mutare.Selector.bootstrap_ast/0`
  — and the runner reads `timeout_exit/0` to classify a capped run as `:timeout`.
  """

  @timeout_env "MUTARE_TIMEOUT"
  @timeout_exit 124

  @doc "Env var the runner sets to give a mutant run its wall-clock cap (ms)."
  @spec timeout_env() :: String.t()
  def timeout_env, do: @timeout_env

  @doc "Exit code the self-halt watcher uses, signalling a timed-out mutant."
  @spec timeout_exit() :: non_neg_integer()
  def timeout_exit, do: @timeout_exit

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

  `MIX_ENV=test` and `MUTANT_UNDER_TEST=<mutant_id>` are always set. `cap` (ms,
  or `nil`) is handed to the injected timeout watcher, which halts the run itself
  if it overruns — so there is no process tree to kill and nothing
  platform-specific.
  """
  @spec mix(Path.t(), [String.t()], String.t(), pos_integer() | nil) ::
          {String.t(), non_neg_integer()}
  def mix(sandbox, args, mutant_id, cap \\ nil) do
    env =
      [{"MIX_ENV", "test"}, {Mutare.Selector.env_var(), mutant_id}]
      |> maybe_cap(cap)

    System.cmd("mix", args, cd: sandbox, stderr_to_stdout: true, env: env)
  end

  @doc """
  Like `mix/4`, but wall-clock-timed: returns `{elapsed_ms, output, exit_status}`.
  """
  @spec timed_mix(Path.t(), [String.t()], String.t(), pos_integer() | nil) ::
          {non_neg_integer(), String.t(), non_neg_integer()}
  def timed_mix(sandbox, args, mutant_id, cap \\ nil) do
    {micros, {output, status}} = :timer.tc(fn -> mix(sandbox, args, mutant_id, cap) end)
    {div(micros, 1000), output, status}
  end

  defp maybe_cap(env, nil), do: env
  defp maybe_cap(env, cap), do: [{@timeout_env, Integer.to_string(cap)} | env]
end
