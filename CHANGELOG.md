# Changelog

All notable changes to this project are documented in this file.

The format is based on [Keep a Changelog](https://keepachangelog.com/en/1.1.0/),
and this project adheres to [Semantic Versioning](https://semver.org/spec/v2.0.0.html).

## [Unreleased]

### Added

- **`:lazy_expression`, a position treatment for a callee that may not evaluate an argument
  eagerly.** Mutare treats every call as a function in every respect its route does not address,
  including when its arguments run: to deliver a whole-call mutant on a pipe stage it evaluates
  the piped value once, ahead of the stage. A macro that evaluates that operand late,
  conditionally, or never (`value |> lazy(enabled?)`) routes the position `:lazy_expression`.
  The argument is mutated exactly like an `:expression`, and is handed to the callee unevaluated
  in every branch. Accepted in `call_routes:` and from `call_routes/0` alike.

### Changed

- **A piped routed call is shown, mutated and delivered as the direct call it is sugar for.**
  `(p in Post) |> from(order_by: …)` reaches `route_arguments/2`, `host/2`, `mutate/2` and
  `Mutare.Calls.resolved_routed_call/1` as `from(p in Post, order_by: …)`. The piped operand is
  argument 0: a classifier routes it by shape, `call.rebuild` can rewrite it, and it may be
  routed `:hosted` (previously a `ContractError`). Reports are unchanged — a mutant that leaves
  argument 0 alone is still located at, and diffed as, the stage the user wrote; one that
  rewrites it is reported over the whole pipe. Stages that take no positional route (an
  ordinary function call, a `:skip`ped call) stay pipes. A rewritten stage whose first position
  is `:expression` or `:interior` still has its piped value evaluated once, as before; one
  routed `:lazy_expression`, or as syntax, never does. **Breaking for adapters:**
  - `Mutare.CallRouting.Call` loses `pipe_left`, `pipe_mode` and `effective_arity`, and its
    five-argument `new` becomes `new/4` (`node, module, name, rebuild`).
  - `Mutare.CallRouting.ArgumentRoutes`' `from_effective` and `from_visible` constructors are
    replaced by `new/2` (one treatment per argument), and its `visible`/`piped` readers by
    `treatments/1`.
  - `route_arguments/2`'s context no longer carries `:pipe_mode` (it is empty).

### Fixed

- **A `|>` displaced out of `Kernel` is no longer treated as the pipe.** In a module that
  writes `import Kernel, except: [|>: 2]` beside its own operator, Mutare read every `|>` as
  `Kernel.|>/2`: a mutated stage was lifted into a closure that applied the custom operator
  twice, which could change the *unmutated* program (an `{:ok, value}`-binding pipe skipped
  the stage), and the stage was resolved and offered to mutators at the piped arity. A
  displaced `|>` is now an ordinary call to that operator. By default its left side is a
  value and its right side is routed `:interior` — the stage's own node is withheld, its
  arguments mutate — and a `call_routes:` entry on the operator (`{MyPipe, :|>, 2, […]}`)
  replaces that default with any positional treatments.

## [0.3.1] - 2026-09-19

### Fixed

- Whole-call mutants on a pipe stage preserve a syntax-valued left operand. Routed
  declarations, patterns, keyword fragments and interpolations reach the macro directly,
  instead of being evaluated through a closure. This lets adapters mutate stages such as
  `(p in Post) |> from(order_by: …)` without poisoning the single build. Mutations inside
  the left operand remain reachable without duplicating their selectors.
- A generated interpolation on a pipe's left keeps its precedence when rendered, including
  when only the left operand carries mutations.

## [0.3.0] - 2026-09-19

### Added

- **`--verify-invariants` (`verify_invariants:`) checks each transformed file
  before the run relies on it.** Mutare reads the metamutant back and emits the
  file a second time. It aborts with `Mutare.InvariantError` when a
  recorded mutant has no branch that runs while it alone is active, when a
  mutant has no coverage record, when generated code names an id that no mutant
  records, when a mutant renders identically to its original code, or when the
  second pass differs. These problems would otherwise distort the report
  silently. They come from custom mutators, hosts, and extensions (for example,
  a host splice that overwrites selectors core has already placed). The checks
  add roughly a sixth to scan time and are off by default.
- `Mutare.Manifest` lists every generated mention of a mutant id (`:mentions`).
- **A routed call written as a pipe stage is shown the pipe's left side.**
  `Mutare.CallRouting.Call` gains `pipe_left` — `:unpiped`, or `{:piped, left}`
  with the left side as written. The piped position is the call's effective
  first argument, and adapters used to route it without seeing it; a
  `route_arguments/2` classifier can now route it by shape (`Post |> from(…)`
  held back from the `alias` family, `build(x) |> from(…)` left mutable), and a
  host or mutator can read a declaration written there. It is the same value
  in `route_arguments/2`, in `host/2`, and from
  `Mutare.Calls.resolved_routed_call/1`. It is read-only, so the piped position
  still cannot be routed `:hosted`.
- `Mutare.CallRouting.Call`'s `new/5` builds a call value from its independent
  facts and derives `arguments`, `pipe_mode`, and `effective_arity`.

### Changed

- **Breaking: a hand-built `%Mutare.CallRouting.Call{}` must name `pipe_left`.** The key
  is enforced, so a test that builds the struct literally stops compiling; build
  it with `Call.new/5` instead. Matching on the struct is unaffected.
- **`Mutare.Test`'s source helpers run the invariant checks by default.**
  `diffs/3`, `diffs_for/4`, `metamutant_source/3`,
  `assert_metamutant_compiles/3`, and `compile_metamutant/3` raise
  `Mutare.InvariantError` for a mutator that breaks the metamutant; pass
  `verify_invariants: false` to opt out.
- **Hosts that target the same fragment share one selector.** Inside a function
  body, a later `Mutare.Mutator.MacroHost`'s mutants join the earlier host's
  selector instead of nesting a second selector around it, and one coverage
  record names every id. Each mutant keeps its own host's `wrap`, the first
  host's wrapped original stays the fallback, and every host's `splice` still
  runs in order — a later one now receives the combined selector. Where no
  active-id binding is in scope (a default argument, a function of a module
  defined at runtime) the selectors nest as before.
- **A lifted function's guard mutants share one clause.** Where a clause's
  mutants change only its guard, they become `when` alternatives of a single
  generated clause instead of each copying the clause body. On fixtures of
  large-bodied clauses with several guard mutants this cut the generated source
  by up to 4× and the compile's CPU time by up to half. Mutants and their results
  are unchanged.

### Fixed

- **A `with`/`for`/`try` clause with alternative guards no longer crashes the
  metamutant compile.** Mutating a guard such as `x when x > 10 when x < 0`
  produced a nested `when` that the compiler's type checker rejected with no
  file or line, so poison recovery could not drop the mutant and the whole run
  aborted.

## [0.2.1] - 2026-09-17

### Fixed

- **Mutant locations are correct again under Sourceror 1.12.3.** Sourceror used to
  size a bare `true`/`false`/`nil` one column too wide, and Mutare subtracted that
  phantom column to compensate. Sourceror 1.12.3 fixed the over-count upstream, so
  the subtraction began cutting a real character instead: a survivor whose range
  ends at one of those three rendered its diff a character short (`trim: tru`,
  closing paren left behind), and the JSON/SARIF reporters emitted the short
  `endColumn`. The compensation is gone, and `sourceror` is now floored at
  `~> 1.12.3` so there is one upstream behaviour rather than two. Mutation
  behaviour was never affected — a metamutant is built from the AST, never the
  range — and reports on Sourceror 1.12.2 and earlier were correct as they stood.

### Changed

- **Mutant runs execute far more of the target at its original speed.** A function
  holding two or more mutation sites now keeps its own source beside the instrumented
  code, and a mutant elsewhere runs that source. This previously reached only lifted
  functions of eight or more variants written in a narrow subset of Elixir; it now covers
  functions that stay in place and ordinary code — local bindings, sibling calls, closures,
  comprehensions, bitstrings and interpolation, structs, `raise`, `Logger` — about 89–97%
  of generated mutants in the projects measured, up from under 10%. Benchmark kernels that
  previously missed it run at 0.11–0.76× their former time while another mutant is active.
  The one metamutant compile costs about 8% more CPU and 17% more BEAM size.
- **Cheaper entry into every instrumented function.** The active file is stored and
  compared as an atom instead of a path string, and the id projection tells the compiler
  it holds an integer. `Mutare.Selector.put/1` and `active/0` are unchanged; manual
  selection in a generated sandbox still uses `MUTARE_MUTANT_NAMESPACE` and
  `MUTARE_ACTIVE_MUTANT`.

## [0.2.0] - 2026-09-14

### Changed

- **Breaking: score API moved from `Mutare.Report` to `Mutare.Score`:** `score/1`,
  `percent/1`, `passes_gate?/2`, `gate_failures/2`, `harness_error_rate/1`, and
  `harness_errors_exceed?/2`.
- **Breaking: `Mutare.Sandbox.prepare/3` now returns `{sandbox, materialized}`.**
  Seed-reuse outcomes and declined inference overrides are returned as data;
  the runner delivers their progress events.
- **Breaking: live-report text helpers moved to `Mutare.Report.Live.Lines`.**
  Callers of the rendering and time-formatting functions previously on
  `Mutare.Report.Live` should use the new module.
- **Breaking for manual sandbox selection: runtime mutant IDs are now local
  to each file.** Manual selection in a generated sandbox needs both
  `MUTARE_MUTANT_NAMESPACE` (the root-relative file) and `MUTARE_ACTIVE_MUTANT`
  (its local ID). Changing another file's candidate count no longer changes an
  otherwise unchanged metamutant, allowing retained builds to survive unrelated
  changes. Reports still use globally unique IDs; standalone transforms retain
  integer-only selection.

- **Focused runs and ignore directives produce smaller builds.** `--line`,
  `--since`, and `--max-mutants` now limit generated branches as well as execution,
  and ignore directives suppress branches before compilation. IDs, ignore
  diagnostics, and mutant-cap accounting are preserved. Files with no emitted
  mutants keep their original bytes, allowing their compiled modules to be reused.
- **Smaller metamutants and less processing overhead.** Clause mutations share
  code in eligible `case`, anonymous-function, `receive`, and `try/rescue`
  constructs, and exclusion guards compress consecutive IDs. Scanning and poison
  recovery avoid redundant parsing; coverage recording caches hits per file and
  writes a more compact dump.
- **Custom string-pattern mutations follow the built-in redundancy rule.** When
  one mutator offers both empty and non-empty string replacements for an exact
  pattern, Mutare drops the empty replacement.

### Added

- **Guard mutations in more clause positions:** `with` and `for` generators,
  `with` and `try` `else` clauses, `try` `catch` clauses, and `for … reduce:`
  bodies. These are supported inside functions where the runtime selector is
  bound; module-level and default-argument positions remain excluded.

### Fixed

- **Mutations activate before project evaluation, runtime configuration, and
  application startup.** Timeouts and owner-death watchers also start before
  target project code, containing mutations that hang during startup. Closures
  and workers created before test helpers load retain the correct selection and
  can record coverage when they run after recording begins; execution confined
  to startup is still not recorded as coverage.
- **Mutations that prevent startup count as kills.** Failures during project
  evaluation, runtime configuration, or `Application.start/2` use the startup
  retry budget before being scored as killed. Errors, exits, and throws retain
  the evidence needed for this classification even when deep stacktraces lose
  the project or configuration frames. Infrastructure failures remain harness
  errors.
- **An empty coverage result no longer manufactures survivors.** A successful
  probe that records no hits marks the selected mutants `:no_coverage`, including
  runs focused entirely on untested code. Missing or malformed capture data
  still falls back to running the suite.
- **Signature inference stays disabled in sandbox Mix projects on Elixir 1.20.**
  The override now reaches effective compiler options, including umbrella
  children and custom configuration paths, and overrides an explicit
  `infer_signatures: true` to prevent pathological metamutant compile times.
  Other compiler options are preserved. If a project cannot be safely rewritten,
  `--verbose` reports the file and reason, and its seeded compiler cache is left
  consistent with the options it actually uses.
- **Generated operators respect Mutare's semantics under restricted or replaced
  `Kernel` imports.** Selectors, guards, and coverage code no longer resolve
  operators through the target's imports. Coverage short-circuits also work on
  Elixir 1.21 development builds, where `:erlang.andalso` is guard-only.
- **Protocol implementations receive lifted mutations.** Functions in
  module-level `defimpl` blocks now receive guard, head-pattern, and clause
  mutations, with `:skip_lifting` resolving to the implementation module.
- **Immediately invoked anonymous functions are mutated.** Mutare now analyzes
  the callee in `callee.(args)`, including the guards, patterns, and bodies of
  `(fn … end).(args)`.
- **Binding conditions preserve custom and return-value mutations.** Custom
  `condition_replacements` callbacks now receive `if`/`unless` conditions whose
  bindings must escape into the body, even with `IfCondition` disabled. Rewriting
  those conditions also preserves per-branch return mutations and the exclusion
  of unit-returning tails.
- **Bitstring generators no longer produce invalid value mutations.** The
  generator wrapper in `for <<… <- binary>>` is treated as syntax, avoiding
  spurious compile-poison recovery.
- **Macro poison recovery associates each expansion with its own file.** Nested
  expansion stacks no longer cross-match macro names and unrelated call sites;
  findings without a corresponding mutant are discarded instead of crashing
  recovery.
- **Configuration rejects inconsistent extension and routing declarations.**
  Mutator modules cannot be registered as non-mutating extensions merely by
  omitting `@behaviour`; declarative routes reject the internal `{:hosted, hosts}`
  form; and `:partition_env` cannot overwrite `ERL_COMPILER_OPTIONS` or other
  environment variables managed by Mutare.
- **The sandbox ownership-marker writer no longer follows symlinks.**
- **Self-hosted fixture coverage no longer overwrites the outer probe's state or
  dump.**

### Security

- Updated locked Igniter and Mint dependencies to 0.8.4 and 1.10.0 respectively
  to address advisories reported by `mix hex.audit`.

## [0.1.2] - 2026-09-07

### Fixed

- **The kept sandbox preserves empty directories.** The incremental
  materialisation that the default kept sandbox uses mirrored files and
  symlinks only, so a directory with nothing in it never reached the sandbox —
  and a shallow git checkout under `deps/` keeps `.git/refs/heads` and
  `.git/refs/tags` empty. git then no longer recognised the checkout and Mix
  reported every git dependency as a lock mismatch before the metamutant could
  compile; a freshly generated Phoenix 1.8 app (`heroicons`, `daisyui`) could
  not run Mutare at all.
- **Rendering no longer consults the target project's `.formatter.exs`.**
  Sourceror reads `locals_without_parens` from it through `Mix.Tasks.Format` on
  every render — evaluating its `import_deps` and plugins inside Mutare's own
  process — and Mix could refuse the lookup mid-scan ("Unknown dependency
  `:ecto_sql` given to `:import_deps`"). Every render now pins the option
  (`Mutare.AST.render_opts/1`); a parsed call keeps the spelling its metadata
  records, and a node built without metadata renders with parentheses.
- **`mix igniter.install mutare` fetches the companion packages it adds.** The
  companions are chosen from the project's own deps at run time, and Igniter
  writes a dep added that way to `mix.exs` without fetching it — so the
  generated `.mutare.exs` named modules of packages that were never fetched or
  locked. The installer now applies the `mix.exs` change and runs `deps.get`
  before writing `.mutare.exs`.

## [0.1.1] - 2026-09-07

### Fixed

- **Unit-return classification exempts behaviour callbacks.** A function that is a
  callback of one of its module's declared behaviours (direct `@behaviour` or
  `use`-injected, read through the behaviour's `behaviour_info/1` when it is
  loadable), or whose first clause carries an `@impl` other than `@impl false`, is
  never classified unit-returning, however its body reads. Its caller is the
  behaviour's runtime, which the source never shows and which may treat a lone
  `:ok` as one contract outcome among several — `Oban.Worker.perform/1`'s `:ok`
  is one of six. 0.1.0 silenced the `:ok` return mutants of every such callback,
  including `mutare_oban`'s worker-return family.

## [0.1.0] - 2026-09-07

Initial release.

### Added

- **Compile-once metamutant.** Source under `lib/` is rewritten into a single
  program that embeds every mutant behind a `:persistent_term` runtime switch,
  compiled once; the suite then runs once per mutant by flipping
  `MUTARE_ACTIVE_MUTANT` — no per-mutant recompilation.
- **A broad built-in mutator set** (all on by default): arithmetic/operator and
  operand swaps, relational and logical swaps, strict-equality relaxation,
  literals of every kind (integer/float/string/charlist/atom/sigil/regex/
  bitstring/date-time), collection/string/map/keyword call rewrites, pattern and
  clause restructurings, guard/default/call drops, and more. See `Mutare.Mutators`.
- **Unit-return classification** — a function (or anonymous function) whose every
  return path is literally `:ok` or `nil` returns no data, so its tails draw no
  return-value constant and no `:ok → :error` swap. Syntactic, and one-sided: it
  can miss a unit function, never silence a data-returning one.
- **Coverage-guided test selection** — coverage is self-recorded by the metamutant
  at runtime and keyed by mutant id; each mutant runs only the test cases that
  cover it (`--per-file` widens that to the covering test *files*, for stateful
  `async: false` suites; `--full` runs the whole suite every time). Uncovered
  mutants are skipped and excluded from the score.
- **Parallel workers with per-mutant timeouts** — mutants run `:workers` at a
  time, each capped by a wall-clock deadline; a mutation that hangs halts itself
  and counts as a kill (no process-tree killing).
- **Compile-poison recovery** — a mutant that won't compile is identified from the
  compile error, dropped (reported as *poisoned*, excluded from the score), and
  the build retried, for a bounded number of rounds; only a compile error that
  can't be attributed to any mutant (or that outlasts the bound) aborts the run,
  with a copy-pasteable `:skip` snippet.
- **`# mutare:ignore` directive** — suppress a known-equivalent mutant per line,
  per span (`-start`/`-end`), or per file (`-file`), with an optional free-text
  reason and an optional `[family]` / `[family:label]` filter; ineffective
  directives are surfaced (`--strict-ignores` escalates).
- **Reporters** — human (default, survivor diffs + score), plus machine-readable
  `json` (Stryker / mutation-testing-elements schema), `html` (interactive
  viewer), and `sarif` (GitHub code scanning) via `--report FORMAT[:PATH]`
  (repeatable) or `:reporters`.
- **Live progress** on stderr; the detailed report and score are printed to stdout.
- **CI integration** — `--since <ref>` to scope to the lines changed against a
  git ref, `--min-score` to gate, `--line` to target lines, and a kept sandbox
  (the default) so the
  compiled build carries across runs; `--sandbox <path>` pins it at a CI cache,
  `--no-keep-sandbox` opts back into a throwaway copy.
- **Umbrella-aware** — target one app, several, or the whole workspace.
- **Extension surface** — `Mutare.Mutator` (custom mutators), independent
  `Mutare.CallRouting` and `Mutare.UseExpansion` capabilities, `:extensions` for
  non-mutating integrations, declarative `:call_routes` configuration
  (user-tier treatments only; the adapter-grade treatments must come from a
  module implementing `Mutare.CallRouting`), the `Mutare.AST` node
  constructors that discharge Sourceror's emission invariants for plugins, and
  the `Mutare.Calls` call-resolution readers (`resolved_call_to/3`,
  `module_key/1`) so plugins match calls without building core's key
  representation, and a declarative environment guard (`required_modules/0`,
  on mutators and extensions): the modules a DSL plugin routes are checked
  loadable once at startup, aborting with `Mutare.EnvironmentError` instead of
  silently registering routes against nothing on an external-source run.
- **`mix igniter.install mutare`** installer that detects frameworks and wires up
  the matching companion packages and `.mutare.exs`.
- **Call routes** (`call_routes:` / `--skip-call Module.fun/arity`) — leave a
  call alone: `:skip` makes a whole call an inert leaf (functions, macros, and
  the construct special forms alike — `Kernel.if/2` or `case` included; a piped receiver and
  the enclosing function's return-value mutants are unaffected), `:raw` leaves
  an argument as written, `:interior` mutates an argument's contents but never
  its own node, and a keyed refinement (`[:expression, timeout: :raw]`) reaches
  one option of a literal keyword argument. The forms Mutare analyzes
  structurally (`if`, `case`, the boolean operators, …) take `:skip` only, and
  definitions (`def`, `defmodule`, …) and literal syntax (`{}`, `%{}`, `=`, …)
  take no route. Routes match qualified,
  aliased, imported, and piped forms, and an entry that matches no call in a
  full scan is warned about.
- **Argument marks** (`argument_marks:`) — extend the built-in timeout table (or
  any label a mutator declares) to your own functions, with the mutators'
  value-aware reaction: `{MyApp.Http, :get, 2, [{:keyword, :recv_timeout}], :timeout}`.

[Unreleased]: https://github.com/foxbenjaminfox/mutare/compare/v0.3.1...HEAD
[0.3.1]: https://github.com/foxbenjaminfox/mutare/compare/v0.3.0...v0.3.1
[0.3.0]: https://github.com/foxbenjaminfox/mutare/compare/v0.2.1...v0.3.0
[0.2.1]: https://github.com/foxbenjaminfox/mutare/compare/v0.2.0...v0.2.1
[0.2.0]: https://github.com/foxbenjaminfox/mutare/compare/v0.1.2...v0.2.0
[0.1.2]: https://github.com/foxbenjaminfox/mutare/compare/v0.1.1...v0.1.2
[0.1.1]: https://github.com/foxbenjaminfox/mutare/compare/v0.1.0...v0.1.1
[0.1.0]: https://github.com/foxbenjaminfox/mutare/releases/tag/v0.1.0
