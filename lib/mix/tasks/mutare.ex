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
      mix mutare --app billing,web        # mutate specific umbrella apps (repeatable,
      mix mutare --app billing --app web  #   and CSV-splitting — these two are equivalent)
      mix mutare --workspace              # mutate every app in an umbrella
      mix mutare --only lib/billing       # scope to a directory
      mix mutare --only lib/billing/invoice.ex  # …or a single file
      mix mutare --only lib/billing --only lib/web
                                          # scope to several paths (repeatable)
      mix mutare --line lib/billing/invoice.ex:42
                                          # only the mutants on that file:line — a
                                          #   narrow rerun, e.g. to recheck one
                                          #   survivor (repeatable; FILE:LINE is the
                                          #   exact prefix the report prints)
      mix mutare --exclude "lib/generated/**" --exclude lib/legacy
                                          # skip files matching globs (repeatable)
      mix mutare --since master             # only files changed vs a git ref (CI)
      mix mutare --mutators relational    # only some mutator families
      mix mutare --mutators builtins,relational   # `builtins` = the whole default set
      mix mutare --min-score 70           # fail (CI) if the score is below 70
      mix mutare --strict-ignores         # fail (CI) if any `# mutare:ignore`
                                          #   suppresses no mutant (typo/stale)
      mix mutare --no-expand-uses         # don't expand `use` to surface the
                                          #   `import`/`alias` it injects (default: on)
      mix mutare --quiet                  # suppress the live stderr progress
                                          #   (spinner/phases/leave-behinds) — for CI;
                                          #   the final + machine reports still print
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
      mix mutare --workers 4 --partition-db
                                          # give each concurrent worker a distinct
                                          #   MIX_TEST_PARTITION (1..workers) so a
                                          #   stateful suite reads it to pick a
                                          #   per-worker database — needs that many
                                          #   DBs pre-created; see below
      mix mutare --partition-env MY_DB_SLOT
                                          # …same, under a custom env var name
      mix mutare --timeout 30000          # per-mutant wall-clock cap, in ms
                                          #   (default: derived from the baseline run)
      mix mutare --timeout-multiplier 5   # cap = baseline run × this factor
                                          #   (default: 3.0; ignored if --timeout set)
      mix mutare --sandbox /tmp/mut --keep-sandbox
                                          # reuse the sandbox + its build cache
                                          #   across runs (CI); see below
      mix mutare --format json --output mutare.json
                                          # write a machine report to a file; the
                                          #   human report still prints to console
      mix mutare --format sarif           # emit SARIF to stdout (suppresses the
                                          #   human report to avoid a collision)
      mix mutare --format json --output mutare.json --format sarif --output mutare.sarif
                                          # `--format`/`--output` are repeatable and
                                          #   paired by position (Nth format ↔ Nth
                                          #   output); a format with no matching
                                          #   `--output` goes to stdout

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

  `--partition-db` (or `--partition-env <NAME>` for a custom var) gives each of
  the `--workers` concurrent runs a **distinct** partition id (`1..workers`) under
  an env var — `MIX_TEST_PARTITION` by default — so a suite with shared state can
  point each worker at its own database and avoid cross-worker collisions. It is
  the `mix test --partitions` convention, so a project already set up for that
  needs no code change:

      # config/test.exs
      config :my_app, MyApp.Repo,
        database: "my_app_test\#{System.get_env("MIX_TEST_PARTITION")}"

  You must pre-create/migrate the `--workers` partitioned databases (the same
  prerequisite `mix test --partitions` has). The pool recycles ids across the run,
  so `--workers 4` needs four databases, not one per mutant; the baseline and
  coverage probe use partition `1`.

  Configuration may also live in `.mutare.exs` (a keyword list); a CLI flag
  overrides the matching key. Every option is optional — the block below lists
  all the file-settable keys with their defaults (`min_score` is illustrative):

      # .mutare.exs
      [
        # --- what to mutate ---
        paths: ["lib"],
        exclude: ["lib/generated/**"],
        # built-in family atoms and/or your own Mutare.Mutator modules. The
        # `:builtins` token (synonym `:all`) means "all built-ins", so
        # `[:builtins, MyMutator]` extends the defaults and `[MyMutator]` replaces
        # them; `{:builtins, except: [:arithmetic]}` drops a family. Omit the key
        # (or `:all`/`:builtins` bare) for the full default set.
        mutators: :all,
        # leave a macro's arguments raw (a DSL body, a pattern) so they aren't
        # mutated — `:skip` covers every argument, a list marks each position
        macros: [{Ecto.Query, :from, :skip}],
        # expand `use` to surface the import/alias it injects (--no-expand-uses)
        expand_uses: true,

        # --- how the suite runs ---
        # :coverage runs only the test files covering each mutant; :full runs all
        test_selection: :coverage,
        workers: System.schedulers_online(),
        # give each concurrent worker a distinct partition id under this env var
        # (1..workers), for per-worker DB isolation — read it in config/test.exs
        # like `mix test --partitions`; nil (default) is off. Needs `workers` DBs.
        partition_env: nil,
        # per-mutant wall-clock cap = baseline run × multiplier, unless an
        # absolute `timeout:` in ms is given instead (then the multiplier is moot)
        timeout_multiplier: 3.0,
        timeout: nil,
        # run the baseline N×, aborting if a test flakes (passes one run, fails another)
        baseline_runs: 1,
        # retry a mutant whose run fails at the harness (infra) level before recording it
        harness_retries: 1,
        # abort if more than this fraction of the mutants that ran erred at the
        # harness level (1.0 = never abort on harness errors)
        max_harness_error_rate: 0.5,
        # test at most the first N mutants in source order (a quick smoke run)
        max_mutants: nil,

        # --- sandbox reuse / build cache (see the prose above) ---
        sandbox: nil,
        keep_sandbox: false,

        # --- output & CI gates ---
        # fail the run (non-zero exit) if the mutation score drops below this
        min_score: 70,
        # fail if any `# mutare:ignore` suppresses no mutant (a typo or stale line)
        strict_ignores: false,
        # suppress the live stderr progress (for CI / piped use)
        quiet: false,
        # emit several reports at once (a bare atom goes to stdout)
        reporters: [:human, {:json, "mutare.json"}, {:sarif, "mutare.sarif"}]
      ]
  """
  use Mix.Task

  alias Mutare.{Config, Options, Project, Report, Runner, Schema}
  alias Mutare.Report.Live
  alias Mutare.Sandbox.Command

  @switches [
    only: [:string, :keep],
    line: [:string, :keep],
    exclude: [:string, :keep],
    mutators: :string,
    min_score: :float,
    sandbox: :string,
    keep_sandbox: :boolean,
    strict_ignores: :boolean,
    quiet: :boolean,
    full: :boolean,
    since: :string,
    baseline_runs: :integer,
    harness_retries: :integer,
    max_harness_error_rate: :float,
    max_mutants: :integer,
    workers: :integer,
    partition_db: :boolean,
    partition_env: :string,
    timeout: :integer,
    timeout_multiplier: :float,
    format: [:string, :keep],
    output: [:string, :keep],
    app: [:string, :keep],
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

    # `--quiet` (`:quiet`) suppresses the live progress reporter entirely: no `Live`
    # process, none of its four hooks wired, so nothing is written to stderr as the
    # run proceeds (for CI / piped use). `nil` here threads through every `if live`
    # below; the runner/scan treat the unset hooks as no-ops, and the final +
    # machine reports are untouched.
    live = maybe_start_live(options)

    try do
      # The scan (discovery + transform of every source) runs before the runner, so
      # we drive its live progress directly from here — `:on_scan` updates the block
      # per file. `clear/1` tears that block down before the count prints to stdout
      # so the two don't collide; the runner then redraws its own phases.
      if live, do: Live.phase(live, :scanning)
      on_scan = if live, do: &Live.scanned(live, &1)
      schema = Schema.build(root, %{options | on_scan: on_scan})
      if live, do: Live.clear(live)
      announce(schema, project, options)
      warn_ineffective_ignores(schema)
      enforce_strict_ignores(schema, options)

      options =
        if live do
          %{
            options
            | reporter: &Live.report(live, &1),
              on_phase: &Live.phase(live, &1),
              on_start: &Live.started(live, &1)
          }
        else
          options
        end

      result = Runner.run_with_schema(schema, root, options)
      # Tear the live status block down before anything else prints, so the final
      # report / error lands on a clean terminal (the block lives on stderr).
      if live, do: Live.finish(live)

      case result do
        {:ok, run} -> report(run, options)
        {:error, reason, detail} -> Mix.raise(format_error(reason, detail))
      end
    after
      # Backstop for an unexpected raise mid-run; `finish/1` is idempotent.
      if live, do: Live.finish(live)
    end
  end

  # Start the live progress reporter unless `--quiet`. `nil` means "no live
  # reporter" — the Mix task leaves every `Live` hook unset and the run is silent
  # on stderr.
  defp maybe_start_live(%Options{quiet: true}), do: nil

  defp maybe_start_live(%Options{}) do
    {:ok, live} = Live.start_link()
    live
  end

  # Compile the host project so its own modules are loadable for in-process `use` expansion
  # (`Mutare.Transform.Uses`). `Mix.Task.run("compile")` only ever builds the **current** Mix
  # project (cwd), so it helps only when that project overlaps the copied tree — i.e. when the
  # target *is*/*contains*/*is contained by* the current project (`targets_current_project?/1`).
  # The literal `copy_root` can be `"."`, `"./"`, or the **absolute umbrella root** (the
  # documented `mix mutare apps/billing` form resolves to it), so we compare expanded paths, not
  # the string. A genuinely external-path target runs in *this* process with *its* deps absent,
  # so compiling here wouldn't help and its `use`s degrade to no-ops. Best-effort: a compile
  # failure never aborts the run (the metamutant still compiles later in the sandbox), and a
  # still-unloadable `use` is simply left unexpanded. Skipped entirely when `--no-expand-uses`.
  # `Mix.Task.run` runs `compile` at most once, so this is a no-op if mix already compiled.
  defp ensure_host_compiled(%Options{expand_uses: true}, root) do
    if targets_current_project?(root), do: Mix.Task.run("compile", [])
    :ok
  rescue
    _ -> :ok
  catch
    _, _ -> :ok
  end

  defp ensure_host_compiled(_options, _root), do: :ok

  # Does the copied tree overlap the current Mix project (cwd)? True when the two are equal or one
  # contains the other; false only for a disjoint external path. `mix` always loads the mix.exs in
  # cwd, so cwd is the current project root.
  defp targets_current_project?(root) do
    target = Path.expand(root)
    cwd = File.cwd!()
    target == cwd or within?(target, cwd) or within?(cwd, target)
  end

  # Is `path` at or below `ancestor`? (Both already absolute, no trailing slash from `Path.expand`.)
  defp within?(ancestor, path), do: String.starts_with?(path, ancestor <> "/")

  # Resolve the target path + `--app`/`--workspace` into copy-root and
  # mutate-scope. A bad `--app` (no matching umbrella app) raises `ArgumentError`,
  # surfaced as a clean Mix failure like the other resolution errors.
  defp resolve_project(target, flags) do
    Project.resolve(target, apps: parse_apps(flags), workspace: flags[:workspace] || false)
  rescue
    error in ArgumentError -> Mix.raise(Exception.message(error))
  end

  # `--app` is repeatable (`:keep`) *and* CSV-splitting, so `--app billing,web` and
  # `--app billing --app web` are equivalent — each occurrence contributes one or more
  # app names, accumulated in order. No `--app` (`[]`) means `nil`: "all apps".
  defp parse_apps(flags) do
    case Keyword.get_values(flags, :app) do
      [] ->
        nil

      csvs ->
        csvs |> Enum.flat_map(&String.split(&1, ",", trim: true)) |> Enum.map(&String.trim/1)
    end
  end

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

  # Warn about every `# mutare:ignore` that suppressed no mutant — a typo'd family
  # (`[arithmatic]`), an empty `[]`, a misplaced standalone line, or a family that
  # produced no mutant there (see `Mutare.Schema.detect_ineffective_ignores/1`).
  # Onto **stderr** (like `Mutare.Report.Live`), so a machine report on stdout
  # stays clean. `--strict-ignores` then turns these into a hard error.
  defp warn_ineffective_ignores(%Schema{ineffective_ignores: []}), do: :ok

  defp warn_ineffective_ignores(%Schema{ineffective_ignores: ineffective}) do
    for {file, directive} <- ineffective do
      IO.puts(
        :stderr,
        "warning: # mutare:ignore#{ignore_filter_label(directive)} at " <>
          "#{file}:#{directive.line} suppressed no mutant"
      )
    end

    :ok
  end

  # The `[families]` a filtered directive named (sorted for a stable message), or
  # `""` for an unfiltered (`:all`) directive.
  defp ignore_filter_label(%{mutators: :all}), do: ""

  defp ignore_filter_label(%{mutators: %MapSet{} = set}),
    do: "[#{set |> Enum.sort() |> Enum.join(", ")}]"

  # `--strict-ignores`: a directive that suppressed nothing is a hard error (the
  # CI counterpart of the warning above), surfaced as a clean Mix failure →
  # non-zero exit, mirroring the `--min-score` `gate/2`. The per-directive detail
  # already printed via `warn_ineffective_ignores/1`.
  defp enforce_strict_ignores(%Schema{ineffective_ignores: []}, _options), do: :ok
  defp enforce_strict_ignores(%Schema{}, %Options{strict_ignores: false}), do: :ok

  defp enforce_strict_ignores(%Schema{ineffective_ignores: ineffective}, %Options{
         strict_ignores: true
       }) do
    n = length(ineffective)

    Mix.raise(
      "--strict-ignores: #{n} `# mutare:ignore` directive#{if n == 1, do: "", else: "s"} " <>
        "suppressed no mutant (see the warnings above)"
    )
  end

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
    Options.renderer(format).render(run.results, run.schema.sources, min_score: options.min_score)
  end

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
