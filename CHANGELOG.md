# Changelog

All notable changes to this project are documented in this file.

The format is based on [Keep a Changelog](https://keepachangelog.com/en/1.1.0/),
and this project adheres to [Semantic Versioning](https://semver.org/spec/v2.0.0.html).

## [Unreleased]

### Fixed

- **Signature inference stays disabled on Elixir 1.20.** Sandbox Mix projects now
  return `infer_signatures: false` in their effective `elixirc_options`, including
  umbrella children and projects with custom config paths. Mix can no longer
  overwrite the earlier global setting with its default. Other compiler options
  and the target checkout are preserved; subsequent baseline/probe boots use the
  same setting.
- **A seeded app build is no longer discarded when its `mix.exs` could not be
  wrapped.** The inference cache entry was realigned for every app Mutare *listed*,
  not every app it actually wrapped. A `mix.exs` that builds its project in an
  externally required file, that Sourceror cannot round-trip, or that cannot be read
  is skipped by the rewrite; stamping its manifest anyway left inference on *and*
  mismatched the compiler cache key, so Mix cold-compiled the whole app while the
  seed reported its beams as reused. The rewrite now reports whether the wrap landed,
  and only those apps are realigned.
- **A `mix.exs` Mutare cannot wrap is reported instead of silently slowing the
  compile.** When the inference override cannot be applied (the file does not
  parse, rewriting it would change its meaning, it defines no module of its own, or
  the rewrite fails), its project compiles with signature inference on, which can
  stretch the one compile from seconds to hours. `--verbose` now names each such
  file and the reason; it is also logged at debug level.
- **The `mix.exs` rewrite is checked for meaning, not just syntax.** It was accepted
  whenever the rendered file parsed; Elixir must now read it back as the original
  plus the hook, or the original is kept. A `throw` or `exit` during the rewrite no
  longer escapes sandbox preparation.

### Changed

- **Sandbox inference overrides explicit target options.** An explicit
  `elixirc_options: [infer_signatures: true]` previously took precedence; the
  sandbox now forces it to `false` so inference cannot stall the metamutant
  compile. The target checkout and other compiler options remain unchanged.
- **Smaller metamutants:** tupled cases record hosted coverage once and exclusion
  guards compress exact runs of mutant IDs. Candidate numbering and reported
  mutations remain unchanged.
- **Generated operators no longer depend on the target's imports.** The activation
  gate, exclusion guards, and the coverage record are emitted as explicit `:erlang`
  calls, so a module that narrows or replaces `Kernel`'s `and`, `==`, `===`, `!==`,
  `<`, `>`, `not`, or `is_integer` cannot change what they mean. Function-heavy
  modules also compile measurably faster and in less memory, because `Kernel.and/2`
  in a body expands to a `case` and the coverage record carries two per function.
- **Focused runs emit only selected mutants.** `--line`, `--since`, and
  `--max-mutants` now reduce generated branches as well as execution. Discovery
  still reserves every ID and checks ignore directives; poisoned and ignored
  sites retain their cap positions. Changing selection can require recompiling
  a retained sandbox.
- **Ignored mutants emit no code.** Ignore directives now suppress generated
  branches before rendering, reducing compiler input and preventing ignored
  replacements from poisoning the build. IDs, diagnostic sites, reasons, and
  mutant-cap consumption are preserved; wholly withheld files keep their exact
  original source.
- **The score and CI gates moved to `Mutare.Score`.** `score/1`, `percent/1`,
  `passes_gate?/2`, `gate_failures/2`, `harness_error_rate/1`, and
  `harness_errors_exceed?/2` were defined on `Mutare.Report`, the human-report
  renderer; they now live on their own module. `Mutare.Report.summary/1` and the
  renderers are unchanged.
- **`Mutare.Sandbox.prepare/3` returns `{sandbox, materialized}` and fires no
  hooks.** The app-build seed outcome and each declined inference wrap come back
  in the second element; `Mutare.Runner.Compile` relays them on `:on_phase`, so
  the sandbox no longer reads the run context's live-progress hooks. The kept-mode
  in-place mirror moved to `Mutare.Sandbox.Mirror`, whose byte-aware, symlink-safe
  writer now also writes the ownership marker (it was written through a second,
  symlink-following writer).

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
- **Live progress** on stderr; the detailed report and score print to stdout.
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

[Unreleased]: https://github.com/foxbenjaminfox/mutare/compare/v0.1.2...HEAD
[0.1.2]: https://github.com/foxbenjaminfox/mutare/compare/v0.1.1...v0.1.2
[0.1.1]: https://github.com/foxbenjaminfox/mutare/compare/v0.1.0...v0.1.1
[0.1.0]: https://github.com/foxbenjaminfox/mutare/releases/tag/v0.1.0
