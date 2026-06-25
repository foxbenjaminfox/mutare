defmodule Mutare.Sandbox.Command do
  @moduledoc """
  Run `mix` against a materialised sandbox as a fresh OS process.

  Every mutant is exercised by its own `mix test` process: the sources never
  change between runs, so mix's incremental compiler finds nothing to rebuild
  and the per-mutant cost is process boot plus the suite. `MIX_ENV=test` and
  `MUTANT_UNDER_TEST=<mutant_id>` are always set; an optional `cap` (ms) bounds a
  run that overruns (a mutation can turn a terminating loop infinite).

  It also owns the env that tunes the **one** metamutant compile for speed
  (`compiler_env/0` — an `ERL_COMPILER_OPTIONS` disabling the SSA alias-analysis
  pass, a free compile win the `Mutare.Runner` applies to that single `mix compile`).

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

  `outcome/1` is the single, total decoder of that *exit-code* contract.
  `outcome/2` refines its ambiguous "anything else" case with the run's output —
  the only place this module reads output to form a *verdict* — recovering two
  *detected*-mutant cases from the otherwise-`:harness_error` bucket:

    * a mutation that broke the **test suite's** own compilation (it ran at the
      test modules' compile time) exits `1` with a test-script compile-error
      banner (`suite_compile_error?/1`) — a kill, not infra.
    * a mutation that minted **unbounded atoms** (an unterminated search building a
      fresh `:"\#{x}_\#{i}"` per step) crashes the BEAM when the global atom table
      fills (`atom_exhausted?/1`) — a resource-divergence exactly like a CPU-bound
      timeout (the suite can never pass with it), so also a kill. The VM aborts
      before the in-process timeout watcher can self-halt, which is why it surfaces
      here rather than as a clean `timeout_exit/0`.

  `timed_test/4` applies the `--exit-status` flag and returns a typed
  `Mutare.Sandbox.Command.Result` decoded via `outcome/2`.

  ## Mix output vocabulary

  Three patterns recognise shapes in `mix`'s human-readable output, and all break
  together if mix ever changes its format — so they live **here**, together, even
  though each is read for a *different* job by a different module:

    * `compile_error_banner/0` — the `== Compilation error in file <path> ==`
      banner; read *here* by `suite_compile_error?/1` to tell a kill from infra.
    * `source_location_regex/0` — a `<file>:<line>` reference; read by
      `Mutare.Poison` to map a compile error back to a mutant id.
    * `test_location_regex/0` — a `<test_file>:<line>` reference (a narrowing of
      the above to `_test.exs`); read by `Mutare.Runner.Baseline` to name the
      tests in a flaky run.

  The consumers are deliberately *not* merged — they parse for different ends —
  but sourcing every pattern from here gives a mix-output-format change one home.

  ## Kill detection stops at the first failure

  A mutant is killed the moment *any* test fails — the verdict is killed-vs-survived,
  not *which* tests fail — so `timed_test/4` also forces `--max-failures 1`. ExUnit
  then stops scheduling tests at the first failure, which is a strict speedup on the
  kill path (the common case for a healthy suite) and changes nothing else: the
  exit-status path is driven solely by `failures > 0` (so one failure still exits
  `failure_exit/0` → `:failed`), and an all-pass survivor run never reaches the cap,
  so it still runs the whole (selected) suite to confirm survival. This is the kill
  path *only* — the baseline (`Mutare.Runner.Baseline`, a whole-suite green check and
  the timing source) and the coverage probe (`Mutare.Runner.CoverageProbe`, which
  must run every test to capture coverage) bypass `timed_test/4` and are unaffected.

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
  @success_exit 0
  @timeout_exit 124
  @failure_exit 101
  @mix_env "test"

  @erl_compiler_options_env "ERL_COMPILER_OPTIONS"

  # Disable only the SSA *alias-analysis* sub-pass (`beam_ssa_alias`, which proves
  # term uniqueness to enable destructive in-place updates) on the one metamutant
  # compile. It is the dominant cost when compiling the metamutant's tuple-heavy
  # generated selectors (~45% of `beam_ssa_opt` on a tuple-heavy module), yet
  # measurably free at runtime — the metamutant runs the suite, not a tight
  # in-place-update loop, so the optimisation buys nothing there. (Contrast
  # `no_ssa_opt`, all SSA optimisation off: a bigger compile win but ~5% slower per
  # mutant run, paid N times — net-negative, like disabling protocol consolidation.)
  # Safe on every OTP: an unknown compiler option is silently ignored, so this is a
  # no-op before the pass existed (pre-OTP-25). See NOTES "Compiler options for the
  # one metamutant compile".
  @metamutant_compile_opt "no_ssa_opt_alias"

  @typedoc """
  What a `mix test` mutant run did, decoded from its exit status (and, for the
  last case, its output):

    * `:passed` — exit `0`: every test passed despite the mutation.
    * `:failed` — exit `failure_exit/0`: a test failed (a clean ExUnit failure).
    * `:timeout` — exit `timeout_exit/0`: the watcher self-halted an overrun.
    * `:harness_error` — any other exit: the suite never ran to a verdict (a
      compile error, a missing dependency, a filesystem race, an OS signal). Not
      a statement about the mutation — the harness itself failed.
    * `:suite_compile_error` — a refinement of `:harness_error`: the *test suite*
      failed to compile because the mutation broke code that runs at the test
      modules' compile time (a `Plug.Router` route macro calling a mutated
      `Plug.Router.Utils` helper, an `EEx`/`use`-time call, a compile-time
      `@attr` expression…). The mutation *was* detected — the suite can't even
      build with it — so the runner counts it as a kill, not an infra failure
      (see `outcome/2`).
    * `:atom_exhausted` — a refinement of `:harness_error`: the mutation made the
      program mint unbounded atoms and the BEAM aborted when the atom table filled.
      A resource-divergence like a timeout (the suite can never pass with it), so
      the runner counts it as a kill — see `outcome/2` and `atom_exhausted?/1`.
  """
  @type outcome ::
          :passed
          | :failed
          | :timeout
          | :harness_error
          | :suite_compile_error
          | :atom_exhausted

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
  Whether `status` is the clean-success exit code (`0`).

  The single home for the "zero means success" reading that every mix run which
  *doesn't* go through `timed_test/4` — the one metamutant compile, the baseline,
  the coverage probe — would otherwise re-derive by matching a literal `0`.
  """
  @spec success?(non_neg_integer()) :: boolean()
  def success?(status), do: status == @success_exit

  @doc """
  Decode a `mix test` mutant-run exit status into its `t:outcome/0` — the single,
  total reading of this module's exit-code contract (see the moduledoc).
  """
  @spec outcome(non_neg_integer()) :: :passed | :failed | :timeout | :harness_error
  def outcome(status) when status == @success_exit, do: :passed
  def outcome(status) when status == @failure_exit, do: :failed
  def outcome(status) when status == @timeout_exit, do: :timeout
  def outcome(_status), do: :harness_error

  @doc """
  Decode an exit status *refined by the run's output* — the only place this
  module looks past the exit code, and only to split one ambiguous case.

  Exit `1` covers both a real harness failure (a missing dep, an infra compile
  error) *and* a mutation that broke the test suite's own compilation. They are
  indistinguishable by code, but they are not the same verdict: the latter means
  the mutation was *detected* (the suite can't build with it), so it is a kill,
  not an infra failure left out of the score.

  We can tell them apart because the metamutant lib is compiled **once** before
  any mutant runs (poison handled at baseline), so a *fresh* compilation error
  during a per-mutant `mix test` can't come from the lib — it can only be a
  re-evaluated `.exs` **test** file the mutation broke at load time. So when an
  otherwise-`:harness_error` run's output reports a compilation error in a test
  script (`suite_compile_error?/1`), it is `:suite_compile_error`. A second
  refinement recovers `:atom_exhausted` — a VM abort from the mutation minting
  unbounded atoms (`atom_exhausted?/1`), a detected resource-divergence. Both are
  kills. Everything else (a lib-file compile error, a missing dep, no marker at
  all) stays `:harness_error` — fail safe: an ambiguous failure is never a kill.
  """
  @spec outcome(non_neg_integer(), String.t()) :: outcome()
  def outcome(status, output) when is_binary(output) do
    case outcome(status) do
      :harness_error ->
        cond do
          atom_exhausted?(output) -> :atom_exhausted
          suite_compile_error?(output) -> :suite_compile_error
          true -> :harness_error
        end

      decoded ->
        decoded
    end
  end

  # === Mix output vocabulary ==================================================
  #
  # Patterns recognising shapes in mix's human-readable output. Co-located here
  # because they all break together if mix ever changes its format, though each
  # is read for a different job by a different module (see the moduledoc).

  @compile_error_banner ~r/== Compilation error in file (\S+) ==/
  @source_location ~r{([\w/.\-]+\.exs?):(\d+)}
  @test_location ~r{([\w/.\-]+_test\.exs):(\d+)}

  # A BEAM *abort* banner — not mix output, but read for the same job (refining a
  # verdict from captured output), so co-located here. The emulator prints this to
  # stderr and halts the whole node the instant the global atom table fills; a
  # mutation that mints unbounded atoms (an unterminated search building a fresh
  # `:"#{x}_#{i}"` per step) is what gets it there. `stderr` is merged into the
  # captured output (`stderr_to_stdout: true`), so the banner reaches `outcome/2`.
  # The wording (`no more index entries in atom_tab`) is stable across OTP releases.
  @atom_table_exhausted ~r/no more index entries in atom_tab/

  # Compiler-diagnostic *headers*. Elixir prints each warning/error as a block headed
  # by one of these markers, the rest of the block (gutter, carets, `└─ file:line:col:`
  # footer) following until the next header. A raised compile exception (`** (…Error)`)
  # is the header of a hard failure. Read by `diagnostic_severity/1`.
  @error_marker ~r/^\s*error:/
  @exception_marker ~r/^\s*\*\* \(\w*Error\)/
  @warning_marker ~r/^\s*warning:/

  @doc """
  Regex matching mix's `== Compilation error in file <path> ==` banner, capturing
  `<path>`. Read here by `suite_compile_error?/1`; exposed so the banner has a
  single home.
  """
  @spec compile_error_banner() :: Regex.t()
  def compile_error_banner, do: @compile_error_banner

  @doc """
  Regex matching a `<file>:<line>` source reference in mix output (an `.ex`/`.exs`
  path and a line, e.g. `lib/foo.ex:5` or `test/foo_test.exs:42`), capturing the
  file and the line. `Mutare.Poison` scans it to map a compile error back to a
  mutant id; it lives here so mix's output shape has one home.
  """
  @spec source_location_regex() :: Regex.t()
  def source_location_regex, do: @source_location

  @doc """
  Regex matching a `<test_file>:<line>` reference in mix output — a narrowing of
  `source_location_regex/0` to `_test.exs` files, capturing the file and the line.
  `Mutare.Runner.Baseline` scans it to name the tests in a flaky run.
  """
  @spec test_location_regex() :: Regex.t()
  def test_location_regex, do: @test_location

  @doc """
  The diagnostic severity a compiler-output `line` *starts*: `:error` (an `error:`
  header or a raised `** (…Error)`), `:warning` (a `warning:` header), or `nil` (any
  other line — a diagnostic's body/footer, or chatter — which inherits its block's
  severity from the preceding header).

  `Mutare.Poison` threads this across the output so it scans only non-warning lines for
  mutant locations: a failed metamutant compile prints every warning the mutations
  provoked (an `unused variable` from a mutant forcing a guard to `true`, a
  `cannot match` from a widened clause), each footered with the same `file:line` shape
  `source_location_regex/0` matches — and mistaking those for the real error's location
  dropped valid mutants as false poison. Co-located with the other mix-output patterns
  so a diagnostic-format change is a single fix.
  """
  @spec diagnostic_severity(String.t()) :: :error | :warning | nil
  def diagnostic_severity(line) when is_binary(line) do
    cond do
      Regex.match?(@error_marker, line) -> :error
      Regex.match?(@exception_marker, line) -> :error
      Regex.match?(@warning_marker, line) -> :warning
      true -> nil
    end
  end

  @doc """
  Whether `output` reports a `mix` compilation error in a **test script** — the
  signature of a mutation that broke the test suite's compilation (see
  `outcome/2`). Matches the `compile_error_banner/0` only when the captured path
  is a `.exs` under a `test/` directory; a lib-file error or no banner is not one.
  Pure, so the discriminator is unit-testable.
  """
  @spec suite_compile_error?(String.t()) :: boolean()
  def suite_compile_error?(output) when is_binary(output) do
    case Regex.run(compile_error_banner(), output) do
      [_, file] -> test_script?(file)
      nil -> false
    end
  end

  # A re-evaluated test script: a `.exs` under a `test/` directory (covers an
  # umbrella's `apps/<app>/test/…` too). Lib sources are `.ex` and compiled once
  # at baseline, so they never produce a per-mutant compile error here.
  defp test_script?(file) do
    String.ends_with?(file, ".exs") and "test" in Path.split(file)
  end

  @doc """
  Whether `output` shows the BEAM aborting because the **atom table** filled — the
  signature of a mutation that mints unbounded atoms (see `outcome/2`). Such a run
  is a detected resource-divergence (the suite can never complete with it), so the
  runner treats it as a kill — like a timeout — rather than an infra failure.

  Matches only when the otherwise-`:harness_error` exit code is *also* paired with
  this VM-abort banner; a normal pass/fail/timeout verdict still wins in
  `outcome/2`. Pure, so the discriminator is unit-testable.
  """
  @spec atom_exhausted?(String.t()) :: boolean()
  def atom_exhausted?(output) when is_binary(output) do
    Regex.match?(@atom_table_exhausted, output)
  end

  @doc """
  The last `lines` lines of captured `mix` output — enough to point at a failure
  without dumping a whole suite run into an error message. The one home for "tail
  the output", shared by the baseline, the coverage probe, and the Mix task's
  error formatter (each picks its own `lines`).
  """
  @spec output_tail(String.t(), pos_integer()) :: String.t()
  def output_tail(output, lines \\ 20) when is_binary(output) do
    output |> String.split("\n") |> Enum.take(-lines) |> Enum.join("\n")
  end

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
  Env entries that tune the **one** metamutant compile for speed: an
  `ERL_COMPILER_OPTIONS` disabling the SSA alias-analysis pass
  (`#{@metamutant_compile_opt}`).

  Read by `Mutare.Runner` for the single `mix compile`. Scoped there on purpose: a
  per-mutant `mix test` never recompiles the lib (sources unchanged), so it carries
  nothing. Merges with any `ERL_COMPILER_OPTIONS` already in the environment so a
  user's own compiler options survive — ours is prepended (`erl_compiler_options/1`).
  """
  @spec compiler_env() :: [{String.t(), String.t()}]
  def compiler_env do
    inherited = System.get_env(@erl_compiler_options_env)
    [{@erl_compiler_options_env, erl_compiler_options(inherited)}]
  end

  @doc """
  Build the `ERL_COMPILER_OPTIONS` value for the metamutant compile: prepend
  `#{@metamutant_compile_opt}` to any `inherited` value (an Erlang term-list string,
  or `nil`/`""` for none), always returning a well-formed `[...]` list string. Pure,
  so the merge is unit-testable.
  """
  @spec erl_compiler_options(String.t() | nil) :: String.t()
  def erl_compiler_options(inherited) do
    case inherited && String.trim(inherited) do
      blank when blank in [nil, ""] ->
        "[#{@metamutant_compile_opt}]"

      trimmed ->
        # Strip the inherited list's outer brackets only (`binary_part`, not `trim` —
        # a nested `[…]` or a trailing `]` inside a term must survive) and splice our
        # option in front; a bare term gets wrapped into a list with it.
        inner =
          if bracketed_list?(trimmed) do
            trimmed |> binary_part(1, byte_size(trimmed) - 2) |> String.trim()
          else
            trimmed
          end

        if inner == "",
          do: "[#{@metamutant_compile_opt}]",
          else: "[#{@metamutant_compile_opt}, #{inner}]"
    end
  end

  defp bracketed_list?(str),
    do: String.starts_with?(str, "[") and String.ends_with?(str, "]")

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
  Build the `mix test` argv for a mutant kill-detection run from `test_args`.

  Always prepends `test --exit-status #{@failure_exit} --max-failures 1`:

    * `--exit-status #{@failure_exit}` makes a clean test failure (a kill)
      distinguishable from a harness error — see the moduledoc.
    * `--max-failures 1` stops ExUnit at the first failure, since one failing test
      is enough to declare a kill (also see the moduledoc).

  `test_args` are the extra arguments (`[]` = whole suite, file-granular args
  otherwise). Pure, so the contract is unit-testable without spawning `mix`.
  """
  @spec test_argv([String.t()]) :: [String.t()]
  def test_argv(test_args) do
    ["test", "--exit-status", Integer.to_string(@failure_exit), "--max-failures", "1" | test_args]
  end

  @doc """
  Run the suite against mutant `mutant_id`, wall-clock-timed, and return a typed
  `Mutare.Sandbox.Command.Result`.

  `test_args` are extra `mix test` arguments (`[]` = whole suite, file-granular
  args otherwise); they are folded into the kill-detection argv by `test_argv/1`
  (forcing `--exit-status #{@failure_exit}` and `--max-failures 1`). `cap` (ms, or
  `nil`) bounds an overrun via the watcher. `env` is extra environment (the runner
  sets a per-worker partition var here, e.g. `MIX_TEST_PARTITION`); `[]` adds none.
  """
  @spec timed_test(Path.t(), [String.t()], non_neg_integer(), pos_integer() | nil, [
          {String.t(), String.t()}
        ]) :: Result.t()
  def timed_test(sandbox, test_args, mutant_id, cap \\ nil, env \\ []) do
    {ms, output, status} = timed_mix(sandbox, test_argv(test_args), mutant_id, cap, env)

    %Result{
      outcome: outcome(status, output),
      exit_status: status,
      output: output,
      duration_ms: ms
    }
  end

  defp maybe_cap(env, nil), do: env
  defp maybe_cap(env, cap), do: [{@timeout_env, Integer.to_string(cap)} | env]
end
