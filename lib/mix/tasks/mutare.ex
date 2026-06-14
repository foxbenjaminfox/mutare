defmodule Mix.Tasks.Mutare do
  @shortdoc "Run mutation testing: compile once, run the suite per mutant"
  @moduledoc """
  Mutation-test the current project.

  Builds a single metamutant embedding every mutant behind a runtime switch,
  compiles it once, runs the suite green as a baseline, then runs the suite once
  per mutant and reports the survivors as diffs.

      mix mutare                          # mutate everything under lib/
      mix mutare --only lib/billing       # scope to a path
      mix mutare --mutators relational    # only some mutator families
      mix mutare --min-score 70           # fail (CI) if the score is below 70

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

  alias Mutare.{Report, Result, Runner, Schema}

  @registry %{
    arithmetic: Mutare.Mutators.Arithmetic,
    relational: Mutare.Mutators.Relational
  }

  @switches [only: :string, mutators: :string, min_score: :float, sandbox: :string]

  @impl Mix.Task
  def run(argv) do
    {flags, _argv} = OptionParser.parse!(argv, strict: @switches)
    config = config_file() |> merge_flags(flags)

    schema = Schema.build(".", config)
    announce(schema)

    case Runner.run_with_schema(schema, ".", Keyword.put(config, :reporter, &progress/1)) do
      {:ok, run} -> report(run, config)
      {:error, reason, detail} -> Mix.raise(format_error(reason, detail))
    end
  end

  # --- config --------------------------------------------------------------

  defp config_file do
    if File.exists?(".mutare.exs") do
      {config, _binding} = Code.eval_file(".mutare.exs")
      config
    else
      []
    end
  end

  defp merge_flags(config, flags) do
    config
    |> maybe_put(:paths, flags[:only] && [flags[:only]])
    |> maybe_put(:mutators, flags[:mutators] && parse_mutators(flags[:mutators]))
    |> maybe_put(:min_score, flags[:min_score])
    |> maybe_put(:sandbox, flags[:sandbox])
    |> Keyword.update(:mutators, :all, & &1)
    |> resolve_mutators()
  end

  defp parse_mutators(csv) do
    csv
    |> String.split(",", trim: true)
    |> Enum.map(&String.trim/1)
    |> Enum.map(&String.to_existing_atom/1)
  end

  defp resolve_mutators(config) do
    case Keyword.get(config, :mutators, :all) do
      :all -> Keyword.delete(config, :mutators)
      families -> Keyword.put(config, :mutators, Enum.map(families, &registry!/1))
    end
  end

  defp registry!(family) do
    Map.get(@registry, family) ||
      Mix.raise("unknown mutator family #{inspect(family)}; known: #{known_families()}")
  end

  defp known_families, do: @registry |> Map.keys() |> Enum.map_join(", ", &to_string/1)

  defp maybe_put(config, _key, nil), do: config
  defp maybe_put(config, key, value), do: Keyword.put(config, key, value)

  # --- output --------------------------------------------------------------

  defp announce(%Schema{} = schema) do
    files = schema.metamutants |> map_size()
    Mix.shell().info("mutare: #{Schema.count(schema)} mutants across #{files} file(s)")

    for {file, reason} <- schema.skipped,
        do: Mix.shell().info("  skipped #{file}: #{inspect(reason)}")

    Mix.shell().info("compiling metamutant once, baseline first…\n")
  end

  defp progress(%Result{status: :killed}), do: IO.write(".")
  defp progress(%Result{status: :survived}), do: IO.write("S")
  defp progress(%Result{}), do: IO.write("?")

  defp report(run, config) do
    Mix.shell().info("\n")
    rendered = Report.render(run.results, run.schema.sources)
    Mix.shell().info(rendered)
    gate(Report.score(run.results), config[:min_score])
  end

  defp gate(_score, nil), do: :ok

  defp gate(score, min_score) do
    if score < min_score do
      Mix.raise(
        "mutation score #{fmt(score)}% is below the required minimum of #{fmt(min_score)}%"
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
