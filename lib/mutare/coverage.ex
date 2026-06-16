defmodule Mutare.Coverage do
  @moduledoc """
  Read back the coverage the metamutant recorded during the probe run.

  The metamutant self-records coverage **synchronously, in the test process**, as
  the suite runs (`Mutare.Coverage.Recorder` owns the generated side); at suite end
  an `ExUnit.after_suite/1` hook dumps it to a file. This module reads that dump.

  The dump is two things, both keyed by **mutant id** (no metamutant↔original line
  mapping — the original line is only for the report):

    * `:aggregate` — the set of mutant ids whose selector ran *at all*, in any
      process (test body, `setup`, `setup_all`, a spawned task). This is the
      **no-coverage** signal: an id not in it can never be killed, so skip it and
      keep it out of the score's denominator.
    * `:by_file` — `%{test_file => MapSet(mutant ids)}`: which mutant ids each test
      *file* covered. Only labeled test processes attribute here, so this drives
      per-file **test selection**. A mutant in `:aggregate` but absent from every
      file's set was covered only by an unlabeled process (a `setup_all`/`on_exit`/
      spawned process); the caller runs the whole suite for it rather than risk a
      false `:no_coverage` (`Mutare.Runner.CoverageProbe` reconciles the two).

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
  The decoded dump: the process-agnostic aggregate hit set, and per-test-file
  attribution. Both are keyed by mutant id.
  """
  @type t :: %{
          aggregate: MapSet.t(pos_integer()),
          by_file: %{String.t() => MapSet.t(pos_integer())}
        }

  @doc """
  Read and decode the probe's coverage dump at `path`.

  Returns `{:error, _}` on anything unusable (missing file, truncated/garbled
  payload, unexpected shape) — the caller degrades such uncertainty to running the
  whole suite, never to a false `:no_coverage`.
  """
  @spec read_dump(Path.t()) :: {:ok, t()} | {:error, term()}
  def read_dump(path) do
    with {:ok, binary} <- read_file(path),
         {:ok, %{aggregate: aggregate, by_file: by_file}} <- decode(binary),
         true <- is_list(aggregate) and is_map(by_file) do
      {:ok,
       %{
         aggregate: MapSet.new(aggregate),
         by_file: Map.new(by_file, fn {file, ids} -> {file, MapSet.new(ids)} end)
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

  defp read_file(path) do
    case File.read(path) do
      {:ok, binary} -> {:ok, binary}
      {:error, reason} -> {:error, reason}
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
