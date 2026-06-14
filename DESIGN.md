# Mutare — a mutation testing tool for Elixir

**Codename:** Mutare · **Status:** design draft · **Target:** Elixir ≥ 1.15, Sourceror ≥ 1.x

Mutation testing measures whether a test suite actually *constrains* behavior: it deliberately breaks the source one small change at a time, and a change the tests fail to catch ("survives") is a precise, located gap in the suite.

**The distinguishing bet of this library is one compilation.** Every other approach to Elixir mutation testing recompiles — or hot-reloads — the project once per mutant, and that recompilation is the dominant cost; it is why mutation testing has a reputation for being an overnight job. Mutare compiles a *single* program that embeds every mutant behind a runtime switch, then selects the active mutant per test run via an environment variable. Compile once; run the suite N times. Everything else in this design is downstream of protecting that invariant.

## Goals

- **One compile, period.** No recompilation or module reload anywhere in the hot loop. The per-mutant cost is process launch plus the tests that cover the mutated line — nothing more.
- Mutate the syntax the author wrote — operators stay operators, clauses stay clauses (source-level, pre-expansion).
- Keep each mutant's change minimal and reviewable; surviving mutants render as one-line diffs.
- Stay fast enough to run per-PR on changed files, not just nightly.

## Non-goals

- Higher-order mutants (combining several mutations). First-order only — combinations make "which change did the test catch?" uninterpretable, and as we'll see they'd also break copy-sharing in the schema.
- Solving equivalent-mutant detection in general (undecidable). We mitigate, we don't pretend.
- Instrumenting macro-generated code. That's a post-expansion concern and a different tool; mutation testing wants the human's source.

## The core technique: mutant schemata

The idea is old and proven — Untch, Offutt & Harrold, *Mutation Analysis Using Mutant Schemata* (1993). The single program embedding all mutants is the **metamutant**; StrykerJS uses exactly this (active-mutant selection at runtime), and Pitest is the bytecode-level cousin. Mutare is the source-level, Sourceror-driven realization for Elixir.

A selector variable lives in `:persistent_term` — O(1) reads, designed for write-once/read-billions, which is precisely the access pattern: set once at suite boot, read at every mutation site. Each site checks the active mutant id and takes the mutated branch only when it matches.

## The two-tier source transform

Sourceror does the surgery with **range-preserving patches** (`Sourceror.get_range/1` to locate a node, `Sourceror.patch_string/2` to splice exactly that byte range), so untouched code stays byte-identical and line numbers stay put — which is what keeps surviving mutants reviewable as clean diffs and keeps stack traces aligned to the original file.

There is one general mechanism and one optimization.

### General mechanism: function lifting + dispatcher

Any mutation — including ones that touch *dispatch*, like guards and clause structure, which cannot host a runtime switch in place — is expressed by duplicating the smallest redefinable unit (the function) with the single mutation applied, and dispatching to the active copy by id. Because guards drive dispatch *across* clauses (a failed guard falls through to the next clause), the entire clause group must be lifted as a unit; lifting clause-by-clause would turn fallthrough into a `FunctionClauseError`.

```elixir
# original
def f(a) when a >= 1, do: x
def f(a) when a < 1,  do: y
def f(_),             do: z

# becomes: two full copies + a catch-all dispatcher
defp __mut1234_orig(a) when a >= 1, do: x
defp __mut1234_orig(a) when a < 1,  do: y
defp __mut1234_orig(_),             do: z

defp __mut1234_mut(a) when a > 1, do: x   # only clause 1's guard changed
defp __mut1234_mut(a) when a < 1, do: y
defp __mut1234_mut(_),            do: z

def f(a) do
  case :persistent_term.get(:mutare_active, 0) do
    1234 -> __mut1234_mut(a)
    _    -> __mut1234_orig(a)
  end
end
```

The dispatcher head is a bare catch-all (`f(a)`, not the original patterns): it forwards raw args and lets the private copies do all pattern/guard matching, preserving fallthrough inside each copy. The public `f/arity` is unchanged at the module boundary — see "External transparency" below.

### Optimization: in-place selector (body expressions)

When the mutation is an expression *inside* a body, duplicating the whole function is wasteful. Wrap the site in a `case` in place, and many independent sites coexist in one shared function body:

```elixir
# source:   total >= threshold
case :persistent_term.get(:mutare_active, 0) do
  17 -> total > threshold     # mutant 17:  >= → >
  18 -> total < threshold     # mutant 18:  >= → <
  _  -> total >= threshold    # baseline + every other mutant
end
```

One `case` per site, one clause per mutant at that site, default branch is the original. The wrapper must sit as a *tail-position* `case` (don't bind the result to a temp) so last-call optimization is preserved.

**The mental model:** lifting is the general mechanism; the in-place selector is the optimization that applies whenever a mutation is a self-contained body expression and therefore needs no duplication. The mutator catalog below is annotated accordingly.

## Runtime selection

The active mutant is constant for an entire suite run, so it's read from the environment once at boot and stashed:

```elixir
# in the project's test bootstrap
active =
  case System.get_env("MUTANT_UNDER_TEST") do
    nil -> 0
    id  -> String.to_integer(id)
  end

:persistent_term.put(:mutare_active, active)
```

`0` is the baseline (no mutant). Mutant ids start at 1.

## The schema doubles as a coverage probe

Because every site has a known source line, intersecting site locations with a single `:cover` run tells us which tests exercise which site — for free, from the build we already made. That feeds two things that were separate work in a recompiling design:

- **No-coverage detection.** A mutant on a line no relevant test executes can never be killed; skip it and keep it out of the score's denominator.
- **Test selection.** Run only the tests that touch the mutated line, not the whole suite, per mutant.

(Alternatively the baseline `_` branch can bump a per-site, per-test counter under a tracking flag; the `:cover` intersection is cheaper to build first.)

## Mutators

Pure functions over AST nodes; they never touch source text — the transform applies them uniformly via the recorded range.

```elixir
@callback mutate(Macro.t()) :: :skip | [Macro.t()]
```

| Family | Examples | Realization |
|---|---|---|
| Arithmetic | `+`↔`-`, `*`↔`/`, `div`/`rem` swap | in-place |
| Relational | `>`↔`>=`, `<`↔`<=`, `==`↔`!=` | in-place |
| Boolean / logic | `and`↔`or`, `&&`↔`\|\|`, wrap condition in `not` | in-place |
| Literals | integers ±1, `true`↔`false`, `nil` sentinel, empty↔non-empty list | in-place |
| Branch swap | exchange `if`/`else` (and `case`/`cond` branch) bodies | in-place |
| **Guards** | negate / widen / narrow a `when` comparison | **lifted** |
| **Clause drop** | remove one clause of a multi-clause function | **lifted** |

Mutators are a registry; users add their own via the behaviour. The `in-place` ones must emit compile-safe substitutions by construction (see compile-poisoning); the `lifted` ones must stay guard-safe where they touch a `when`.

## Execution model

- **Compile once.** Run the two-tier transform across all in-scope sources, compile the resulting metamutant to a dedicated build path. This is the only compilation.
- **Fresh OS process per mutant run.** Each run is a separate process with `MUTANT_UNDER_TEST` set, sharing the already-compiled `_build`. Process isolation is non-negotiable: a mutant that corrupts an ETS table or crashes a supervisor must not bleed into the next mutant, and reloading into a shared BEAM is a correctness trap. The win we're banking is the death of *recompilation*, not of process boot — and boot is amortized by running only the covering tests.
- **Baseline first.** Run the suite green (active mutant `0`) before anything. If it's red or flaky, abort loudly — mutation testing on a non-green suite is meaningless, and flakiness manufactures fake kills. Detect flakiness by running the baseline twice and quarantining any test that disagrees with itself.
- **Test selection** via the coverage probe: per mutant, run only the tests touching its line.
- **Timeouts.** A mutation can turn a terminating loop infinite. Per-mutant wall-clock cap = `baseline_time × multiplier`; a timeout counts as *killed* (the mutation caused observable misbehavior).

## Cost model

```
recompiling tools:   N × (recompile + tests)
Mutare:              1 × compile_schema  +  N × (process_boot + covering_tests)
```

`compile_schema` is a single compilation, larger than a normal one because lifted mutants duplicate whole functions and in-place mutants inflate bodies. For any project whose dependency fan-out makes per-mutant recompilation non-trivial — i.e. all of them — paying that inflation once instead of N times is the whole game.

## Known costs and sharp edges

- **Compile-poisoning.** Every mutated branch now lives in the one build, so if a *single* mutated branch won't compile, the whole build dies and you get nothing. This constrains in-place mutators to compile-safe substitutions (most high-value ones — `+`↔`-`, `>`↔`>=`, `true`↔`false` — always compile) and guard mutators to guard-safe outputs. A mutator that can emit an undefined variable, or an unused variable under `--warnings-as-errors`, poisons everything. Optional safety net: compile each candidate branch in isolation at discovery and drop the poisoners (a one-time cost, not per-run).
- **Lifting duplicates whole functions, per mutant.** First-order means each lifted mutant is a full copy with exactly one change; copies can't be shared (sharing = higher-order). A function with K guard/clause mutants → K+1 copies. In-place mutants stay duplication-free. So mutation density on heavily-overloaded functions is where code size and the single compile's time actually grow.
- **Recursion bounces through the dispatcher.** A recursive call inside a lifted copy goes back through the public dispatcher every step — correct, and LCO survives (each hop is a tail call), but 2× the calls per recursion. Fix: within a lifted copy, redirect self-calls to that copy directly, sound because the active mutant is constant for the run. Caveats: `&f/arity` captures must stay pointed at the public dispatcher, and mutual recursion isn't a self-call.
- **External transparency holds** — the quiet payoff. Callers, function captures, and `@behaviour`/`@impl` callbacks all hit the unchanged public `f/arity`; the surgery is invisible at the module boundary. `@spec`/`@doc` ride on the dispatcher; lifted copies are private and `@doc false`.
- **Error provenance shifts.** A `FunctionClauseError` now raises from the lifted private fn, not `f`, so the message names it. Irrelevant to kill/survive; mildly ugly if raw errors surface in reports.
- **Default arguments** (`def f(a, b \\ 5)`) generate a header plus arities; normalize defaults away before lifting rather than special-casing the header.
- **Per-site runtime tax.** Every in-place site does a `:persistent_term` read plus a branch on every execution, including the baseline run. Fast, but measurable in hot loops — worth profiling on a suite that's already slow.

## Equivalent mutants

Some mutations produce a program semantically identical to the original (`x * 1` vs `x / 1`, a bound never reached) and can never be killed, inflating the denominator. Undecidable in general. Mitigations: don't emit obviously-equivalent mutations; honor a `# mutare:ignore` annotation on a node or range; report suspected-equivalent survivors separately so they don't drag the score.

## CLI & config

```
mix mutare                      # build the schema, run all mutants
mix mutare --only lib/billing   # scope to a path
mix mutare --since master         # changed files vs a git ref (CI mode)
mix mutare --mutators relational,boolean
```

```elixir
# .mutare.exs
[
  paths: ["lib"],
  exclude: ["lib/generated/**"],
  mutators: :all,                 # or a list
  workers: System.schedulers_online(),
  timeout_multiplier: 3.0,
  min_score: 70,                  # CI fails below this
  test_selection: :coverage       # :coverage | :full
]
```

## Output & scoring

```
mutation score = killed / (total − no_coverage − ignored)
```

The headline number tracks trends; the **list of surviving mutants, each a diff at file:line**, is the product:

```diff
lib/billing/invoice.ex:42  [relational, in-place]  SURVIVED
-     if total >= threshold do
+     if total > threshold do
```

This says, to the character: nothing in the suite distinguishes `>` from `>=` at the threshold boundary — a missing boundary test.

## Milestones

1. **Walking skeleton.** Sourceror discovery + in-place selector + relational/arithmetic mutators + persistent_term selection + fresh-process runner + diff report. Whole-suite execution, single worker. Proves one-compile end-to-end.
2. **Function lifting + dispatcher.** Brings guard and clause-drop mutators online; the design's distinctive piece.
3. **Coverage probe → no-coverage skipping + test selection.** Turns "overnight" into "per-PR."
4. **Parallel workers, timeouts, `--since`, `min_score` gating, ignore annotations, custom-mutator API, compile-poisoning pre-filter.**

## Open questions

- Worker isolation by full source copy vs per-worker `MIX_BUILD_PATH` against the shared schema build — measure on a large umbrella.
- Self-call redirection inside lifted copies: ship in v2, or defer until profiling shows recursion cost matters?
- Per-test coverage source: `:cover` line intersection (cheap, needs line→test bookkeeping) vs an in-schema counter under a tracking flag.
- Umbrella projects: one schema per app and aggregate, or treat the umbrella as one corpus?
- Compile-poisoning pre-filter: always-on (safe, costs one isolated compile per candidate at discovery) vs opt-in for projects with adventurous custom mutators?
