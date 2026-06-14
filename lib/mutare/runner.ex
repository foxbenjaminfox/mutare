defmodule Mutare.Runner do
  @moduledoc """
  Compile once, then run the suite once per mutant in a fresh OS process.

  The flow protects the one-compile invariant: we compile the sandbox a single
  time, run the baseline green, then launch one `mix test` process per mutant
  with `MUTANT_UNDER_TEST` set. Sources never change between runs, so mix's
  incremental compiler finds nothing to rebuild — the per-mutant cost is process
  boot plus the suite, never recompilation.

  M1 is whole-suite, single worker. Coverage-driven test selection, parallel
  workers, and timeouts arrive in later milestones.
  """

  alias Mutare.{Result, Sandbox, Schema}

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

      with :ok <- compile(sandbox),
           {:ok, baseline_ms} <- baseline(sandbox) do
        results =
          Enum.map(schema.sites, fn site ->
            result = run_mutant(sandbox, site)
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

  # Baseline must be green; a red or flaky suite makes mutation testing meaningless.
  defp baseline(sandbox) do
    {micros, {output, status}} = :timer.tc(fn -> mix(sandbox, ["test"], "0") end)

    if status == 0 do
      {:ok, div(micros, 1000)}
    else
      {:error, :baseline_failed, output}
    end
  end

  defp run_mutant(sandbox, site) do
    {micros, {output, status}} =
      :timer.tc(fn -> mix(sandbox, ["test"], Integer.to_string(site.id)) end)

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
