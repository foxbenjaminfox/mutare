# Implementation notes & deferred work

A running log of decisions made and limitations discovered while building Mutare.
`DESIGN.md` is the vision; this file tracks reality and what's intentionally left
for later. Items are tagged with the milestone that should resolve them.

## Deferred / known limitations

### Metamutant line preservation `[M3]`
In-place selectors wrap a site in a multi-line `case`, so line numbers **shift**
in the metamutant build artifact. This is fine today: M1 runs the whole suite
(no line mapping needed) and the diff **report patches the original source**, not
the metamutant — so author-facing output and stack traces against the original
are unaffected. But the **coverage probe (M3)** intersects metamutant site lines
with a `:cover` run, which needs metamutant-line ↔ original-line correspondence.
Options to revisit then: emit single-line wrappers, or stamp the original `line:`
metadata onto every injected node. Decide when building M3.

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
whose value is a multi-line `case`). `Mutare.Transform.normalize_do_blocks/1`
flips every do-family keyword block to block form before rendering. Metamutant
only; the report is unaffected. Keep an eye on Sourceror releases in case this
becomes unnecessary.

### Non-body operator positions `[M2 for guards/clauses]`
- **Guards:** in-place mutators now skip operators inside `when` (fixed — a
  `case` in a guard is a compile error and would poison the whole build).
  Mutating guards properly is the **lifted** mechanism in M2.
- **Module-attribute expressions** (`@x 1 + 2`): currently wrapped. They compile
  (persistent_term reads the default at compile time → original) but the mutant
  is frozen at compile time and can never activate — an inert/equivalent mutant.
  Harmless but wasteful; could be excluded like guards.
- **Default arg values** (`def f(a \\ b + 1)`): currently mutated; compiles and
  is evaluated at call time, so it's a live mutant. Design says normalize
  defaults away before lifting — relevant in M2.

### No timeouts `[M4]`
A mutation can turn a terminating loop infinite; a mutant run would hang. Per-
mutant wall-clock cap (`baseline × multiplier`, timeout = killed) is M4.
`System.cmd/3` has no timeout, so this needs a Port/Task with kill.

### Whole-suite, single worker `[M3 / M4]`
Every mutant runs the entire suite serially. Coverage-driven test selection and
no-coverage skipping are M3; parallel workers are M4.

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
