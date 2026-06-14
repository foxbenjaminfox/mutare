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

The coverage probe, parallel workers, timeouts and `--since` are later milestones.

## Usage

```
mix mutare                          # mutate everything under lib/
mix mutare --only lib/billing       # scope to a path
mix mutare --mutators relational    # choose mutator families
mix mutare --min-score 70           # fail (CI) below a score
```

Optional `.mutare.exs`:

```elixir
[
  paths: ["lib"],
  exclude: ["lib/generated/**"],
  mutators: :all,
  min_score: 70
]
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
