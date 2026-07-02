# Changelog

All notable changes to this project are documented in this file.

The format is based on [Keep a Changelog](https://keepachangelog.com/en/1.1.0/),
and this project adheres to [Semantic Versioning](https://semver.org/spec/v2.0.0.html).

## 0.1.0 - Unreleased

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
- **Coverage-guided test selection** — coverage is self-recorded by the metamutant
  at runtime and keyed by mutant id; each mutant runs only the test files that
  cover it. Uncovered mutants are skipped and excluded from the score (`--full`
  opts out).
- **Parallel workers with per-mutant timeouts** — mutants run `:workers` at a
  time, each capped by a wall-clock deadline; a mutation that hangs halts itself
  and counts as a kill (no process-tree killing).
- **Compile-poison recovery** — a mutant that won't compile is identified from the
  compile error, dropped (reported as *poisoned*, excluded from the score), and
  the build retried, so one bad mutation never sinks the single build.
- **`# mutare:ignore` directive** — suppress a known-equivalent mutant per line,
  with an optional free-text reason and an optional `[family]` / `[family:label]`
  filter; ineffective directives are surfaced (`--strict-ignores` escalates).
- **Reporters** — human (default, survivor diffs + score), plus machine-readable
  `json` (Stryker / mutation-testing-elements schema), `html` (interactive
  viewer), and `sarif` (GitHub code scanning) via `--format` or `:reporters`.
- **Live progress** on stderr; the detailed report and score print to stdout.
- **CI integration** — `--since <ref>` to scope to changed files, `--min-score`
  to gate, `--line` to target lines, and `--keep-sandbox` to cache the compiled
  sandbox across runs.
- **Umbrella-aware** — target one app, several, or the whole workspace.
- **Extension surface** — `Mutare.Mutator` (custom mutators), independent
  `Mutare.MacroRouting` and `Mutare.UseExpansion` capabilities, `:extensions` for
  non-mutating integrations, and declarative `:macro_routes` configuration
  (user-tier treatments only; the adapter-grade treatments must come from a
  module implementing `Mutare.MacroRouting`).
- **`mix igniter.install mutare`** installer that detects frameworks and wires up
  the matching companion packages and `.mutare.exs`.
