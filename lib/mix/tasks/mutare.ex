defmodule Mix.Tasks.Mutare do
  @shortdoc "Run mutation testing: compile once, run the suite per mutant"
  @moduledoc """
  Mutation-test the current project.

  Builds a single metamutant embedding every mutant behind a runtime switch,
  compiles it once, runs the suite green as a baseline, then runs the suite once
  per mutant and reports the survivors as diffs.

      mix mutare                          # mutate everything under lib/
      mix mutare path/to/project          # target another project directory
      mix mutare --only lib/billing       # scope to a path
      mix mutare --mutators relational    # only some mutator families
      mix mutare --min-score 70           # fail (CI) if the score is below 70
      mix mutare --full                   # run the whole suite per mutant
                                          #   (no per-file test selection)

  Configuration may also live in `.mutare.exs` (a keyword list); CLI flags win.

      # .mutare.exs
      [
        paths: ["lib"],
        exclude: ["lib/generated/**"],
        mutators: :all,
        min_score: 70
      ]
  """
  use Mix.Task

  alias Mutare.{Config, Report, Result, Runner, Schema}

  @switches [
    only: :string,
    mutators: :string,
    min_score: :float,
    sandbox: :string,
    full: :boolean
  ]

  @impl Mix.Task
  def run(argv) do
    {flags, rest} = OptionParser.parse!(argv, strict: @switches)
    root = List.first(rest) || "."
    config = resolve_config(root, flags)

    schema = Schema.build(root, config)
    announce(schema, root)

    case Runner.run_with_schema(schema, root, Keyword.put(config, :reporter, &progress/1)) do
      {:ok, run} -> report(run, config)
      {:error, reason, detail} -> Mix.raise(format_error(reason, detail))
    end
  end

  defp resolve_config(root, flags) do
    Config.merge(Config.load(root), flags)
  rescue
    error in ArgumentError -> Mix.raise(Exception.message(error))
  end

  # --- output --------------------------------------------------------------

  defp announce(%Schema{} = schema, root) do
    files = schema.metamutants |> map_size()
    where = if root == ".", do: "", else: " in #{root}"
    Mix.shell().info("mutare#{where}: #{Schema.count(schema)} mutants across #{files} file(s)")

    for {file, reason} <- schema.skipped,
        do: Mix.shell().info("  skipped #{file}: #{inspect(reason)}")

    Mix.shell().info("compiling metamutant once, baseline first…\n")
  end

  defp progress(%Result{status: :killed}), do: IO.write(".")
  defp progress(%Result{status: :timeout}), do: IO.write("T")
  defp progress(%Result{status: :survived}), do: IO.write("S")
  defp progress(%Result{status: :no_coverage}), do: IO.write("-")
  defp progress(%Result{status: :ignored}), do: IO.write("i")
  defp progress(%Result{status: :poisoned}), do: IO.write("x")
  defp progress(%Result{}), do: IO.write("?")

  defp report(run, config) do
    Mix.shell().info("\n")
    Mix.shell().info(Report.render(run.results, run.schema.sources))
    gate(run.results, config[:min_score])
  end

  defp gate(results, min_score) do
    unless Report.passes_gate?(results, min_score) do
      Mix.raise(
        "mutation score #{fmt(Report.score(results))}% is below the required minimum of #{fmt(min_score)}%"
      )
    end
  end

  defp fmt(number), do: :erlang.float_to_binary(number / 1, decimals: 1)

  defp format_error(:nothing_to_mutate, detail), do: detail

  defp format_error(:compile_failed, detail) do
    "the metamutant failed to compile (compile-poisoning).\n\n" <> tail(detail)
  end

  defp format_error(:baseline_failed, detail) do
    "baseline suite is not green; mutation testing needs a passing suite.\n\n" <> tail(detail)
  end

  defp tail(output) do
    output |> String.split("\n") |> Enum.take(-25) |> Enum.join("\n")
  end
end
