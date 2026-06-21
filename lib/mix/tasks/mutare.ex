defmodule Mix.Tasks.Mutare do
  @shortdoc "Run mutation testing: compile once, run the suite per mutant"
  @moduledoc """
  Mutation-test the current project.

  Builds a single metamutant embedding every mutant behind a runtime switch,
  compiles it once, runs the suite green as a baseline, then runs the suite once
  per mutant and reports the survivors as diffs.

      mix mutare                          # mutate everything under lib/
      mix mutare path/to/project          # target another project directory
      mix mutare apps/billing             # mutate one umbrella app (copies the umbrella)
      mix mutare --app billing,web        # mutate specific umbrella apps
      mix mutare --workspace              # mutate every app in an umbrella
      mix mutare --only lib/billing       # scope to a directory
      mix mutare --only lib/billing/invoice.ex  # …or a single file
      mix mutare --since master             # only files changed vs a git ref (CI)
      mix mutare --mutators relational    # only some mutator families
      mix mutare --min-score 70           # fail (CI) if the score is below 70
      mix mutare --no-expand-uses         # don't expand `use` to surface the
                                          #   `import`/`alias` it injects (default: on)
      mix mutare --full                   # run the whole suite per mutant
                                          #   (no per-file test selection)
      mix mutare --baseline-runs 2        # run the baseline 2×; abort if a test
                                          #   flakes (passes one run, fails another)
      mix mutare --harness-retries 2      # re-run a mutant up to 2× if its run
                                          #   fails at the harness level (infra)
      mix mutare --max-harness-error-rate 0.3
                                          # abort if >30% of the mutants that ran
                                          #   failed at the harness level (1.0 = off)
      mix mutare --max-mutants 50         # test at most 50 mutants (the first 50
                                          #   in source order) — a quick smoke run
      mix mutare --workers 4              # run 4 mutants concurrently
                                          #   (default: System.schedulers_online/0)
      mix mutare --timeout 30000          # per-mutant wall-clock cap, in ms
                                          #   (default: derived from the baseline run)
      mix mutare --sandbox /tmp/mut --keep-sandbox
                                          # reuse the sandbox + its build cache
                                          #   across runs (CI); see below
      mix mutare --format json --output mutare.json
                                          # write a machine report to a file; the
                                          #   human report still prints to console
      mix mutare --format sarif           # emit SARIF to stdout (suppresses the
                                          #   human report to avoid a collision)

  By default Mutare materialises a throwaway sandbox copy and recompiles the
  metamutant cold every run, then removes the sandbox when the run finishes (so
  the temp dir doesn't accumulate). Pass `--sandbox <path>` to keep a default run's
  sandbox around (e.g. to inspect the generated metamutant). `--keep-sandbox`
  instead **preserves** the sandbox between runs and re-materialises it
  incrementally (only changed files are rewritten, so mix's compiler reuses the
  cached `_build`). On CI, pair it with `--sandbox <path>` pointed at a cached
  directory (cache `<path>/_build` and `<path>/deps`, keyed on `mix.lock`);
  locally, `--keep-sandbox` alone reuses a stable per-project temp dir.

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
        # fail the run (non-zero exit) if the score drops below this — the
        # same CI gate as `--min-score`, which overrides it when both are given
        min_score: 70,
        reporters: [:human, {:json, "mutare.json"}, {:sarif, "mutare.sarif"}]
      ]
  """
  use Mix.Task

  alias Mutare.{Config, Options, Project, Report, Runner, Schema}
  alias Mutare.Report.Live
  alias Mutare.Sandbox.Command

  @switches [
    only: :string,
    mutators: :string,
    min_score: :float,
    sandbox: :string,
    keep_sandbox: :boolean,
    full: :boolean,
    since: :string,
    baseline_runs: :integer,
    harness_retries: :integer,
    max_harness_error_rate: :float,
    max_mutants: :integer,
    workers: :integer,
    timeout: :integer,
    format: :string,
    output: :string,
    app: :string,
    workspace: :boolean,
    expand_uses: :boolean
  ]

  @impl Mix.Task
  def run(argv) do
    {flags, rest} = OptionParser.parse!(argv, strict: @switches)
    target = List.first(rest) || "."
    project = resolve_project(target, flags)
    options = resolve_options(project, flags)
    root = project.copy_root

    # Surface first-party `use MyAppWeb, :controller` bundles: `Mutare.Transform.Uses` expands
    # `use` in-process, which needs the host app's modules loadable. Deps are already on the
    # code path; the host app is compiled here, best-effort, before the scan transforms it.
    ensure_host_compiled(options, root)

    {:ok, live} = Live.start_link()

    try do
      # The scan (discovery + transform of every source) runs before the runner, so
      # we drive its live progress directly from here — `:on_scan` updates the block
      # per file. `clear/1` tears that block down before the count prints to stdout
      # so the two don't collide; the runner then redraws its own phases.
      Live.phase(live, :scanning)
      schema = Schema.build(root, %{options | on_scan: &Live.scanned(live, &1)})
      Live.clear(live)
      announce(schema, project, options)

      options = %{
        options
        | reporter: &Live.report(live, &1),
          on_phase: &Live.phase(live, &1),
          on_start: &Live.started(live, &1)
      }

      result = Runner.run_with_schema(schema, root, options)
      # Tear the live status block down before anything else prints, so the final
      # report / error lands on a clean terminal (the block lives on stderr).
      Live.finish(live)

      case result do
        {:ok, run} -> report(run, options)
        {:error, reason, detail} -> Mix.raise(format_error(reason, detail))
      end
    after
      # Backstop for an unexpected raise mid-run; `finish/1` is idempotent.
      Live.finish(live)
    end
  end

  # Compile the host project so its own modules are loadable for in-process `use` expansion
  # (`Mutare.Transform.Uses`). Only for the **current project** (`copy_root == "."`) — an
  # external-path target runs in *this* process with *its* deps absent, so compiling here
  # wouldn't help and its `use`s degrade to no-ops. Best-effort: a compile failure never aborts
  # the run (the metamutant still compiles later in the sandbox), and a still-unloadable `use`
  # is simply left unexpanded. Skipped entirely when `--no-expand-uses`. `Mix.Task.run` runs
  # `compile` at most once, so this is a no-op if mix already compiled.
  defp ensure_host_compiled(%Options{expand_uses: true}, ".") do
    Mix.Task.run("compile", [])
    :ok
  rescue
    _ -> :ok
  catch
    _, _ -> :ok
  end

  defp ensure_host_compiled(_options, _root), do: :ok

  # Resolve the target path + `--app`/`--workspace` into copy-root and
  # mutate-scope. A bad `--app` (no matching umbrella app) raises `ArgumentError`,
  # surfaced as a clean Mix failure like the other resolution errors.
  defp resolve_project(target, flags) do
    Project.resolve(target, apps: parse_apps(flags[:app]), workspace: flags[:workspace] || false)
  rescue
    error in ArgumentError -> Mix.raise(Exception.message(error))
  end

  defp parse_apps(nil), do: nil
  defp parse_apps(csv), do: csv |> String.split(",", trim: true) |> Enum.map(&String.trim/1)

  # Resolve `.mutare.exs` + CLI flags into a validated `Mutare.Options`. Both an
  # unknown mutator (from `Config`) and an invalid option (from `Options.new/1`)
  # raise `ArgumentError`, surfaced here as a clean Mix failure. `.mutare.exs` and
  # `--since` resolve against the copy-root (the umbrella root for an umbrella).
  defp resolve_options(%Project{} = project, flags) do
    project.copy_root
    |> Config.load()
    |> Config.merge(flags)
    |> scope_to_changes(project.copy_root, flags)
    |> Keyword.put(:project, project)
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

  defp announce(%Schema{} = schema, %Project{} = project, %Options{} = options) do
    files = schema.metamutants |> map_size()

    Mix.shell().info(
      "mutare#{scope_label(project)}: #{Schema.count(schema)} mutants" <>
        "#{cap_label(options)} across #{files} file(s)"
    )

    for {file, reason} <- schema.skipped,
        do: Mix.shell().info("  skipped #{file}: #{inspect(reason)}")

    # The phase progress (compiling, baseline, coverage probe, then the per-mutant
    # loop) is shown live by `Mutare.Report.Live`, so we don't pre-announce it here.
    Mix.shell().info("")
  end

  # `--max-mutants` caps the run; the count above is already the (capped) number
  # we'll test, so note the cap so a small count isn't a surprise.
  defp cap_label(%Options{max_mutants: nil}), do: ""
  defp cap_label(%Options{max_mutants: n}), do: " (--max-mutants #{n})"

  defp scope_label(%Project{umbrella?: true, mutate_scope: scope}) do
    " (umbrella: #{Enum.map_join(scope, ", ", & &1.app)})"
  end

  defp scope_label(%Project{copy_root: "."}), do: ""
  defp scope_label(%Project{copy_root: root}), do: " in #{root}"

  defp report(run, %Options{} = options) do
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

  defp render_for(format, run, options) do
    renderer(format).render(run.results, run.schema.sources, min_score: options.min_score)
  end

  defp renderer(:human), do: Report
  defp renderer(:json), do: Report.Json
  defp renderer(:html), do: Report.Html
  defp renderer(:sarif), do: Report.Sarif

  defp gate(results, min_score) do
    unless Report.passes_gate?(results, min_score) do
      Mix.raise(
        "mutation score #{Report.percent(Report.score(results))}% is below the required minimum of #{Report.percent(min_score)}%"
      )
    end
  end

  defp format_error(:nothing_to_mutate, detail), do: detail

  defp format_error(:too_many_harness_errors, detail), do: detail

  defp format_error(:compile_failed, detail) do
    "the metamutant failed to compile (compile-poisoning).\n\n" <> Command.output_tail(detail, 25)
  end

  defp format_error(:baseline_failed, detail) do
    "baseline suite is not green; mutation testing needs a passing suite.\n\n" <>
      Command.output_tail(detail, 25)
  end

  defp format_error(:baseline_flaky, detail) do
    "baseline suite is flaky (passed on some runs, failed on others); mutation " <>
      "testing needs a deterministically green suite — a flaky test manufactures " <>
      "false kills. Fix or quarantine the test(s), then re-run.\n\n" <> detail
  end
end
