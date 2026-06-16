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
      mix mutare --since master             # only files changed vs a git ref (CI)
      mix mutare --mutators relational    # only some mutator families
      mix mutare --min-score 70           # fail (CI) if the score is below 70
      mix mutare --full                   # run the whole suite per mutant
                                          #   (no per-file test selection)
      mix mutare --harness-retries 2      # re-run a mutant up to 2× if its run
                                          #   fails at the harness level (infra)
      mix mutare --max-harness-error-rate 0.3
                                          # abort if >30% of the mutants that ran
                                          #   failed at the harness level (1.0 = off)
      mix mutare --format json --output mutare.json
                                          # write a machine report to a file; the
                                          #   human report still prints to console
      mix mutare --format sarif           # emit SARIF to stdout (suppresses the
                                          #   human report to avoid a collision)

  `--format` is one of `human` (the default console report), `json` (the
  mutation-testing-elements / Stryker report schema), `html` (that JSON in the
  interactive report viewer), or `sarif` (survivors as findings for GitHub code
  scanning).

  Configuration may also live in `.mutare.exs` (a keyword list); CLI flags win.
  Use `reporters:` to emit several formats at once (a bare atom goes to stdout):

      # .mutare.exs
      [
        paths: ["lib"],
        exclude: ["lib/generated/**"],
        mutators: :all,
        min_score: 70,
        reporters: [:human, {:json, "mutare.json"}, {:sarif, "mutare.sarif"}]
      ]
  """
  use Mix.Task

  alias Mutare.{Config, Options, Report, Result, Runner, Schema}

  @switches [
    only: :string,
    mutators: :string,
    min_score: :float,
    sandbox: :string,
    full: :boolean,
    since: :string,
    harness_retries: :integer,
    max_harness_error_rate: :float,
    format: :string,
    output: :string
  ]

  @impl Mix.Task
  def run(argv) do
    {flags, rest} = OptionParser.parse!(argv, strict: @switches)
    root = List.first(rest) || "."
    options = resolve_options(root, flags)

    schema = Schema.build(root, options)
    announce(schema, root)

    case Runner.run_with_schema(schema, root, %{options | reporter: &progress/1}) do
      {:ok, run} -> report(run, options)
      {:error, reason, detail} -> Mix.raise(format_error(reason, detail))
    end
  end

  # Resolve `.mutare.exs` + CLI flags into a validated `Mutare.Options`. Both an
  # unknown mutator (from `Config`) and an invalid option (from `Options.new/1`)
  # raise `ArgumentError`, surfaced here as a clean Mix failure.
  defp resolve_options(root, flags) do
    Config.load(root)
    |> Config.merge(flags)
    |> scope_to_changes(root, flags)
    |> Options.new()
  rescue
    error in ArgumentError -> Mix.raise(Exception.message(error))
  end

  # `--since <ref>` restricts mutation to files changed versus that git ref.
  defp scope_to_changes(config, root, flags) do
    case flags[:since] do
      nil ->
        config

      ref ->
        case Mutare.Changes.since(root, ref) do
          {:ok, files} -> Keyword.put(config, :only_files, files)
          {:error, detail} -> Mix.raise("`--since #{ref}` failed:\n#{detail}")
        end
    end
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
  defp progress(%Result{status: :harness_error}), do: IO.write("E")

  defp report(run, %Options{} = options) do
    Mix.shell().info("\n")
    Enum.each(options.reporters, fn {format, path} -> emit(format, path, run, options) end)
    gate(run.results, options.min_score)
  end

  # A `nil` path means stdout (the console); a path means write the rendered
  # report to that file and note where it went.
  defp emit(format, nil, run, options) do
    Mix.shell().info(render_for(format, run, options))
  end

  defp emit(format, path, run, options) do
    File.write!(path, render_for(format, run, options))
    Mix.shell().info("wrote #{format} report to #{path}")
  end

  defp render_for(:human, run, _options), do: Report.render(run.results, run.schema.sources)

  defp render_for(format, run, options) do
    renderer(format).render(run.results, run.schema.sources, min_score: options.min_score)
  end

  defp renderer(:json), do: Report.Json
  defp renderer(:html), do: Report.Html
  defp renderer(:sarif), do: Report.Sarif

  defp gate(results, min_score) do
    unless Report.passes_gate?(results, min_score) do
      Mix.raise(
        "mutation score #{fmt(Report.score(results))}% is below the required minimum of #{fmt(min_score)}%"
      )
    end
  end

  defp fmt(number), do: :erlang.float_to_binary(number / 1, decimals: 1)

  defp format_error(:nothing_to_mutate, detail), do: detail

  defp format_error(:too_many_harness_errors, detail), do: detail

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
