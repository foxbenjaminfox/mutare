# Mutare

Mutation testing for Elixir, built on **one compilation**.

Mutation testing measures whether your test suite actually *constrains* behavior:
it deliberately breaks the source one small change at a time, and a change the
tests fail to catch ("survives") is a precise, located gap in the suite.

Every other Elixir approach recompiles once per mutant — the dominant cost, and
why mutation testing has a reputation for being an overnight job. Mutare compiles
a *single* program (the **metamutant**) that embeds every mutant behind a runtime
switch, then selects the active mutant per test run via an environment variable.
**Compile once; run the suite N times.**

See [`DESIGN.md`](DESIGN.md) for the full rationale and roadmap.

## Status

**Milestone 1 — walking skeleton.** Proven end to end:

- source → metamutant transform via Sourceror (in-place `:persistent_term`
  selector), for **arithmetic** and **relational** mutators
- one compilation, then a fresh OS process per mutant (`MUTANT_UNDER_TEST`)
- baseline-first execution, kill/survive classification
- survivors reported as one-line diffs at `file:line`, plus a mutation score

**Milestone 2 — function lifting + dispatcher.** For mutations that touch
*dispatch*, the clause group is duplicated and a bare catch-all dispatcher routes
to the active copy by id:

- **guard mutations** — operator swaps inside `when` (a `case` can't live in a
  guard)
- **clause-drop** — remove one clause of a multi-clause function
- coexists with in-place selectors, which still apply inside the lifted `__orig`
  copy; the public `f/arity` is unchanged at the module boundary

**Milestone 3 — coverage probe.** The baseline runs with `--cover`:

- **no-coverage skipping** — a mutant whose selector line no test executes is
  skipped and excluded from the score's denominator
- **test selection** — each test file is probed once for coverage; a mutant runs
  only the files that cover its line (file-granular; `--full` runs the whole
  suite per mutant)

**Milestone 4 (in progress) — parallel workers + timeouts.** Mutants run
`:workers` at a time; each run is capped (`baseline × :timeout_multiplier`), and
a mutation that hangs (e.g. a loop turned infinite) is caught — the run halts
itself after the deadline (portable; no process-killing) and counts as a kill.

Suppress a known-equivalent mutant with a comment — trailing ignores its line,
standalone ignores the next line; ignored mutants are excluded from the score:

```elixir
def discounted(amount, percent), do: amount - amount * percent / 100  # mutare:ignore
```

Add a free-text reason (surfaced in the report so the exclusion documents
itself), and/or narrow the directive to specific mutator families with a
`[...]` filter — bracketed families are suppressed, everything else still runs:

```elixir
# mutare:ignore everything on the next line is exercised elsewhere
def passthrough(x), do: x + 0

def parity(n), do: rem(n, 2) == 0  # mutare:ignore[arithmetic] only `rem` is equivalent here
```

A filter accepts the built-in family names (`arithmetic`, `relational`,
`logical`, `literal`, `conditional`, `list`, `collection`, `collection_arity`,
`string_call`, `map_keyword`, `string`, `float`),
plus `clause_drop` and any custom mutator's `name/0`. Filtering fails safe: an
unknown name (a typo) or an empty `[]` matches nothing, so the mutant runs
rather than being silently hidden.

If a mutant won't compile (e.g. a custom mutator emits something invalid), it
would normally sink the whole single build — so Mutare detects the offending
mutant from the compile error, drops it (reported as *poisoned*, excluded from
the score), and rebuilds.

This completes the design's milestones (M1–M4).

## Usage

```
mix mutare                          # mutate everything under lib/
mix mutare --only lib/billing       # scope to a path
mix mutare --since master           # only files changed vs a git ref (CI)
mix mutare --mutators relational    # choose mutator families
mix mutare --min-score 70           # fail (CI) below a score
mix mutare --full                   # whole suite per mutant (no test selection)
mix mutare --format json --output mutare.json   # machine-readable report to a file
```

Optional `.mutare.exs`:

```elixir
[
  paths: ["lib"],
  exclude: ["lib/generated/**"],
  # built-in family atoms and/or your own modules implementing Mutare.Mutator
  mutators: [:arithmetic, :relational, MyApp.Mutators.Boolean],
  min_score: 70,
  workers: System.schedulers_online(),
  timeout_multiplier: 3.0,
  test_selection: :coverage,
  # emit several reports at once (a bare atom goes to stdout)
  reporters: [:human, {:json, "mutare.json"}, {:sarif, "mutare.sarif"}]
]
```

### Machine-readable output

By default Mutare prints the human report to the console. `--format` selects a
machine format, and `--output PATH` writes it to a file (otherwise it goes to
stdout). To emit more than one format in a single run, list `reporters:` in
`.mutare.exs` (above).

- **`json`** — the [mutation-testing-elements](https://github.com/stryker-mutator/mutation-testing-elements)
  / Stryker **report schema**. A standardized, versioned document covering every
  mutant (not just survivors), ready for the Stryker dashboard and other tooling.
- **`html`** — that same JSON embedded in the official interactive report viewer:
  a single self-contained file with a file tree, inline mutant annotations on the
  source, and the score. (Opening it fetches the viewer bundle from a CDN.)
- **`sarif`** — surviving mutants as SARIF 2.1.0 findings, so GitHub code scanning
  shows each one as an inline annotation on the pull-request diff.

When a machine format is written to a file, the human report still prints to the
console; when it takes stdout (no `--output`), the human report is suppressed to
avoid a collision.

### Custom mutators

A mutator is any module implementing the two-callback `Mutare.Mutator`
behaviour — `mutate/1` (an AST node → `:skip` or a list of mutated nodes) and
`name/0`. List it under `:mutators` above. Placement (in-place vs lifted into a
guard) is decided by *where the node sits*, so the same `mutate/1` works in both:

```elixir
defmodule MyApp.Mutators.Boolean do
  @behaviour Mutare.Mutator
  @impl true
  def name, do: :boolean
  @impl true
  def mutate({:and, meta, [l, r]}), do: [{:or, meta, [l, r]}]
  def mutate({:or, meta, [l, r]}), do: [{:and, meta, [l, r]}]
  def mutate(_node), do: :skip
end
```

Example output:

```
mutare: 3 mutants across 1 file(s)
compiling metamutant once, baseline first…

.S.

lib/calc.ex:3  [relational, in-place]  SURVIVED
-  def gte?(a, b), do: a >= b
+  def gte?(a, b), do: a > b

mutation score: 66.7%  (2 killed, 1 survived, 3 total)
```

That survivor says, to the character: nothing in the suite distinguishes `>`
from `>=` at the boundary — a missing boundary test.

## Development

```
mix test                    # full suite (incl. an end-to-end runner test)
mix test --exclude runner   # skip the slower subprocess integration test
```
