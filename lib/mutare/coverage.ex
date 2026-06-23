defmodule Mutare.Coverage do
  @moduledoc """
  Read back the coverage the metamutant recorded during the probe run.

  The metamutant self-records coverage **synchronously, in the test process**, as
  the suite runs (`Mutare.Coverage.Recorder` owns the generated side); at suite end
  an `ExUnit.after_suite/1` hook dumps it to a file. This module reads that dump.

  The dump is three things, all keyed by **mutant id** (no metamutant↔original line
  mapping — the original line is only for the report):

    * `:aggregate` — the set of mutant ids whose selector ran *at all*, in any
      process (test body, `setup`, `setup_all`, a spawned task). This is the
      **no-coverage** signal: an id not in it can never be killed, so skip it and
      keep it out of the score's denominator.
    * `:by_file` — `%{test_file => MapSet(mutant ids)}`: which mutant ids each test
      *file* covered. A line running in the test process is labeled directly; one
      running in a `Task` it spawned is attributed via the caller chain; one running
      in a module's `setup_all` is attributed via the `__ex_unit__/2` stacktrace
      frame (module-granular, the file selection needs). This drives per-file **test
      selection**.
    * `:unlabeled` — the set of mutant ids whose selector ran in a process with no
      recoverable test label *at all* — `on_exit`/a bare spawn, or the rare
      `setup_all` whose work happened off-stack in a `Task` it spawned. An id here
      was covered, but *which* test owns it is unknown, so the caller runs the
      **whole suite** for it — even if `:by_file` *also* attributes it to some file,
      since that partial attribution would otherwise mask the unlabeled coverage and
      manufacture a false survivor. `Mutare.Runner.CoverageProbe` reconciles the
      three.

  Why not `:cover`: its counters live in a single global table keyed
  `{module, line}` with no per-process partition, so attributing coverage to a
  test in one run needs a per-test snapshot, and the only global per-test signal
  ExUnit emits is an async cast to formatters that races test execution (fast
  `async: false` modules' coverage is lost). Self-recording in the metamutant
  sidesteps that entirely — and is process-agnostic for the aggregate, so it is a
  *better* no-coverage detector than `:cover` ever was.
  """

  require Logger

  @typedoc """
  The decoded dump: the process-agnostic aggregate hit set, per-test-file
  attribution, and the unlabeled (whole-suite) hit set. All keyed by mutant id.
  """
  @type t :: %{
          aggregate: MapSet.t(pos_integer()),
          by_file: %{String.t() => MapSet.t(pos_integer())},
          unlabeled: MapSet.t(pos_integer())
        }

  @doc """
  Read and decode the probe's coverage dump at `path`.

  Returns `{:error, _}` on anything unusable (missing file, truncated/garbled
  payload, unexpected shape) — the caller degrades such uncertainty to running the
  whole suite, never to a false `:no_coverage`.
  """
  @spec read_dump(Path.t()) :: {:ok, t()} | {:error, term()}
  def read_dump(path) do
    with {:ok, binary} <- File.read(path),
         {:ok, %{aggregate: aggregate, by_file: by_file} = decoded} <- decode(binary),
         unlabeled = Map.get(decoded, :unlabeled, []),
         true <- is_list(aggregate) and is_map(by_file) and is_list(unlabeled) do
      {:ok,
       %{
         aggregate: MapSet.new(aggregate),
         by_file: Map.new(by_file, fn {file, ids} -> {file, MapSet.new(ids)} end),
         unlabeled: MapSet.new(unlabeled)
       }}
    else
      {:error, reason} ->
        Logger.warning(
          "coverage dump unusable (#{path}), falling back to run-all: #{inspect(reason)}"
        )

        {:error, reason}

      other ->
        Logger.warning("coverage dump has unexpected shape (#{path}), falling back to run-all")
        {:error, {:bad_shape, other}}
    end
  end

  # `:erlang.binary_to_term` raises on a truncated/garbage payload — turn that
  # into an `{:error, _}` like every other unusable-dump case.
  defp decode(binary) do
    {:ok, :erlang.binary_to_term(binary)}
  rescue
    error -> {:error, error}
  end
end
