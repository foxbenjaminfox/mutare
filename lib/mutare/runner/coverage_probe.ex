defmodule Mutare.Runner.CoverageProbe do
  @moduledoc """
  Decide, per mutant, which test files to run — coverage-driven test selection.

  Runs *after* `Mutare.Runner.Baseline` has confirmed the suite green and measured
  the timing; this module is purely about coverage and never green-checks or times
  anything. Keeping the two apart is the point: folding coverage into the baseline
  made `baseline_ms` a sum of per-file process boots (an inflated timeout cap), and
  meant the suite was never confirmed green *together* — only file-by-file.

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

  Coverage is advisory, never authoritative. Anything uncertain — an unreadable
  coverdata, a `--cover` run that recorded nothing, or a probe file that isn't
  green *in isolation* (a cross-file dependency) — degrades to `:run_all`: we
  never skip a mutant on doubt. A probe file failing in isolation is no longer a
  red baseline (the baseline already proved the suite green together); it is just
  coverage we couldn't gather, so we run everything rather than abort.
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

    * `:run_all` — coverage is unusable or uncertain (couldn't read coverdata, a
      probe file wasn't green in isolation, or not a single line registered a hit,
      which means `:cover` itself likely failed). Run *every* mutant against the
      whole suite — never skip on doubt.
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
  def run(sandbox, %Schema{} = schema, :full), do: aggregate_probe(sandbox, schema)
  def run(sandbox, %Schema{} = schema, :coverage), do: per_file_probe(sandbox, schema)

  # One aggregate `--cover` run: covered mutants run the whole suite. A non-green
  # cover run (anomalous — the baseline already passed) or an unreadable coverdata
  # is coverage we can't trust → `:run_all`.
  defp aggregate_probe(sandbox, schema) do
    args = ["test", "--cover", "--export-coverage", "mutare"]
    {_output, status} = Command.mix(sandbox, args, Selector.baseline())

    with 0 <- status,
         {:ok, hits} <- Coverage.hits(Path.join(sandbox, "cover/mutare.coverdata")) do
      index = Coverage.index(Map.values(schema.metamutants))
      whole_suite_selection(index, hits)
    else
      _ -> :run_all
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
        # A probe file that wasn't green in isolation, or a coverdata we couldn't
        # read: coverage is uncertain. Run every mutant against the whole suite
        # rather than risk a false `:no_coverage` for one whose only covering file
        # we couldn't read.
        case run_files(sandbox, files) do
          :uncertain ->
            :run_all

          {:ok, file_hits} ->
            index = Coverage.index(Map.values(schema.metamutants))
            per_file_selection(index, file_hits)
        end
    end
  end

  # Run each test file with --cover, collecting its hit set. A file that isn't
  # green in isolation or whose coverdata we can't read is `:uncertain` — we must
  # not turn an unreadable/failed file into an empty hit set, which would silently
  # drop mutants to `:no_coverage`. The caller bails to conservative `:run_all`.
  defp run_files(sandbox, files) do
    files
    |> Enum.with_index()
    |> Enum.reduce_while({:ok, %{}}, fn {file, index}, {:ok, acc} ->
      name = cover_name(file, index)
      args = ["test", file, "--cover", "--export-coverage", name]
      {_output, status} = Command.mix(sandbox, args, Selector.baseline())

      with 0 <- status,
           {:ok, hits} <- Coverage.hits(Path.join(sandbox, "cover/#{name}.coverdata")) do
        {:cont, {:ok, Map.put(acc, file, hits)}}
      else
        _ -> {:halt, :uncertain}
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
