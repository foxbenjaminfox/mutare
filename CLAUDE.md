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

- **`Mutare.Transform`** — the heart. `source → {metamutant_source, [%Site{}]}`. Two mechanisms,
  chosen *by where a node sits*, never declared by the mutator:
  - **in-place selector** for body expressions: wrap the operator in a tail-position
    `case :persistent_term.get(:mutare_active, 0) do <id> -> mutated; _ -> original end`.
  - **function lifting + dispatcher** for `when` guards and clause structure (a `case` can't
    live in a guard): duplicate the whole clause group into private `__orig`/`__mut` copies and
    make the public `f/arity` a bare dispatcher. In-place selectors live only in `__orig`.
- **`Mutare.Schema`** — runs `Transform` across discovered files, threading **globally-unique,
  stable** mutant ids. Honors `:paths`/`:exclude`, `:only_files` (for `--since`), and `:skip_ids`
  (for poison recovery — the id counter advances even for skipped ids, so ids stay stable across
  rebuilds; this stability is relied upon).
- **`Mutare.Sandbox`** — copies the target project to a temp dir and overwrites the metamutant
  sources. Injects a **dependency-free bootstrap** into `test_helper.exs`: reads
  `MUTANT_UNDER_TEST` into `:persistent_term`, plus a portable timeout watcher that `System.halt/1`s
  the run itself after the cap (no killing an OS process tree).
- **`Mutare.Runner`** — the orchestrator. Compiles the sandbox **once** (recovering from
  compile-poisoning, see below), runs a coverage probe, then runs `:workers` mutants concurrently
  via `Task.async_stream`, each a fresh `mix test` OS process. Per-mutant wall-clock cap; a
  timeout is a kill (`:timeout`). Returns `%{schema, results, sandbox, baseline_ms}`.
- **`Mutare.Coverage`** — the probe. Works **entirely in metamutant line space**: re-parses the
  rendered metamutant to map each mutant id to its selector's catch-all line, intersects with
  `:cover` per-line hits. No-coverage mutants are skipped; per-test-file selection runs only
  covering files per mutant. (`:cover` lives in OTP `:tools`, which this module adds to the code
  path at runtime.)
- **`Mutare.Poison`** — on a failed metamutant compile, maps the error's `file:line` to the
  offending mutant id (re-parsing selector clauses). The runner drops it via `:skip_ids` and
  rebuilds, bounded. Zero cost when nothing poisons.
- **`Mutare.Report`** — diffs each *surviving* mutant against the **original** source via
  `Sourceror.patch_string` (clean one-line diffs), and computes the score:
  `killed / (total − no_coverage − ignored − poisoned)`.
- **`Mutare.Mutator`** + **`Mutare.Mutators.*`** — the public extension behaviour (`mutate/1`,
  `name/0`) and built-in families (Arithmetic, Relational).
- **`Mutare.Config`** / **`Mutare.Changes`** / **`Mix.Tasks.Mutare`** — `.mutare.exs` + CLI flag
  resolution, `git diff` for `--since`, and the CLI entry point.

### Cross-cutting things that bite

- **The selection contract is split across three modules and baked into generated code.** The
  `:persistent_term` key (`:mutare_active`), the env var (`MUTANT_UNDER_TEST`), and the timeout
  env/exit code are defined in `Mutare.Selector` / `Mutare.Sandbox` but *emitted into the
  metamutant* by `Mutare.Transform`. Keep them in sync — change them in one place and the
  metamutant stops responding.
- **Two renderers, on purpose.** The metamutant is a throwaway build artifact (AST rewrite via
  `Sourceror.to_string`, only needs to compile); the report patches the original source. Don't
  try to make one serve both.
- **Two line spaces, decoupled.** Coverage matches in metamutant-line space; the report works in
  original-line space. They never need to be related — don't reintroduce a mapping between them.
- **Compile-safety is layered.** Built-in mutators are compile-safe by construction (operator
  swaps reuse operands); dangerous positions (guards, the `/` in `&fun/arity` captures) are
  excluded structurally; the poison pre-filter is the backstop for the unknown (e.g. custom
  mutators). A mutation that won't compile would sink the whole single build.

## Adding a mutator

Implement `Mutare.Mutator` (`mutate/1` returning `:skip` or a list of mutated nodes that reuse
the original operands; `name/0`). Register a built-in in `Mutare.Config`'s `@registry`; users
list custom modules directly under `:mutators` in `.mutare.exs`. Do **not** decide in-place vs
lifted — placement is positional. `test/support/boolean_mutator.ex` is a working example.

## Result statuses

`:killed` / `:survived` (the product is the survivor diffs, not the headline score), plus three
that are excluded from the denominator: `:no_coverage` (no test runs the line), `:ignored`
(`# mutare:ignore`), `:poisoned` (dropped — wouldn't compile). `:timeout` counts as a kill.
