# CLAUDE.md

Guidance for Claude Code working in this repo.

**This file is a map, not a manual.** It exists to tell you *where* things are and
*which* gotchas to internalize before touching anything. The detail lives elsewhere,
and that's deliberate — duplicating it here is how four copies drift:

- **Per-module mechanics** → that module's `@moduledoc` (read it when you're in the file).
- **The *why* behind non-obvious decisions** → `NOTES.md`, the implementation logbook
  (deferred work, sharp edges, dead ends). Cross-referenced below as *NOTES "title"*.
- **How the project thinks** → `PHILOSOPHY.md`.
- **User-facing overview** → `README.md`.

When you find yourself explaining *how a single module works* in this file, stop — that
belongs in its moduledoc. Keep this navigational.

## What this is

Mutare is a **mutation testing tool for Elixir**, built on one bet: **compile once**.
It rewrites a target project's source into a single *metamutant* program that embeds every
mutant behind a `:persistent_term` runtime switch, compiles it once, then runs the suite once
per mutant by flipping `MUTARE_ACTIVE_MUTANT`. Read `PHILOSOPHY.md` and `NOTES.md` before
substantial changes — they are unusually load-bearing and will save you re-deriving things.

## Commands

```
mix test                                        # full suite (subprocess + property soaks included)
mix test --exclude runner --exclude property    # fast loop: skips subprocesses and the property soak
mix test --only property                        # just the transform property soak
mix test test/mutare/transform_test.exs          # a single file
mix test test/mutare/transform_test.exs:42       # a single test (by line)
mix format
mix compile --warnings-as-errors      # CI-style; the project is kept warnings-clean
mix mutare examples/auth              # run the tool against a bundled demo project
mix run script.exs                    # ad-hoc exploration in the lib context (uses MIX_ENV=dev)
```

`@moduletag :runner` tests (`runner_test`, `coverage_test`, `mix_task_test`, `timeout_test`,
`poison_test`, `ignore_test`, …) shell out to real `mix test` subprocesses; `@moduletag :property`
tests are PropCheck soaks that render/compile/run streams of generated modules. Both are slow —
exclude them while iterating, run the full suite before committing. `mix run` uses `:dev`, where
`test/support/*.ex` fixtures (the custom-mutator examples) are **not** compiled — they exist only
under `MIX_ENV=test`.

## Architecture

The pipeline, in dependency order. A change usually touches one stage; the contracts *between*
stages are the whole game. Each entry is a one-line role + the moduledoc to read for detail.

- **`Mutare.Transform`** — the heart. `source → {metamutant_source, [%Site{}], next_id}` via an
  explicit staged pipeline (resolve → analyze/classify → plan → assign → emit → render) over a
  small IR. Context is classified *positively* and routed; mutators run **once**. Its sub-modules:
  - **Name resolution pre-passes** (`Resolve` is the driver; `Aliases`, `Imports`, `Uses`,
    `Behaviours`) — one walk that stamps every call/construct with what it resolves to, so the
    call-matching families recognise aliased / imported / Erlang-atom / `use`-injected forms, and
    behaviour-gated mutators see the enclosing `@behaviour` set. `Uses` expands `use` (in-process,
    or via an extension override) to recover the `import`/`alias` idiomatic Phoenix/Ecto hide.
  - **`Calls` / `Analyze.Captures`** — the single `resolved_call/1` reader every call family uses
    (returns `{module, fun, args, rebuild}`), plus `&Mod.fun/N` capture mutation. `Mutare.Calls`
    is the published facade re-exporting the author-facing readers.
  - **`Analyze`** — the context-threaded recursive descent that names each position's context
    (`:runtime` / `:pattern` / `:scaffold` / `:compile_time` / …) and attaches a typed candidate to
    each mutatable node's own metadata. This is where most routing subtlety lives (patterns, pipes,
    conditions with escaping bindings, keyword keys, macros) — read the moduledoc before editing it.
  - **`ModulePlan` / `FunctionPlan` / `Candidate.*`** — the IR: statements classified into items,
    liftable clause groups, and one typed struct per legal mutation kind.
  - **Emit** (`emit/2`, plus pure helpers `ClauseAST` / `GuardBuild` / `LiftedEmit` /
    `CaseClauseEmit` / `Tag` / `Overlap` / `Super`) — assigns ids bottom-up and delivers each
    candidate by one of two mechanisms: an **in-place `case` selector** (body expressions) or
    **function lifting + a dispatcher** (guards, head patterns, clause structure — where a `case`
    is illegal). Placement is positional; mutators never choose. `Overlap` drops a leaf mutant a
    call rewrite already covers.
- **`Mutare.Schema`** — runs `Transform` across discovered files, threading **globally-unique,
  stable** mutant ids via a two-phase parallel build (count → prefix-sum → render). Honors
  `:paths`/`:exclude`/`:only_files` (`--since`)/`:only_lines` (`--line`)/`:max_mutants`/`:skip_ids`
  (poison recovery; the id counter advances even for skipped ids, so ids stay stable across rebuilds).
- **`Mutare.Manifest` / `Mutare.Metamutant`** — the lazily-built map from a metamutant line range
  back to the mutant id(s) living there, so **Poison** can attribute a compile error. Keyed by id;
  no metamutant↔original line mapping.
- **`Mutare.Sandbox`** (+ `Seed`, `Command`, `Command.Invocation`/`Output`, `CompilerOptions`) —
  materializes a temp copy of the target, overwrites the metamutant sources, injects a
  dependency-free bootstrap (selector reader + timeout watcher + coverage helper), and seeds the
  deps'/app's compiled `_build` so the one compile is minimal. `Command` is the **run side of the
  exit-code contract**: it runs a mutant `mix test` and decodes the exit code into a typed outcome
  (`:passed`/`:failed`/`:timeout`/`:harness_error`, refined from output into
  `:suite_compile_error`/`:atom_exhausted`/`:boot_failure`).
- **`Mutare.Runner`** (+ `Baseline`, `CoverageProbe`, `Partitions`) — the orchestrator: compile
  once (recovering from poison), check the baseline is green, run a coverage probe for test
  selection, then run `:workers` mutants concurrently and map each outcome to a result status.
  Owns the retry/abort guards (`:harness_retries`, `:max_harness_error_rate`, the dedicated
  `:boot_failure` budget) and the runner-loop caps (`:max_survivors`).
- **`Mutare.Coverage` / `Mutare.Coverage.Recorder`** — coverage is **self-recorded** by the
  metamutant at runtime (not `:cover`), keyed by mutant id and attributed per test process. Drives
  `:no_coverage` and per-file test selection.
- **`Mutare.Poison`** (+ `Hint`) — on a failed compile, maps the error's `file:line` to mutant
  id(s), drops them via `:skip_ids`, and rebuilds (bounded). `Hint` renders a copy-pasteable
  `:skip` snippet for the one poison class that can't be auto-isolated (a macro needing a
  compile-time literal arg).
- **`Mutare.Report`** (+ `Live`, `Json`/`Html`/`Sarif`) — the default human reporter diffs each
  surviving mutant against the **original** source and computes the score
  `killed / (total − no_coverage − ignored − poisoned − harness_error)`. `Live` is the live stderr
  progress (`GenServer`); the machine reporters are pure renderers selected via `:reporters`.
- **Config surface** — `Mutare.Options` (validated user config) + `Options.Registry` (the single
  source of every option's default/CLI-switch/validator) + `Mutare.Run.Context` (runtime wiring:
  the resolved project + the four live-progress hooks). `Mutare.Config`/`Changes` +
  `Mix.Tasks.Mutare` resolve `.mutare.exs` + CLI flags + `git diff` for `--since`.
- **Extension surface** — `Mutare.Mutator` (+ capability behaviours `Mutator.Structural` /
  `Mutator.MacroHost`) and `Mutare.Mutators.*` (the built-in families); `Mutare.Mutators` (the one
  ordered registry + resolver); `Mutare.Mutator.Spec` (the resolved unit of "a mutator to run");
  `Mutare.MacroRouting` + its internal registry (static and shape-aware known-macro routing);
  `Mutare.UseExpansion` (a `use` override); `Mutare.Extension` (the non-mutating `:extensions`
  boundary). See "Extending it".

The built-in mutator families are **all on by default**. Don't catalogue them here — the
`Mutare.Mutators` `@registry` is the source of truth for *which* exist, and each family's swap
table/exclusions/rationale live in its own `@moduledoc`. Two cross-cutting facts to know going in:
core *categorizes* families by how it routes them (in-place operator/value swaps, literal swaps,
call-matching, structural, behaviour-gated, configurable — which producing callback a family
implements tells you which), and families have **ownership splits** so two don't emit the same
mutant (e.g. `true`/`false`/`nil` belong to `Literal`/`Conditional` not `AtomLiteral`; commutative
operators and boolean ops are excluded from `OperandSwap`; `Relational` owns equality *polarity*
while `StrictEquality` owns *relaxation*). No single moduledoc lists all the splits, but each is
documented in the **owning** family's moduledoc — check there before adding a swap that might overlap
another family's.

## Cross-cutting things that bite

These span modules, so no single moduledoc holds them. Internalize them before substantial changes.

- **The selection/coverage/timeout contracts are split across modules and baked into generated
  code.** The `:persistent_term` selection key and `MUTARE_ACTIVE_MUTANT` live in `Mutare.Selector`;
  the timeout env var + watcher in `Mutare.Sandbox.Command.Invocation` and its exit code in
  `Mutare.Sandbox.Command`; the coverage contract (`MUTARE_COVERAGE`, `:mutare_track`, the ETS
  tables, `MutareCov`, the dump file) in `Mutare.Coverage.Recorder`. `Mutare.Transform` emits the
  selectors/coverage into the metamutant; `Mutare.Sandbox` emits the reader/watcher/helper into the
  bootstrap. Change one half in isolation and the metamutant stops responding. (The selection key is
  resolved at *runtime* by `Selector.key/0` so Mutare can dogfood itself without clobbering its own
  active mutant — NOTES "Self-hosting".)
- **Two renderers, on purpose.** The metamutant is a build artifact (AST rewrite via
  `Sourceror.to_string`, only needs to compile); the report patches the original source. Don't try
  to make one serve both.
- **Two line spaces, decoupled.** Poison works in metamutant-line space (via `Manifest`); the report
  works in original-line space. They never need relating — don't reintroduce a mapping. (Coverage
  uses neither; it keys by mutant id.)
- **Compile-safety is layered.** Built-in mutators are compile-safe by construction (swaps reuse
  operands); dangerous/inert positions are excluded *positively* by the context classifier, not a
  blacklist; the poison pre-filter is the backstop for the unknown (custom mutators, DSLs). A single
  mutation that won't compile would sink the whole single build.

## Extending it

Implement `Mutare.Mutator`: `name/0` plus at least one producing callback. **Placement is
positional** — you never decide in-place vs lifted. Build literal replacements with
**`Mutare.AST.literal/1`** (it encodes the Sourceror clean-meta rule; building them by hand silently
re-renders the original). Register a built-in by adding one `family: Module` entry to the
`Mutare.Mutators` `@registry`; users add custom modules under `:mutators` in `.mutare.exs`.

Pick the callback by what you're mutating — each has a working fixture under `test/support/` and full
contract docs on the behaviour. Capability behaviours are declared alongside `Mutare.Mutator`:

| Kind | Implement | Example fixture |
| --- | --- | --- |
| Node-level swap | `mutate/1` | `boolean_mutator.ex` |
| Arity-changing / pipe-aware call | `mutate/2` (reads `pipe_mode`) | — (`CollectionArity`) |
| Configurable (`{Module, opts}`) | `mutate/2` (reads `context.opts`) | `configurable_mutator.ex` |
| Structural return tail / condition | `return_replacements` / `condition_replacements` | `structural_mutator.ex` |
| Structural head pattern | `pattern_mutations/2` | (`PatternSwap`/`PatternWildcard`) |
| Behaviour-gated | read `context.behaviours` (or the `+1`-arity structural callbacks) | `behaviour_mutator.ex` |
| Call-matching (stdlib/remote) | resolve via `Mutare.Calls.resolved_call/1` | `resolved_call_mutator.ex` |
| Macro routing (static or shape-aware) | `Mutare.MacroRouting.macro_routes/0` + optional `route_arguments/2` | `macro_mutator.ex` / `host_mutator.ex` |
| Selector-hosting (mutate inside a DSL fragment) | subscribe via `Mutator.MacroHost.hosted_macros/0` + implement `host/2` | `host_mutator.ex` |
| Per-kind `# mutare:ignore` qualifier | `variants/0` (opt-in) + tag via `Mutation.tagged/2` *or* `variant/2` | (value & operator families) |

An **extension** is a non-mutating module implementing `Mutare.MacroRouting`,
`Mutare.UseExpansion`, or both. It has no `name/0`, never appears in a report, and is listed under
`:extensions`; enabled mutators are inspected for routing capabilities separately. The motivating
case is Gettext; see `test/support/extension_fixtures.ex` and NOTES "Extension `use`-expansion
override".

The contract details (notes, `:as` renaming, the macro-routing treatments
`:expression`/`:pattern`/`:binding_pattern`/`:skip`/`:hosted`/`:scalar_interpolation`/`{:keyword, …}`, the
variant-label rules) are in the
`Mutare.Mutator` / `Mutare.MacroRouting` / `Mutare.Mutator.MacroHost` /
`Mutare.UseExpansion` moduledocs — read those when implementing.

## Result statuses & `# mutare:ignore`

`:killed` / `:survived` are the verdict (the product is the survivor diffs, not the headline score).
Four are excluded from the score denominator: `:no_coverage`, `:ignored`, `:poisoned`,
`:harness_error` (a run that never reached a verdict — infra failure, **not** charged as a kill).
`:timeout` and `:atom_exhausted` count as kills. Every per-status fact (classification, JSON name,
labels, styling) lives once in the `Mutare.Result.Status` descriptor registry — add a status by
adding a row plus the type union.

The `# mutare:ignore` directive (`Mutare.Ignore`) is parsed from Sourceror comment metadata:

```
# mutare:ignore                              suppress every mutant on the line
# mutare:ignore <free text>                  suppress all; the text is recorded as the reason
# mutare:ignore[arithmetic, relational]      suppress only those mutator families
# mutare:ignore[relational:>]                suppress only the `i < j → i > j` reflection; `<=` runs
# mutare:ignore[return_value:empty]          suppress one mutation kind by its declared label
# mutare:ignore[literal] off-by-one is fine  filter + reason together
```

The `[...]` filter matches a site's `mutator` name, optionally `:`-qualified with a **variant label**
the mutator *declares* (`variants/0`, then tags each mutation via `Mutation.tagged/2` or derives it
with `variant/2`) — not a token derived from the rendered AST.
Qualifiers are strict where the mistake is certain (a `[family:label]` on an active family that
doesn't declare that label is a hard `Mutare.Ignore.SpecError`); an unknown *family* stays lenient
(indistinguishable from a `--mutators`-excluded one). A directive that suppresses nothing is surfaced
as `ineffective` (warned at scan time; `--strict-ignores` escalates to a non-zero abort). Details in
the `Mutare.Ignore` moduledoc.
