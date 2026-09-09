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
      recoverable test label *at all* — a bare spawn, a `setup`-registered `on_exit`
      closure, or the rare `setup_all` whose work happened off-stack in a `Task` it
      spawned (an `on_exit` registered in a test body *is* recovered, via its
      closure frame in ExUnit's per-test runner process). An id here
      was covered, but *which* test owns it is unknown, so the caller runs the
      **whole suite** for it — even if `:by_file` *also* attributes it to some file,
      since that partial attribution would otherwise mask the unlabeled coverage and
      manufacture a false survivor.

  Two more keys carry the finer **test-case** granularity `:tests` selection uses
  (both keyed by mutant id, both empty in a dump written before this contract, so an
  old dump degrades `:tests` to `:coverage`):

    * `:by_test` — `%{mutant id => MapSet(runnable test names)}`: the individual
      ExUnit tests (`test `/`doctest `/`property ` names) that covered each id, so a
      mutant can run `mix test <file> --only test:<name>` instead of the whole file.
    * `:wholefile` — the set of ids with a labeled but **non-narrowable**
      attribution (a `setup_all` or an `on_exit`, which cover through a module-scoped
      context, not a single runnable test). `:tests` must run the whole file for such
      an id — narrowing to named tests would drop the covering context and
      manufacture a false survivor.

  `Mutare.Runner.CoverageProbe` reconciles them all. A valid empty aggregate means
  no emitted mutant was covered. The helper writes an explicit error if any
  capture table is missing, so lost capture data cannot masquerade as zero hits.

  Schema dumps use `{file_namespace, local_id}` identities; standalone transforms
  use integers. `read_dump/2` accepts `Mutare.RuntimeId.index(schema.sites)` and
  translates every collection to report ids before the runner consumes it. An
  unknown identity invalidates the dump and triggers run-all, never false
  no-coverage. `read_dump/1` exposes the runtime identities as recorded.

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
  The decoded dump. Keyed by mutant id throughout:

    * `aggregate` — the process-agnostic hit set (no-coverage detection).
    * `by_file` — per-test-*file* attribution (`:coverage` selection, and the
      `:tests` fallback).
    * `unlabeled` — the whole-suite hit set.
    * `by_test` — per-test-*case* attribution: `id => runnable test names` that
      covered it (`:tests` narrowing).
    * `wholefile` — ids with a labeled but non-narrowable attribution
      (`setup_all`/`on_exit`), which `:tests` must not narrow to named tests.

  `by_test`/`wholefile` are absent from a dump written before this contract; they
  default to empty so an old dump still reads (degrading `:tests` to `:coverage`).
  """
  @type t :: %{
          aggregate: MapSet.t(Mutare.RuntimeId.t()),
          by_file: %{String.t() => MapSet.t(Mutare.RuntimeId.t())},
          unlabeled: MapSet.t(Mutare.RuntimeId.t()),
          by_test: %{Mutare.RuntimeId.t() => MapSet.t(String.t())},
          wholefile: MapSet.t(Mutare.RuntimeId.t())
        }

  @doc """
  Read and decode the probe's coverage dump at `path`.

  An optional runtime-to-report index translates every recorded identity. Omitting
  it returns raw runtime identities, useful for inspecting a standalone dump.

  Returns `{:error, _}` on anything unusable (missing file, truncated/garbled
  payload, a capture error from the helper, unexpected shape — including a
  well-formed outer map whose *nested* keys, ids or collections are the wrong type)
  — the caller degrades such uncertainty to running the whole suite, never to a
  false `:no_coverage`. It raises for no input.
  """
  @spec read_dump(Path.t(), map() | nil) :: {:ok, t()} | {:error, term()}
  def read_dump(path, report_ids \\ nil) do
    with {:ok, binary} <- File.read(path),
         {:ok, decoded} <- decode(binary),
         :ok <- valid_shape(decoded),
         {:ok, decoded} <- translate(decoded, report_ids) do
      %{aggregate: aggregate, by_file: by_file} = decoded
      unlabeled = Map.get(decoded, :unlabeled, [])
      by_test = Map.get(decoded, :by_test, %{})
      wholefile = Map.get(decoded, :wholefile, [])

      {:ok,
       %{
         aggregate: MapSet.new(aggregate),
         by_file: Map.new(by_file, fn {file, ids} -> {file, MapSet.new(ids)} end),
         unlabeled: MapSet.new(unlabeled),
         by_test: Map.new(by_test, fn {id, names} -> {id, MapSet.new(names)} end),
         wholefile: MapSet.new(wholefile)
       }}
    else
      {:error, reason} ->
        Logger.warning(
          "coverage dump unusable (#{path}), falling back to run-all: #{inspect(reason)}"
        )

        {:error, reason}

      :bad_shape ->
        Logger.warning("coverage dump has unexpected shape (#{path}), falling back to run-all")
        {:error, :bad_shape}
    end
  end

  # Convert every id-bearing field together. A missing identity is uncertainty,
  # never an absent hit: the runner must fall back to running every mutant.
  defp translate(decoded, nil), do: {:ok, decoded}

  defp translate(decoded, report_ids) do
    id = &Map.fetch!(report_ids, &1)
    ids = &Enum.map(&1, id)

    {:ok,
     %{
       aggregate: ids.(decoded.aggregate),
       by_file: Map.new(decoded.by_file, fn {file, hits} -> {file, ids.(hits)} end),
       unlabeled: ids.(Map.get(decoded, :unlabeled, [])),
       by_test:
         Map.new(Map.get(decoded, :by_test, %{}), fn {hit, names} -> {id.(hit), names} end),
       wholefile: ids.(Map.get(decoded, :wholefile, []))
     }}
  rescue
    error in KeyError -> {:error, {:unknown_runtime_id, error.key}}
  end

  # The decoded payload must be a map carrying the keys and field types the rest of the module
  # assumes. A valid-but-wrong-shaped term (e.g. an atom, or a map missing `:aggregate`/`:by_file`)
  # routes to `:bad_shape` → the caller's run-all fallback, never a false `:no_coverage` and never
  # an unhandled `{:ok, term}` crashing the `with`.
  #
  # The check goes all the way *into* the collections, not just their outer type, because the
  # elements are what the rest of the pipeline consumes: `MapSet.new/1` raises
  # `Protocol.UndefinedError` on a non-enumerable `by_file` value, and a non-binary `by_file` key or
  # `by_test` name reaches `mix test` argv in `Mutare.Runner.CoverageProbe` (`"test:" <> name`
  # raises on a non-binary). Either would escape `read_dump/1` as an exception, contradicting the
  # documented `{:error, _}` contract. The traversal is O(dump) and runs once, right after a full
  # instrumented suite — free next to what it guards.
  defp valid_shape(%{aggregate: aggregate, by_file: by_file} = decoded) do
    if ids?(aggregate) and
         ids?(Map.get(decoded, :unlabeled, [])) and
         ids?(Map.get(decoded, :wholefile, [])) and
         map_of?(by_file, &is_binary/1, &ids?/1) and
         map_of?(Map.get(decoded, :by_test, %{}), &id?/1, &names?/1),
       do: :ok,
       else: :bad_shape
  end

  defp valid_shape({:error, {:missing_coverage_table, _table} = reason}), do: {:error, reason}
  defp valid_shape(_other), do: :bad_shape

  # Integer ids belong to standalone transforms; schema ids include their file
  # namespace. Baseline zero is never a recorded mutant.
  defp id?({namespace, id}),
    do: is_binary(namespace) and namespace != "" and is_integer(id) and id > 0

  defp id?(id), do: is_integer(id) and id > 0

  defp ids?(list), do: is_list(list) and Enum.all?(list, &id?/1)

  defp names?(list), do: is_list(list) and Enum.all?(list, &is_binary/1)

  # `Map.to_list/1` rather than enumerating `map` directly: a struct is a map, and enumerating one
  # that implements `Enumerable` (a `MapSet`, say) yields bare elements the `{k, v}` clause would
  # crash on. Expanding the struct to its fields instead lets it fail the key check like any other
  # wrong shape.
  defp map_of?(map, key?, value?) do
    is_map(map) and Enum.all?(Map.to_list(map), fn {k, v} -> key?.(k) and value?.(v) end)
  end

  # `:erlang.binary_to_term` raises on a truncated/garbage payload — turn that
  # into an `{:error, _}` like every other unusable-dump case.
  defp decode(binary) do
    {:ok, :erlang.binary_to_term(binary)}
  rescue
    error -> {:error, error}
  end
end
