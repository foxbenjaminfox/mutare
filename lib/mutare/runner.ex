defmodule Mutare.Runner do
  @moduledoc """
  Compile once, then run the suite once per mutant in a fresh OS process.

  The flow protects the one-compile invariant: we compile the sandbox a single
  time, run the baseline green, then launch one `mix test` process per mutant
  with `MUTANT_UNDER_TEST` set. Sources never change between runs, so mix's
  incremental compiler finds nothing to rebuild — the per-mutant cost is process
  boot plus the suite, never recompilation.

  ## Coverage probe (test selection)

  Before the per-mutant loop we run a coverage probe (the baseline, green-checked
  in the same pass). Two modes, set by `:test_selection`:

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

  Single worker still; parallel workers and timeouts are M4.
  """

  alias Mutare.{Coverage, Result, Sandbox, Schema}

  @type run :: %{
          schema: Schema.t(),
          results: [Result.t()],
          sandbox: Path.t(),
          baseline_ms: non_neg_integer()
        }

  @type error ::
          {:error, :compile_failed | :baseline_failed | :nothing_to_mutate, String.t()}

  @doc """
  Run mutation testing against the project at `root`.

  Returns `{:ok, run}` or `{:error, reason, detail}`. Options are forwarded to
  `Mutare.Schema.build/2` and `Mutare.Sandbox.prepare/3`.
  """
  @spec run(Path.t(), keyword()) :: {:ok, run()} | error()
  def run(root \\ ".", opts \\ []) do
    schema = Schema.build(root, opts)
    run_with_schema(schema, root, opts)
  end

  @doc """
  Run a pre-built schema (lets a caller report the mutant count before launching).

  Recognised options: `:sandbox` (forwarded) and `:reporter`, a 1-arity
  function called with each `Mutare.Result` as it completes — for live progress.
  """
  @spec run_with_schema(Schema.t(), Path.t(), keyword()) :: {:ok, run()} | error()
  def run_with_schema(%Schema{} = schema, root \\ ".", opts \\ []) do
    if Schema.count(schema) == 0 do
      {:error, :nothing_to_mutate,
       "no mutation sites found under #{inspect(opts[:paths] || ["lib"])}"}
    else
      sandbox = Sandbox.prepare(root, schema, opts)
      reporter = Keyword.get(opts, :reporter, fn _result -> :ok end)
      mode = Keyword.get(opts, :test_selection, :coverage)

      with :ok <- compile(sandbox),
           {:ok, baseline_ms, selection} <- probe(sandbox, schema, mode) do
        results =
          Enum.map(schema.sites, fn site ->
            result = classify(sandbox, site, selection)
            reporter.(result)
            result
          end)

        {:ok, %{schema: schema, results: results, sandbox: sandbox, baseline_ms: baseline_ms}}
      end
    end
  end

  # The one compilation.
  defp compile(sandbox) do
    case mix(sandbox, ["compile"], "0") do
      {_output, 0} -> :ok
      {output, _status} -> {:error, :compile_failed, output}
    end
  end

  # === coverage probe ========================================================
  #
  # Returns {:ok, baseline_ms, selection} where selection is either `:all` (run
  # every mutant against the whole suite) or `%{id => test_args}` — ids present
  # run with those `mix test` args ([] = whole suite); ids absent are
  # :no_coverage. A red probe means the baseline isn't green → abort.

  defp probe(sandbox, schema, :full), do: aggregate_probe(sandbox, schema)
  defp probe(sandbox, schema, _coverage), do: per_file_probe(sandbox, schema)

  # One aggregate `--cover` run: covered mutants run the whole suite.
  defp aggregate_probe(sandbox, schema) do
    args = ["test", "--cover", "--export-coverage", "mutare"]
    {micros, {output, status}} = :timer.tc(fn -> mix(sandbox, args, "0") end)

    if status == 0 do
      coverdata = Path.join(sandbox, "cover/mutare.coverdata")

      selection =
        case Coverage.covered_ids(Map.values(schema.metamutants), coverdata) do
          {:ok, covered} -> Map.new(covered, &{&1, []})
          {:error, _reason} -> :all
        end

      {:ok, div(micros, 1000), selection}
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

          {:ok, ms, file_hits} ->
            {:ok, ms, selection(index, file_hits)}
        end
    end
  end

  # Run each test file with --cover (green-checked), collecting its hit set.
  defp run_files(sandbox, files) do
    Enum.reduce_while(files, {:ok, 0, %{}}, fn file, {:ok, ms, acc} ->
      name = cover_name(file)
      args = ["test", file, "--cover", "--export-coverage", name]
      {micros, {output, status}} = :timer.tc(fn -> mix(sandbox, args, "0") end)

      if status == 0 do
        hits =
          case Coverage.hits(Path.join(sandbox, "cover/#{name}.coverdata")) do
            {:ok, hits} -> hits
            {:error, _} -> MapSet.new()
          end

        {:cont, {:ok, ms + div(micros, 1000), Map.put(acc, file, hits)}}
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

  # === per-mutant runs =======================================================

  defp classify(sandbox, site, :all), do: run_mutant(sandbox, site, [])

  defp classify(sandbox, site, selection) when is_map(selection) do
    case Map.fetch(selection, site.id) do
      {:ok, test_args} -> run_mutant(sandbox, site, test_args)
      :error -> %Result{site: site, status: :no_coverage, duration_ms: 0, output: nil}
    end
  end

  defp run_mutant(sandbox, site, test_args) do
    {micros, {output, status}} =
      :timer.tc(fn -> mix(sandbox, ["test" | test_args], Integer.to_string(site.id)) end)

    %Result{
      site: site,
      # exit 0 means every test passed *despite* the mutation → it SURVIVED.
      status: if(status == 0, do: :survived, else: :killed),
      duration_ms: div(micros, 1000),
      output: output
    }
  end

  defp mix(sandbox, args, mutant_id) do
    System.cmd("mix", args,
      cd: sandbox,
      stderr_to_stdout: true,
      env: [{"MIX_ENV", "test"}, {Mutare.Selector.env_var(), mutant_id}]
    )
  end
end
