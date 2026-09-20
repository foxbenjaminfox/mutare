# Metamutant compilation

## Coverage cache

`coverage_cache.exs` compares the current dependency-free helper with a saved reference
source, using identical compiler options in one VM:

```sh
git show 937cb7f1:lib/mutare/coverage/helper_template.ex > /tmp/mutare-reference-helper.ex
elixir --erl '+S 2:2' bench/coverage_cache.exs /tmp/mutare-reference-helper.ex labeled
elixir --erl '+S 2:2' bench/coverage_cache.exs /tmp/mutare-reference-helper.ex unlabeled
```

It generates callers with literal ID payloads, warms their caches, and measures seven
alternating samples in fresh workers. The matrix varies IDs per hit and co-recording
groups in one namespace; output reports median time, reductions per hit, and minor GCs
from that sample. `unlabeled` includes memoized attribution recovery. These measurements
cover repeated probe hits; they exclude full-suite startup and ordinary mutant runs,
which do not call the helper. Exact-list comparisons may cost more for callers
that allocate new ID lists dynamically than for these generated literal payloads.

A third argument, `cold`, measures the other path: each fresh worker hits 2,048 distinct
groups once, unwarmed, so every hit records its ids.

```sh
elixir --erl '+S 2:2' bench/coverage_cache.exs /tmp/mutare-reference-helper.ex labeled cold
```

A cold hit costs microseconds rather than the warm path's ~130 ns, most of it in the
process-dictionary and map updates, so expect differences between helpers of a few
percent to sit inside the noise; read the reductions column beside the times.

## Compile fixtures

`compile_shapes.exs` generates dependency-free Mix projects. Generate each
revision's fixtures first, then time compilation in fresh processes with the same
Elixir/OTP, scheduler count, and compiler options:

```sh
mix run bench/compile_shapes.exs /tmp/mutare-shapes
cd /tmp/mutare-shapes/case-100
MIX_ENV=test ERL_COMPILER_OPTIONS='[no_ssa_opt_alias,time]' \
  /usr/bin/time -v mix compile --force --no-verification --profile time
MIX_ENV=test mix run --no-compile smoke.exs
```

The compile command assumes no inherited Erlang compiler options. When there are
other options, merge `time` and `no_ssa_opt_alias` into them. `--no-verification`
requires Elixir 1.19 or later. All generated projects disable signature inference
explicitly, including on Mix 1.20. The smoke command runs separately from the timed
compile and checks baseline behavior; it does not validate every mutant or coverage
attribution. These are standalone compiler fixtures, without the sandbox bootstrap.

The full matrix has 174 projects, including large arithmetic metamutants. To work
on a subset, pass one or more **name prefixes** after the output directory:

```sh
mix run bench/compile_shapes.exs /tmp/mutare-clauses fn receive rescue_
mix run bench/compile_shapes.exs /tmp/mutare-ignore ignored
mix run bench/compile_shapes.exs /tmp/mutare-bodies head_body-default-8x guard_body
mix run bench/compile_shapes.exs /tmp/mutare-rescue \
  head_body-isolated-8x guard_body-isolated-8x \
  rescue_types-isolated-8x rescue_clauses-isolated-8x
```

Prefixes are literal and combined with OR; `fn` selects both `fn-` and
`fn_default-`. Each invocation replaces the tables with the selected fixtures.
Use separate output directories for different selections and revisions: existing
project directories and builds are retained. Regeneration writes files only when
their bytes change, so it can also test a no-change rebuild.

## Fixture matrix

Restricted mutator sets isolate a delivery mechanism. Their default counterparts
use `Mutare.Mutators.all()` so nested body selectors and interacting families are
included in the decision. `projects.tsv` records the configured set for every project.

| Names | Varying dimension | Purpose |
| --- | --- | --- |
| `case-*`, `case_default-*` | 25 / 50 / 100 clauses | Tupled-case delivery and coverage payload |
| `guards-*`, `guards_default-*` | 8 / 16 / 32 comparisons | Guard duplication and exclusions, including alternative guards |
| `arithmetic-*`, `arithmetic_default-*` | 40 / 80 / 160 additions | Literal RHS expression depth, Arithmetic-only versus defaults |
| `arithmetic_variables-*` | Same depths, variable RHS | Operand-sharing counterexample, with defaults |
| `fn-*`, `fn_default-*` | 10 / 20 / 40 clauses | Per-clause function delivery; two arguments, guards, captured outer binding |
| `receive-*`, `receive_default-*` | 10 / 20 / 40 clauses | Per-clause receive delivery; unmatched messages, mailbox order, zero timeout |
| `head_body-{isolated,default}-NxB` | 2 / 4 / 8 head literals × 10 / 40 / 160 body statements | Raw-body duplication from pattern mutations; isolated set is IntegerLiteral |
| `guard_body-{isolated,default}-NxB` | Same grid, guard comparisons × body statements | Raw-body duplication from guard mutations; isolated set is Relational |
| `case_body-*`, `fn_body-*`, `receive_body-*` (`-{isolated,default}-NxB`) | The `guard_body` grid inside a `case`, `fn`, or `receive` clause | Raw-body duplication from guard mutations in the arrow-clause constructs; isolated set is Relational |
| `rescue_types-{isolated,default}-NxB` | Same grid, exception types × body statements | Compare whole-`try` duplication with shared protected bodies for type-list narrowing; isolated set is RescueType |
| `rescue_clauses-{isolated,default}-NxB` | Same grid, rescue clauses × body statements | Same comparison for rescue-clause removal; isolated set is RescueType |
| `ignored-{arithmetic,default}-{0,50,100}` | Percentage of 1,000 functions ignored | Measure emission suppression against the same executable source |
| `ignored-file`, `ignored-variant` | Whole-file / `arithmetic:-` directives | Completely suppressed files and selective variant suppression, with defaults |
| `focused-{all,10,1}` | Selected mutant cap | Same 100-function source with different emission selections |
| `retained-{arithmetic,default}-{before,after}` | One extra addition in file A; identical file B | Detect cross-file ID changes and unnecessary recompilation of B |

Body grids vary the two dimensions independently; don't compare only their diagonal.
Their bodies use sequential `x = x + 2` assignments, avoiding a simultaneous increase
in expression nesting. Rescue smoke checks exercise success, every listed exception
type, and an unhandled exception. Ordered messages from `do`, the rescue handler,
and `after` check that the body executes once and cleanup executes exactly once,
after handling or before propagation reaches the caller. These are baseline controls;
a factoring change also needs mutant-level checks of exception handling and `after`
semantics. The investigation and its remaining obligations live in NOTES.md,
"Try/rescue: whole-construct duplication".

The rescue grids use the same bound exception variable in every clause and have no
`catch`, so they exercise the factoring path. Other rescue shapes retain whole-`try`
delivery; the semantic tests cover those fallbacks. Factoring adds small handler-only
tries while sharing the large protected body: total `try` count alone cannot measure
this improvement. Compare source/AST growth as body size increases.

## Reading the output

Each project contains generated `lib/*.ex`, its exact input under `originals/lib/`,
and `smoke.exs`. Only `lib/` compiles. The root contains:

- `sizes.tsv`: aggregate source/generated UTF-8 bytes, AST nodes, definition clauses,
  cases, anonymous functions, receives, tries, and arrow clauses, plus site and ignored counts.
  The original six columns remain first.
- `files.tsv`: the same per-file metrics, with SHA-256 hashes of original and generated
  source. In the retained pair, B's original hash must stay equal; its generated hash
  reveals whether an unrelated edit still rewrites it.
- `projects.tsv`: generated project names and their mutator sets; also a list for batch
  compilation without accidentally including stale directories from an earlier run.
- `environment.exs`: the generator's Elixir, OTP, ERTS, and scheduler versions/settings.
  Record the compiler's environment and Git revision alongside timing results too.

`sites` counts reported sites, including ignored ones; focused fixtures report only
the selected slice. It is **not** a count of emitted mutants. Constructs are counted
with `Macro.prewalk/3` before expansion: `definitions` counts `def`/`defp`/macro
clauses, and `clauses` counts all `->` nodes, including generated selectors. These
metrics expose duplication, but don't measure the compiler's post-expansion work.

Compilation timings exclude discovery/rendering and include Mix VM boot. Keep the
compiler profile to separate boot, frontend, and backend work. Use repeated
alternating runs of the same fixture across revisions, with no other benchmarks or
tests running concurrently. Record wall time, CPU time, and peak RSS; peak RSS is
per process, not the sum of all compiler workers. Final BEAM size cannot measure
work eliminated by late passes. Raw results under `bench/results/` are ignored.

## Retained-build comparisons

`overlay.exs` copies a generated variant into a dedicated working project, writing
only changed bytes and preserving its `_build`. It prints which files changed and
refuses a destination containing extra `.ex` sources. It does not copy the variant's
build, originals, or timestamps. Run it **outside** the timed compile:

```sh
# From this repository; use a fresh working directory for each experiment.
elixir bench/overlay.exs /tmp/mutare-shapes/retained-default-before /tmp/mutare-retained
(cd /tmp/mutare-retained && MIX_ENV=test ERL_COMPILER_OPTIONS='[no_ssa_opt_alias,time]' \
  /usr/bin/time -v mix compile --no-verification --profile time --verbose)

# No-change control: should preserve every source mtime and recompile no source.
elixir bench/overlay.exs /tmp/mutare-shapes/retained-default-before /tmp/mutare-retained
(cd /tmp/mutare-retained && MIX_ENV=test ERL_COMPILER_OPTIONS='[no_ssa_opt_alias,time]' \
  /usr/bin/time -v mix compile --no-verification --profile time --verbose)

# A changed; inspect whether B is rewritten and appears in verbose compile output.
elixir bench/overlay.exs /tmp/mutare-shapes/retained-default-after /tmp/mutare-retained
(cd /tmp/mutare-retained && MIX_ENV=test ERL_COMPILER_OPTIONS='[no_ssa_opt_alias,time]' \
  /usr/bin/time -v mix compile --no-verification --profile time --verbose)
```

Omit `--force` throughout this experiment. Apply the same procedure to
`focused-all` → `focused-10` → `focused-1` in a separate working directory to measure
selection changes. Compare both transition directions, repeat the no-change control,
and keep the file hashes as well as the timings. These isolate Mix reuse of generated
sources; they don't measure sandbox copying, dependency seeding, or `--since` discovery.

For Elixir 1.20's separate module-definition experiment, add
`module_definition: :interpreted` beside `infer_signatures: false` in a working
project. Restore `:compiled` for the comparison. This changes module-definition
execution during compilation, not the resulting application's execution model.
It is intentionally not enabled by Mutare.

## Runtime and alias-analysis comparisons

`alias_analysis.exs` freezes generated source, then compiles the identical bytes
with SSA alias analysis enabled and disabled, leaving signature inference and
verification disabled in both builds. It also compiles an original-source control.
It needs no additional dependencies. Run with a quiet machine and a fixed scheduler
count; the final argument defaults to five alternating rounds:

```sh
ERL_FLAGS='+S 2:2' mix run bench/alias_analysis.exs /tmp/mutare-alias 5
```

The optional `clean` experiment compares original source, the metamutant with
clean function copies disabled, and the metamutant with them enabled, holding
alias analysis **disabled** throughout:

```sh
ERL_FLAGS='+S 2:2' mix run bench/alias_analysis.exs /tmp/mutare-clean 5 clean
```

A fourth argument sets the clean experiment's site threshold (`clean 1` gives every
eligible region a clean implementation, including the single-site leaves). `clean_alias`
crosses the two: original and clean builds, each with alias analysis on and off, since a
clean binary loop is source code again and that is where `private_append` applies.

```sh
ERL_FLAGS='+S 2:2' mix run bench/alias_analysis.exs /tmp/mutare-clean-alias 5 clean_alias
```

Both experiments exercise tuple updates, binary appending, many body selectors,
recursive clause dispatch, case dispatch, and pipelines with callbacks, and then what
the first clean-path contract refused: fresh and `case`-local bindings (`bindings`), a
recursive function no family lifts (`body_only`), a closure created once and invoked per
element (`callback`), and leaf functions of one to four selector sites called from an
ignored driver (`leaf1`…`leaf4`). The leaves locate the policy's crossover and expose
the fixed cost every instrumented activation pays whatever its body holds. The alias
experiment uses arithmetic/relational mutations; the clean experiment also uses
integer mutations so literal function heads require lifting. Clean emission must
retain exactly the same site metadata as ordinary emission; the script checks this.

Each build runs in a fresh VM, measuring baseline, probe, an active mutant elsewhere
in the same file, an active mutant in another file, and a safe body mutant inside
the measured recursive function. Before timing, the worker compares results with
separately compiled original and single-mutant source. Selected mutations preserve
termination. Each measured sample has a fresh process, a stable test attribution
label, and a warm code path. The probe uses the real generated coverage helper.

The output directory contains `compile.tsv` (whole Mix compile wall time, BEAM
bytes, and Code chunk bytes), `runtime.tsv` (kernel execution time, reductions,
minor-GC count, and VM-wide reclaimed words), `environment.exs` (runtime versions,
revision, source hashes, and inherited options), original/generated sources,
compiler logs, and disassembly. Reclaimed words measure garbage collection, not
total allocation, and can include incidental VM activity. Runtime excludes VM
startup; compile timing includes it. Microsecond-scale kernels and small timing
differences need more repetitions or larger inputs. This is a kernel benchmark,
not an end-to-end suite benchmark.

The experiment preserves inherited Erlang compiler options and refuses inherited
`no_ssa_opt`/`no_ssa_opt_alias`, since they would invalidate the on/off comparison.
Run on each relevant OTP version: OTP 26 can expose `private_append`, while
destructive tuple updates require OTP 27 or later. Source appearance alone cannot
establish whether either optimization survived compilation; inspect the saved BEAM.

**Measurements live in [NOTES.md](../NOTES.md), not here.** Record dated results and
the decisions they inform there; keep raw output local rather than checking in a
second table that becomes stale when generation changes.

## Comparing revisions

`alias_analysis.exs` runs each build in its own OS process for about a minute. That is
sound for builds compared within one invocation on a quiet machine, and unsound for
comparing two revisions' outputs on a shared one: background load drifts by more than the
effect, and it has shown two builds with byte-identical code 30–70% apart. `kernel_ab.exs`
takes the projects `alias_analysis.exs` wrote — by this revision or another — loads them
into **one VM**, each under its own module name and selection key, and alternates them
sample by sample:

```sh
# The reference revision, in a worktree; it needs this revision's kernels to compare like
# with like, so copy the script over before generating.
git worktree add --detach /tmp/mutare-ref <revision>
cp bench/alias_analysis.exs /tmp/mutare-ref/bench/
(cd /tmp/mutare-ref && ln -s "$OLDPWD/deps" deps &&
  MIX_BUILD_PATH=/tmp/mutare-ref-build mix run bench/alias_analysis.exs /tmp/ref-out 1 clean)

mix run bench/alias_analysis.exs /tmp/new-out 1 clean
ERL_FLAGS='+S 2:2' elixir bench/kernel_ab.exs /tmp/mutare-ab 15 \
  original=/tmp/new-out/original previous=/tmp/ref-out/clean new=/tmp/new-out/clean
```

The last build named is the one under test; ratio columns divide its minimum by each
earlier build's. It reads each project's mutant ids and iteration counts from its
`worker.exs`, and whether that revision stored file namespaces as strings or atoms from
its generated code. States are baseline, a mutant elsewhere in the file, in another file,
and inside the kernel; the probe is left to `alias_analysis.exs`.
Every state but the last checks that all builds compute the same result before timing.
Rows whose builds hold identical code show the noise floor of the session: read every
other ratio against it.

## Inspecting dispatch instructions

`dispatch_shapes.exs` compares current ID-equality guards with literal-ID patterns
in lifted function heads and tupled case clauses, preserving clause order. It also
compiles three instrumented pipeline stages for inspection of their immediately
invoked closures:

```sh
mix run bench/dispatch_shapes.exs /tmp/mutare-dispatch
```

Each fixture writes its original source, both generated sources, both BEAM files,
disassemblies, and a summary of instruction counts and BEAM sizes. The root records
the compiler environment, including inherited `ERL_COMPILER_OPTIONS`. Signature
inference is disabled where supported; clean function copies are disabled to isolate
the dispatch comparison. Equality of instruction lists ignores line markers.

This is a compiler-output experiment, not a runtime benchmark or semantic validation
of a new emitter. Check whether `make_fun`, `call_fun`, or `put_tuple` instructions
actually remain before optimizing presumed closure or tuple allocations. A smaller
BEAM or a different comparison instruction alone does not establish faster execution.
