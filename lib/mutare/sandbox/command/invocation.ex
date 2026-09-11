defmodule Mutare.Sandbox.Command.Invocation do
  @moduledoc """
  Spawn `mix` against a materialised sandbox as a fresh OS process.

  Every mutant is exercised by its own `mix test` process: the sources never
  change between runs, so mix's incremental compiler finds nothing to rebuild
  and the per-mutant cost is process boot plus the suite. `MIX_ENV=test` and
  the variables selecting the mutant (`Mutare.Selector.environment/1`) are always
  set; an optional `cap` (ms) bounds a run that overruns (a mutation can turn a
  terminating loop infinite).

  This module owns everything about *how a run is invoked*: the environment it
  runs under (`mix_env/0`, the reserved variable set in `reserved_env_names/0`,
  the self-hosting isolation vars), the raw spawn (`mix/4`/`timed_mix/5`), and the
  **timeout enforcement mechanism** — the env var the cap travels in
  (`timeout_env/0`) and the dependency-free watcher AST (`watcher_ast/0`) that
  `Mutare.Sandbox` renders into the target's test bootstrap. The matching half —
  *decoding* what a run did from its exit code, including the `timeout_exit/0` the
  watcher signals — is `Mutare.Sandbox.Command`; `Mutare.Sandbox.Command.timed_test/5`
  composes the two (run here, decode there).

  The cap is not enforced by killing a process tree (which needs platform-specific
  signals); instead the watcher reads `timeout_env/0` and, after the deadline,
  `System.halt/1`s the run itself with `Mutare.Sandbox.Command.timeout_exit/0`.

  A second, structurally identical self-halt guards against the opposite failure:
  the *owner* dying rather than the run overrunning. Every run's stdin is a pipe
  whose write end only the spawning Mutare process holds, so if that process dies
  — however abruptly — the pipe hits EOF. The owner-death watcher
  (`owner_watch_ast/0`, gated by `owner_watch_env/0`, rendered by `Mutare.Sandbox`
  into the sandbox's config and test bootstrap) blocks reading stdin and halts the
  run with `Mutare.Sandbox.Command.owner_lost_exit/0` the moment that EOF arrives,
  so no sandbox `mix` outlives the run that spawned it.
  """

  @timeout_env "MUTARE_TIMEOUT"
  @compile_timeout_env "MUTARE_COMPILE_TIMEOUT"
  @owner_watch_env "MUTARE_OWNER_WATCH"
  @erl_options_env "ELIXIR_ERL_OPTIONS"
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
  Env var the runner sets to give the **one metamutant compile** its wall-clock
  cap (ms).

  A sibling of `timeout_env/0` with its own name on purpose: the watcher that
  reads it (`compile_watcher_ast/0`) lives in the sandbox `config/config.exs`
  prefix, which mix evaluates on *every* sandbox boot — so it must be armed only
  when `Mutare.Runner` sets this variable on the compile invocation, and stay
  inert on the baseline, the coverage probe, and every per-mutant `mix test`
  (whose cap is `timeout_env/0`, armed from the test bootstrap instead).
  """
  @spec compile_timeout_env() :: String.t()
  def compile_timeout_env, do: @compile_timeout_env

  @doc """
  Env var that arms the owner-death watcher (`owner_watch_ast/0`).

  Set by `mix/4` on every sandbox run, and only there: the watcher halts the run
  the moment stdin hits EOF, which is the owner-died signal *only* when stdin is
  the spawning process's pipe. A sandbox `mix` run by hand (or by CI with stdin
  at `/dev/null`) must stay unaffected, so the watcher is inert unless this
  variable is set.
  """
  @spec owner_watch_env() :: String.t()
  def owner_watch_env, do: @owner_watch_env

  @doc """
  Run `mix <args>` in `sandbox` as a fresh OS process, returning
  `{output, exit_status}`.

  `MIX_ENV=test` and `MUTARE_ACTIVE_MUTANT` are always set; `mutant_id`
  is a runtime identity (`Mutare.Selector.baseline/0` for a baseline run). For a
  schema mutant, `Selector.environment/1` splits its `{file, local_id}` into the
  namespace and integer environment variables; integer calls clear any inherited
  namespace. `opts`:

    * `:cap` (ms, or `nil`) — handed to the injected timeout watcher, which halts
      the run itself if it overruns, so there is no process tree to kill and
      nothing platform-specific.
    * `:env` — further environment variables (the coverage probe sets its capture
      flag this way).
  """
  @spec mix(Path.t(), [String.t()], Mutare.RuntimeId.t(),
          cap: pos_integer() | nil,
          env: [{String.t(), String.t()}]
        ) :: {String.t(), non_neg_integer()}
  def mix(sandbox, args, mutant_id, opts \\ []) do
    env =
      [
        {"MIX_ENV", @mix_env},
        # Arm the owner-death watcher: this run's stdin is our pipe, so EOF on it
        # means we died and the run must halt itself rather than orphan.
        {@owner_watch_env, "1"},
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
      |> Kernel.++(Mutare.Selector.environment(mutant_id))
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
      @compile_timeout_env,
      @owner_watch_env,
      # Carries the `:max_heap_mb` cap (`heap_cap_env/1`) when that option is on.
      @erl_options_env,
      Mutare.Selector.env_var(),
      Mutare.Selector.namespace_env(),
      Mutare.Selector.override_env(),
      Mutare.Coverage.Recorder.env_var(),
      Mutare.Coverage.Recorder.dump_path_env(),
      Mutare.Coverage.Recorder.root_env(),
      Mutare.Coverage.Recorder.fixture_override_env()
    ]
  end

  @doc """
  The env entry that caps every BEAM process's heap in a sandbox run, or `[]`
  when `mb` is `nil` (the `:max_heap_mb` default — no cap).

  The cap rides in `ELIXIR_ERL_OPTIONS` as `+hmax <words>` (the emulator's
  default per-process `max_heap_size`, which **kills the offending process**
  when exceeded). This is the memory analogue of the wall-clock watcher, and
  like it needs nothing platform-specific: no cgroups, no `ulimit`, no process
  tree to hunt down. A mutation that makes code allocate without bound (the
  motivating incident: a dropped guard turning a function unconditionally
  self-recursive, ~25GB RSS in under a second, OOM-killed) then dies as an
  ordinary, fast, attributable test failure inside the run — the growing heap
  belongs to the test process exercising the mutant — instead of racing the
  kernel's OOM killer for the whole host.

  A pre-existing `ELIXIR_ERL_OPTIONS` in Mutare's own environment is preserved
  and the cap appended after it (later emulator flags win), so a user's flags
  survive with the cap applied on top.

  One honest limit: `max_heap_size` counts the process *heap* — lists, tuples,
  maps, small binaries (the incident's growth shape, and the common one for
  runaway recursion). Large (refc) binaries live off-heap and are not counted,
  so a pure binary-append runaway is not contained by this cap.

  Not applied to the one metamutant compile: the metamutant is ~25× the source
  and the compiler's per-process memory is legitimately large — a cap sized for
  the suite's runtime could sink the build. The runtime runs (baseline, coverage
  probe, every per-mutant `mix test`) all get it — the baseline doubles as
  validation that the suite itself fits under the cap, so a too-small value
  surfaces as a red baseline up front rather than as false kills mid-run.
  """
  @spec heap_cap_env(pos_integer() | nil) :: [{String.t(), String.t()}]
  def heap_cap_env(nil), do: []

  def heap_cap_env(mb) when is_integer(mb) and mb > 0 do
    words = div(mb * 1_048_576, :erlang.system_info(:wordsize))
    flag = "+hmax #{words}"

    merged =
      case System.get_env(@erl_options_env) do
        nil -> flag
        "" -> flag
        existing -> existing <> " " <> flag
      end

    [{@erl_options_env, merged}]
  end

  @doc """
  Like `mix/4`, but wall-clock-timed: returns `{elapsed_ms, output, exit_status}`.

  `env` is extra environment passed straight through to `mix/4` (the runner uses
  it to set a per-worker partition var, e.g. `MIX_TEST_PARTITION`); `[]` adds none.
  """
  @spec timed_mix(Path.t(), [String.t()], Mutare.RuntimeId.t(), pos_integer() | nil, [
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
  def watcher_ast, do: deadline_watcher(@timeout_env)

  @doc """
  Dependency-free watcher that enforces the one metamutant compile's wall-clock cap.

  The same self-halt watcher as `watcher_ast/0`, armed by `compile_timeout_env/0`
  instead: `Mutare.Sandbox` renders it into the sandbox's `config/config.exs`
  prefix (mix evaluates config before the compilers run, the same property the
  owner-death watcher uses), and `Mutare.Runner` sets the variable only on the
  compile invocation — so a thrashing compile halts itself with
  `Mutare.Sandbox.Command.timeout_exit/0` instead of blocking the run
  indefinitely, and every other sandbox boot evaluates the watcher inert.
  """
  @spec compile_watcher_ast() :: Macro.t()
  def compile_watcher_ast, do: deadline_watcher(@compile_timeout_env)

  # The self-halt deadline primitive both wall-clock watchers share: read a cap
  # (ms) from `env_var`, then sleep-and-halt with the timeout exit code. Inert
  # when the variable is unset or empty, so each watcher fires only for the run
  # kind whose invocation arms it.
  defp deadline_watcher(env_var) do
    timeout_exit = Mutare.Sandbox.Command.timeout_exit()

    quote do
      case System.get_env(unquote(env_var)) do
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
  Dependency-free watcher that halts a sandbox run whose owner died.

  Reads `owner_watch_env/0`: unset (a manual run in a kept sandbox, CI with a
  closed stdin) it is inert, otherwise it spawns a process that blocks reading
  stdin and, on `:eof`, `System.halt/1`s the run with
  `Mutare.Sandbox.Command.owner_lost_exit/0`. Under `mix/4` the run's stdin is a
  pipe whose write end only the owning Mutare process holds; when that process
  dies — clean exit, crash, or SIGKILL (the kernel closes its descriptors) — the
  pipe hits EOF and the run reaps itself, instead of surviving re-parented (a
  compute-bound `mix` never touches stdout, so it would otherwise run on
  untouched). `Mutare.Sandbox` renders this AST into the sandbox's
  `config/config.exs` (mix evaluates config before compiling, so the one-time
  metamutant compile and every run's boot phase are covered) and into the test
  bootstrap alongside `watcher_ast/0` (covering suites under a config layout the
  config injection can't reach). Like the timeout watcher, it needs nothing
  platform-specific and no dependency on Mutare — the same self-halt primitive
  pointed at a second hazard.

  Data on stdin never arrives under `mix/4` (Mutare writes nothing to the pipe),
  so the watcher simply re-blocks on anything that isn't `:eof`; a target suite
  that reads stdin itself sees exactly what it would without the watcher —
  a silent, open pipe.
  """
  @spec owner_watch_ast() :: Macro.t()
  def owner_watch_ast do
    owner_watch_env = @owner_watch_env
    owner_lost_exit = Mutare.Sandbox.Command.owner_lost_exit()

    quote do
      case System.get_env(unquote(owner_watch_env)) do
        nil ->
          :ok

        "" ->
          :ok

        _armed ->
          spawn(fn ->
            watch = fn watch ->
              # `:io.get_line/2` (not `IO.read/2`) so the rendered snippet stays
              # stable across Elixir versions in the target project.
              case :io.get_line(:standard_io, "") do
                :eof -> System.halt(unquote(owner_lost_exit))
                {:error, _} -> System.halt(unquote(owner_lost_exit))
                _data -> watch.(watch)
              end
            end

            watch.(watch)
          end)
      end
    end
  end

  defp maybe_cap(env, nil), do: env
  defp maybe_cap(env, cap), do: [{@timeout_env, Integer.to_string(cap)} | env]
end
