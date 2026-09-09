defmodule Mutare.Runner.CoverageProbe do
  @moduledoc """
  Decide, per mutant, which test files to run — coverage-driven test selection.

  Runs *after* `Mutare.Runner.Baseline` has confirmed the suite green and measured
  the timing; this module is purely about coverage and never green-checks or times
  anything. Keeping the two apart is the point: folding coverage into the baseline
  made `baseline_ms` a sum of per-file process boots (an inflated timeout cap), and
  meant the suite was never confirmed green *together* — only file-by-file.

  It is **one instrumented suite run**. The probe runs `mix test` once at baseline
  with the coverage-capture flag set, so the metamutant self-records — *in the test
  process, synchronously* — which mutant ids each test file covers, plus a
  process-agnostic aggregate of every id that ran at all (`Mutare.Coverage.Recorder`
  owns the capture, `Mutare.Coverage` reads the dump). No `:cover`, no per-file
  subprocess fan-out, and no async-formatter race that loses fast `async: false`
  modules' coverage.

  Three modes, set by `:test_selection`, a granularity ladder from safest/slowest to
  fastest — `:full` ⊃ `:coverage` ⊃ `:tests`:

    * `:tests` (default) — per mutant, run only the individual **test cases** that
      covered its line, via `mix test <file> --only test:<name>` (one `--only`
      per covering test). Finer than `:coverage`: where `:coverage` runs a whole
      covering file, `:tests` runs just the tests in it that touched the line. It
      falls back to `:coverage`'s whole-file selection for any id whose coverage
      can't be pinned to runnable tests — an id in the `wholefile` set (covered
      through a `setup_all`/`on_exit`, which map to a module-scoped context, not a
      single test), or one covered via an unlabeled process (whole suite). So the
      narrowing is applied *only* where every covering attribution is a concrete,
      runnable test.
    * `:coverage` — per mutant, run only the test *files* that covered its line (a
      `setup_all` attributes to its own module's file via the `__ex_unit__/2`
      stacktrace frame; a `Task` via its caller chain; a test-registered `on_exit`
      via its closure frame); a mutant whose code ran in an *unlabeled* process (a
      bare spawn, a `setup`-registered `on_exit` closure, or a `setup_all` whose work
      happened in a spawned `Task`) runs the whole suite — even if some file *also*
      attributes it, since that partial attribution would otherwise mask the
      unlabeled coverage and produce a false survivor; a mutant that never ran at all
      is `:no_coverage` (skipped, and kept out of the score's denominator).
    * `:full` — no per-file selection: every covered mutant runs the whole suite,
      the rest are `:no_coverage`. Safest for suites with cross-file dependencies —
      including a `setup_all` with cross-module global side effects, which `:coverage`
      attributes to its own file only (see `Mutare.Coverage.Recorder`).

  ## `:tests` and the file-granular safety margin it trades away

  `:coverage` is file-granular on purpose: if any test in a file covers the line, the
  whole file runs — so a **sibling test that kills the mutant indirectly** (fails
  because a covering test in the same `async: false` module ran the mutated line and
  left corrupt shared state, without the sibling touching the line itself) is still
  run. `:tests` narrows to the covering tests only, dropping that sibling — so on a
  stateful, cross-test-dependent suite `:tests` can turn such a kill into a false
  survivor. It is the default on the assumption that suites are predominantly
  `async: true` with per-test-isolated state (where a sibling that never runs the
  line cannot observe the mutation, so nothing is lost); `:coverage` is the opt-out
  (`--per-file`) and `:full` the fully conservative escape hatch.

  The narrowing never manufactures a false *kill*: every name emitted is a test that
  actually ran in one of the included files during the probe, so at least one test
  always matches and `mix test --only` never hits its "no test executed" error (which
  would otherwise surface as a harness error, not a kill).

  Coverage is advisory, never authoritative. Anything uncertain — a non-zero
  probe exit, an unreadable dump, or missing capture tables — degrades to
  `:run_all`: we never skip a mutant on doubt. A valid empty dump means none of
  the emitted mutants ran; focused selection can legitimately leave the entire
  aggregate empty. But because `:run_all` makes every covered mutant run the
  whole suite — prohibitive on a large project — a failed probe run is retried
  once before degrading: the baseline was green moments earlier, so a probe
  failure is usually a flaky test, and one extra suite run is cheap next to a
  whole run's selection quality. The probe run is wall-clock capped for the same reason (by
  default a generous multiple of the per-mutant cap, since instrumentation adds
  overhead a plain baseline doesn't have; `:probe_timeout` sets an explicit cap
  instead): a pathological interaction between the coverage capture and the
  target's hot loops must degrade to `:run_all`, not hang the whole run at the
  probe stage forever.
  """

  alias Mutare.{Coverage, Schema, Selector}
  alias Mutare.Coverage.Recorder
  alias Mutare.Sandbox.Command
  alias Mutare.Sandbox.Command.{Invocation, Output}

  require Logger

  # How many times the probe run may be attempted in total (1 + retries). The
  # baseline was confirmed green moments before the probe, so a failed probe is
  # far more often a flaky test than anything systematic — and degrading to
  # run-all on one flake makes *every* covered mutant run the whole suite, which
  # on a large project can make the run de facto infeasible. One retry buys back
  # that whole class of degradations for the price of one extra suite run.
  @probe_attempts 2

  @typedoc """
  What the probe decided for one mutant:

    * `{:run, test_args}` — its line is covered; run `mix test` with these args
      (`[]` = whole suite; file-granular file paths otherwise; under `:tests` those
      file paths plus `--only test:<name>` flags narrowing to the covering tests).
    * `:no_coverage` — nothing runs its line; skip it and keep it out of the
      score's denominator.
  """
  @type outcome :: {:run, [String.t()]} | :no_coverage

  @typedoc """
  What the probe decided for the whole run:

    * `:run_all` — coverage is unusable or uncertain (the probe failed, the dump
      couldn't be read, or capture tables were missing).
      Run *every* mutant against the whole suite — never skip on doubt.
    * `{:selective, outcomes}` — a per-mutant decision. `outcomes` is **total**:
      every mutant id maps to an explicit `outcome`, so a `:no_coverage` mutant
      is named, never implied by a missing key.
  """
  @type selection :: :run_all | {:selective, %{pos_integer() => outcome()}}

  @doc """
  Build the per-mutant test selection (see `t:selection/0`).

  Never fails: every uncertainty degrades to the conservative `:run_all`. The
  green check and timing live in `Mutare.Runner.Baseline`, which runs first.

  `env` is extra environment for the probe run — a fixed partition entry (e.g.
  `MIX_TEST_PARTITION=1`) when `:partition_env` is on, so the partitioned suite
  finds a valid database; `[]` (the default) adds none. The probe is a single
  sequential run, so one fixed partition suffices (`Mutare.Runner.Partitions`).

  `cap` (ms, or `nil` for uncapped) bounds the probe's wall clock via the same
  injected self-halt watcher a per-mutant run uses; an overrun exits
  `Mutare.Sandbox.Command.timeout_exit/0` and degrades to `:run_all` like any
  other non-zero probe exit (see the moduledoc).
  """
  @spec run(
          Path.t(),
          Schema.t(),
          :tests | :coverage | :full,
          [{String.t(), String.t()}],
          pos_integer() | nil
        ) :: selection()
  def run(sandbox, %Schema{} = schema, mode, env \\ [], cap \\ nil)
      when mode in [:tests, :coverage, :full] do
    # Absolute paths: an umbrella runs each app's suite with cwd = the app dir, so
    # the dump must land at one fixed place and the test-file paths must be
    # normalised against the sandbox root, not whichever app is running.
    root = Path.expand(sandbox)
    dump = Path.join(root, Recorder.dump_file())

    with true <- Command.success?(attempt_probe(sandbox, root, dump, env, cap, @probe_attempts)),
         {:ok, coverage} <- Coverage.read_dump(dump, Mutare.RuntimeId.index(schema.sites)) do
      select(mode, schema, coverage)
    else
      _ -> :run_all
    end
  end

  @doc """
  Summarise a `t:selection/0` for display (e.g. the `--verbose` coverage note): how
  many mutants got per-file / whole-suite selection (`covered`) versus were skipped as
  `:no_coverage`. `:run_all` (coverage unusable or uncertain) carries no per-mutant
  counts — every covered mutant runs the whole suite — so its counts are zero and
  `run_all?` is true. Pure (no IO), so it is unit-testable without a probe run.
  """
  @spec summarize(selection()) :: %{
          covered: non_neg_integer(),
          no_coverage: non_neg_integer(),
          run_all?: boolean()
        }
  def summarize(:run_all), do: %{covered: 0, no_coverage: 0, run_all?: true}

  def summarize({:selective, outcomes}) do
    {covered, no_coverage} =
      Enum.reduce(outcomes, {0, 0}, fn
        {_id, :no_coverage}, {covered, none} -> {covered, none + 1}
        {_id, {:run, _args}}, {covered, none} -> {covered + 1, none}
      end)

    %{covered: covered, no_coverage: no_coverage, run_all?: false}
  end

  @doc """
  Does `selection` hold a whole-suite run — `:run_all`, or any `{:run, []}` outcome
  (`:full` mode's covered mutants; an id covered only from an unlabeled process)?
  `Mutare.Runner` reads the umbrella dependency graph (a Mix boot) only when it does,
  since that graph narrows nothing else. Pure.
  """
  @spec broad_runs?(selection()) :: boolean()
  def broad_runs?(:run_all), do: true

  def broad_runs?({:selective, outcomes}),
    do: Enum.any?(outcomes, &match?({_id, {:run, []}}, &1))

  # Run the probe, retrying a failed attempt while attempts remain. A cap overrun
  # (`Command.timeout_exit/0`) is NOT retried: the overrun is systematic — the
  # retry would just burn another full cap and overrun again. Each attempt clears
  # the dump first: `ExUnit.after_suite/1` writes it even for a failing suite, so
  # a failed attempt can leave a partial dump the next read must not trust.
  defp attempt_probe(sandbox, root, dump, env, cap, attempts_left) do
    File.rm(dump)
    {output, status} = run_probe(sandbox, root, dump, env, cap)

    cond do
      Command.success?(status) ->
        status

      status != Command.timeout_exit() and attempts_left > 1 ->
        Logger.warning(
          "coverage probe exited #{status} (the baseline was green, so likely a flaky test); " <>
            "retrying (#{attempts_left - 1} left) rather than degrading to run-all selection"
        )

        attempt_probe(sandbox, root, dump, env, cap, attempts_left - 1)

      true ->
        # The baseline already confirmed the suite green, so a non-zero probe is
        # unexpected — and silently degrading to run-all (every covered mutant runs
        # the whole suite) is a big, invisible slowdown. Surface it.
        Logger.warning(
          probe_failure(status, cap) <>
            "; falling back to run-all selection " <>
            "(every covered mutant runs the whole suite). Probe output:\n#{Output.output_tail(output, 15)}"
        )

        status
    end
  end

  # One instrumented baseline run: the metamutant self-records coverage. A non-zero
  # exit means the dump may be partial (for example `max_failures` can abort before
  # later files run), so the caller treats it as uncertainty → retry/`:run_all`
  # (`attempt_probe/6` owns that policy). The dump path and the path-normalisation
  # root travel in env vars so the helper, running with a per-app cwd in an
  # umbrella, writes one union dump with root-relative keys.
  defp run_probe(sandbox, root, dump, partition_env, cap) do
    env =
      [
        {Recorder.env_var(), "1"},
        {Recorder.dump_path_env(), dump},
        {Recorder.root_env(), root}
      ] ++ partition_env

    Invocation.mix(sandbox, ["test"], Selector.baseline(), cap: cap, env: env)
  end

  # Name the overrun case explicitly: "exited 124" hides that the probe was
  # halted by its own cap, which is the one failure whose remedy (`:probe_timeout`)
  # differs from an ordinary suite failure.
  defp probe_failure(status, cap) do
    if status == Command.timeout_exit() do
      "coverage probe overran its #{cap}ms cap and was halted " <>
        "(set `:probe_timeout` / --probe-timeout if the instrumented suite is legitimately slow)"
    else
      "coverage probe exited #{status}"
    end
  end

  @doc """
  Decide the per-mutant `t:selection/0` from an already-decoded coverage dump.

  The pure core of `run/5` (no IO): given the `mode`, the `Mutare.Schema` (for the
  total id list), and a valid `Mutare.Coverage.t()`, it returns a **total**
  `{:selective, outcomes}`. An empty aggregate marks every mutant `:no_coverage`;
  `run/5` handles probe failures and unusable dumps before selection. Exposed so
  the mode reconciliation — including `:tests` narrowing and its whole-file/whole-suite
  fallbacks — is unit-testable without spawning a probe.
  """
  @spec select(:tests | :coverage | :full, Schema.t(), Coverage.t()) ::
          {:selective, %{pos_integer() => outcome()}}
  def select(mode, %Schema{} = schema, coverage) do
    outcomes = Map.new(schema.sites, fn %{id: id} -> {id, outcome(mode, id, coverage)} end)
    {:selective, outcomes}
  end

  # `:full` — covered (ran at all) → whole suite; otherwise `:no_coverage`.
  defp outcome(:full, id, %{aggregate: aggregate}) do
    if MapSet.member?(aggregate, id), do: {:run, []}, else: :no_coverage
  end

  # `:coverage`, per id:
  #   * never ran (not in the aggregate) → `:no_coverage`;
  #   * ran in an unlabeled process (a bare spawn / a `setup`-registered `on_exit`
  #     closure / a `setup_all` whose work ran off-stack in a `Task`) → whole
  #     suite. This dominates attribution on purpose: an id can be attributed to
  #     file A (a test there touches the line) *and* be covered via an unlabeled
  #     process. Trusting the partial attribution would run only A and miss the
  #     unlabeled killer — a false survivor.
  #   * otherwise → only the files that attributed it (a `setup_all` attributes to
  #     its own module's file via the `__ex_unit__/2` stacktrace recovery, and a
  #     test-registered `on_exit` via its closure frame, so neither is forced to
  #     whole-suite — see `Mutare.Coverage.Recorder`).
  defp outcome(:coverage, id, %{aggregate: aggregate, unlabeled: unlabeled, by_file: by_file}) do
    cond do
      not MapSet.member?(aggregate, id) -> :no_coverage
      MapSet.member?(unlabeled, id) -> {:run, []}
      true -> by_file |> covering_files(id) |> run_args()
    end
  end

  # `:tests` refines the `:coverage` decision: it narrows a whole-file selection to the
  # individual covering tests when — and only when — every attribution of the id is a concrete,
  # runnable test. It reuses `:coverage` verbatim for everything else, so all of that mode's
  # conservatism is inherited unchanged:
  #   * `:no_coverage` and the whole-suite (`{:run, []}`) unlabeled/degraded cases pass through —
  #     `narrow/2` only touches a non-empty file list;
  #   * an id in `wholefile` (covered via a `setup_all`/`on_exit`, not a single test) keeps its
  #     whole covering files — narrowing would drop the covering context;
  #   * a narrowable id runs its covering files plus `--only test:<name>` for each covering test.
  defp outcome(:tests, id, coverage) do
    case outcome(:coverage, id, coverage) do
      {:run, [_ | _] = files} = base -> narrow(id, files, coverage) || base
      other -> other
    end
  end

  # `{:run, files ++ name filters}` when the id is safely narrowable, else `nil` (keep whole files).
  # Narrowable = not in `wholefile` (no non-runnable attribution) AND at least one covering test
  # name — an empty name set can't be narrowed without risking a `mix test --only` "no test
  # executed" error, so it degrades to the whole-file `:coverage` decision.
  defp narrow(id, files, %{wholefile: wholefile, by_test: by_test}) do
    with false <- MapSet.member?(wholefile, id),
         %MapSet{} = names <- Map.get(by_test, id),
         false <- MapSet.size(names) == 0 do
      {:run, files ++ only_args(names)}
    else
      _ -> nil
    end
  end

  # `["--only", "test:<name>", ...]`, sorted for a deterministic argv. Built as list elements, so a
  # test name with spaces (`"test foo bar"`) is one argv token needing no shell quoting; `mix test`
  # splits `test:<name>` on the first `:` (`ExUnit.Filters.parse/1`), so a name with a `:` survives.
  defp only_args(names) do
    names |> Enum.sort() |> Enum.flat_map(&["--only", "test:" <> &1])
  end

  defp run_args([]), do: {:run, []}
  defp run_args(files), do: {:run, Enum.sort(files)}

  defp covering_files(by_file, id) do
    for {file, ids} <- by_file, MapSet.member?(ids, id), do: file
  end
end
