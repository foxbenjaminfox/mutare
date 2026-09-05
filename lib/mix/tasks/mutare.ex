defmodule Mix.Tasks.Mutare do
  @shortdoc "Run mutation testing: compile once, run the suite per mutant"
  @moduledoc """
  Mutation-test the current project.

  Mutare builds a single *metamutant*, embedding every possible mutant behind a runtime switch, compiles it once, runs your test suite once as baseline with no mutants active, then for each mutant runs the part of the suite that potentially covers the mutant, reporting back with the mutants your tests failed to catch.

  ## Getting started

  Run it with no arguments to mutate everything under `lib/`. On a large project, start with a single module. It often is convenient to mutation test one module at a time, or otherwise slice-by-slice.

      mix mutare                                 # mutate everything under lib/
      mix mutare --only lib/billing/invoice.ex   # ...or just one file (a good first run)
      mix mutare --max-mutants 50                # ...or just the first 50 mutants (to see mutare in action)

  The workflow is a loop: run it, look at each mutation your tests failed to catch—each survivor—then either add a test that would catch it or mark it with a `# mutare:ignore` comment if it is not worth testing, and run again.

  ## Reading the results

  Every mutant finishes in one of these states. The headline mutation score is the percentage of *testable* mutants your suite killed:

      score = killed / (total − no_coverage − ignored − poisoned − harness_error)

    * `killed`      — a test failed on the mutant. Your suite caught the change.
    * `survived`    — every test still passed: no test tells the mutated code apart from the original. Survivors are the point of the tool, and print as a one-line diff so you can see exactly what slipped through.
    * `timeout`     — the mutant ran past the per-mutant time cap (e.g. it created an infinite loop). Counts as killed. (So does a mutant that exhausts the atom table and crashes the VM.)
    * `no_coverage` — no test runs that line at all, so nothing could catch it. Excluded from the score; fix it by covering the line.
    * `ignored`     — suppressed by a `# mutare:ignore` comment (below). Excluded.
    * `poisoned`    — the mutated code would not compile, so it was dropped. Excluded. (Rare — the built-in mutators are compile-safe.)
    * `harness_error` — the mutant's test run never reached a pass/fail verdict (an infrastructure hiccup, not a real result). Excluded.

  A run exits 0 even when mutants survive — survivors are findings to act on, not a build failure. See "Continuous integration" below to make a low score or a stale ignore exit non-zero.

  ## Troubleshooting baseline-only failures

  Mutare's baseline run executes the rewritten metamutant with no mutant active. For ordinary calls it should behave like your original code, but one implementation detail is observable: structural mutations that cannot be selected in-place — guards, head patterns, and clause-shape changes — are delivered by lifting the original function body into a generated dispatcher and leaving a wrapper at the source function name. If that code raises, exact exception metadata or stacktrace frames may name an internal function such as `__mutare_name_arity_g1` instead of the original function.

  A test that asserts `FunctionClauseError.function`, `FunctionClauseError.arity`, or exact stacktrace frame names can therefore pass under plain `mix test` and fail only inside Mutare's baseline. Prefer asserting the observable error and module/behavior, not the rewritten internal function identity.

  If you need a compatibility escape hatch while changing those tests, configure `skip_lifting: [{MyApp.Mod, :fun, arity}]` or pass `--skip-lifting MyApp.Mod.fun/arity`. That keeps the matching function in-place, which also means Mutare will not generate guard, head-pattern, or clause-drop mutants for that function.

  ## Suppressing a mutant

  Some survivors are *equivalent* mutants — the mutation cannot change observable behaviour, so no test could ever kill it — or are simply not worth a test. Silence one with a `# mutare:ignore` comment at the end of the line (or on the line just above it):

      def to_float(n), do: n * 1.0   # mutare:ignore  multiplying by 1.0 is identity

  After the keyword come two optional, ordered parts — a `[family]` filter and a free-text reason:

      # mutare:ignore                            suppress every mutant on the line
      # mutare:ignore the reason text            suppress all; record the reason
      # mutare:ignore[arithmetic, relational]    suppress only those families
      # mutare:ignore[relational:>]              suppress one kind: the `i > j` swap
      # mutare:ignore[integer] off-by-one is ok  a filter and a reason together

  The names inside `[...]` are mutator families (see below). A family may be qualified with `:label` to suppress only one *kind* of its mutants — `relational` declares `> >= < <= == != === !==`, `return_value` declares `empty`/`sentinel`, `integer` declares `zero`/`succ`/`pred`, `boolean` declares `negate`. Run `--list-mutators` to see every built-in family's labels. Filtering fails safe: an unknown family, an empty `[]`, or a malformed `[…` (no closing bracket) matches nothing, so the mutant runs rather than hides — but a qualified label a known built-in (or active custom) doesn't declare is a hard error (with a "did you mean"), so a typo can't silently fail to match. An ignore that suppresses no mutant (a typo'd family, a line that has no mutant) is reported as a warning — and with `--strict-ignores`, exits the run 1.

  For a span that isn't worth annotating line by line — a literal lookup table, a generated module — two scoped verbs take the same filter and reason:

      # mutare:ignore-start spot-checked; the round-trip test covers the table
      def encode(?A), do: ?B
      def encode(?B), do: ?C
      # mutare:ignore-end

      # mutare:ignore-file generated by `mix gen.tables` — do not hand-edit

  A region suppresses everything from its `-start` through its `-end` (both delimiter lines inclusive); `# mutare:ignore-file`, anywhere in a file, suppresses the whole file. A broken pairing — an `-end` with no `-start`, nested `-start`s, a region never closed — is a hard error, and a scoped directive that suppresses nothing is warned exactly like a line one. Grammar details are in the `Mutare.Ignore` docs; audit what's suppressed with `--list-ignores`.

  A directive is per line or per span. To leave a *call* alone everywhere it appears — an analytics emitter, a logger — route it instead: `--skip-call Mixpanel.track/3`, or a `call_routes:` entry in `.mutare.exs` (which can also leave single arguments as written, or keep a DSL macro's body out of the mutation set). See the configuration file section below and the README's "Routing calls".

  ## Mutator families

  All families run by default. Run `mix mutare --list-mutators` to print the catalog. Select a subset with `--mutators a,b,c` (or the `:mutators` key in `.mutare.exs`); list `builtins` to keep the whole default set and add to it — `--mutators builtins,relational` is every built-in, while `--mutators relational` is *only* the relational family. The family atoms, by kind:

    * Operators — `arithmetic`, `operand_swap`, `bitwise`, `relational`, `strict_equality`, `logical`, `list`, `conditional`
    * Literals — `integer`, `boolean`, `string`, `float`, `atom`, `convention`, `charlist`, `word_list`, `string_sigil`, `map`, `tuple`, `bitstring`, `bitstring_spec`, `regex`, `datetime`, `alias`
    * Calls (rewrite or drop a stdlib/remote call) — `collection`, `collection_arity`, `string_call`, `string_byte`, `map_keyword`, `keyword_delete`, `map_set`, `period_boundary`, `call_removal`, `default_drop`, `mode_swap`, `numeric`, `math`, `integer_call`
    * Structural — `return_value`, `if_condition`, `pattern_swap`, `pattern_wildcard`, `rescue_type`, `guard_drop`
    * Behaviour-aware — `genserver` (swaps an OTP callback's return tuple; fires only inside a `@behaviour GenServer` module)

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
      mix mutare --check                  # compile the metamutant (with poison
                                          #   recovery) but run no tests — a fast
                                          #   preflight for "will my DSLs build?".
                                          #   Prints a copy-pasteable :call_routes
                                          #   fix for any unknown macro it had to skip

  ## Choosing what to mutate

      mix mutare path/to/project          # target a different project directory
      mix mutare --only lib/billing       # scope to a directory
      mix mutare --only lib/a --only lib/b   # ...or several paths (repeatable)
      mix mutare --exclude "lib/generated/**" --exclude lib/legacy
                                          # skip files matching globs (repeatable)
      mix mutare --since master           # only lines changed vs a git ref
      mix mutare --line lib/billing/invoice.ex:42
                                          # only the mutants on that file:line — a
                                          #   narrow rerun, e.g. to recheck one
                                          #   survivor (repeatable; FILE:LINE is the
                                          #   exact prefix the report prints)
      mix mutare --mutators relational,arithmetic   # only some families (see above)
      mix mutare --skip-lifting MyApp.Mod.fun/2
                                          # keep one function in-place; no guard,
                                          #   head-pattern, or clause-drop mutants
      mix mutare --skip-call Mixpanel.track/3
                                          # skip every call to it — nothing inside
                                          #   the call is mutated (repeatable; also
                                          #   Mod.fun for any arity, Mod.* for a module)
      mix mutare --no-expand-uses         # don't expand `use` to discover the
                                          #   import/alias/@behaviour it injects
                                          #   (on by default; matters for Phoenix/Ecto)
      mix mutare --no-seed-app-build      # force a cold compile instead of reusing the
                                          #   app's built beams on a narrowed run
                                          #   (on by default)

  `--only`/`--exclude`/`--line` paths (and `:paths` in `.mutare.exs`) are resolved relative to the **target project**, not the directory `mix` was invoked from: targeting another checkout is `mix mutare ./phoenix --only lib/phoenix/naming.ex` — not `--only phoenix/lib/...`. A path that matches nothing aborts with `no mutation sites found`.

  ## Continuous integration

  By default a run exits 0 no matter how many mutants survive. CI gates add a non-zero exit when a run violates the policy you choose:

      mix mutare --min-score 70           # exit 1 if the mutation score is below 70%
      mix mutare --max-no-coverage 0      # exit 1 if any mutant has no covering test
      mix mutare --fail-on-poisoned       # exit 1 if any mutant had to be dropped
                                          #   because the mutated code would not compile
      mix mutare --fail-on-harness-error  # exit 1 if any mutant run reached no verdict
      mix mutare --strict-ignores         # exit 1 if any `# mutare:` comment matched
                                          #   no mutant (a typo'd verb/family or stale line)

  Combine `--since` with CI gates to gate only the code a pull request changed, and `--quiet` to drop the live progress animation (spinner, phases, per-survivor lines); the final report (and any machine reports) will still be printed.

      mix mutare --since origin/main --min-score 80 --quiet

  ## Tuning the run

      mix mutare --workers 8              # run 8 mutants concurrently (default: half
                                          #   your schedulers, capped at 4 — each worker
                                          #   is a full `mix test` BEAM that uses all
                                          #   of them)
      mix mutare --full                   # run the whole suite for every mutant
                                          #   (default: only the test cases that cover it)
      mix mutare --per-file               # run whole covering test *files*, not just
                                          #   the individual covering tests — the opt-out
                                          #   for stateful async:false suites where
                                          #   per-test narrowing could hide a kill
      mix mutare --no-full                # force coverage-guided selection even if
                                          #   .mutare.exs set test_selection: :full
                                          #   (--no-per-file likewise restores :tests)
      mix mutare --timeout 30000          # per-mutant wall-clock cap, in ms
                                          #   (default: derived from the baseline run)
      mix mutare --timeout-multiplier 5   # ...or set the cap to baseline × this,
                                          #   scaled by half the concurrent workers
                                          #   (the baseline is timed uncontended)
                                          #   (default: 3.0; ignored if --timeout is set)
      mix mutare --probe-timeout 600000   # wall-clock cap for the coverage probe run,
                                          #   in ms (default: 10× the per-mutant cap);
                                          #   an overrun degrades to run-all selection
      mix mutare --max-heap-mb 4096       # cap each BEAM process's heap (in MB) in the
                                          #   baseline/probe/mutant runs — a mutation can
                                          #   make code allocate without bound (faster
                                          #   than the time cap can catch), and a capped
                                          #   runaway dies as an ordinary test failure
                                          #   instead of OOMing the machine. Size it well
                                          #   above the suite's biggest honest process;
                                          #   the baseline runs under the same cap, so a
                                          #   too-small value fails fast, up front
                                          #   (default: no cap)
      mix mutare --baseline-runs 2        # run the green baseline 2× and abort if a
                                          #   test flakes (passes once, fails once) —
                                          #   a flaky test manufactures false kills
      mix mutare --baseline-retries 3     # retry an all-red baseline up to 3× before
                                          #   aborting; mixed pass/fail baseline runs
                                          #   still abort as flaky
      mix mutare --kill-runs 2            # require each killed mutant to kill twice;
                                          #   a passing rerun is reported survived
      mix mutare --no-confirm-timeouts    # record a timed-out run as :timeout right
                                          #   away. By default a timeout is confirmed
                                          #   with one sequential (uncontended) re-run
                                          #   first — the cap is derived from an
                                          #   uncontended baseline, so under parallel
                                          #   workers a slow-but-finite mutant could
                                          #   otherwise be falsely recorded as killed
      mix mutare --harness-retries 4      # re-run a mutant up to 4× if its run fails
                                          #   at the infrastructure level (default 2)
      mix mutare --max-harness-error-rate 0.3
                                          # abort if more than 30% of the mutants
                                          #   that ran failed at the infrastructure
                                          #   level (1.0 = never abort on these)
      mix mutare --max-survivors 5        # stop the run once 5 mutants have survived
                                          #   (in source order) — surface a few test
                                          #   gaps to fix without a full run. The result
                                          #   set is then partial, so CI gates are skipped
      mix mutare --time-budget 10m        # stop launching new mutants once 10 minutes of
                                          #   the per-mutant phase elapse (units h/m/s,
                                          #   e.g. 90s, 1h30m), draining the in-flight ones.
                                          #   "see what I can get in 10 minutes"; like
                                          #   --max-survivors the result set is partial, so
                                          #   CI gates are skipped
      mix mutare --verbose                # narrate what's happening at each step: a
                                          #   line per mutant (with its duration) plus
                                          #   per-phase detail — compile time, baseline
                                          #   timing, coverage breakdown, timeout cap,
                                          #   worker count. (--quiet wins over it)

  ### Flaky tests: expect mutation testing to find them

  A mutation run re-runs your suite (or coverage-selected slices of it) far more times, in far more configurations, than normal CI does — so it is disproportionately good at *surfacing* pre-existing flaky tests. A flake at the baseline blocks the whole run (`baseline suite is not green`); one mid-run can manufacture a false kill. If your suite occasionally fails on its own, fix that first (or detect it explicitly with `--baseline-runs 2`) — it's a property of the target suite, not a Mutare failure to debug.

  A related, narrower instability: a mutant on a **timeout-shaped configuration literal** (`timeout: :infinity`, a generous deadline) may be observable only under load — its verdict can honestly differ between runs because the mutated timeout only fires when something is slow. For codebases with such literals, `--kill-runs 2` requires every kill to be reproduced, surfacing that load-dependence instead of recording whichever verdict the first run happened to produce.

  ## Umbrella projects

      mix mutare apps/billing             # mutate one app (copies the whole umbrella)
      mix mutare --app billing,web        # specific apps (repeatable, and comma-separated)
      mix mutare --app billing --app web  #   (equivalent to the line above)
      mix mutare --workspace              # mutate every app in the umbrella

  ## Database isolation across workers

  A suite with shared state (a database, say) can collide when several mutants run at once. `--partition-db` (or `--partition-env <NAME>` for a custom variable) gives each of the `--workers` concurrent runs a distinct partition id (`1..workers`) under an environment variable — `MIX_TEST_PARTITION` by default — so each worker can point at its own database:

      mix mutare --workers 4 --partition-db           # distinct MIX_TEST_PARTITION per worker
      mix mutare --workers 4 --partition-env MY_SLOT  # ...under a custom variable name
      mix mutare --no-partition-db                    # disable a partition_env from .mutare.exs

  This is the same convention as `mix test --partitions`, so a project already set up for that needs no code change:

      # config/test.exs
      config :my_app, MyApp.Repo,
        database: "my_app_test\#{System.get_env("MIX_TEST_PARTITION")}"

  You must pre-create and migrate the `--workers` partitioned databases (just as is required by `mix test --partitions`). The pool recycles ids across the run, so `--workers 4` needs four databases, not one per mutant; the baseline and coverage probe use partition `1`.

  ## Sandbox and build cache

      mix mutare --sandbox /tmp/mut                 # keep the generated sandbox to inspect it
      mix mutare --sandbox /tmp/mut --keep-sandbox  # reuse the sandbox + its build cache (CI)

  By default Mutare materialises a throwaway sandbox copy, recompiles the metamutant cold every run, and removes the sandbox when it finishes (so the temp dir does not accumulate). `--sandbox <path>` keeps that sandbox around — handy for inspecting the generated metamutant. `--keep-sandbox` instead preserves the sandbox between runs and re-materialises it incrementally (only changed files are rewritten, so mix's compiler reuses the cached `_build`). On CI, pair it with `--sandbox <path>` pointed at a cached directory (cache `<path>/_build` and `<path>/deps`, keyed on `mix.lock`); locally, `--keep-sandbox` alone reuses a stable per-project temp dir.

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

  Each destination takes one report: at most one may omit `:PATH` (two documents on stdout would be valid in neither format), and no two may name the same path (only the last written would survive). Either collision is a startup error naming the clashing formats.

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
        # skip a call outright (`:skip` — an analytics emitter, a logger), or leave a
        # macro's arguments as written (`:raw` — a DSL body, a pattern) so they
        # aren't mutated; a list treats each position (`:expression`, `:raw`,
        # `:interior`, a keyed `[timeout: :raw]` refinement of a keyword argument);
        # `:*` wildcards a slot: {M, :*, :skip} = whole module, {:*, name, :raw}
        # = that name in any module (a more specific line overrides)
        call_routes: [{Mixpanel, :track, 3, :skip}, {Ecto.Query, :from, :raw}],
        # extend the built-in timeout table (and any label a companion package
        # documents) to your own functions: {Module, :fun, arity, positions, label}
        argument_marks: [{MyApp.Http, :get, 2, [{:keyword, :recv_timeout}], :timeout}],
        # keep specific functions in-place when lifted function names are observable;
        # entries are {Module, function_name_atom_or_string, arity}
        skip_lifting: [],
        # non-mutating source-understanding modules implementing
        # Mutare.CallRouting, Mutare.UseExpansion, or both
        extensions: [],
        # expand `use` to surface the import/alias it injects (--no-expand-uses)
        expand_uses: true,

        # --- how the suite runs ---
        # :tests runs only the individual test cases covering each mutant; :coverage
        # runs whole covering files (opt-out for stateful async:false suites); :full
        # runs the whole suite for every mutant
        test_selection: :tests,
        # concurrent mutant runs; default: half the schedulers, capped at 4 (each
        # worker is a full `mix test` BEAM that itself uses every scheduler)
        workers: 4,
        # give each concurrent worker a distinct partition id under this env var
        # (1..workers), for per-worker DB isolation — read it in config/test.exs
        # like `mix test --partitions`; nil (default) is off. Needs `workers` DBs.
        partition_env: nil,
        # per-mutant wall-clock cap = baseline run × multiplier × half the
        # concurrent workers (the baseline is timed uncontended), unless an
        # absolute `timeout:` in ms is given instead (then the multiplier is moot)
        timeout_multiplier: 3.0,
        timeout: nil,
        # cap each BEAM process's heap (MB) in the baseline/probe/mutant runs, so a
        # mutation that allocates without bound dies as an ordinary test failure
        # instead of OOMing the machine; nil (default) is no cap
        max_heap_mb: nil,
        # run the baseline N×, aborting if a test flakes (passes one run, fails another)
        baseline_runs: 1,
        # retry a consistently-red baseline attempt before aborting (useful for
        # target suites with occasional startup/load flakes)
        baseline_retries: 0,
        # require a killed mutant to kill N times before recording the kill; if any
        # rerun passes, record it as survived (unanimous-kill, default unchanged)
        kill_runs: 1,
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
        # iterate-and-fix workflow); the partial result set skips CI gates
        max_survivors: nil,
        # stop launching new mutants once this much wall-clock time in the
        # per-mutant phase elapses — a duration string like "10m"/"90s"/"1h30m"
        # (nil = no budget); in-flight mutants drain, and the partial result set
        # skips CI gates, exactly like max_survivors
        time_budget: nil,

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
        # exit 1 if the run records more than this many uncovered mutants; nil disables the gate
        max_no_coverage: nil,
        # exit 1 if any mutant had to be dropped because the mutated code would not compile
        fail_on_poisoned: false,
        # exit 1 if any mutant's test run reached no pass/fail/timeout verdict
        fail_on_harness_error: false,

        # exit 1 if any `# mutare:ignore` suppresses no mutant (a typo or stale
        # line), or any `# mutare:` comment names no recognized directive
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

  alias Mutare.{Config, Options, Project, Runner, Schema}
  alias Mutare.CLI
  alias Mutare.CLI.{Diagnostics, Info, Outcome}
  alias Mutare.Options.Registry
  alias Mutare.Report.Live
  alias Mutare.Run.Context

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
                dry_run: :boolean,
                # compile-only preflight: compile (with poison recovery) but run no tests
                check: :boolean
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
        flags[:check] -> run_check(project, context, root)
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

    {live, schema, run_context} = start_live_scan(project, context, root)

    try do
      result = Runner.run_with_schema(schema, root, run_context)
      # Tear the live status block down before anything else prints, so the final
      # report / error lands on a clean terminal (the block lives on stderr).
      if live, do: Live.finish(live)

      case result do
        {:ok, run} ->
          Outcome.warn_poison_recovery(run)
          Outcome.report(run, options)

        {:error, reason, detail} ->
          Mix.raise(Outcome.format_error(reason, detail, root))
      end
    after
      # Backstop for an unexpected raise during the runner; `finish/1` is idempotent. A
      # scan-time abort (a variant-label `Mutare.Ignore.SpecError`, or a `--strict-ignores`
      # failure) is already torn down inside `start_live_scan/3` before it reaches here.
      if live, do: Live.finish(live)
    end
  end

  # `--check`: the compile-only preflight. Scan + compile the metamutant (with the same
  # poison recovery a full run does), then stop before the baseline and per-mutant phase.
  # It answers "will this project's DSLs let Mutare build?" cheaply — the value on a
  # first run against an unfamiliar macro-heavy codebase, where the alternative is
  # discovering poison mid-run. Shares the scan/live prelude with the full run; only the
  # runner call and the reporting differ. Site diffs are never shown, so the scan defers
  # them (`defer_site_code: true`) to keep the render cheap.
  defp run_check(%Project{} = project, %Context{} = context, root) do
    context = %{context | defer_site_code: true}
    options = context.options
    {live, schema, run_context} = start_live_scan(project, context, root)

    try do
      result = Runner.check_with_schema(schema, root, run_context)
      if live, do: Live.finish(live)

      case result do
        {:ok, check} -> Info.print_check(check, project, scan_degraded_uses(schema, options))
        {:error, reason, detail} -> Mix.raise(Outcome.format_error(reason, detail, root))
      end
    after
      if live, do: Live.finish(live)
    end
  end

  # The module-level `use`s that failed to expand in-process during the scan, across every
  # in-scope source — computed here (only for `--check`) rather than on the `Mutare.Schema`
  # so a normal run pays nothing for it. `--no-expand-uses` opted out of expansion, so there
  # is nothing to diagnose. Each entry is `%{file, module, line, reason}` (see
  # `Mutare.Transform.Uses.degraded_uses/2`). The textual prefilter keeps the re-parse off
  # files that have no syntax-shaped `use` token; a `:sources` entry parsed cleanly in the scan.
  defp scan_degraded_uses(%Schema{}, %Options{expand_uses: false}), do: []

  defp scan_degraded_uses(%Schema{sources: sources}, %Options{extensions: extensions}) do
    for {file, source} <- sources,
        source_might_contain_use?(source),
        entry <- Mutare.Transform.Uses.degraded_uses(Sourceror.parse_string!(source), extensions),
        do: Map.put(entry, :file, file)
  end

  # Elixir accepts both `use Foo` (with any whitespace, including tabs) and
  # `use(Foo, opts)`, so the scan-time diagnostic must not key on the exact
  # `"use "` spelling. False positives are fine: this is only a cheap --check
  # prefilter before the real AST walk.
  defp source_might_contain_use?(source) do
    Regex.match?(~r/(^|[^\p{L}\p{N}_?!])use(?:\s|\()/u, source)
  end

  # The shared scan/live prelude of a compile-backed run (`run_mutation_testing/3` and
  # `--check`): host-compile for `use` expansion, start the live reporter, scan with live
  # progress, announce + emit the scan-time warnings, and wire the runner's live hooks.
  # Returns `{live, schema, run_context}`. Callers set `context.defer_site_code` before
  # calling (it drives the `summarize_sites` decision below and the scan's render), then
  # own the `try/after` around the runner call and the `Live.finish` teardown.
  defp start_live_scan(%Project{} = project, %Context{} = context, root) do
    options = context.options

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

    # The scan runs here, *before* the caller's `try/after` — so a scan-time abort (a
    # variant-label `Mutare.Ignore.SpecError` from `Schema.build`, a `--strict-ignores`
    # `Mix.raise` from `enforce_strict_ignores`, or a custom mutator/extension `throw`/exit)
    # would bypass that `Live.finish` and leave the live block dangling on the terminal. Own
    # the teardown here: tear it down on any non-successful exit, then re-raise for
    # `dispatch_with_options/2` to render exception-shaped aborts as clean Mix failures.
    # `finish/1` is idempotent, so the caller's `after` remains a harmless backstop.
    try do
      scan_with_live(project, context, options, root, live)
    rescue
      e ->
        if live, do: Live.finish(live)
        reraise e, __STACKTRACE__
    catch
      kind, reason ->
        if live, do: Live.finish(live)
        :erlang.raise(kind, reason, __STACKTRACE__)
    end
  end

  # The scan body of `start_live_scan/3`, wrapped by its teardown guard. Returns
  # `{live, schema, run_context}` on success.
  defp scan_with_live(
         %Project{} = project,
         %Context{} = context,
         %Options{} = options,
         root,
         live
       ) do
    # Build the cheap per-site live `summary` only when the in-flight activity line will actually
    # consume it — which needs *both*:
    #   * an **animating** (ANSI/tty) reporter — a plain piped/CI run prints only leave-behind
    #     lines and drops `{:start, …}`, so the activity line, and the summary, are never shown; and
    #   * a **deferred** scan (`defer_site_code`) — the eager modes (`--verbose`, JSON/HTML) already
    #     carry `*_code`, so the activity line falls back to `describe/1` and the summary is redundant.
    # Everything else (`--quiet`, a pipe, an eager render) builds no summary and pays no `Macro` cost.
    summarize? = live != nil and Live.animating?(live) and context.defer_site_code
    context = %{context | summarize_sites: summarize?}

    # The scan (discovery + transform of every source) runs before the runner, so
    # we drive its live progress directly from here — `:on_scan` updates the block
    # per file. `clear/1` tears that block down before the count prints to stdout
    # so the two don't collide; the runner then redraws its own phases.
    if live, do: Live.phase(live, :scanning)
    on_scan = if live, do: &Live.scanned(live, &1)
    schema = Schema.build(root, %{context | on_scan: on_scan})
    if live, do: Live.clear(live)
    announce(schema, project, options)
    Diagnostics.surface(schema, options)

    # Wire the runner's live hooks (reporter/phase/start) now that the scan is done — the
    # scan drove `:on_scan` directly above; these drive the per-mutant phase. A distinct
    # binding (not a rebind of `context`) so it stays clear that the scan/announce above ran
    # on the unhooked context and only the runner + report see the hooked one.
    {live, schema, wire_live_hooks(context, live)}
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

  # `--since <ref>` restricts mutation to the lines changed versus that git ref
  # (the same `:only_lines` site filter `--line` uses), so a one-line edit to a
  # large module mutates only that line, not the whole file. If an explicit
  # `:only_lines` filter is already present (e.g. `--line`), `--since` narrows it
  # by intersection rather than replacing the user's requested lines.
  defp scope_to_changes(config, root, flags) do
    case flags[:since] do
      nil ->
        config

      ref ->
        case Mutare.Changes.since(root, ref) do
          {:ok, lines} -> Keyword.put(config, :only_lines, intersect_only_lines(config, lines))
          {:error, detail} -> Mix.raise("`--since #{ref}` failed:\n#{detail}")
        end
    end
  end

  defp intersect_only_lines(config, changed_lines) do
    case Keyword.get(config, :only_lines) do
      nil ->
        changed_lines

      %MapSet{} = only_lines ->
        maybe_intersect_valid_lines(only_lines, changed_lines)

      only_lines when is_list(only_lines) ->
        maybe_intersect_valid_lines(only_lines, changed_lines)

      invalid ->
        invalid
    end
  end

  defp maybe_intersect_valid_lines(only_lines, changed_lines) do
    if Enum.all?(only_lines, &valid_line_filter?/1) do
      only_lines
      |> MapSet.new()
      |> MapSet.intersection(changed_lines)
    else
      only_lines
    end
  end

  defp valid_line_filter?({file, line}) when is_binary(file) and file != "" and is_integer(line),
    do: line > 0

  defp valid_line_filter?(_entry), do: false

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

  # Neither `--max-survivors` nor `--time-budget` reduces the candidate count (every mutant is still
  # compiled in), but either may end the run early — the first once N survivors surface, the second
  # once the wall-clock budget elapses — so flag them up front rather than have the run stop
  # unexpectedly.
  defp stop_label(%Options{} = options), do: survivor_label(options) <> budget_label(options)

  defp survivor_label(%Options{max_survivors: nil}), do: ""

  defp survivor_label(%Options{max_survivors: n}),
    do: " (stop after #{n} survivor#{CLI.plural(n)})"

  defp budget_label(%Options{time_budget: nil}), do: ""
  defp budget_label(%Options{time_budget: budget}), do: " (time budget #{budget})"
end
