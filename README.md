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
`string_call`, `map_keyword`, `call_removal`, `default_drop`, `numeric`, `math`,
`integer`, `string`, `float`),
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
mix mutare --workers 4              # run N mutants concurrently
mix mutare --timeout 30000          # per-mutant wall-clock cap, in ms
mix mutare --format json --output mutare.json   # machine-readable report to a file
```

Optional `.mutare.exs`:

```elixir
[
  paths: ["lib"],
  exclude: ["lib/generated/**"],
  # which mutators run (see "Choosing which mutators run" below). Built-in family
  # atoms and/or your own modules; the `:builtins` token means "all built-ins", so
  # `[:builtins, MyApp.Mutators.Boolean]` extends the defaults rather than replacing.
  mutators: [:arithmetic, :relational, MyApp.Mutators.Boolean],
  # mark a macro's arguments as off-limits for mutation, by module/name/arity
  # (see "Skipping macro arguments" below). `:skip` = every argument; a list
  # skips only the marked positions (`:expression` = mutate as normal).
  macros: [
    {Ecto.Query, :from, :skip},
    {MyApp.Schema, :field, 2, [:expression, :skip]}
  ],
  # fail the run (non-zero exit) if the mutation score drops below this;
  # the same CI gate as `--min-score`, which overrides this when given
  min_score: 70,
  workers: System.schedulers_online(),
  # per-mutant cap = baseline × timeout_multiplier, unless an absolute
  # `timeout:` (ms) is set — both also available as --workers / --timeout
  timeout_multiplier: 3.0,
  test_selection: :coverage,
  # emit several reports at once (a bare atom goes to stdout)
  reporters: [:human, {:json, "mutare.json"}, {:sarif, "mutare.sarif"}]
]
```

These are the common keys; `mix help mutare` documents the full set — sandbox /
build-cache reuse (`sandbox`, `keep_sandbox`), baseline re-runs (`baseline_runs`),
the harness-error guards (`harness_retries`, `max_harness_error_rate`),
`max_mutants`, `strict_ignores`, `quiet`, and `expand_uses` — each also a CLI flag.

### Live progress

While a run is in flight, Mutare shows live progress on **stderr**: the current
phase (compiling once, baseline, coverage probe), then a permanent line for each
surviving mutant the moment it's found (plus timeouts and harness errors), and —
in a terminal — a status block at the bottom with a spinner, the mutant currently
under test, and a counter with an ETA. Piped or on CI it degrades to plain
scrollback (no cursor tricks). The detailed survivor diffs and the score still
print to **stdout** at the end, so `mix mutare > report.txt` captures the report
while you watch progress on the terminal.

### Machine-readable output

By default Mutare prints the human report to the console (stdout). `--format`
selects a machine format, and `--output PATH` writes it to a file (otherwise it
goes to stdout). To emit more than one format in a single run, list `reporters:`
in `.mutare.exs` (above).

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

### Skipping macro arguments

Some macros take arguments that aren't ordinary runtime code — a query DSL body,
a pattern, a schema definition. Mutating inside them is pointless at best and can
break the single compile at worst (a selector spliced into `Ecto.Query.from`'s
body, say). When Mutare can't tell a macro call from a normal function call, list
the macro under `macros:` in `.mutare.exs` and its arguments are left **raw** — no
custom mutator required:

```elixir
macros: [
  # every argument of `from/_` (any arity) is left untouched
  {Ecto.Query, :from, :skip},
  # only the 2nd argument of `field/2` is skipped; the 1st mutates as normal
  {MyApp.Schema, :field, 2, [:expression, :skip]}
]
```

An entry is `{Module, :name, arity, treatment}`, or `{Module, :name, treatment}`
to match **any arity**. The `treatment` is either a single atom applied to every
argument or a per-position list:

- `:skip` — leave the argument raw (no descent, no mutation).
- `:expression` — mutate it as normal runtime code (the default).
- `:pattern` — treat it as a match pattern (descend, but don't mutate the pattern
  itself); for the rare macro that takes one (like `match?/2`).

A per-position list is padded with `:expression`, so `[:expression, :skip]` reads
as "mutate the first argument, skip the second, mutate the rest". The macro is
matched however it's written — directly, aliased, or imported (bare). `Module` may
be an Elixir module (`Ecto.Query`), an Erlang atom module (`:binary`), and is
resolved purely syntactically, so it needn't be a dependency of the Mutare process.

### Choosing which mutators run

The `:mutators` list (in `.mutare.exs`, or `--mutators` on the CLI) is sugar over
one canonical idea: **a list of mutators, each with its configuration.** Every
shorthand below desugars to that, so whenever a config confuses you, expand it in
your head and you have exactly the set that runs, in order.

The conveniences, simplest first:

```elixir
# 1. The canonical form — a mutator and its config:
mutators: [{Mutare.Mutators.Arithmetic, []}, {MyApp.Mutators.Boolean, []}]

# 2. Drop the config when it's empty — bare module or family atom:
mutators: [:arithmetic, MyApp.Mutators.Boolean]
#          ^ a built-in family atom expands to its module with default config.
#            (Atoms name built-ins; external mutators are named by their module.)

# 3. Omit :mutators entirely → every built-in family, default config, no externals.
```

To work *from* the defaults rather than listing everything, use the **`:builtins`**
group token (its synonym is `:all`). Whether it appears decides extend vs. replace:

```elixir
mutators: [:builtins, MyApp.Mutators.Boolean]   # EXTEND  — all built-ins + your own
mutators: [MyApp.Mutators.Boolean]              # REPLACE — only your own

mutators: [{:builtins, except: [:arithmetic, :relational]}]   # all built-ins but these
```

To **reconfigure** a built-in, don't reach for magic — exclude it, then re-add it
configured yourself:

```elixir
mutators: [
  {:builtins, except: [:convention]},                 # all built-ins but the stock one…
  {Mutare.Mutators.ConventionAtom, pairs: [[:active, :inactive]]}   # …re-added, configured
]
```

So: **family atoms name a built-in, `:builtins` names the whole built-in group,
including the token extends, leaving it out replaces, and `except:` removes.** On
the CLI, `--mutators` takes a CSV of those atoms (`--mutators builtins,relational`);
`except:` and custom modules are `.mutare.exs`-only.

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
