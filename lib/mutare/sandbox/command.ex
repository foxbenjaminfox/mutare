defmodule Mutare.Sandbox.Command do
  @moduledoc """
  Decode what a `mix test` mutant run *did*, and orchestrate one typed run.

  Every mutant is exercised by its own `mix test` process (spawned by
  `Mutare.Sandbox.Command.Invocation`). This module owns the *run side* of the
  **exit-code contract** — every code a mutant run can exit with, and what each one
  means — plus the one entry point that runs a mutant and hands back a typed
  `Mutare.Sandbox.Command.Result`. The neighbouring modules own the rest of what was
  once one file:

    * `Mutare.Sandbox.Command.Invocation` — process execution, the environment a run
      gets, and the timeout-watcher AST (the *run* side of the timeout contract).
    * `Mutare.Sandbox.Command.Output` — every pattern that reads `mix`'s human-readable
      output, including the discriminators `outcome/2` consults below.
    * `Mutare.Sandbox.CompilerOptions` — the env that speeds the one metamutant compile.

  ## The exit-code contract

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
  `outcome/2` refines its ambiguous "anything else" case with the run's output (via
  the `Mutare.Sandbox.Command.Output` discriminators). Two refinements recover
  *detected*-mutant cases from the otherwise-`:harness_error` bucket:

    * a mutation that broke the **test suite's** own compilation (it ran at the
      test modules' compile time) exits `1` with a test-script compile-error
      banner (`Output.suite_compile_error?/1`) — a kill, not infra.
    * a mutation that minted **unbounded atoms** (an unterminated search building a
      fresh `:"\#{x}_\#{i}"` per step) crashes the BEAM when the global atom table
      fills (`Output.atom_exhausted?/1`) — a resource-divergence exactly like a CPU-bound
      timeout (the suite can never pass with it), so also a kill. The VM aborts
      before the in-process timeout watcher can self-halt, which is why it surfaces
      here rather than as a clean `timeout_exit/0`.

  A third refinement does **not** change the verdict — it stays a harness error —
  but *names a known-transient cause* so the runner can message and retry it
  better (`Output.boot_failure?/1` → `:boot_failure`): the sandbox node died **during
  boot** and its own diagnostic was erased by a secondary `:standard_error`
  failure (a torn-down IO device). The mutation says nothing — it is concurrent
  workers contending on shared singletons at startup — so it is kept out of the
  score like any harness error, but it is recognised here so the engine stops
  pointing at output that can't help (the real cause is unrecoverable) and retries
  it harder (see `Mutare.Runner`).

  `timed_test/4` applies the `--exit-status` flag (`test_argv/1`), runs the mutant via
  `Mutare.Sandbox.Command.Invocation.timed_mix/5`, and returns a typed
  `Mutare.Sandbox.Command.Result` decoded via `outcome/2`.

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
  """

  alias Mutare.Sandbox.Command.{Invocation, Output, Result}

  @success_exit 0
  @timeout_exit 124
  @failure_exit 101

  # Startup work a per-mutant `mix test` can safely skip. The metamutant lib is compiled
  # **once** before any mutant runs and its sources never change between runs (the
  # one-compile invariant), so each per-mutant boot otherwise re-does pure-overhead checks:
  #
  #   * `--no-compile` — skip mix's compile-staleness scan (it `stat`s every source against
  #     the compile manifest only to find nothing changed). The beams are already present;
  #     `.exs` test scripts are still evaluated, so a mutation that breaks a *test file* at
  #     load time still surfaces as `:suite_compile_error` (a lib compile error can't happen
  #     per-mutant — the lib is built once).
  #   * `--no-deps-check` — deps are resolved/compiled at the one compile step and don't change.
  #   * `--no-archives-check` — installed archives don't change between runs.
  #
  # Pure overhead paid N times: a per-mutant run is process boot + the covering tests, and for
  # a fast suite that boot dominates (see NOTES "Skip redundant per-mutant `mix test` startup
  # work"). Applied to the per-mutant kill-detection path only — not the one-time baseline /
  # coverage probe, where the saving is negligible and a plain `mix test` is the conservative
  # authoritative check.
  @boot_skip_flags ["--no-compile", "--no-deps-check", "--no-archives-check"]

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
      the runner counts it as a kill — see `outcome/2` and `Output.atom_exhausted?/1`.
    * `:boot_failure` — a refinement of `:harness_error` that is **still not a
      kill**: the sandbox node died during boot and its own diagnostic was erased
      by a secondary `:standard_error` failure (`Output.boot_failure?/1`). A known-
      transient contention signature (concurrent workers stampeding shared
      services at startup), kept out of the score like any harness error but named
      so the runner messages it actionably and retries it harder.
  """
  @type outcome ::
          :passed
          | :failed
          | :timeout
          | :harness_error
          | :suite_compile_error
          | :atom_exhausted
          | :boot_failure

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
  contract looks past the exit code, and only to split one ambiguous case.

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
  script (`Output.suite_compile_error?/1`), it is `:suite_compile_error`. A second
  refinement recovers `:atom_exhausted` — a VM abort from the mutation minting
  unbounded atoms (`Output.atom_exhausted?/1`), a detected resource-divergence. Both
  are kills. A third — `:boot_failure` (`Output.boot_failure?/1`) — stays a harness
  error but names a known-transient boot-time contention crash, so the runner can
  message and retry it better. Everything else (a lib-file compile error, a missing
  dep, no marker at all) stays `:harness_error` — fail safe: an ambiguous failure is
  never a kill.
  """
  @spec outcome(non_neg_integer(), String.t()) :: outcome()
  def outcome(status, output) when is_binary(output) do
    case outcome(status) do
      :harness_error ->
        cond do
          # Kills first: a detected mutation must never be masked by a boot banner
          # (they don't co-occur — a node dead at boot never compiled a test
          # script nor filled the atom table — but precedence is fail-safe).
          Output.atom_exhausted?(output) -> :atom_exhausted
          Output.suite_compile_error?(output) -> :suite_compile_error
          Output.boot_failure?(output) -> :boot_failure
          true -> :harness_error
        end

      decoded ->
        decoded
    end
  end

  @doc """
  Build the `mix test` argv for a mutant kill-detection run from `test_args`.

  Always prepends `test --exit-status #{@failure_exit} --max-failures 1` plus the
  boot-skip flags `#{Enum.join(@boot_skip_flags, " ")}`:

    * `--exit-status #{@failure_exit}` makes a clean test failure (a kill)
      distinguishable from a harness error — see the moduledoc.
    * `--max-failures 1` stops ExUnit at the first failure, since one failing test
      is enough to declare a kill (also see the moduledoc).
    * `#{Enum.join(@boot_skip_flags, " ")}` skip mix startup checks that are pure
      overhead under the one-compile invariant (the lib is built once, sources never
      change between runs) — see `@boot_skip_flags`.

  `test_args` are the extra arguments (`[]` = whole suite, file-granular args
  otherwise), appended last so file-granular selection stays at the tail. Pure, so
  the contract is unit-testable without spawning `mix`.
  """
  @spec test_argv([String.t()]) :: [String.t()]
  def test_argv(test_args) do
    ["test", "--exit-status", Integer.to_string(@failure_exit), "--max-failures", "1"] ++
      @boot_skip_flags ++ test_args
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
    {ms, output, status} =
      Invocation.timed_mix(sandbox, test_argv(test_args), mutant_id, cap, env)

    %Result{
      outcome: outcome(status, output),
      exit_status: status,
      output: output,
      duration_ms: ms
    }
  end
end
