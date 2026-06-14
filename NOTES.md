# Implementation notes & deferred work

A running log of decisions made and limitations discovered while building Mutare.
`DESIGN.md` is the vision; this file tracks reality and what's intentionally left
for later. Items are tagged with the milestone that should resolve them.

## Deferred / known limitations

### Metamutant line preservation — RESOLVED (avoided) `[M3, done]`
In-place selectors and lifted copies shift line numbers in the metamutant, so we
worried the coverage probe would need a metamutant↔original line map. It doesn't.
The probe works **entirely in metamutant line space**: `Mutare.Coverage` re-parses
the rendered metamutant, maps each mutant id → the line of its selector's catch-all
(`_ ->`) branch, and intersects with `:cover`'s per-line hits on the baseline. The
original line is only ever used by the report (which patches the original source),
so the two never need to be related. No line preservation required.

Two `:cover` gotchas worth remembering (both handled in `Mutare.Coverage`):
- `:cover.analyse(:coverage, :line)` returns `{:result, ok, fail}` (3-tuple) on
  this OTP, not the documented `{:ok, _}`.
- cover does **not** count the `case` keyword line of a selector nested on a
  continuation line (`acc +\n  case … end`); it counts the catch-all body line.
  So we key coverage on the catch-all body line, which is hit iff the selector
  ran at baseline.

### Sandbox isolation & dependencies `[M4 / open question]`
`Mutare.Sandbox` copies the whole project (excluding `_build`/`.git`, keeping
`deps`) to a temp dir. Consequences:
- **Path deps don't resolve in the copy.** A target using `{:mutare, path: ...}`
  (or any local path dep) breaks in `/tmp`. That's why the example is driven via
  `mix mutare examples/toy` (positional root) rather than depending on Mutare.
  Hex deps are fine (they're under the copied `deps/`).
- We don't run `mix deps.get` in the sandbox; relies on the original having
  fetched deps already. Fine for the common case, revisit for robustness.
- The design's open question stands: full source copy vs per-worker
  `MIX_BUILD_PATH` against one shared schema build — measure on a large umbrella.

### Keyword-`do:` normalization (Sourceror workaround) `[done, watch]`
Sourceror's formatter raises when rendering `def f, do: <case>` (keyword block
whose value is a multi-line `case`). `Mutare.Transform.normalize_keyword_blocks/1`
flips every keyword-format key back to a plain atom key before rendering.
Metamutant only; the report is unaffected. Keep an eye on Sourceror releases in
case this becomes unnecessary.

### Non-body operator positions
- **Guards:** mutated via lifting (M2) — operators in a `when` are swapped in a
  duplicated clause group, since a `case` can't live in a guard. In-place still
  skips them.
- **Module-attribute expressions** (`@x 1 + 2`): wrapped in place. They compile
  (persistent_term reads the default at compile time → original) but the mutant
  is frozen at compile time and can never activate — an inert/equivalent mutant.
  Harmless but wasteful; could be excluded like guards.
- **Default arg values** (`def f(a \\ b + 1)`): mutated in place; live mutant.
  Note such functions are *not lifted* (defaults expand to multiple arities;
  normalize-then-lift is deferred), so they get no guard/clause-drop mutants.

### Function lifting (M2): sharp edges `[various]`
- **Recursion bounces through the dispatcher.** A self-call inside a lifted copy
  hits the public dispatcher and re-dispatches — correct, LCO survives, but ~2×
  the calls. Self-call redirection (point self-calls at the active copy) is
  deferred (DESIGN open question / v2).
- **Error provenance shifts.** `FunctionClauseError` now raises from the lifted
  private fn (`__mutare_f_1_g3_orig`), so its message names that, not `f`.
  Irrelevant to kill/survive; mildly ugly in raw error output.
- **`@doc`/`@spec`/`@impl`** ride on the public dispatcher because we emit it
  *first* in the lifted group (attributes attach to the next def). Private copies
  are `defp` (no docs needed). Not exhaustively tested across attribute shapes.
- **Not lifted (fall back to in-place):** functions with default args, and
  operator-named functions (`def a ~> b` — can't be spelled `__mutare_~>_2_…`).
- **Private names** are `__mutare_<name>_<arity>_g<group>_{orig,m<id>}`: the
  `g<group>` counter keeps them unique even for non-consecutive same-name clause
  groups, and `?`/`!` (legal only at a name's end) are replaced so they can sit
  mid-identifier. The public dispatcher keeps the real name.
- **Lifting duplicates whole functions** (K+1 copies for K lifted mutants), so
  code size / single-compile time grows with mutation density on overloaded
  functions — the accepted cost (first-order ⇒ no copy sharing).

### No timeouts `[M4]`
A mutation can turn a terminating loop infinite; a mutant run would hang. Per-
mutant wall-clock cap (`baseline × multiplier`, timeout = killed) is M4.
`System.cmd/3` has no timeout, so this needs a Port/Task with kill.

### Whole-suite, single worker `[M3b / M4]`
No-coverage skipping is done (M3a). Still pending: coverage-driven *test
selection* — running only the tests that touch a mutant's line, rather than the
whole suite (M3b, needs per-test coverage) — and parallel workers (M4). Covered
mutants still each run the entire suite serially.

### Equivalent mutants `[partial]`
Per DESIGN's "don't emit obviously-equivalent mutations" mitigation, the
arithmetic mutator skips the multiplicative-identity swap on a right operand
(`a * 1`, `a / 1`) — only the right operand, since `1 * a → 1 / a` is a
reciprocal. `div`/`rem` are never identities (`rem(a, 1)` is `0`).

We deliberately do **not** skip `a + 0` / `a - 0`: adding/subtracting a literal
zero is genuinely observable when normalizing `-0.0` (`x + 0.0` clears the sign,
`x - 0.0` keeps it), so that mutant is a real check on whether such code is
tested. (`a * 1` vs `a / 1` is also not strictly equivalent — `/` yields a float
— but that int→float difference is `==`-invisible and rarely intentional, so we
treat it as noise.) See `Mutare.Mutators.Arithmetic`.

Still open: the demo's `percent: 0` survivors are equivalent only *under that
test data* (not statically), and there's no `# mutare:ignore` annotation or
suspected-equivalent reporting yet.

### Self-hosting: tests that touch `:mutare_active` `[dogfood artifact]`
Mutation-testing Mutare *with Mutare* has a trap: Mutare's own `selector_test`
and `integration_test` call `Selector.put/1` on `:mutare_active` — the very key
the runner uses to hold the active mutant. Since `:persistent_term` is global and
the whole suite shares one BEAM, those tests reset the active mutant to baseline
mid-run, so any mutant whose only killing test runs *after* them registers a
**false survivor** (confirmed: `runner.ex` mutants survive in the full suite but
die when `runner_test` runs alone). Normal targets never touch this key, so it's
a self-hosting artifact only. If we want clean self-dogfooding later: run those
selector-touching tests in a separate pass, or make the key configurable so the
suite-under-test and the harness don't collide.

### Surface skipped files more loudly `[soon]`
`Schema`/`safe_transform` skips a file that fails to transform (good — one bad
file shouldn't sink the run) and the task prints `skipped <file>: <reason>` in
its banner. But that's easy to miss, and it's exactly how the two
compile-poisoning bugs below hid. Consider a `--strict` mode that fails on any
skip, and/or making poisoning structural exclusions (below) the norm.

## Dogfooding findings (M1)

Running `mix mutare` on Mutare's own `lib` (24 mutants, 14 killed) surfaced:

- **Compile-poisoning #1 (fixed):** a `case`-valued map/keyword field
  (`%{ms: div(x, 1000)}`) crashed Sourceror's formatter → file silently skipped.
  Fixed by block-wrapping the selector + generalising keyword-key normalization.
- **Compile-poisoning #2 (fixed):** the `/` in a `&fun/arity` capture is an
  arity separator, not division; mutating it produced an invalid `&(case …)`.
  Fixed by excluding capture-arity `/` (and guard operators) from in-place sites.
  There may be more poisoning shapes lurking — the design's "compile each
  candidate in isolation and drop poisoners" safety net (M4) would catch unknowns
  structurally instead of us enumerating them.
- **Real test gap (fixed):** `Report.summary/1`'s no-coverage branch was
  untested (`no_coverage > 0` survived). Test added.
- **Real test gap (fixed):** the `mix mutare` score gate (`score < min_score`)
  had no tests. Resolved by extracting the decision into the pure
  `Report.passes_gate?/2` (unit-tested at the boundary) and the option handling
  into `Mutare.Config` (unit-tested); the task is now a thin shell with a fast
  failure-path test plus one slow end-to-end test. The cosmetic banner mutant
  (`root == "."`) is left as an accepted low-value survivor.
- **Near-equivalent mutant (now skipped):** `number / 1` → `number * 1` in the
  task's `fmt/1`. This looked equivalent but isn't quite — `/` always yields a
  float, so `number * 1` on an integer would crash `:erlang.float_to_binary`;
  it survived in the dogfood only for lack of coverage. The arithmetic mutator
  now skips multiplicative-identity right-operands (`* 1`, `/ 1`), so this site
  produces no mutant at all (see below).

## Decisions log

- **Two renderers.** The metamutant is produced by AST rewrite + `Sourceror.to_string`
  (a throwaway compile artifact — only needs to be valid). The diff report uses
  `Sourceror.patch_string` against the original source (clean one-line diffs).
  Each side uses the right tool; AST substitution also preserves tail position
  (LCO) for free.
- **Nesting via catch-all placement.** The `_` branch holds the transformed
  children so inner selectors stay reachable when an outer mutant is inactive;
  mutant branches reuse original operands (sound — exactly one mutant is ever
  active).
- **ids are per-mutation, global.** A single source site (one `>=`) can yield
  several mutants, each its own id; ids are threaded across files by `Schema`.
- **Dependency-free bootstrap.** The sandbox injects a plain
  `:persistent_term.put` snippet into `test_helper.exs`, so targets need nothing
  added to their deps.
