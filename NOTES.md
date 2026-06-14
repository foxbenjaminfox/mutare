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

### Equivalent mutants `[later]`
The demo's `percent: 0` survivors are equivalent *under that test data*. No
`# mutare:ignore` annotation or suspected-equivalent reporting yet (DESIGN lists
the mitigations).

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
