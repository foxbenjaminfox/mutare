defmodule Mutare.Runner.Probe do
  @moduledoc """
  The coverage probe: run the baseline once (green-checked) and decide, per
  mutant, which test files to run.

  Two modes, set by `:test_selection`:

    * `:coverage` (default) — run each test *file* once with `--cover` and record
      which selector lines it hits. Then per mutant, run only the files that
      cover its line; a mutant no file covers is `:no_coverage` (skipped, and
      kept out of the score's denominator). This is the "overnight → per-PR" win.
    * `:full` — one aggregate `--cover` run for no-coverage detection, then run
      the whole suite for every covered mutant (no per-file selection). Safer for
      suites with cross-file dependencies.

  Selection is file-granular, not per-individual-test: if any test in a file
  covers the line, the whole file runs — so a test that kills a mutant indirectly
  (without touching the line itself) is still included, as long as a sibling test
  in its file does touch the line.

  The probe doubles as the green baseline check: it runs the baseline mutant
  (`MUTANT_UNDER_TEST=0`), so a red probe means the baseline isn't green and the
  run aborts.
  """

  alias Mutare.{Coverage, Schema, Selector}
  alias Mutare.Sandbox.Command

  @typedoc """
  What the probe decided for one mutant:

    * `{:run, test_args}` — its selector line is covered; run `mix test` with
      these args (`[]` = whole suite, file-granular args otherwise).
    * `:no_coverage` — no test covers its line; skip it and keep it out of the
      score's denominator.
  """
  @type outcome :: {:run, [String.t()]} | :no_coverage

  @typedoc """
  What the probe decided for the whole run:

    * `:run_all` — coverage is unusable or uncertain (couldn't read coverdata, or
      not a single line registered a hit, which means `:cover` itself likely
      failed). Run *every* mutant against the whole suite — never skip on doubt.
    * `{:selective, outcomes}` — a per-mutant decision. `outcomes` is **total**:
      every mutant id maps to an explicit `outcome`, so a `:no_coverage` mutant
      is named, never implied by a missing key.
  """
  @type selection :: :run_all | {:selective, %{pos_integer() => outcome()}}

  @doc """
  Run the probe and build the per-mutant test selection.

  Returns `{:ok, baseline_ms, selection}` (see `t:selection/0` — either `:run_all`
  or `{:selective, outcomes}`). A red probe means the baseline isn't green →
  `{:error, :baseline_failed, output}`.
  """
  @spec run(Path.t(), Schema.t(), :coverage | :full) ::
          {:ok, non_neg_integer(), selection()} | {:error, :baseline_failed, String.t()}
  def run(sandbox, %Schema{} = schema, :full), do: aggregate_probe(sandbox, schema)
  def run(sandbox, %Schema{} = schema, :coverage), do: per_file_probe(sandbox, schema)

  # One aggregate `--cover` run: covered mutants run the whole suite.
  defp aggregate_probe(sandbox, schema) do
    args = ["test", "--cover", "--export-coverage", "mutare"]
    {ms, output, status} = Command.timed_mix(sandbox, args, Selector.baseline())

    if status == 0 do
      coverdata = Path.join(sandbox, "cover/mutare.coverdata")
      index = Coverage.index(Map.values(schema.metamutants))

      selection =
        case Coverage.hits(coverdata) do
          {:ok, hits} -> whole_suite_selection(index, hits)
          {:error, _reason} -> :run_all
        end

      {:ok, ms, selection}
    else
      {:error, :baseline_failed, output}
    end
  end

  # Full mode: a covered mutant runs the whole suite (`[]`), the rest are
  # `:no_coverage` — total over every mutant id. An empty hit set means `:cover`
  # recorded nothing (it likely failed), not that everything is genuinely
  # uncovered, so we don't skip the world — run everything instead.
  defp whole_suite_selection(index, hits) do
    if MapSet.size(hits) == 0 do
      :run_all
    else
      outcomes =
        Map.new(index, fn {id, module_line} ->
          if MapSet.member?(hits, module_line),
            do: {id, {:run, []}},
            else: {id, :no_coverage}
        end)

      {:selective, outcomes}
    end
  end

  # One `--cover` run per test file: a mutant runs only the files covering it.
  defp per_file_probe(sandbox, schema) do
    case test_files(sandbox) do
      [] ->
        aggregate_probe(sandbox, schema)

      files ->
        index = Coverage.index(Map.values(schema.metamutants))

        case run_files(sandbox, files) do
          {:error, output} ->
            {:error, :baseline_failed, output}

          # A coverdata read failed: coverage is uncertain. Run every mutant
          # against the whole suite rather than risk a false `:no_coverage` for
          # one whose only covering file we couldn't read.
          {:uncertain, ms} ->
            {:ok, ms, :run_all}

          {:ok, ms, file_hits} ->
            {:ok, ms, per_file_selection(index, file_hits)}
        end
    end
  end

  # Run each test file with --cover (green-checked), collecting its hit set. A
  # green run whose coverdata we can't read is `:uncertain` — we must not turn an
  # unreadable file into an empty hit set, which would silently drop mutants to
  # `:no_coverage`. Bail to conservative (`:run_all`) execution instead.
  defp run_files(sandbox, files) do
    files
    |> Enum.with_index()
    |> Enum.reduce_while({:ok, 0, %{}}, fn {file, index}, {:ok, ms, acc} ->
      name = cover_name(file, index)
      args = ["test", file, "--cover", "--export-coverage", name]
      {file_ms, output, status} = Command.timed_mix(sandbox, args, Selector.baseline())

      if status == 0 do
        case Coverage.hits(Path.join(sandbox, "cover/#{name}.coverdata")) do
          {:ok, hits} -> {:cont, {:ok, ms + file_ms, Map.put(acc, file, hits)}}
          {:error, _reason} -> {:halt, {:uncertain, ms + file_ms}}
        end
      else
        {:halt, {:error, output}}
      end
    end)
  end

  # Per mutant, the test files that cover its line — total over every mutant id,
  # with `:no_coverage` named explicitly (never implied by a missing key). If not
  # a single file covered anything, `:cover` likely failed (rather than the suite
  # genuinely covering nothing), so run everything instead of skipping the world.
  defp per_file_selection(index, file_hits) do
    if Enum.all?(file_hits, fn {_file, hits} -> MapSet.size(hits) == 0 end) do
      :run_all
    else
      outcomes =
        Map.new(index, fn {id, module_line} ->
          case covering_files(file_hits, module_line) do
            [] -> {id, :no_coverage}
            files -> {id, {:run, files}}
          end
        end)

      {:selective, outcomes}
    end
  end

  defp covering_files(file_hits, module_line) do
    for {file, hits} <- file_hits, MapSet.member?(hits, module_line), do: file
  end

  defp test_files(sandbox) do
    sandbox
    |> Path.join("test/**/*_test.exs")
    |> Path.wildcard()
    |> Enum.map(&Path.relative_to(&1, sandbox))
    |> Enum.sort()
  end

  # Each file needs its own `cover/<name>.coverdata`. Sanitizing the path alone is
  # lossy — `test/foo_bar_test.exs` and `test/foo/bar_test.exs` both collapse to
  # `test_foo_bar_test_exs` — so colliding files would share a coverdata file and
  # clobber each other's hits. Appending the index makes the name unique: the file
  # list is sorted and distinct, so each index is too, regardless of iteration
  # order (so it stays collision-free even if the per-file probe is parallelized).
  defp cover_name(file, index) do
    "#{String.replace(file, ~r/[^A-Za-z0-9]/, "_")}_#{index}"
  end
end
