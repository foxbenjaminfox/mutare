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

  alias Mutare.{Coverage, Schema}
  alias Mutare.Sandbox.Command

  @type selection :: :all | %{pos_integer() => [String.t()]}

  @doc """
  Run the probe and build the per-mutant test selection.

  Returns `{:ok, baseline_ms, selection}` where `selection` is either `:all`
  (run every mutant against the whole suite) or `%{id => test_args}` — ids
  present run with those `mix test` args (`[]` = whole suite); ids absent are
  `:no_coverage`. A red probe means the baseline isn't green → `{:error,
  :baseline_failed, output}`.
  """
  @spec run(Path.t(), Schema.t(), :coverage | :full) ::
          {:ok, non_neg_integer(), selection()} | {:error, :baseline_failed, String.t()}
  def run(sandbox, %Schema{} = schema, :full), do: aggregate_probe(sandbox, schema)
  def run(sandbox, %Schema{} = schema, _coverage), do: per_file_probe(sandbox, schema)

  # One aggregate `--cover` run: covered mutants run the whole suite.
  defp aggregate_probe(sandbox, schema) do
    args = ["test", "--cover", "--export-coverage", "mutare"]
    {ms, output, status} = Command.timed_mix(sandbox, args, "0")

    if status == 0 do
      coverdata = Path.join(sandbox, "cover/mutare.coverdata")

      selection =
        case Coverage.covered_ids(Map.values(schema.metamutants), coverdata) do
          {:ok, covered} -> Map.new(covered, &{&1, []})
          {:error, _reason} -> :all
        end

      {:ok, ms, selection}
    else
      {:error, :baseline_failed, output}
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

          # A coverdata read failed: coverage is uncertain. Run every covered
          # mutant against the whole suite rather than risk skipping one whose
          # only covering file we couldn't read (false :no_coverage).
          {:uncertain, ms} ->
            {:ok, ms, :all}

          {:ok, ms, file_hits} ->
            {:ok, ms, selection(index, file_hits)}
        end
    end
  end

  # Run each test file with --cover (green-checked), collecting its hit set.
  # A green run whose coverdata we can't read is `:uncertain` — we must not turn
  # an unreadable file into an empty hit set, which would silently drop mutants
  # to :no_coverage. Bail to conservative (:all) execution instead.
  defp run_files(sandbox, files) do
    Enum.reduce_while(files, {:ok, 0, %{}}, fn file, {:ok, ms, acc} ->
      name = cover_name(file)
      args = ["test", file, "--cover", "--export-coverage", name]
      {file_ms, output, status} = Command.timed_mix(sandbox, args, "0")

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

  # Build %{id => covering files}. If nothing was covered at all, cover probably
  # failed — fall back to running everything (:all) rather than skip the world.
  defp selection(index, file_hits) do
    if Enum.all?(file_hits, fn {_file, hits} -> MapSet.size(hits) == 0 end) do
      :all
    else
      for {id, module_line} <- index,
          files = covering_files(file_hits, module_line),
          files != [],
          into: %{},
          do: {id, files}
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

  defp cover_name(file), do: String.replace(file, ~r/[^A-Za-z0-9]/, "_")
end
