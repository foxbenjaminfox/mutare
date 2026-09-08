# Metamutant compilation

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

The full matrix has 120 projects, including large arithmetic metamutants. To work
on a subset, pass one or more **name prefixes** after the output directory:

```sh
mix run bench/compile_shapes.exs /tmp/mutare-clauses fn receive rescue_
mix run bench/compile_shapes.exs /tmp/mutare-ignore ignored
mix run bench/compile_shapes.exs /tmp/mutare-bodies head_body-default-8x guard_body
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
| `fn-*`, `fn_default-*` | 10 / 20 / 40 clauses | Whole-function duplication; two arguments, guards, captured outer binding |
| `receive-*`, `receive_default-*` | 10 / 20 / 40 clauses | Whole-receive duplication; unmatched messages, mailbox order, zero timeout |
| `head_body-{isolated,default}-NxB` | 2 / 4 / 8 head literals × 10 / 40 / 160 body statements | Raw-body duplication from pattern mutations; isolated set is IntegerLiteral |
| `guard_body-{isolated,default}-NxB` | Same grid, guard comparisons × body statements | Raw-body duplication from guard mutations; isolated set is Relational |
| `rescue_types-{isolated,default}-NxB` | Same grid, exception types × body statements | Type-list narrowing copies an unchanged `try` body |
| `rescue_clauses-{isolated,default}-NxB` | Same grid, rescue clauses × body statements | Clause removal copies an unchanged `try` body |
| `ignored-{arithmetic,default}-{0,50,100}` | Percentage of 1,000 functions ignored | Measure emission suppression against the same executable source |
| `ignored-file`, `ignored-variant` | Whole-file / `arithmetic:-` directives | Completely suppressed files and selective variant suppression, with defaults |
| `focused-{all,10,1}` | Selected mutant cap | Same 100-function source with different emission selections |
| `retained-{arithmetic,default}-{before,after}` | One extra addition in file A; identical file B | Detect cross-file ID changes and unnecessary recompilation of B |

Body grids vary the two dimensions independently; don't compare only their diagonal.
Their bodies use sequential `x = x + 2` assignments, avoiding a simultaneous increase
in expression nesting. Rescue fixtures exercise both success and handled failure,
and include an `after` block. The smoke checks are useful controls for future
rewrites, not substitutes for the transform's semantic regression suite.

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

**Measurements live in [NOTES.md](../NOTES.md), not here.** Record dated results and
the decisions they inform there; keep raw output local rather than checking in a
second table that becomes stale when generation changes.
