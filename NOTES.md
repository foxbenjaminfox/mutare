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

### Timeouts — portable self-halt (M4 done) `[refine]`
A mutation can turn a terminating loop infinite. Each mutant run gets a
wall-clock cap (`baseline × :timeout_multiplier`, default 3.0, floored; or an
explicit `:timeout` ms), and a timeout counts as a kill (`:timeout`).

The cap is enforced **portably, with no process-killing**: the injected sandbox
watcher (`Mutare.Sandbox`) spawns a process that `System.halt(124)`s after the
deadline. The BEAM preempts a looping process, so the watcher always runs (even
on a tight infinite loop — confirmed); if the suite finishes first the watcher
dies with the VM; exit 124 ⇒ timed out. This replaced an earlier Port + `kill`/
`ps` process-group approach (Unix-only, and `Port.close` alone did *not* kill a
hung beam — SIGTERM is trapped). Caveat: a hang that wedges *every* scheduler in
a non-yielding NIF could starve the watcher — not reachable from mutating Elixir
source, so not handled.

False-timeout guard: the cap floor is 10 s. The baseline is measured uncontended
but mutants run under parallel-worker contention, so a tight cap was
false-timing-out slow-but-finite mutants (a non-deterministic false kill, seen in
testing). A true infinite loop overruns any floor, so the generous floor keeps
correctness without missing real hangs. Per-covering-file caps would be tighter
and more precise — a refinement.

### Parallel workers (M4 done) `[refine]`
The per-mutant phase runs `:workers` mutants concurrently (default
`System.schedulers_online/0`) via `Task.async_stream` in the shared sandbox.
Concurrent `mix test` in one sandbox contends on mix's build lock ("Waiting for
lock…") and, since each spawns a full BEAM, oversubscribes CPU — a real but
bounded overhead (4 workers gave ~2.4× in a spike). The design's open question —
per-worker `MIX_BUILD_PATH` vs full source copy — would remove the contention;
deferred. Default workers may be worth lowering from schedulers_online to cut
oversubscription.

### Test selection — file-granular (M3b done) `[refine / M4]`
Coverage-driven *test selection* is done at **test-file** granularity: each test
file runs once with `--cover`, and a mutant runs only the files that cover its
line (`:no_coverage` if none). `test_selection: :full` (or `--full`) reverts to
whole-suite-per-mutant.

Why file-granular, not per-individual-test: per-test coverage needs to snapshot
`:cover` around each test, but **ExUnit formatter events are async casts** — a
formatter's `:cover.reset/analyse` races with test execution (confirmed: the
first test saw every line, the second saw none). The only synchronous per-test
hooks are `setup`/`on_exit`, which can't be injected globally. Per-file avoids
this (aggregate cover per file, no race) and is also *safer* for the indirect-
kill case: if any test in a file covers the line, the whole file runs, so a test
that kills the mutant without touching the line itself is still included as long
as a sibling does. True per-test would need N per-test `mix` runs (one boot each)
— deferred.

Caveat: `:coverage` runs each test file *in isolation* for the probe, so a suite
with cross-file dependencies (a test relying on state another file set up) can
fail the baseline; use `:full` there.

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

`# mutare:ignore` (done) is the manual escape hatch: a trailing comment ignores
its line, a standalone comment the next line; matching mutants are recorded
`:ignored` — not run, kept out of the score's denominator (`killed / (total −
no_coverage − ignored)`), surfaced in the summary. Line-based and text-scanned
(a literal `"# mutare:ignore"` string would also match — rare). It still
*generates* the (unused) selector for an ignored mutant, so it does **not**
rescue a compile-poisoning mutant — that's the compile-poisoning pre-filter's
job, not ignore's. Suspected-equivalent auto-reporting is still future work.

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
- **Custom mutators (done).** `Mutare.Mutator` is the public extension point:
  `mutate/1` + `name/0`. `:mutators` in `.mutare.exs` accepts built-in family
  atoms *and* any module implementing the behaviour (validated, with a helpful
  error otherwise). Dropped the old `kind/0` callback — it was vestigial and
  misleading: placement (in-place selector vs lifting into a guard) is decided
  by the node's *position*, not declared by the mutator. Limit: `mutate/1` does
  node-level mutations; structural mutations (clause-drop) remain built-in only,
  not expressible by a custom mutator. CLI `--mutators` CSV is for built-in
  families (short names); custom modules go in `.mutare.exs`.
