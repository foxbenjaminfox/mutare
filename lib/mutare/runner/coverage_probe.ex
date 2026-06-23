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

  Two modes, set by `:test_selection`:

    * `:coverage` (default) — per mutant, run only the test files that covered its
      line (a `setup_all` attributes to its own module's file via the `__ex_unit__/2`
      stacktrace frame; a `Task` via its caller chain); a mutant whose code ran in an
      *unlabeled* process (`on_exit`, a bare spawn, or a `setup_all` whose work
      happened in a spawned `Task`) runs the whole suite — even if some file *also*
      attributes it, since that partial attribution would otherwise mask the
      unlabeled coverage and produce a false survivor; a mutant that never ran at all
      is `:no_coverage` (skipped, and kept out of the score's denominator).
    * `:full` — no per-file selection: every covered mutant runs the whole suite,
      the rest are `:no_coverage`. Safer for suites with cross-file dependencies —
      including a `setup_all` with cross-module global side effects, which `:coverage`
      attributes to its own file only (see `Mutare.Coverage.Recorder`).

  Selection is file-granular, not per-individual-test: if any test in a file covers
  the line, the whole file runs — so a test that kills a mutant indirectly (without
  touching the line itself) is still included, as long as a sibling test in its
  file does touch the line.

  Coverage is advisory, never authoritative. Anything uncertain — a non-zero
  probe exit, an unreadable dump, or an empty dump (the probe recorded nothing,
  so the capture itself likely failed) — degrades to `:run_all`: we never skip a
  mutant on doubt.
  """

  alias Mutare.{Coverage, Schema, Selector}
  alias Mutare.Coverage.Recorder
  alias Mutare.Sandbox.Command

  require Logger

  @typedoc """
  What the probe decided for one mutant:

    * `{:run, test_args}` — its line is covered; run `mix test` with these args
      (`[]` = whole suite, file-granular args otherwise).
    * `:no_coverage` — nothing runs its line; skip it and keep it out of the
      score's denominator.
  """
  @type outcome :: {:run, [String.t()]} | :no_coverage

  @typedoc """
  What the probe decided for the whole run:

    * `:run_all` — coverage is unusable or uncertain (couldn't read the dump, or
      not a single id was recorded, which means the capture itself likely failed).
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
  """
  @spec run(Path.t(), Schema.t(), :coverage | :full) :: selection()
  def run(sandbox, %Schema{} = schema, mode) when mode in [:coverage, :full] do
    # Absolute paths: an umbrella runs each app's suite with cwd = the app dir, so
    # the dump must land at one fixed place and the test-file paths must be
    # normalised against the sandbox root, not whichever app is running.
    root = Path.expand(sandbox)
    dump = Path.join(root, Recorder.dump_file())
    File.rm(dump)

    with true <- Command.success?(probe!(sandbox, root, dump)),
         {:ok, coverage} <- Coverage.read_dump(dump) do
      select(mode, schema, coverage)
    else
      _ -> :run_all
    end
  end

  # One instrumented baseline run: the metamutant self-records coverage. We don't
  # cap it (it is a baseline-equivalent run), but a non-zero exit means the dump
  # may be partial (for example `max_failures` can abort before later files run),
  # so the caller treats it as uncertainty → `:run_all`. The dump path and the
  # path-normalisation root travel in env vars so the helper, running with a
  # per-app cwd in an umbrella, writes one union dump with root-relative keys.
  defp probe!(sandbox, root, dump) do
    env = [
      {Recorder.env_var(), "1"},
      {Recorder.dump_path_env(), dump},
      {Recorder.root_env(), root}
    ]

    {output, status} = Command.mix(sandbox, ["test"], Selector.baseline(), env: env)

    unless Command.success?(status) do
      # The baseline already confirmed the suite green, so a non-zero probe is
      # unexpected — and silently degrading to run-all (every covered mutant runs
      # the whole suite) is a big, invisible slowdown. Surface it.
      Logger.warning(
        "coverage probe exited #{status}; falling back to run-all selection " <>
          "(every covered mutant runs the whole suite). Probe output:\n#{Command.output_tail(output, 15)}"
      )
    end

    status
  end

  # An empty aggregate means the capture recorded nothing (it likely failed), not
  # that the suite genuinely covers nothing — so run everything.
  defp select(mode, %Schema{} = schema, coverage) do
    if MapSet.size(coverage.aggregate) == 0 do
      :run_all
    else
      ids = Enum.map(schema.sites, & &1.id)
      outcomes = Map.new(ids, fn id -> {id, outcome(mode, id, coverage)} end)
      {:selective, outcomes}
    end
  end

  # `:full` — covered (ran at all) → whole suite; otherwise `:no_coverage`.
  defp outcome(:full, id, %{aggregate: aggregate}) do
    if MapSet.member?(aggregate, id), do: {:run, []}, else: :no_coverage
  end

  # `:coverage`, per id:
  #   * never ran (not in the aggregate) → `:no_coverage`;
  #   * ran in an unlabeled process (`on_exit`/a bare spawn/a `setup_all` whose work
  #     ran off-stack in a `Task`) → whole suite. This dominates attribution on
  #     purpose: an id can be attributed to file A (a test there touches the line)
  #     *and* be covered via an unlabeled process. Trusting the partial attribution
  #     would run only A and miss the unlabeled killer — a false survivor.
  #   * otherwise → only the files that attributed it (a `setup_all` attributes to
  #     its own module's file via the `__ex_unit__/2` stacktrace recovery, so it is
  #     no longer forced to whole-suite — see `Mutare.Coverage.Recorder`).
  defp outcome(:coverage, id, %{aggregate: aggregate, unlabeled: unlabeled, by_file: by_file}) do
    cond do
      not MapSet.member?(aggregate, id) -> :no_coverage
      MapSet.member?(unlabeled, id) -> {:run, []}
      true -> by_file |> covering_files(id) |> run_args()
    end
  end

  defp run_args([]), do: {:run, []}
  defp run_args(files), do: {:run, Enum.sort(files)}

  defp covering_files(by_file, id) do
    for {file, ids} <- by_file, MapSet.member?(ids, id), do: file
  end
end
