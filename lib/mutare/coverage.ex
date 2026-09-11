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
  (both keyed by mutant id):

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
  capture table is missing, so lost capture data cannot masquerade as zero hits,
  and it always writes all five keys — a dump missing one is malformed, not a
  partial capture, and is rejected like any other wrong shape.

  Schema dumps record `{file_namespace, local_id}` identities; standalone
  transforms record integers. On disk, each id collection groups local ids under
  their namespace (`nil` for integers), so a file path appears once per group, not
  once per id. `read_dump/2` flattens the groups and accepts
  `Mutare.RuntimeId.index(schema.sites)` to translate every collection to report
  ids before the runner consumes it. An unknown identity invalidates the dump and
  triggers run-all, never false no-coverage. `read_dump/1` exposes the runtime
  identities as recorded.

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
  """
  @type t :: %__MODULE__{
          aggregate: MapSet.t(Mutare.RuntimeId.t()),
          by_file: %{String.t() => MapSet.t(Mutare.RuntimeId.t())},
          unlabeled: MapSet.t(Mutare.RuntimeId.t()),
          by_test: %{Mutare.RuntimeId.t() => MapSet.t(String.t())},
          wholefile: MapSet.t(Mutare.RuntimeId.t())
        }

  @enforce_keys [:aggregate, :by_file, :unlabeled, :by_test, :wholefile]
  defstruct @enforce_keys

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
         {:ok, coverage} <- translate(decoded, report_ids) do
      {:ok, coverage}
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

  # Flatten each namespace group back to runtime identities and, given an index, convert those to
  # report ids — every id-bearing field together, into the `MapSet`s the runner consumes. A
  # missing identity is uncertainty, never an absent hit: the first one stops the translation
  # with `{:error, {:unknown_runtime_id, id}}`, and the runner falls back to running every
  # mutant.
  defp translate(decoded, report_ids) do
    lookup = lookup(report_ids)

    with {:ok, aggregate} <- id_set(decoded.aggregate, lookup),
         {:ok, unlabeled} <- id_set(decoded.unlabeled, lookup),
         {:ok, wholefile} <- id_set(decoded.wholefile, lookup),
         {:ok, by_file} <- map_values(decoded.by_file, &id_set(&1, lookup)),
         {:ok, by_test} <- names_by_id(decoded.by_test, lookup) do
      {:ok,
       %__MODULE__{
         aggregate: aggregate,
         by_file: by_file,
         unlabeled: unlabeled,
         by_test: by_test,
         wholefile: wholefile
       }}
    end
  end

  # The identity translation: report ids through the index, or the runtime identities as
  # recorded when there is none. Returns `{:ok, id}` or `:error` for an identity the index lacks.
  defp lookup(nil), do: &{:ok, &1}
  defp lookup(report_ids), do: &Map.fetch(report_ids, &1)

  # A namespace-grouped id collection → `{:ok, MapSet}` of translated ids.
  defp id_set(grouped, lookup) do
    grouped
    |> Enum.flat_map(fn {namespace, locals} -> Enum.map(locals, &runtime_id(namespace, &1)) end)
    |> translate_all(lookup)
    |> case do
      {:ok, ids} -> {:ok, MapSet.new(ids)}
      error -> error
    end
  end

  # The per-test attribution — `%{namespace => %{local => names}}` — flattened to
  # `%{id => MapSet(names)}` with every id translated.
  defp names_by_id(by_test, lookup) do
    entries =
      for {namespace, names_by_local} <- by_test,
          {local, names} <- names_by_local,
          do: {runtime_id(namespace, local), MapSet.new(names)}

    with {:ok, ids} <- translate_all(Enum.map(entries, &elem(&1, 0)), lookup) do
      {:ok, ids |> Enum.zip(Enum.map(entries, &elem(&1, 1))) |> Map.new()}
    end
  end

  # Translate every identity (order preserved), or stop at the first the index lacks.
  defp translate_all(runtime_ids, lookup) do
    Enum.reduce_while(runtime_ids, {:ok, []}, fn runtime_id, {:ok, acc} ->
      case lookup.(runtime_id) do
        {:ok, id} -> {:cont, {:ok, [id | acc]}}
        :error -> {:halt, {:error, {:unknown_runtime_id, runtime_id}}}
      end
    end)
    |> case do
      {:ok, reversed} -> {:ok, Enum.reverse(reversed)}
      error -> error
    end
  end

  # Apply `fun` (returning `{:ok, value} | {:error, _}`) to each value of `map`, stopping at the
  # first error.
  defp map_values(map, fun) do
    Enum.reduce_while(map, {:ok, %{}}, fn {key, value}, {:ok, acc} ->
      case fun.(value) do
        {:ok, translated} -> {:cont, {:ok, Map.put(acc, key, translated)}}
        error -> {:halt, error}
      end
    end)
  end

  defp runtime_id(nil, id), do: id
  defp runtime_id(namespace, id), do: {namespace, id}

  # The decoded payload must be a map carrying all five keys with the field types the rest of the
  # module assumes (the helper always writes all five — `Mutare.Coverage.HelperTemplate`). A
  # valid-but-wrong-shaped term (e.g. an atom, or a map missing a key) routes to `:bad_shape` →
  # the caller's run-all fallback, never a false `:no_coverage` and never an unhandled
  # `{:ok, term}` crashing the `with`.
  #
  # The check goes all the way *into* the collections, not just their outer type, because the
  # elements are what the rest of the pipeline consumes: `MapSet.new/1` raises
  # `Protocol.UndefinedError` on a non-enumerable `by_file` value, and a non-binary `by_file` key or
  # `by_test` name reaches `mix test` argv in `Mutare.Runner.CoverageProbe` (`"test:" <> name`
  # raises on a non-binary). Either would escape `read_dump/1` as an exception, contradicting the
  # documented `{:error, _}` contract. The traversal is O(dump) and runs once, right after a full
  # instrumented suite — free next to what it guards.
  defp valid_shape(%{
         aggregate: aggregate,
         by_file: by_file,
         unlabeled: unlabeled,
         by_test: by_test,
         wholefile: wholefile
       }) do
    if grouped_ids?(aggregate) and
         grouped_ids?(unlabeled) and
         grouped_ids?(wholefile) and
         map_of?(by_file, &is_binary/1, &grouped_ids?/1) and
         map_of?(by_test, &namespace?/1, &names_by_id?/1),
       do: :ok,
       else: :bad_shape
  end

  defp valid_shape({:error, {:missing_coverage_table, _table} = reason}), do: {:error, reason}
  defp valid_shape(_other), do: :bad_shape

  # Ids arrive grouped under the file namespace a schema build recorded them with, or under `nil` for
  # a standalone transform's integers. Baseline zero is never a recorded mutant.
  defp grouped_ids?(grouped), do: map_of?(grouped, &namespace?/1, &ids?/1)

  defp namespace?(namespace), do: is_nil(namespace) or (is_binary(namespace) and namespace != "")

  defp id?(id), do: is_integer(id) and id > 0

  defp ids?(list), do: is_list(list) and Enum.all?(list, &id?/1)

  defp names?(list), do: is_list(list) and Enum.all?(list, &is_binary/1)

  defp names_by_id?(map), do: map_of?(map, &id?/1, &names?/1)

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
