defmodule Mix.Tasks.Mutare do
  @shortdoc "Run mutation testing: compile once, run the suite per mutant"
  @moduledoc """
  Mutation-test the current project.

  Mutare builds a single *metamutant*, embeding every possible mutant behind a runtime switch, compiles it once, runs your test suite once as baseline with no mutants active, then for each mutant runs the part of the suite that potentially covers the mutant, reporting back with the mutants your tests failed to catch.

  ## Getting started

  Run it with no arguments to mutate everything under `lib/`. On a large project, start with a single module. It often is convinent to mutation test one module at a time, or otherwise slice-by-slice.

      mix mutare                                 # mutate everything under lib/
      mix mutare --only lib/billing/invoice.ex   # ...or just one file (a good first run)
      mix mutare --max-mutants 50                # ...or just the first 50 mutants (to see mutare in action)

  The workflow is a loop: run it, look at each mutation your tests failed to catch—each survivor—then either add a test that would catch it or mark it with a `# mutare:ignore` comment if it is not worth testing, and run again.

  ## Reading the results

  Every mutant finishes in one of these states. The headline mutation score is
  the percentage of *testable* mutants your suite killed:

      score = killed / (total − no_coverage − ignored − poisoned − harness_error)

    * `killed`      — a test failed on the mutant. Your suite caught the change.
    * `survived`    — every test still passed: no test tells the mutated code apart
                      from the original. Survivors are the point of the tool, and
                      print as a one-line diff so you can see exactly what slipped
                      through.
    * `timeout`     — the mutant ran past the per-mutant time cap (e.g. it created
                      an infinite loop). Counts as killed. (So does a mutant that
                      exhausts the atom table and crashes the VM.)
    * `no_coverage` — no test runs that line at all, so nothing could catch it.
                      Excluded from the score; fix it by covering the line.
    * `ignored`     — suppressed by a `# mutare:ignore` comment (below). Excluded.
    * `poisoned`    — the mutated code would not compile, so it was dropped.
                      Excluded. (Rare — the built-in mutators are compile-safe.)
    * `harness_error` — the mutant's test run never reached a pass/fail verdict (an
                      infrastructure hiccup, not a real result). Excluded.

  A run exits 0 even when mutants survive — survivors are findings to act on, not a build failure. See "Continuous integration" below to make a low score or a stale ignore exit non-zero.

  ## Suppressing a mutant

  Some survivors are *equivalent* mutants — the mutation cannot change observable behaviour, so no test could ever kill it — or are simply not worth a test. Silence one with a `# mutare:ignore` comment at the end of the line (or on the line just above it):

      def to_float(n), do: n * 1.0   # mutare:ignore  multiplying by 1.0 is identity

  After the keyword come two optional, ordered parts — a `[family]` filter and a free-text reason:

      # mutare:ignore                            suppress every mutant on the line
      # mutare:ignore the reason text            suppress all; record the reason
      # mutare:ignore[arithmetic, relational]    suppress only those families
      # mutare:ignore[relational:>]              suppress one kind: the `i > j` swap
      # mutare:ignore[literal] off-by-one is ok  a filter and a reason together

  The names inside `[...]` are mutator families (see below). A family may be qualified with `:label` to suppress only one *kind* of its mutants — `relational` declares `> >= < <= == != === !==`, `return_value` declares `empty`/`sentinel`, `literal` declares `zero`/`succ`/`pred`/`negate`. Run `--list-mutators` to see every built-in family's labels. Filtering fails safe: an unknown family, an empty `[]`, or a malformed `[…` (no closing bracket) matches nothing, so the mutant runs rather than hides — but a qualified label a known built-in (or active custom) doesn't declare is a hard error (with a "did you mean"), so a typo can't silently fail to match. An ignore that suppresses no mutant (a typo'd family, a line that has no mutant) is reported as a warning — and with `--strict-ignores`, exits the run 1.

  ## Mutator families

  All families run by default. Run `mix mutare --list-mutators` to print the catalog.
  Select a subset with `--mutators a,b,c` (or the `:mutators` key in `.mutare.exs`);
  list `builtins` to keep the whole default set and add to it — `--mutators builtins,relational` is every built-in, while `--mutators relational` is *only* the relational family. The family atoms, by kind:

    * **Operators** — `arithmetic`, `operand_swap`, `bitwise`, `relational`,
      `strict_equality`, `logical`, `list`, `conditional`
    * **Literals** — `literal`, `string`, `float`, `atom`, `convention`,
      `charlist`, `word_list`, `string_sigil`, `map`, `tuple`, `bitstring`,
      `bitstring_spec`, `regex`, `datetime`, `alias`
    * **Calls** (rewrite or drop a stdlib/remote call) — `collection`,
      `collection_arity`, `string_call`, `string_byte`, `map_keyword`, `map_set`,
      `call_removal`, `default_drop`, `mode_swap`, `numeric`, `math`, `integer`
    * **Structural** — `return_value`, `if_condition`, `pattern_swap`,
      `pattern_wildcard`, `rescue_type`, `guard_drop`
    * **Behaviour-aware** — `genserver` (swaps an OTP callback's return tuple;
      fires only inside a `@behaviour GenServer` module)

  Each family's exact swap table lives in its own module's docs — print one with `mix mutare --explain relational`. You can also list your own module implementing `Mutare.Mutator` under `:mutators` to add a custom mutator.

  ## Inspecting without running

  These flags print information and exit, touching neither the sandbox nor the suite — for discovery, scripting, and debugging configuration:

      mix mutare --version                # the installed mutare version
      mix mutare --list-mutators          # the built-in mutator catalog (see above)
      mix mutare --explain relational     # one family's full documentation
      mix mutare --list-macros            # macros whose arguments are routed
                                          #   specially (built-ins + your config)
      mix mutare --list-ignores           # every `# mutare:ignore` in scope, each
                                          #   flagged active or ineffective
      mix mutare --show-config            # the effective options after merging
                                          #   .mutare.exs, CLI flags, and defaults
      mix mutare --dry-run                # list the mutants that *would* run, by
                                          #   file — no compile, no tests. Honours
                                          #   --only/--since/--mutators/--line/etc.

  ## Choosing what to mutate

      mix mutare path/to/project          # target a different project directory
      mix mutare --only lib/billing       # scope to a directory
      mix mutare --only lib/a --only lib/b   # ...or several paths (repeatable)
      mix mutare --exclude "lib/generated/**" --exclude lib/legacy
                                          # skip files matching globs (repeatable)
      mix mutare --since master           # only files changed vs a git ref
      mix mutare --line lib/billing/invoice.ex:42
                                          # only the mutants on that file:line — a
                                          #   narrow rerun, e.g. to recheck one
                                          #   survivor (repeatable; FILE:LINE is the
                                          #   exact prefix the report prints)
      mix mutare --mutators relational,arithmetic   # only some families (see above)
      mix mutare --no-expand-uses         # don't expand `use` to discover the
                                          #   import/alias/@behaviour it injects
                                          #   (on by default; matters for Phoenix/Ecto)
      mix mutare --no-seed-app-build      # force a cold compile instead of reusing the
                                          #   app's built beams on a narrowed run
                                          #   (on by default)

  ## Continuous integration

  By default a run exits 0 no matter how many mutants survive. Two flags add a non-zero exit so a CI job can fail the build:

      mix mutare --min-score 70           # exit 1 if the mutation score is below 70%
      mix mutare --strict-ignores         # exit 1 if any `# mutare:ignore` matched
                                          #   no mutant (a typo'd family or stale line)

  Combine `--since` with `--min-score` to gate only the code a pull request changed, and `--quiet` to drop the live progress animation (spinner, phases, per-survivor lines); the final report (and any machine reports) will still be printed.

      mix mutare --since origin/main --min-score 80 --quiet

  ## Tuning the run

      mix mutare --workers 4              # run 4 mutants concurrently
                                          #   (default: System.schedulers_online/0)
      mix mutare --full                   # run the whole suite for every mutant
                                          #   (default: only the tests that cover it)
      mix mutare --timeout 30000          # per-mutant wall-clock cap, in ms
                                          #   (default: derived from the baseline run)
      mix mutare --timeout-multiplier 5   # ...or set the cap to baseline × this
                                          #   (default: 3.0; ignored if --timeout is set)
      mix mutare --baseline-runs 2        # run the green baseline 2× and abort if a
                                          #   test flakes (passes once, fails once) —
                                          #   a flaky test manufactures false kills
      mix mutare --harness-retries 4      # re-run a mutant up to 4× if its run fails
                                          #   at the infrastructure level (default 2)
      mix mutare --max-harness-error-rate 0.3
                                          # abort if more than 30% of the mutants
                                          #   that ran failed at the infrastructure
                                          #   level (1.0 = never abort on these)
      mix mutare --max-survivors 5        # stop the run once 5 mutants have survived
                                          #   (in source order) — surface a few test
                                          #   gaps to fix without a full run. The score
                                          #   is then partial, so the --min-score gate
                                          #   is skipped
      mix mutare --verbose                # narrate what's happening at each step: a
                                          #   line per mutant (with its duration) plus
                                          #   per-phase detail — compile time, baseline
                                          #   timing, coverage breakdown, timeout cap,
                                          #   worker count. (--quiet wins over it)

  ## Umbrella projects

      mix mutare apps/billing             # mutate one app (copies the whole umbrella)
      mix mutare --app billing,web        # specific apps (repeatable, and comma-separated)
      mix mutare --app billing --app web  #   (equivalent to the line above)
      mix mutare --workspace              # mutate every app in the umbrella

  ## Database isolation across workers

  A suite with shared state (a database, say) can collide when several mutants run at once. `--partition-db` (or `--partition-env <NAME>` for a custom variable) gives each of the `--workers` concurrent runs a **distinct** partition id (`1..workers`) under an environment variable — `MIX_TEST_PARTITION` by default — so each worker can point at its own database:

      mix mutare --workers 4 --partition-db           # distinct MIX_TEST_PARTITION per worker
      mix mutare --workers 4 --partition-env MY_SLOT  # ...under a custom variable name

  This is the same convention as `mix test --partitions`, so a project already set up for that needs no code change:

      # config/test.exs
      config :my_app, MyApp.Repo,
        database: "my_app_test\#{System.get_env("MIX_TEST_PARTITION")}"

  You must pre-create and migrate the `--workers` partitioned databases (just as is required by `mix test --partitions`). The pool recycles ids across the run, so `--workers 4` needs four databases, not one per mutant; the baseline and coverage probe use partition `1`.

  ## Sandbox and build cache

      mix mutare --sandbox /tmp/mut                 # keep the generated sandbox to inspect it
      mix mutare --sandbox /tmp/mut --keep-sandbox  # reuse the sandbox + its build cache (CI)

  By default Mutare materialises a throwaway sandbox copy, recompiles the metamutant cold every run, and removes the sandbox when it finishes (so the temp dir does not accumulate). `--sandbox <path>` keeps that sandbox around — handy for inspecting the generated metamutant. `--keep-sandbox` instead **preserves** the sandbox between runs and re-materialises it incrementally (only changed files are rewritten, so mix's compiler reuses the cached `_build`). On CI, pair it with `--sandbox <path>` pointed at a cached directory (cache `<path>/_build` and `<path>/deps`, keyed on `mix.lock`); locally, `--keep-sandbox` alone reuses a stable per-project temp dir.

  ## Output formats

      mix mutare --report json:mutare.json
                                          # write a machine report to a file; the
                                          #   human report still prints to the console
      mix mutare --report sarif           # emit SARIF to stdout (this suppresses the
                                          #   human report, so the two don't collide)
      mix mutare --report json:mutare.json --report sarif:mutare.sarif
                                          # `--report` is repeatable; omit :PATH to
                                          #   write that report to stdout

  `--report` takes `FORMAT[:PATH]`, where `FORMAT` is one of `human` (the default console report), `json` (the mutation-testing-elements / Stryker report schema), `html` (that JSON embedded in the interactive report viewer), or `sarif` (survivors as findings for GitHub code scanning).

  ## Configuration file (`.mutare.exs`)

  Configuration may also live in `.mutare.exs` (a keyword list); a CLI flag overrides the matching key. Every option is optional — the block below lists all the file-settable keys with their defaults:

      # .mutare.exs
      [
        # --- what to mutate ---
        paths: ["lib"],
        exclude: ["lib/generated/**"],
        # built-in family atoms and/or your own Mutare.Mutator modules. The
        # `:builtins` token means "all built-ins", so `[:builtins, MyMutator]`
        # extends the defaults and `[MyMutator]` replaces them;
        # `{:builtins, except: [:arithmetic]}` drops a family. Omit the key for
        # the full default set.
        mutators: [:builtins],
        # leave a macro's arguments raw (a DSL body, a pattern) so they aren't
        # mutated — `:skip` covers every argument, a list marks each position;
        # `:*` wildcards a slot: {M, :*, :skip} = whole module, {:*, name, :skip}
        # = that name in any module (a more specific line overrides)
        macro_routes: [{Ecto.Query, :from, :skip}],
        # non-mutating source-understanding modules implementing
        # Mutare.MacroRouting, Mutare.UseExpansion, or both
        extensions: [],
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
        # (a boot-time node crash, a known-transient contention signature, is retried
        # harder still from its own dedicated budget — see `mix help mutare`)
        harness_retries: 2,
        # abort if more than this fraction of the mutants that ran erred at the
        # harness level (1.0 = never abort on harness errors)
        max_harness_error_rate: 0.5,
        # test at most the first N mutants in source order (a quick smoke run)
        max_mutants: nil,
        # stop the run once the first N surviving mutants are found (an
        # iterate-and-fix workflow); the partial score skips the --min-score gate
        max_survivors: nil,

        # --- sandbox reuse / build cache (see "Sandbox and build cache" above) ---
        sandbox: nil,
        keep_sandbox: false,
        # on a narrowed run (--only/--line/--since), reuse the app's already-built
        # beams so the one compile rebuilds just the mutated file(s) — not the whole
        # app. On by default; --no-seed-app-build forces a cold compile
        seed_app_build: true,

        # --- output & CI gates ---
        # exit the run with code 1 if the mutation score drops below this percentage; by default there is no minimum score
        # min_score: 70,

        # exit 1 if any `# mutare:ignore` suppresses no mutant (a typo or stale line)
        strict_ignores: false,
        # suppress the live stderr progress (for CI / piped use)
        quiet: false,
        # narrate each step in detail: a line per mutant + per-phase numbers
        # (compile/baseline timing, coverage breakdown, cap, workers). `quiet` wins
        verbose: false,
        # emit several reports at once (default is [:human]; the file path is optional and if omitted the report is printed to stdout.)
        # reporters: [:human, {:json, "mutare.json"}, {:sarif, "mutare.sarif"}]
      ]
  """
  use Mix.Task

  alias Mutare.{Config, Options, Project, Report, Runner, Schema}
  alias Mutare.CLI
  alias Mutare.CLI.Info
  alias Mutare.Options.Registry
  alias Mutare.Report.Live
  alias Mutare.Run.Context
  alias Mutare.Sandbox.Command.Output

  # The strict `OptionParser` switch list, composed from three sources so each flag's parse shape
  # lives next to its meaning: the **passthrough** option flags from `Mutare.Options.Registry`
  # (a 1:1 `--key`/`--no-key` rename), the **exceptional/translated** flags from `Mutare.Config`
  # (`--only`/`--full`/`--report`/…), and the task's own **project/scope + inspect-and-exit** flags
  # below (which are neither options nor config-translated). Adding a passthrough option is then a
  # single registry entry — no edit here.
  @switches Registry.cli_switches() ++
              Config.cli_switches() ++
              [
                since: :string,
                app: [:string, :keep],
                workspace: :boolean,
                # inspect-and-exit flags (print information, run nothing)
                version: :boolean,
                list_mutators: :boolean,
                explain: :string,
                list_macros: :boolean,
                list_ignores: :boolean,
                show_config: :boolean,
                dry_run: :boolean
              ]
  @parse_error_switches Enum.map(@switches, fn
                          {key, [type, :keep]} -> {key, type}
                          switch -> switch
                        end)

  @impl Mix.Task
  def run(argv) do
    {flags, rest} = parse_args!(argv)

    # Inspect-and-exit flags print information and do nothing else. These three need
    # no project or config, so they short-circuit before any resolution.
    cond do
      flags[:version] -> Mix.shell().info(Info.version_string())
      flags[:list_mutators] -> Info.print_mutator_catalog()
      flags[:explain] -> Info.explain_mutator(flags[:explain])
      true -> dispatch_with_options(flags, rest)
    end
  end

  defp parse_args!(argv) do
    OptionParser.parse!(argv, strict: @switches)
  rescue
    error in OptionParser.ParseError ->
      Mix.raise(Exception.message(error))

    error in ArgumentError ->
      # Some Elixir versions accept repeatable switch specs for parsing but choke on them while
      # formatting a parse error's "Supported options" block. Re-render with equivalent
      # non-repeatable specs so malformed CLI syntax still surfaces as a Mix usage error.
      if option_parser_format_error?(__STACKTRACE__) do
        Mix.raise(parse_error_message(argv))
      else
        reraise error, __STACKTRACE__
      end
  end

  defp parse_error_message(argv) do
    OptionParser.parse!(argv, strict: @parse_error_switches)
    "invalid command-line arguments"
  rescue
    error in OptionParser.ParseError -> Exception.message(error)
  end

  defp option_parser_format_error?(stacktrace) do
    Enum.any?(stacktrace, fn
      {OptionParser, function, _arity, _meta} when function in [:format_error, :format_errors] ->
        true

      _entry ->
        false
    end)
  end

  # Everything past the no-config flags resolves the project + options first; the
  # remaining inspect-and-exit flags then branch off that, and a normal run falls
  # through to `run_mutation_testing/3`.
  defp dispatch_with_options(flags, rest) do
    target = List.first(rest) || "."
    project = resolve_project(target, flags)
    options = resolve_options(project, flags)

    # `project` is run *context*, not configuration — it rides on the `Run.Context` alongside the
    # validated options (and, later, the live-progress hooks), not inside the `Options` struct.
    context = Context.new(options, project: project)
    root = project.copy_root

    try do
      cond do
        flags[:show_config] -> Info.print_effective_config(project, options)
        flags[:list_macros] -> Info.print_macro_registry(options)
        flags[:list_ignores] -> Info.print_ignores(project, scan(context, root))
        flags[:dry_run] -> Info.print_dry_run(project, scan(context, root))
        true -> run_mutation_testing(project, context, root)
      end
    rescue
      # A variant-label spec error from *any* scan — a normal run *or* a `--dry-run`/`--list-ignores`
      # info mode (both build a `Mutare.Schema`, so both can raise) — e.g. a `# mutare:ignore[family:label]`
      # naming a known family's bad variant, or a mutator declaring a wire-unsafe label/name. Render it
      # as a clean Mix abort, not a raw stacktrace.
      error in Mutare.Ignore.SpecError -> Mix.raise(Exception.message(error))
    end
  end

  defp run_mutation_testing(%Project{} = project, %Context{} = context, root) do
    options = context.options

    # Defer the per-mutant diff render (the build's dominant cost) when the active reporters need
    # diff text for survivors *alone* — re-derived at report time (`Mutare.Runner.Hydrate`). Set on
    # the context so both the scan (`Schema.build`) and the run (`run_with_schema`) see it. The
    # info commands (`--dry-run`/`--list-ignores`) use the un-flagged context above, so they keep
    # rendering eagerly (they describe *every* site).
    context = %{context | defer_site_code: defer_site_code?(options)}

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

    # Build the cheap per-site live `summary` only when the in-flight activity line will actually
    # consume it — which needs *both*:
    #   * an **animating** (ANSI/tty) reporter — a plain piped/CI run prints only leave-behind
    #     lines and drops `{:start, …}`, so the activity line, and the summary, are never shown; and
    #   * a **deferred** scan (`defer_site_code`) — the eager modes (`--verbose`, JSON/HTML) already
    #     carry `*_code`, so the activity line falls back to `describe/1` and the summary is redundant.
    # Everything else (`--quiet`, a pipe, an eager render) builds no summary and pays no `Macro` cost.
    summarize? = live != nil and Live.animating?(live) and context.defer_site_code
    context = %{context | summarize_sites: summarize?}

    try do
      # The scan (discovery + transform of every source) runs before the runner, so
      # we drive its live progress directly from here — `:on_scan` updates the block
      # per file. `clear/1` tears that block down before the count prints to stdout
      # so the two don't collide; the runner then redraws its own phases.
      if live, do: Live.phase(live, :scanning)
      on_scan = if live, do: &Live.scanned(live, &1)
      schema = Schema.build(root, %{context | on_scan: on_scan})
      if live, do: Live.clear(live)
      announce(schema, project, options)
      warn_ineffective_ignores(schema)
      enforce_strict_ignores(schema, options)

      # Wire the runner's live hooks (reporter/phase/start) now that the scan is done — the
      # scan drove `:on_scan` directly above; these drive the per-mutant phase. A distinct
      # binding (not a rebind of `context`) so it stays clear that the scan/announce above ran
      # on the unhooked context and only the runner + report see the hooked one.
      run_context = wire_live_hooks(context, live)

      result = Runner.run_with_schema(schema, root, run_context)
      # Tear the live status block down before anything else prints, so the final
      # report / error lands on a clean terminal (the block lives on stderr).
      if live, do: Live.finish(live)

      case result do
        {:ok, run} -> report(run, options)
        {:error, reason, detail} -> Mix.raise(format_error(reason, detail))
      end
    after
      # Backstop for an unexpected raise mid-run; `finish/1` is idempotent. A variant-label
      # `Mutare.Ignore.SpecError` from the scan propagates through here (the live block is torn
      # down) to `dispatch_with_options/2`, which renders it as a clean Mix abort.
      if live, do: Live.finish(live)
    end
  end

  # The shared scan for the scan-backed info commands (`--dry-run`, `--list-ignores`):
  # discover + transform every in-scope source, compiling and running nothing. Takes the
  # `Run.Context` so the umbrella scope (`context.project`) reaches `Schema.build/2`.
  defp scan(%Context{} = context, root) do
    ensure_host_compiled(context.options, root)
    Schema.build(root, context)
  end

  # Whether the run may defer per-mutant diff rendering — the build's dominant cost (rendering a
  # `Sourceror` diff for *every* mutant when only the displayed handful need it). Safe to defer
  # when every active reporter needs diff text for survivors **alone**: the default human report
  # and SARIF. `--verbose` leaves a line (with its diff) for *every* mutant as the run streams,
  # and `:json`/`:html` emit *every* mutant's replacement, so those render eagerly up front.
  # `Mutare.Runner.Hydrate` re-derives the deferred survivors' code at report time. Scoped to the
  # Mix task's known reporters; the library `Mutare.run/2` path never sets it (a custom `:reporter`
  # hook may read any result's code), so it stays eager.
  defp defer_site_code?(%Options{verbose: true}), do: false

  defp defer_site_code?(%Options{reporters: reporters}),
    do: Enum.all?(reporters, fn {format, _path} -> format in [:human, :sarif] end)

  # Start the live progress reporter unless `--quiet`. `nil` means "no live
  # reporter" — the Mix task leaves every `Live` hook unset and the run is silent
  # on stderr.
  defp maybe_start_live(%Options{quiet: true}), do: nil

  defp maybe_start_live(%Options{verbose: verbose}) do
    {:ok, live} = Live.start_link(verbose: verbose)
    live
  end

  # Point the runner's three live hooks at the `Live` server, or leave the `Run.Context`
  # untouched when there is no live reporter (`--quiet`, or the direct `Mutare.run/2` API).
  defp wire_live_hooks(context, nil), do: context

  defp wire_live_hooks(context, live) do
    %{
      context
      | reporter: &Live.report(live, &1),
        on_phase: &Live.phase(live, &1),
        on_start: &Live.started(live, &1)
    }
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

  # `--app` is repeatable (`:keep`) *and* comma-separated, so `--app billing,web` and
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
      "mutare#{CLI.scope_label(project)}: #{Schema.count(schema)} mutants" <>
        "#{cap_label(options)}#{stop_label(options)} across #{files} file(s)"
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

  # `--max-survivors` doesn't reduce the candidate count (every mutant is still
  # compiled in), but the run may end early once N survivors surface, so flag it
  # up front rather than have the run stop unexpectedly.
  defp stop_label(%Options{max_survivors: nil}), do: ""

  defp stop_label(%Options{max_survivors: n}),
    do: " (stop after #{n} survivor#{CLI.plural(n)})"

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
  # `""` for an unfiltered (`:all`) directive. A `{family, target}` entry renders
  # back to its source form — `relational:>` when qualified, bare `arithmetic`
  # otherwise — so the warning echoes what the user wrote.
  defp ignore_filter_label(%{mutators: :all}), do: ""

  defp ignore_filter_label(%{mutators: %MapSet{} = set}),
    do:
      "[#{set |> Enum.map(&Mutare.Ignore.Directive.entry_label/1) |> Enum.sort() |> Enum.join(", ")}]"

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
      "--strict-ignores: #{n} `# mutare:ignore` directive#{CLI.plural(n)} " <>
        "suppressed no mutant (see the warnings above)"
    )
  end

  defp report(run, %Options{} = options) do
    Enum.each(options.reporters, fn {format, path} -> emit(format, path, run, options) end)
    finish_run(run, options)
  end

  # On a complete run, apply the `--min-score` CI gate. On an early stop
  # (`--max-survivors`), the score is over a partial prefix of the mutants, so a
  # gate would be misleading — instead note what happened (on stderr, so a machine
  # report on stdout stays clean, like `warn_ineffective_ignores/1`) and skip it.
  defp finish_run(%{stopped_early: false} = run, %Options{} = options),
    do: gate(run.results, options.min_score)

  defp finish_run(%{stopped_early: true} = run, %Options{} = options) do
    IO.puts(:stderr, early_stop_note(run, options))
  end

  # The partial-run note for an early stop: how many survivors were found, how much
  # of the candidate set was evaluated, and — only when a `--min-score` was set —
  # that its gate was skipped because the score is partial.
  defp early_stop_note(run, %Options{} = options) do
    survivors = Enum.count(run.results, &(&1.status == :survived))
    evaluated = length(run.results)
    total = Schema.count(run.schema)

    "stopped after finding #{survivors} survivor#{CLI.plural(survivors)} (--max-survivors " <>
      "#{options.max_survivors}); evaluated #{evaluated} of #{total} mutant#{CLI.plural(total)}. " <>
      "The mutation score above is over this partial set" <> gate_skipped_note(options.min_score)
  end

  defp gate_skipped_note(nil), do: "."
  defp gate_skipped_note(_min_score), do: ", so the --min-score gate was not applied."

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

  # A poisoned compile that recovery couldn't isolate. Lead with a remediation
  # hint when we recognise the cause (a macro requiring a literal argument — see
  # `Mutare.Poison.Hint`), then the raw compiler error for the full detail. The
  # raw error can be long, so a footer points back up to the hint (the fix is at
  # the top, but the user reads the error dump last).
  defp format_error(:compile_failed, detail) do
    intro = "the metamutant failed to compile (compile-poisoning).\n\n"
    tail = Output.output_tail(detail, 25)

    case Mutare.Poison.Hint.for_compile_failure(detail) do
      nil ->
        intro <> tail

      hint ->
        footer =
          "\n\n↑ Scroll up for how to fix this — the remediation hint is above the original error."

        intro <> hint <> "\n\nOriginal compile error:\n\n" <> tail <> footer
    end
  end

  defp format_error(:baseline_failed, detail) do
    "baseline suite is not green; mutation testing needs a passing suite.\n\n" <>
      Output.output_tail(detail, 25)
  end

  defp format_error(:baseline_flaky, detail) do
    "baseline suite is flaky (passed on some runs, failed on others); mutation " <>
      "testing needs a deterministically green suite — a flaky test manufactures " <>
      "false kills. Fix or quarantine the test(s), then re-run.\n\n" <> detail
  end
end
