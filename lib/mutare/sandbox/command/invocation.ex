defmodule Mutare.Sandbox.Command.Invocation do
  @moduledoc """
  Spawn `mix` against a materialised sandbox as a fresh OS process.

  Every mutant is exercised by its own `mix test` process: the sources never
  change between runs, so mix's incremental compiler finds nothing to rebuild
  and the per-mutant cost is process boot plus the suite. `MIX_ENV=test` and
  `MUTANT_UNDER_TEST=<mutant_id>` are always set; an optional `cap` (ms) bounds a
  run that overruns (a mutation can turn a terminating loop infinite).

  This module owns everything about *how a run is invoked*: the environment it
  runs under (`mix_env/0`, the reserved variable set in `reserved_env_names/0`,
  the self-hosting isolation vars), the raw spawn (`mix/4`/`timed_mix/5`), and the
  **timeout enforcement mechanism** — the env var the cap travels in
  (`timeout_env/0`) and the dependency-free watcher AST (`watcher_ast/0`) that
  `Mutare.Sandbox` renders into the target's test bootstrap. The matching half —
  *decoding* what a run did from its exit code, including the `timeout_exit/0` the
  watcher signals — is `Mutare.Sandbox.Command`; `Mutare.Sandbox.Command.timed_test/4`
  composes the two (run here, decode there).

  The cap is not enforced by killing a process tree (which needs platform-specific
  signals); instead the watcher reads `timeout_env/0` and, after the deadline,
  `System.halt/1`s the run itself with `Mutare.Sandbox.Command.timeout_exit/0`.
  """

  @timeout_env "MUTARE_TIMEOUT"
  @mix_env "test"

  @doc """
  The `MIX_ENV` every sandbox `mix` runs under (`"test"`). The single home for the value,
  so `Mutare.Sandbox` (which builds `_build/<env>/lib` paths) and `Mutare.Transform.Uses`
  share it rather than re-hardcoding the string.
  """
  @spec mix_env() :: String.t()
  def mix_env, do: @mix_env

  @doc "Env var the runner sets to give a mutant run its wall-clock cap (ms)."
  @spec timeout_env() :: String.t()
  def timeout_env, do: @timeout_env

  @doc """
  Run `mix <args>` in `sandbox` as a fresh OS process, returning
  `{output, exit_status}`.

  `MIX_ENV=test` and `MUTANT_UNDER_TEST=<mutant_id>` are always set; `mutant_id`
  is the integer the metamutant switches on (`Mutare.Selector.baseline/0` for a
  baseline run), rendered into the env var here. `opts`:

    * `:cap` (ms, or `nil`) — handed to the injected timeout watcher, which halts
      the run itself if it overruns, so there is no process tree to kill and
      nothing platform-specific.
    * `:env` — further environment variables (the coverage probe sets its capture
      flag this way).
  """
  @spec mix(Path.t(), [String.t()], non_neg_integer(),
          cap: pos_integer() | nil,
          env: [{String.t(), String.t()}]
        ) :: {String.t(), non_neg_integer()}
  def mix(sandbox, args, mutant_id, opts \\ []) do
    env =
      [
        {"MIX_ENV", @mix_env},
        {Mutare.Selector.env_var(), Integer.to_string(mutant_id)},
        # Self-hosting isolation: give the suite-under-test a private selection
        # key so its own `Selector.put/1` calls can't clobber the harness's
        # active-mutant slot. Inert on a normal target (no `Mutare.Selector`
        # compiled in); see `Mutare.Selector`'s moduledoc.
        {Mutare.Selector.override_env(), Mutare.Selector.suite_key()},
        # The same isolation for the coverage helper module name: give the
        # suite-under-test's `test/support/mutare_cov.ex` stand-in a private name so
        # it can't co-define `:mutare_cov` with the real helper the sandbox writes
        # (a clash that breaks the probe's `dump/1`). Inert on a normal target (no
        # such stand-in compiled in); see `Mutare.Coverage.Recorder`'s moduledoc.
        {Mutare.Coverage.Recorder.fixture_override_env(),
         Mutare.Coverage.Recorder.suite_fixture_module()}
      ]
      |> maybe_cap(opts[:cap])
      |> Kernel.++(opts[:env] || [])

    System.cmd("mix", args, cd: sandbox, stderr_to_stdout: true, env: env)
  end

  @doc """
  The environment variable names Mutare itself sets on a sandbox `mix` — the base
  env in `mix/4` plus the cap (`timeout_env/0`) and the coverage-probe vars folded
  in via `:env`. The authoritative reserved set: `Mutare.Options` rejects a
  `:partition_env` that collides with one of these, since the partition entry is
  *appended* to this list and a duplicate key's resolution is unspecified (it would
  silently clobber e.g. `MIX_ENV`). Sourced from the same accessors the env is
  built from, so it can't drift.
  """
  @spec reserved_env_names() :: [String.t()]
  def reserved_env_names do
    [
      "MIX_ENV",
      @timeout_env,
      Mutare.Selector.env_var(),
      Mutare.Selector.override_env(),
      Mutare.Coverage.Recorder.env_var(),
      Mutare.Coverage.Recorder.dump_path_env(),
      Mutare.Coverage.Recorder.root_env(),
      Mutare.Coverage.Recorder.fixture_override_env()
    ]
  end

  @doc """
  Like `mix/4`, but wall-clock-timed: returns `{elapsed_ms, output, exit_status}`.

  `env` is extra environment passed straight through to `mix/4` (the runner uses
  it to set a per-worker partition var, e.g. `MIX_TEST_PARTITION`); `[]` adds none.
  """
  @spec timed_mix(Path.t(), [String.t()], non_neg_integer(), pos_integer() | nil, [
          {String.t(), String.t()}
        ]) ::
          {non_neg_integer(), String.t(), non_neg_integer()}
  def timed_mix(sandbox, args, mutant_id, cap \\ nil, env \\ []) do
    {micros, {output, status}} =
      :timer.tc(fn -> mix(sandbox, args, mutant_id, cap: cap, env: env) end)

    {div(micros, 1000), output, status}
  end

  @doc """
  Dependency-free watcher that enforces a mutant run's wall-clock cap.

  Reads `timeout_env/0`: with no cap it is inert, otherwise it spawns a process
  that sleeps for the cap and then `System.halt/1`s the run with
  `Mutare.Sandbox.Command.timeout_exit/0` — so the run halts *itself* and there is
  no process tree to kill. `Mutare.Sandbox` renders this AST into the target
  project's test bootstrap, mirroring how it renders `Mutare.Selector.bootstrap_ast/0`,
  so the target needs nothing platform-specific and no dependency on Mutare.
  """
  @spec watcher_ast() :: Macro.t()
  def watcher_ast do
    timeout_env = @timeout_env
    timeout_exit = Mutare.Sandbox.Command.timeout_exit()

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

  defp maybe_cap(env, nil), do: env
  defp maybe_cap(env, cap), do: [{@timeout_env, Integer.to_string(cap)} | env]
end
