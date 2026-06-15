defmodule Mutare.Runner do
  @moduledoc """
  Compile once, then run the suite once per mutant in a fresh OS process.

  The flow protects the one-compile invariant: we compile the sandbox a single
  time, run the baseline green, then launch one `mix test` process per mutant
  with `MUTANT_UNDER_TEST` set. Sources never change between runs, so mix's
  incremental compiler finds nothing to rebuild — the per-mutant cost is process
  boot plus the suite, never recompilation.

  ## Coverage probe (test selection)

  Before the per-mutant loop we run a coverage probe (`Mutare.Runner.Probe`),
  which doubles as the green baseline check and, per mutant, picks the test files
  it needs (or marks it `:no_coverage`). See that module for the selection modes.

  ## Parallel workers and timeouts

  The per-mutant phase runs `:workers` mutants concurrently (default
  `System.schedulers_online/0`), each its own `mix test` OS process in the shared
  sandbox. Each run has a wall-clock cap (`baseline × :timeout_multiplier`,
  default 3.0, with a floor; or an explicit `:timeout` in ms): a mutation can
  turn a terminating loop infinite, so the run is capped.

  The cap is enforced *portably* by the mutant run **halting itself** — the
  injected watcher (see `Mutare.Sandbox`) calls `System.halt/1` after the
  deadline — rather than the runner killing an OS process tree (which needs
  platform-specific signals). A capped run exits with
  `Mutare.Sandbox.Command.timeout_exit/0`, which we count as `:timeout` (a kill —
  the hang is observable misbehavior).
  """

  alias Mutare.{Options, Poison, Result, Sandbox, Schema, Selector, Site}
  alias Mutare.Runner.Probe
  alias Mutare.Sandbox.Command

  @timeout_exit Command.timeout_exit()

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

  `opts` is a `Mutare.Options` (or a keyword list resolved into one). Returns
  `{:ok, run}` or `{:error, reason, detail}`.
  """
  @spec run(Path.t(), Options.t() | keyword()) :: {:ok, run()} | error()
  def run(root \\ ".", opts \\ []) do
    options = Options.new(opts)
    schema = Schema.build(root, options)
    run_with_schema(schema, root, options)
  end

  @doc """
  Run a pre-built schema (lets a caller report the mutant count before launching).

  `opts` is a `Mutare.Options` (or a keyword list resolved into one). Beyond the
  schema/sandbox fields, it uses `:reporter` — a 1-arity function called with each
  `Mutare.Result` as it completes, for live progress — and `:test_selection`,
  `:workers`, `:timeout`, `:timeout_multiplier`.
  """
  @spec run_with_schema(Schema.t(), Path.t(), Options.t() | keyword()) ::
          {:ok, run()} | error()
  def run_with_schema(%Schema{} = schema, root \\ ".", opts \\ []) do
    options = Options.new(opts)

    if Schema.count(schema) == 0 do
      {:error, :nothing_to_mutate, "no mutation sites found under #{inspect(options.paths)}"}
    else
      reporter = options.reporter || fn _result -> :ok end
      mode = options.test_selection

      # Prepare + compile, recovering from compile-poisoning by dropping the
      # offending mutants and rebuilding. `schema` here may differ from the input
      # (poisoners flagged), which is what the run reports against.
      with {:ok, schema, sandbox} <- prepare_compiling(schema, root, options),
           {:ok, baseline_ms, selection} <- Probe.run(sandbox, schema, mode) do
        cap = timeout_cap(baseline_ms, options)
        workers = options.workers

        results =
          schema.sites
          |> Task.async_stream(
            fn site ->
              result = classify(sandbox, site, selection, cap)
              reporter.(result)
              result
            end,
            max_concurrency: workers,
            ordered: true,
            timeout: :infinity
          )
          |> Enum.map(fn {:ok, result} -> result end)

        {:ok, %{schema: schema, results: results, sandbox: sandbox, baseline_ms: baseline_ms}}
      end
    end
  end

  # Per-mutant wall-clock cap. An explicit `:timeout` (ms) wins; otherwise
  # baseline × `:timeout_multiplier` (default 3.0), with a floor so tiny suites
  # don't get an absurdly small cap. A mutation can turn a terminating loop
  # infinite, so without a cap a single mutant could hang the whole run.
  defp timeout_cap(_baseline_ms, %Options{timeout: ms}) when is_integer(ms) and ms > 0, do: ms

  defp timeout_cap(baseline_ms, %Options{timeout_multiplier: multiplier}) do
    # A generous floor: under parallel workers the baseline (measured
    # uncontended) underestimates a mutant's wall time, so a tight cap would
    # false-timeout a slow-but-finite mutant. A true infinite loop runs far
    # past any floor, so we still catch it.
    max(round(baseline_ms * multiplier), 10_000)
  end

  # Materialise the schema and compile it once, recovering from compile-poisoning.
  @poison_attempts 25

  defp prepare_compiling(
         schema,
         root,
         %Options{} = options,
         skip_ids \\ MapSet.new(),
         attempts \\ @poison_attempts
       ) do
    sandbox = Sandbox.prepare(root, schema, options)

    case compile(sandbox) do
      :ok ->
        {:ok, schema, sandbox}

      {:error, :compile_failed, output} = failure ->
        poison = Poison.ids(output, schema.metamutants)

        if attempts > 0 and not MapSet.subset?(poison, skip_ids) do
          # Drop the poisoning mutants and rebuild. Ids are stable across rebuilds
          # (the transform advances its counter for skipped ids), so accumulated
          # `skip_ids` keep referring to the same mutations.
          skip_ids = MapSet.union(skip_ids, poison)
          # Rebuild against the *same* files this schema covers (not a fresh
          # discovery), so a restricted schema (`from_files/4`, `:only_files`,
          # `:exclude`) can't silently expand. Forward the original options so
          # `:mutators` survive; ids stay stable across rebuilds.
          schema = Schema.rebuild(schema, root, options, skip_ids)
          prepare_compiling(schema, root, options, skip_ids, attempts - 1)
        else
          # Couldn't identify (or keep making progress on) the poison → give up.
          failure
        end
    end
  end

  # The one compilation.
  defp compile(sandbox) do
    case Command.mix(sandbox, ["compile"], Selector.baseline()) do
      {_output, 0} -> :ok
      {output, _status} -> {:error, :compile_failed, output}
    end
  end

  # === per-mutant runs =======================================================

  defp classify(_sandbox, %Site{poisoned: true} = site, _selection, _cap) do
    %Result{site: site, status: :poisoned, duration_ms: 0, output: nil}
  end

  defp classify(_sandbox, %Site{ignored: true} = site, _selection, _cap) do
    %Result{site: site, status: :ignored, duration_ms: 0, output: nil}
  end

  defp classify(sandbox, site, :run_all, cap), do: run_mutant(sandbox, site, [], cap)

  defp classify(sandbox, site, {:selective, outcomes}, cap) do
    case Map.fetch(outcomes, site.id) do
      {:ok, {:run, test_args}} ->
        run_mutant(sandbox, site, test_args, cap)

      {:ok, :no_coverage} ->
        %Result{site: site, status: :no_coverage, duration_ms: 0, output: nil}

      # `outcomes` is total over every mutant id, so this is unreachable in
      # practice; a missing id is a bug, not a no-coverage signal — run it rather
      # than silently drop a mutant from the score.
      :error ->
        run_mutant(sandbox, site, [], cap)
    end
  end

  defp run_mutant(sandbox, site, test_args, cap) do
    {ms, output, status} =
      Command.timed_mix(sandbox, ["test" | test_args], site.id, cap)

    %Result{site: site, status: classify_status(status), duration_ms: ms, output: output}
  end

  # exit 0 = every test passed despite the mutation → SURVIVED; the watcher's
  # exit code = the mutation caused a hang we capped (:timeout, a kill); any
  # other non-zero = a test failed → KILLED.
  defp classify_status(0), do: :survived
  defp classify_status(status) when status == @timeout_exit, do: :timeout
  defp classify_status(_status), do: :killed
end
