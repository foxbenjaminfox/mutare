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

Any mutation — including ones that touch *dispatch*, like guards and clause structure, which cannot host a runtime switch in place — is expressed by lifting the function: the whole clause group moves into one private function that takes the active mutant id as an extra argument, and the public function becomes a dispatcher that reads the id and forwards. Because guards drive dispatch *across* clauses (a failed guard falls through to the next clause), the clause group is lifted **as a unit** — but it is *not* duplicated per mutant. Each source clause is emitted once, gated `when mutare_active !== <id>` for the mutants that override/drop it; each mutant is a single extra clause gated `when mutare_active === <id>`, placed before the original it replaces. Fallthrough is preserved (all clauses live in the one function, in order), and a function with C clauses and M mutants emits ~C+M clauses, not C×M.

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

Every site sits behind a selector whose catch-all runs on every baseline execution of that line — so the metamutant can **self-record coverage**. Under a tracking flag (set only for one instrumented baseline run), the catch-all records the site's mutant ids into shared ETS *synchronously, in the test process*, keyed by the running test's label; an `after_suite` hook dumps it. That single run feeds two things that were separate work in a recompiling design:

- **No-coverage detection.** A mutant whose line no test executes (process-agnostic aggregate) can never be killed; skip it and keep it out of the score's denominator.
- **Test selection.** Run only the test *files* that covered the line, per mutant. A covered-but-unattributed mutant (its code ran only in an unlabeled process) runs the whole suite.

This is the *per-site, per-test counter under a tracking flag* sketched as the alternative in the original design — chosen over a `:cover` line intersection because cover's table is global (`{module, line}`, no per-process partition), so attributing coverage to a test in one run needs an async-formatter snapshot that **races** test execution and loses fast `async: false` modules' coverage. Self-recording captures it in-process, accumulate-only, with no race. (`Mutare.Coverage.Recorder` owns the generated side; `Mutare.Coverage` reads the dump.)

## Mutators

Pure functions over AST nodes; they never touch source text — the transform applies them uniformly via the recorded range.

```elixir
@callback mutate(Macro.t()) :: :skip | [Macro.t()]
```

Realization is **positional, not declared** by the mutator: the same `mutate/1` is delivered in-place in a body or by lifting in a `when` guard, decided by where the matched node sits (see *Function lifting*). All built-in families are **on by default**; a user narrows the set by listing a subset under `:mutators`.

| Family | Examples |
|---|---|
| Arithmetic | `+`↔`-`, `*`↔`/`, `div`↔`rem`, unary `-x`→`x` |
| Relational | `>`↔`>=`, `<`↔`<=`, `==`↔`!=`, direction flips |
| Logical | `and`↔`or`, `&&`↔`\|\|`, strip `not`/`!` |
| Literal | integers `n`→`{n±1, 0}`, `true`↔`false` |
| Conditional | a boolean-valued node → `true` / `false` ("remove conditionals") |
| List | `++`↔`--`, non-empty list literal → `[]` |
| Collection | `Enum.filter`↔`reject`, `all?`↔`any?`, `min`↔`max`, … (arity-blind renames) |
| CollectionArity | arity-*changing* `Enum` calls: `sort`/`sort_by`→`reverse` (drop comparator/key), `count/2`→`count/1`, `count_until/3`→`/2`, `reverse/1`↔`sort/1` — **pipe-aware** (via `mutate/2`) |
| StringCall | `String.starts_with?`↔`ends_with?`, `upcase`↔`downcase`, `trim_leading`↔`trailing`, `first`↔`last`, … |
| Numeric | complementary numeric builtins: `Kernel` `min`↔`max`, `round`↔`trunc`, `ceil`↔`floor`, `Float.ceil`↔`Float.floor` — qualified forms (`Float.`/`Kernel.`) are arity-blind renames, bare-`Kernel` swaps are **pipe-aware** (arity-checked); `div`↔`rem` lives in Arithmetic |
| MapKeyword | conditional-write lattice for `Map`/`Keyword`: `put`↔`put_new`↔`replace`↔`replace!` (overwrite / insert-if-absent / update-if-present / raise; arity-blind) |
| CallRemoval | remove a transparent transform — `Enum.sort`/`reverse`/`uniq`/`dedup`, `List.flatten`, `String.trim`/`downcase`, … → its first arg (in a pipe: `Function.identity()`); **pipe-aware** |
| DefaultDrop | drop a trailing default/fallback — `Map.get`/`pop`/`Keyword.get`/`Enum.at`/`List.first`/`last` `/n`→`/n-1`, `get_lazy`/`pop_lazy`→base (skips a literal-`nil` default); **pipe-aware** |
| StringLiteral | a string → `""` *and* `"mutare"` (drops the one matching the original) |
| FloatLiteral | floats `x`→`{x±1.0, 0.0}` |
| **Return value** | a function clause's return-path tail (`:do`, and each `rescue`/`catch`/`else` clause body) → a contrasting *pair*: empty/zero + a non-nil sentinel (numeric→`0`/`1`, `<>`→`""`/`"mutare"`, `++`/`--`→`[]`/`[:mutare]`, else→`nil`/`:mutare`) — structural, in place |
| **Pattern swap** | swap two variables inside a container — `{x, y}`→`{y, x}`, `[a, b]`→`[b, a]`, map values; in a `def`/`defp` head (lifted) or a `case`/`receive`/`fn` clause (in-place, structural) |
| **Pattern wildcard** | a variable that repeats in a pattern → replace one occurrence with `_`, dropping the equality constraint — `f(x, x)`→`f(_, x)`; in a `def`/`defp` head (lifted) or a `case`/`receive`/`fn` clause (in-place, structural) |
| **Clause drop** | remove one clause of a multi-clause function (structural, lifted) |

Guard, head-pattern-literal, head-pattern-structure (variable swap / wildcard), and clause-drop mutants are the **lifted** ones (a `case` can't live in a `when` or a pattern, so the whole clause group is duplicated behind a dispatcher); everything else is delivered in place when it sits in a body. A literal in a `def`/`defp` head (`def f(1)`, `def f(%{1 => 2})`) is mutated this way — only literal-valued mutations are admitted, since only a literal is legal in a pattern. The same lift path carries the structural head-pattern rewrites (swap two variables in a container; wildcard one of a repeated variable's occurrences), which are likewise pattern-legal by construction. **Return value** is structural like clause-drop (its target — a clause's *return position* — is one only the transform knows, not a node a `mutate/1` could match) but is delivered *in place*: the tail is a body position, so its constant goes behind the same tail-position selector `case`. The call-matching families (Collection, StringCall, Numeric, …) recognise a call by its **resolved** module through one reader (`Mutare.Transform.Calls.resolved_call/1`), fed by a single lexical pre-pass (`Mutare.Transform.Resolve`) that threads one scoped environment and stamps every call. Its rules live in two vocabulary modules. `Mutare.Transform.Aliases` resolves `alias` and stamps each remote call's module position, so an aliased `S.upcase` (`alias String, as: S`) is mutated to `S.downcase` — the alias preserved in the diff — and a shadow `alias MyApp.Enum` is correctly *not* mutated. `Mutare.Transform.Imports` resolves `import` and stamps each *bare* call, so a bare `reject(xs, f)` after `import Enum` is mutated like `Enum.reject` (bare when the whole module is imported, qualified otherwise). It needs only a *module*, not a definition — any compiling bare call is unambiguous — and learns exported arities by runtime reflection (resolution is per-arity); a `Kernel` function can only be displaced by `import Kernel, except:/only:`, which it tracks so the bare-`Kernel` families skip a displaced call. The two **interleave** in source order (an `alias` can rebind a later `import`'s module), which the single fold gets right by construction. (Erlang atom-module imports and operator displacement are out of scope.) Mutators are a registry (`Mutare.Mutators`); users add their own via the behaviour. Every mutation must be compile-safe by construction (one poisoned branch sinks the single build) and guard-safe where it can reach a `when` — built-ins satisfy both: operator swaps reuse operands, literal swaps stay the same kind, and the families that touch operators the parser forbids in guards (`&&`/`||`/`!`/`++`/`--`) can never appear there. Return-value and clause-drop are structural (not expressible by a node-level `mutate/1`) and stay built-in.

## Execution model

- **Compile once.** Run the two-tier transform across all in-scope sources, compile the resulting metamutant to a dedicated build path. This is the only compilation.
- **Fresh OS process per mutant run.** Each run is a separate process with `MUTANT_UNDER_TEST` set, sharing the already-compiled `_build`. Process isolation is non-negotiable: a mutant that corrupts an ETS table or crashes a supervisor must not bleed into the next mutant, and reloading into a shared BEAM is a correctness trap. The win we're banking is the death of *recompilation*, not of process boot — and boot is amortized by running only the covering tests.
- **Baseline first.** Run the suite green (active mutant `0`) before anything. If it's red or flaky, abort loudly — mutation testing on a non-green suite is meaningless, and flakiness manufactures fake kills. Detect flakiness by running the baseline up to N times (`--baseline-runs`, default 1): all green proceeds, all red is `:baseline_failed`, and a disagreement aborts `:baseline_flaky` naming the offending tests. Abort-and-name is the shipped behavior; *quarantining* the flaky tests and proceeding over the stable subset is a deferred refinement (see `NOTES.md`).
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
- **Lifting adds a clause per mutant, not a whole copy.** First-order means each lifted mutant differs from baseline by exactly one change, in exactly one clause — so it is emitted as a *single* id-gated clause in the shared lifted function, not a full copy of the group (an earlier design did copy the whole group → `C×M` clauses, quadratic on a big dispatcher; see NOTES "lifting blowup"). A group with C clauses and M guard/head/drop mutants → ~C+M clauses. In-place mutants stay duplication-free. Mutation density on heavily-overloaded functions still grows code size, but linearly now, not multiplicatively.
- **Recursion bounces through the dispatcher.** A recursive call inside the lifted function goes back through the public dispatcher every step — correct, and LCO survives (each hop is a tail call), but 2× the calls per recursion (and a fresh `:persistent_term` read each hop). Fix: rewrite a self-call inside the lifted function to call the lifted function directly, threading the already-bound `mutare_active`, sound because the active mutant is constant for the run. Caveats: `&f/arity` captures must stay pointed at the public dispatcher, and mutual recursion isn't a self-call.
- **External transparency holds** — the quiet payoff. Callers, function captures, and `@behaviour`/`@impl` callbacks all hit the unchanged public `f/arity`; the surgery is invisible at the module boundary. `@spec`/`@doc` ride on the dispatcher; lifted copies are private and `@doc false`.
- **Error provenance shifts.** A `FunctionClauseError` now raises from the lifted private fn, not `f`, so the message names it. Irrelevant to kill/survive; mildly ugly if raw errors surface in reports.
- **Default arguments** (`def f(a, b \\ 5)`) generate a header plus arities; normalize defaults away before lifting rather than special-casing the header.
- **Per-site runtime tax.** Every in-place site does a `:persistent_term` read plus a branch on every execution, including the baseline run. Fast, but measurable in hot loops — worth profiling on a suite that's already slow.

## Equivalent mutants

Some mutations produce a program semantically identical to the original (`x * 1` vs `x / 1`, a bound never reached) and can never be killed, inflating the denominator. Undecidable in general. Mitigations: don't emit obviously-equivalent mutations; honor a `# mutare:ignore` annotation — optionally scoped to specific mutator families with a `[family, …]` filter and carrying a free-text reason that the report surfaces, so each exclusion documents *why* it's equivalent; report suspected-equivalent survivors separately so they don't drag the score.

## CLI & config

```
mix mutare                      # build the schema, run all mutants
mix mutare --only lib/billing   # scope to a path (a directory or a single .ex file)
mix mutare --since master         # changed files vs a git ref (CI mode)
mix mutare --mutators relational,logical,conditional
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
- ~~Per-test coverage source: `:cover` line intersection vs an in-schema counter under a tracking flag.~~ **Resolved:** self-recording in the metamutant under a tracking flag (see *The schema doubles as a coverage probe*). `:cover` can't attribute per-test in one run without an async-formatter snapshot that races test execution.
- ~~Umbrella projects: one schema per app and aggregate, or treat the umbrella as one corpus?~~ **Resolved:** treat the umbrella as one corpus — copy the whole umbrella (so `in_umbrella` siblings resolve), thread one globally-unique id space, and mutate a scoped subset of apps. The split is *copy-root* (the umbrella root, materialised) vs *mutate-scope* (which `apps/*` get metamutants), resolved by `Mutare.Project`. See NOTES.md *Umbrella support*.
- Compile-poisoning pre-filter: always-on (safe, costs one isolated compile per candidate at discovery) vs opt-in for projects with adventurous custom mutators?
