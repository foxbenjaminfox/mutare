# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository.

## What this is

Mutare is a **mutation testing tool for Elixir**, built on one bet: **compile once**.
It rewrites a target project's source into a single *metamutant* program that embeds every
mutant behind a `:persistent_term` runtime switch, compiles it once, then runs the suite once
per mutant by flipping `MUTANT_UNDER_TEST`. Read `DESIGN.md` (the blueprint), `PHILOSOPHY.md`
(how the project thinks), and `NOTES.md` (the implementation logbook — deferred work, sharp
edges, and the *why* behind non-obvious decisions) before substantial changes; they are
unusually load-bearing and will save you re-deriving things.

## Commands

```
mix test                              # full suite (~25s; includes slow subprocess tests)
mix test --exclude runner             # fast loop: skips tests that spawn real `mix` subprocesses
mix test test/mutare/transform_test.exs          # a single file
mix test test/mutare/transform_test.exs:42       # a single test (by line)
mix format
mix compile --warnings-as-errors      # CI-style; the project is kept warnings-clean
mix mutare examples/toy               # run the tool against the bundled demo project
mix run script.exs                    # ad-hoc exploration in the lib context (uses MIX_ENV=dev)
```

Tests tagged `@moduletag :runner` (e.g. `runner_test`, `coverage_test`, `mix_task_test`,
`timeout_test`, `poison_test`, `ignore_test`) shell out to real `mix test` subprocesses and are
slow — exclude them while iterating, but run the full suite before committing. `mix run` uses
the `:dev` env, where `test/support/*.ex` fixtures are **not** compiled; those (custom mutator
fixtures) only exist under `MIX_ENV=test`.

## Architecture

The pipeline, in dependency order. A change usually touches one stage; understanding the
contract between them is the whole game.

- **`Mutare.Transform`** — the heart. `source → {metamutant_source, [%Site{}], next_id}`. An
  explicit staged pipeline (analyze → classify → **plan** → assign → emit → render) over a small
  IR, not a walk-everything-then-subtract blacklist. Context is classified *positively* and
  routed; mutators run **once**. The IR splits *vocabulary* (plan structs, owning discovery) from
  *emission* (id assignment, site recording, AST building — kept in `Transform`):
  - **`Transform.ModulePlan`** — a statement sequence classified into items: `{:lift, FunctionPlan}`,
    `{:in_place, clauses}`, `{:statement, node}`. `build/3` does the run-chunking + non-consecutive
    detection; `Transform.emit_module_plan/2` walks the items.
  - **`Transform.FunctionPlan`** — one liftable clause group: signature, clauses, a single shared
    *tagged* clause group, and its typed lifted candidates. `mutated_clauses/2` reconstructs a
    mutant copy on demand (so the group is stored once, not per guard mutant).
  - **`Transform.Candidate.{InPlace,Guard,Drop}`** — typed candidate variants (one struct per
    legal kind), replacing the old single struct that redundantly stored `context`/`kind`/
    `operation` and admitted illegal combinations. The matching `Site` constructor is chosen by
    pattern-matching the variant at emit.
  - **analyze + classify (`analyze/3`)** is a single context-threaded recursive descent: it
    *names the context* of each position as it descends (routing is positional — the spec side of
    a `::` goes one way, the value side another, which a flat `Macro.traverse` accumulator can't
    express) and attaches a typed `Candidate.InPlace` to each mutatable node's *own metadata*
    (`meta[:mutare]`) — which is why there's no fragile `{line, column}` node identity and no
    double mutator invocation. Two contexts are threaded: `:runtime` → in-place (`:guard`/
    `:clause_drop` are produced by the separate lift path), and `:pattern` (don't mutate, but keep
    descending so default-arg values and `size()` args are still reached). The rest are recognised
    and pruned by dedicated clauses: `:compile_time` (module-attribute values like `@x 1 + 2`,
    `defmacro`/`defmacrop` bodies, `quote` blocks, **and** `import`/`alias`/`require`/`use`
    directives whose args must be compile-time literals — frozen at compile/expansion time, so a
    selector there is inert, or in a directive arg like `import …, only: [f: 1]` / a quoted
    pattern outright illegal), `:spec` (a bitstring type
    specifier — separators/`unit()`/type atoms excluded, but
    `size(expr)` args recursed; `analyze_spec/3`), and `:capture_arity` (the `/` in `&fun/arity`,
    an arity separator not division).
  - **assign + emit (`emit/2`)** is a bottom-up `Macro.postwalk` so ids are assigned in
    post-order DFS; the id counter advances even for `:skip_ids` (poison recovery relies on it).
  - **in-place selector** for body expressions: wrap the operator in a tail-position
    `case :persistent_term.get(:mutare_active, 0) do <id> -> mutated; _ -> original end`.
  - **function lifting + dispatcher** for `when` guards and clause structure (a `case` can't
    live in a guard): duplicate the whole clause group into private `__orig`/`__mut` copies and
    make the public `f/arity` a bare dispatcher. In-place selectors live only in `__orig`.
    Guard targets are tagged via `meta[:mutare_tag]` on a single shared clause group held by the
    `FunctionPlan`; `FunctionPlan.mutated_clauses/2` materializes each mutant copy on demand, so
    emission never re-finds the node and the group isn't copied per guard mutant.
- **`Mutare.Schema`** — runs `Transform` across discovered files, threading **globally-unique,
  stable** mutant ids. Honors `:paths`/`:exclude`, `:only_files` (for `--since`), and `:skip_ids`
  (for poison recovery — the id counter advances even for skipped ids, so ids stay stable across
  rebuilds; this stability is relied upon). Per mutated file it also stores a **`Mutare.Manifest`**
  (built once from the rendered metamutant), which Coverage and Poison read back.
- **`Mutare.Manifest`** — the per-file, per-mutant map of *where each mutant lives in its
  rendered metamutant*: the full **generated line ranges** (selector clause bodies, lifted
  private `defp` copies, and a whole-`case` fallback) that **Poison** maps a compile error back
  to a mutant id with. Built once by `Schema` (re-parsing the metamutant via `Sourceror` for
  `get_range/1`). `Mutare.Metamutant` owns the selector-subject AST and the `subject?/1`
  recognizer this walk uses. (Coverage no longer lives here — the metamutant self-records it at
  runtime, keyed by mutant id, so there is no `{module, line}` location to precompute.)
- **`Mutare.Sandbox`** — workspace materialization. Copies the target project to a temp dir and
  overwrites the metamutant sources. Injects a **dependency-free bootstrap** into `test_helper.exs`:
  reads `MUTANT_UNDER_TEST` into `:persistent_term`, plus a portable timeout watcher that
  `System.halt/1`s the run itself after the cap (no killing an OS process tree). Also writes the
  dependency-free `MutareCov` coverage helper (`lib/mutare_cov.ex`) and appends the coverage
  bootstrap *after* `ExUnit.start/0` (it registers an `after_suite` dump) — both inert unless the
  probe sets `MUTARE_COVERAGE` (see `Mutare.Coverage.Recorder`).
- **`Mutare.Sandbox.Command`** — command execution against a materialized sandbox: `mix/4` and
  `timed_mix/4` spawn a fresh `mix` OS process with `MIX_ENV=test`/`MUTANT_UNDER_TEST` set. Owns the
  *run side* of the **exit-code contract** and decodes it into a typed
  `Mutare.Sandbox.Command.Result` (`timed_test/4`): `0`→`:passed`, `failure_exit/0`→`:failed`,
  `timeout_exit/0`→`:timeout`, anything else→`:harness_error` (the total decoder is `outcome/1`).
  The pivot is `--exit-status failure_exit/0`, forced onto every mutant `mix test`: a clean ExUnit
  failure (a kill) exits with that distinctive code, while a compile error / missing dep / broken
  helper exits `1` — so a harness error is no longer indistinguishable from a kill. Also owns the
  timeout sub-contract — the env var the cap travels in (`timeout_env/0`) and the exit code a
  timeout signals (`timeout_exit/0`); the `Mutare.Sandbox` bootstrap renders the watcher that
  honours them.
- **`Mutare.Runner`** — the orchestrator. Compiles the sandbox **once** (recovering from
  compile-poisoning, see below), runs the baseline green then a coverage probe, then runs
  `:workers` mutants concurrently via `Task.async_stream`, each a fresh `mix test` OS process.
  Per-mutant wall-clock cap; a timeout is a kill (`:timeout`). Maps each run's typed
  `Command.outcome` onto a result status — notably `:harness_error` (an infra failure that never
  reached a verdict) stays out of the score, never charged as a kill. Two knobs guard against
  flaky/broken infra: `:harness_retries` (re-run a harness-erroring mutant before recording it)
  and `:max_harness_error_rate` (abort `{:error, :too_many_harness_errors, …}` when persistent
  harness errors exceed that fraction of the mutants that *ran*). Returns
  `%{schema, results, sandbox, baseline_ms}`.
- **`Mutare.Runner.Baseline`** — a whole-suite `mix test` (no `--cover`) at the baseline mutant:
  the authoritative green check (a red suite aborts with `:baseline_failed`) and the source of
  `baseline_ms` (a *single* run's wall-clock — the per-mutant timeout cap is scaled from it). With
  `:baseline_runs` > 1 it runs the suite up to N times (short-circuiting on disagreement) to catch
  a **flaky** suite: all green → proceed (`baseline_ms` = the slowest green run); all red →
  `:baseline_failed`; mixed → `:baseline_flaky` (abort, naming the disagreeing tests — a flaky test
  manufactures false kills). The all-green/all-red/mixed decision is the pure, tested
  `Baseline.classify/1`.
- **`Mutare.Runner.CoverageProbe`** — coverage-driven test selection, run after the baseline. A
  **single** instrumented `mix test` at baseline (`MUTARE_COVERAGE=1`), then it reads the dump.
  Per mutant: never ran → `:no_coverage`; covered with attributed test files → those files;
  covered but **unattributed** (its code ran only in an unlabeled process — `setup_all`,
  `on_exit`, a spawned task) → whole suite, *not* `:no_coverage`. Returns a bare `selection`
  (`:run_all | {:selective, %{id => outcome}}`) and **can't fail**: an unreadable/empty dump
  degrades to `:run_all`. Split from the baseline on purpose — folding the two conflated a green
  check that never ran the suite together with a `baseline_ms` summed over N per-file process
  boots (an inflated cap). See `NOTES.md`.
- **`Mutare.Coverage.Recorder`** — the **generated** side of coverage capture (owns the contract
  the metamutant and the bootstrap share): `record_ast/1` (spliced into every selector catch-all),
  `helper_source/0` (the `MutareCov` module `Sandbox` writes in), and `bootstrap_ast/0`. The
  catch-all records the site's mutant ids into shared ETS *synchronously, in the test process*,
  gated `mutare_active == 0 and :persistent_term.get(:mutare_track, false) and MutareCov.hit(ids)`
  — inert on per-mutant runs (short-circuits on the id compare) and outside the probe.
- **`Mutare.Coverage`** — reads back the probe's dump: `%{aggregate, by_file}`, both keyed by
  **mutant id**. `aggregate` (process-agnostic: any process that ran the line) is the no-coverage
  signal; `by_file` (labeled test processes only) drives per-file selection. No `:cover`, no
  coverdata, no metamutant↔original line mapping. Why self-record, not `:cover`: cover's table is
  global (`{module, line}`, no per-process partition), so per-test attribution in one run needs an
  async-formatter snapshot that **races** test execution and loses fast `async: false` modules'
  coverage; recording in the metamutant captures it in-process, accumulate-only (no reset).
- **`Mutare.Poison`** — on a failed metamutant compile, maps the error's `file:line` to the
  offending mutant id(s) via the manifest's **generated line ranges** (`Manifest.ids_at_line/2`,
  narrowest range wins). This catches poison anywhere a mutant's code lives — a multiline body, a
  lifted private `defp`, or (as a coarse fallback) the surrounding `case` — not just a selector
  clause's start line. The runner drops the implicated ids via `:skip_ids` and rebuilds, bounded.
  Zero cost when nothing poisons.
- **`Mutare.Report`** — diffs each *surviving* mutant against the **original** source via
  `Sourceror.patch_string` (clean one-line diffs), and computes the score:
  `killed / (total − no_coverage − ignored − poisoned − harness_error)`. This is the default
  *human* reporter.
- **`Mutare.Report.{Json,Html,Sarif}`** — the **machine** reporters, pure renderers paralleling
  `Mutare.Report` (`(results, sources, opts) → String.t()`; all IO stays in the Mix task). **Json**
  emits the standardized *mutation-testing-elements / Stryker* report schema (every mutant, keyed
  by file; `Result.status` maps 7-for-7 onto the schema's `MutantStatus` — the one place the two
  vocabularies meet). **Html** embeds that JSON into the `mutation-test-report-app` web component
  (no bespoke renderer; neutralises `</` so embedded source can't close the inline `<script>`).
  **Sarif** emits survivors-only as SARIF 2.1.0 findings for GitHub code scanning (reuses
  `Site.describe/1` as the message). Encoding is the stdlib `JSON` module — hence the `elixir`
  floor is `~> 1.18`. Selected via the `:reporters` option (below).
- **`Mutare.Mutator`** + **`Mutare.Mutators.*`** — the public extension behaviour (`mutate/1`,
  `name/0`) and the built-in families, **all on by default**: Arithmetic (binary swaps +
  unary-minus removal), Relational, Logical (`and`↔`or`, `&&`↔`||`, `not`/`!` strip), Literal
  (integers `n`→`{n±1, 0}`, `true`↔`false`), Conditional (a boolean-valued node → `true`/`false`),
  List (`++`↔`--`, non-empty list literal → `[]`), Collection (`Enum`/`List` predicate swaps),
  StringLiteral (a string → `""` *and* the sentinel `"mutare"`), FloatLiteral. A user narrows the
  set by listing a subset under `:mutators`.
- **`Mutare.Mutators`** — the **single ordered registry** of built-in families and the one place
  mutator lists are resolved/validated. `all/0` is the default set (every registered module — an
  unset `:mutators`/`:all`); `families/0` is every registered atom; `resolve/1` maps any family atom
  + custom modules to validated modules. `Transform` (its default), `Config` (the CLI/`.mutare.exs`
  path), and `Options` (the direct `Mutare.run/2` API) all derive from it — so a family registered
  here is part of `:all` and resolvable/validated everywhere, with no second list to drift.
- **`Mutare.Config`** / **`Mutare.Changes`** / **`Mix.Tasks.Mutare`** — `.mutare.exs` + CLI flag
  resolution, `git diff` for `--since`, and the CLI entry point. Output formats resolve here too:
  `--format`/`--output` (CLI) and `reporters:` (`.mutare.exs`) become the `Mutare.Options`
  `:reporters` list (`[{format, path | nil}]`, `nil` = stdout). `Config.resolve_reporters/2` owns
  the **collision rule** — `--format` *with* `--output` keeps the human report on the console and
  writes the machine format to the file; `--format` *alone* takes stdout and drops the human
  report. Note `:reporters` (output formats; `Options` validates the format set) is distinct from
  `:reporter` (the live per-mutant progress callback the task sets).

### Cross-cutting things that bite

- **The selection contract is split across modules and baked into generated code.** The
  `:persistent_term` key (`:mutare_active`) and the selector env var (`MUTANT_UNDER_TEST`) are
  defined in `Mutare.Selector`; the timeout env var and exit code in `Mutare.Sandbox.Command`; the
  coverage-capture contract (the `MUTARE_COVERAGE` env var, the `:mutare_track` flag, the ETS table
  names, the `MutareCov` helper, the dump file) in `Mutare.Coverage.Recorder`. They are *emitted
  into generated code* — the selectors and coverage record into the metamutant by `Mutare.Transform`,
  the reader/timeout watcher/coverage bootstrap+helper into the bootstrap by `Mutare.Sandbox`. Keep
  them in sync — change one in isolation and the metamutant stops responding.
- **Two renderers, on purpose.** The metamutant is a throwaway build artifact (AST rewrite via
  `Sourceror.to_string`, only needs to compile); the report patches the original source. Don't
  try to make one serve both.
- **Two line spaces, decoupled.** Poison maps a compile error in metamutant-line space (via
  `Manifest`); the report works in original-line space. They never need to be related — don't
  reintroduce a mapping between them. (Coverage uses neither: it keys by mutant id.)
- **Compile-safety is layered.** Built-in mutators are compile-safe by construction (operator
  swaps reuse operands); dangerous/inert positions (guards, module-attribute values, the `/` in
  `&fun/arity` captures) are excluded *positively* by the context classifier (`skip_node?/1`),
  not by a blacklist; the poison pre-filter is the backstop for the unknown (e.g. custom
  mutators). A mutation that won't compile would sink the whole single build.

## Adding a mutator

Implement `Mutare.Mutator` (`mutate/1` returning `:skip` or a list of mutated nodes that reuse
the original operands; `name/0`). Register a built-in by adding a `family: Module` entry to
`Mutare.Mutators`'s ordered `@registry` — the only edit, since the default set (`:all`),
`families/0` and resolution all follow from it (everything registered is on by default). Users
list custom modules directly under `:mutators` in `.mutare.exs`. Do **not** decide in-place vs
lifted — placement is positional. `test/support/boolean_mutator.ex` is a working example.

Remember the Sourceror **clean-meta** rule for literal-valued mutators: a literal parses as
`{:__block__, meta, [value]}` and renders from a `:token` string in `meta`, so reusing the
original meta would render the *original* text even after changing the value (a silent equivalent
no-op). Emit replacements with fresh metadata (`{:__block__, [], [value]}`).

## Result statuses

`:killed` / `:survived` (the product is the survivor diffs, not the headline score), plus four
that are excluded from the denominator: `:no_coverage` (no test runs the line), `:ignored`
(`# mutare:ignore` — see below), `:poisoned` (dropped — wouldn't compile), and `:harness_error` (the mutant
run never reached a verdict — a compile error, missing dep, or filesystem race — so it measures
nothing about the mutation; classified by `Mutare.Sandbox.Command`'s exit-code contract, **not**
charged as a kill). `:timeout` counts as a kill.

### The `# mutare:ignore` directive (`Mutare.Ignore`)

Parsed from Sourceror's comment metadata (not a raw-text scan), so a literal string that *reads*
like the directive is never mistaken for one. Trailing ⇒ own line, standalone ⇒ next line
(`previous_eol_count` decides). The grammar after the keyword has two optional, ordered parts:

```
# mutare:ignore                              suppress every mutant on the line
# mutare:ignore <free text>                  suppress all; the text is recorded as the reason
# mutare:ignore[arithmetic, relational]      suppress only those mutator families
# mutare:ignore[literal] off-by-one is fine  filter + reason together
```

The `[...]` **filter** matches a site's `mutator` name (the families in `Mutare.Mutators`, plus
`clause_drop` and any custom `name/0`); without brackets, *all* mutators match. Filtering fails
**safe** — an unknown name or empty `[]` matches nothing, so the mutant runs rather than hides,
and bracket-less trailing words are always prose, never an accidental filter. The matched
directive's reason rides onto the `Site` (`ignore_reason`) and `Mutare.Report` lists each ignored
mutant with it. `Mutare.Ignore.directives_from_ast/1` returns `%{line => [%Ignore.Directive{}]}`;
`Transform` applies it per `{line, mutator}`, not per line.
