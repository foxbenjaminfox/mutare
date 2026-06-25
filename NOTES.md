# Implementation notes & deferred work

A running log of decisions made and limitations discovered while building Mutare.
`DESIGN.md` is the vision; this file tracks reality and what's intentionally left
for later. Items are tagged with the milestone that should resolve them.

## Deferred / known limitations

### Metamutant line preservation — RESOLVED (avoided) `[M3, done]`
In-place selectors and lifted copies shift line numbers in the metamutant, so we
worried coverage would need a metamutant↔original line map. It doesn't — coverage
keys by **mutant id** (the metamutant self-records ids, see *Test selection* below),
not by line at all. Poison still works in metamutant line space (a compile error's
line → the mutant id whose generated code spans it, via `Mutare.Manifest`), and the
original line is only ever used by the report. So no line space ever needs relating
to another. (Originally coverage *did* key on a line — the selector's catch-all body
line intersected with `:cover` hits — which carried two `:cover` gotchas, an OTP-
specific `analyse` shape and cover not counting a nested selector's `case` line;
self-recording by id retired both along with `:cover`.)

### Per-mutant metamutant manifest `[done]`
`Mutare.Manifest` is the per-file, per-mutant readback of *where each mutant lives
in its rendered metamutant*. **`Poison`** builds one **lazily** (`from_source/1`),
on a failed compile, only for the file(s) the error names — passing
`schema.metamutants` (the rendered sources) to `Poison.ids/2`, which memoizes the
manifest within one recovery so a file faulting on several lines is parsed once. It
carries the **generated line ranges** of each mutant's code. (It used to also carry a
coverage location, but coverage now self-records by id — see *Test selection* — so
the manifest is Poison-only.)

It used to be built **eagerly by `Schema`**, once per mutated file during the scan,
and stored under `:manifests`. That was the scan's dominant cost and pure waste on
the happy path: a manifest is read *only* on a compile failure (rare — built-in
mutators are compile-safe), yet `Manifest.from_source/1` re-parses the whole rendered
metamutant with `Sourceror.parse_string!`, which is **super-linear** in file size.
The metamutant is ~25× the source (every mutant embeds an original+mutant selector
branch), so a 1500-line file becomes a ~40k-line metamutant whose re-parse alone took
**minutes** — building all of them up front added several minutes to every run and
threw them away. Deferring to the poison path removed that from healthy runs. (The
scan is still transform/render-bound; see *Scan is transform-bound* below.)

The ranges fixed a real poison-recovery gap. The old mapping matched a compile
error's line only against a selector clause body's *start* line, so it missed every
poison whose bad code isn't there:
- **lifted mutations** (a custom mutator poisoning a `when` guard produced
  `MapSet.new([])` → abort): the bad code lives in a generated private
  `defp __mutare_…_m<id>`, lines below the dispatcher clause that merely *calls* it;
- **multiline bodies**: an in-place mutant can fault on any line of its body;
- **structural errors**: the compiler sometimes points at the surrounding `case`.

So the manifest records the full ranges of each mutant's generated code — its
selector clause body, its lifted private copies, and the whole `case` attributed to
every id it hosts. `Manifest.ids_at_line/2` resolves an error line by **narrowest
containing range**: a specific clause/def wins, so a precise error drops exactly the
offending mutant; only a structural error that nothing narrower contains falls back
to the whole-`case` range (dropping every mutant it hosts — a bounded over-drop that
still recovers, never the old abort).

Implementation notes:
- Ranges only exist *after* rendering, so the manifest re-parses for
  `Sourceror.get_range/1`. The re-parse is `Code.string_to_quoted!` (with
  `:token_metadata` + `:columns`), **not** `Sourceror.parse_string!`. `get_range/1`
  reads only token metadata (`:line`/`:column`/`:closing`/`:end`/
  `:end_of_expression`), which the stdlib parser already emits; Sourceror's *extra*
  comment-merging pass is quadratic on a large metamutant and is precisely what the
  manifest doesn't need. On this repo's own `transform.ex` (a 1.8 MB lifted
  metamutant from a 25-clause `analyze/3`) the Sourceror re-parse alone took **~6.5
  min**, dwarfing the ~20 s transform and making `mix mutare` *on Mutare itself*
  look hung mid-scan; the stdlib parse is **~0.65 s** and yields **byte-identical
  regions** (verified across all 4437). A `:literal_encoder` reproduces Sourceror's
  `{:__block__, _, [literal]}` wrapping, so `Mutare.Metamutant.subject?/1` (made
  tolerant of that wrapping — one recognizer, both parsers) and the integer
  clause-pattern unwrapping keep working unchanged. (Sourceror remains the
  *renderer*; only this readback parse moved.)
  NB this only tamed cause #2 (the slow re-parse). Cause #1 — lifting duplicates
  the *whole* clause group per mutant, so `analyze/3`'s 25 clauses × ~100 lift
  candidates ≈ 2500 generated clause-defs → the 1.8 MB blowup and the ~20 s
  transform/render — is still open. See "lifting blowup" below.
- A lifted private copy is attributed to its id by name (`~r/\A__mutare_.*_m(\d+)\z/`);
  `…_orig` and user code never match, so they're left out.
- `Mutare.Metamutant` shrank to just the selector-subject AST contract
  (`subject_ast/0` + `subject?/1`); the metamutant *walk* now lives in `Mutare.Manifest`.

### Unknown block macros: poison the whole block, not one mutant at a time `[done]`
An **unknown module-level block macro** (`custom_dsl do … end`) has its `do` body
analyzed as **runtime** — the guess that a DSL `unquote`s it into a function body, so a
literal/operator there could be a real runtime value (`analyze_module_macro_block/2`).
The guess is right for the common "generate a function" DSL, but wrong for a DSL that
treats the body as *opaque compile-time AST* it pattern-matches or splices into an
illegal position (a guard, a pattern): the injected selector `case` is then rejected and
the **single build fails wholesale** — not for one mutation, but for *every* mutation in
the block (the selector is the problem, and every mutant adds one).

The existing per-id poison backstop would drop one implicated mutant, rebuild, hit the
*next* selector, and repeat — O(mutants-in-block) rounds, easily exhausting the 25-attempt
budget on a real DSL block, or stalling if a round's error doesn't map. So the runner
**escalates**: when a poison recurs inside an unknown block macro, it skips *every* mutant
in that block at once (`Mutare.Runner.escalate_block_poison/3`), the runtime equivalent of
"mark the macro `:skip`" — the body renders raw and compiles.

**Evidence-based, not eager** (the precision fix). A poison inside an unknown block has *two*
distinct causes that demand opposite responses: the DSL rejecting the injected selector
**wholesale** (every mutant in the block will fail — escalate), vs. *one* mutant's broken
*replacement* — classically a **custom mutator** emitting uncompilable code inside the block
(only that mutant should drop; its compile-safe-by-construction siblings should still run).
Eagerly escalating on the *first* poison conflates them: a single buggy custom mutant would
drag the innocent built-in arithmetic/literal siblings in its block to `:poisoned`, silently
shrinking the score's denominator. The build can't tell the modes apart — whether an unknown
DSL rejects a given selector is information that only exists at compile time — but they differ
in **recurrence under a single drop**: wholesale recurs (drop one selector → the next fails),
id-specific does not (drop the bad mutant → the rest compile). So escalation waits for the
**second strike**: the *first* poison in a block drops just the implicated id(s) and marks the
block *struck* (threaded through `prepare_compiling`'s `struck` set); only a *later, distinct*
poison in an already-struck block drops the whole block. A genuinely-wholesale block therefore
costs **one extra rebuild** (drop one, see it recur, escalate); an id-specific failure stops
over-skipping. The residual imprecision — two *independent* id-specific failures in one block
escalate it on the second — is accepted: distinguishing that from wholesale recurrence means
trying each id individually, the exact budget blow-up escalation exists to prevent.

Why escalate via `skip_ids` rather than literally re-running the transform with the macro
registered `:skip`: **id stability**. The whole poison loop relies on ids being stable
across rebuilds (the counter advances even for skipped ids), so an accumulated `skip_ids`
keeps referring to the same mutations. A true `:skip` would stop *analyzing* the body, so
its ids would never be claimed and every later id would shift — silently invalidating the
`skip_ids` from other files. Skipping the block's ids instead keeps the body analyzed (ids
still claimed and advanced), but emits every node raw (`emit_site/3`'s "all skipped → no
selector" path), yielding **byte-identical raw output** while ids stay put. The block's
mutants are recorded `:poisoned` (out of the score) — exactly right: the DSL can't compile
them, which is what `:poisoned` *means*, and more informative than a registry `:skip`
(which would make them vanish entirely).

Identity is **per-invocation** — `{file, {macro_name, nid}}`, tagged on each
`Site.block_macro` by the transform (`Transform.emit_block_macro/2` tags the sites its
block-body `emit` created — they are the head of the newest-first `ctx.sites`; the `nid`
is the block-macro statement node's). The bare name alone was wrong: a DSL that dispatches
on an argument — `guarded :guard do …` splicing into a guard (hostile) vs `guarded :body
do …` into a body (fine) — would bucket *both* invocations under `:guarded`, so a poison
in one would silently suppress the other's valid mutants. That is the same lossy-identity
trap `Overlap` rejected (see "node identity, not range"): a name collides distinct
invocations exactly as a Sourceror range collides distinct nodes. The statement node's
`nid` (the injective, rebuild-stable DFS counter) makes the tag per-invocation; the name
rides along for readability. The cost is a possible extra recovery *round* — if a DSL macro
`raise`s on the first hostile block (halting expansion), K same-name hostile blocks take K
rounds vs the name-bucket's 1 — but the compiler-error kind (the common case, splicing into
an illegal position) batches all errors per pass, K > 25 (the attempt budget) same-name
*raising* blocks in one file is pathological, and soundness (never silently dropping valid
mutants) outranks a round count. If it ever bit, the fallback is "broaden a tag to the bare
name after it poisons in ≥2 distinct invocations" — deferred (YAGNI).

Only an **unknown** macro is tagged (`Analyze.unknown_block_macro_name/1` returns `nil` for
a registered one): a user who registered the macro — even as `:expression` — chose how to
treat it, and is never auto-skipped. Scope/limit: this fires only when `Poison.ids/2` maps
the error to a block-macro mutant id; a DSL whose error lands on an unmappable line (the
macro call site, not the spliced selector) still aborts — the pre-existing poison-mapping
ceiling, not made worse here.

### Remediation hint for an unrecoverable macro-literal poison `[done]`
The one poison class recovery structurally *can't* isolate: a macro that requires a
**compile-time literal** argument (`Size.megabytes(5)`, a constant-folding DSL helper). Mutare
wraps the literal in a runtime selector `case`; the macro receives that `case` AST instead of a
literal and **raises while the compiler is expanding it**. The compiler reports the macro
**call site**, not the spliced selector inside it — and those are different lines (the call on
line N, the `case` opening on N+1) — so `Poison.ids/2` maps the error to `[]` and the whole run
aborts (the ceiling above). Dropping individual mutants can't help either: the macro gets the
`case` AST regardless of the *runtime* mutant, so it fails even at baseline; only removing the
selector entirely (i.e. not descending into the macro's args) fixes it, which is exactly what
registering the macro `:skip` does.

So rather than only re-derive the ideal (auto-recovery here is hard — you'd have to re-resolve
the macro call in metamutant line space to find the enclosing call's range), the abort now
**explains itself**. `Mutare.Poison.Hint` (pure, output-string → hint-string) scans the captured
compiler output for `expanding macro: Mod.fun/arity` stacktrace frames — the stable signature of
*any* exception raised during macro expansion (a `FunctionClauseError` from a literal-only
clause, a macro's own `raise`) — and renders a copy-pasteable `.mutare.exs` `:skip` snippet
naming each macro (`{Mod, :fun, :skip}`, the arity-agnostic 3-tuple). It takes only the
**innermost** frame of each stacktrace: a literal-only macro nested inside another
(`if Size.megabytes(5)`) raises a *stack* of frames, printed innermost-first
(`Size.megabytes/1`, then the enclosing `Kernel.if/2`) — only the inner macro's argument was
mutated, so the outer frames are expansion *context*, not the culprit. Skipping them keeps a broad
wrapper out of the advice (`{Kernel, :if, :skip}` would stop Mutare descending into *every* `if`,
hiding valid mutants). A fresh `** (Error)` header re-arms the per-stacktrace capture, so a
multi-file failure still yields one culprit per error. `Mix.Tasks.Mutare`'s
`:compile_failed` formatter leads with that hint, then the raw compiler error. The pattern lives
in `Hint`, not with `Sandbox.Command`'s exit-code patterns: it's read only for human remediation,
never to form a verdict. The `HintTest` unit-tests the parsing; a `:runner` poison test bridges
to the *real* compiler output (so a `expanding macro:` format drift is caught). Note `:skip` is
the only fix — `# mutare:ignore` is applied *after* rendering, so the selector is still spliced
and the compile still fails.

### Warn for ineffective `# mutare:ignore` directives `[done]`
`# mutare:ignore` filtering fails **safe** — a typo'd family (`[arithmatic]`), an empty
`[]`, a standalone directive on the wrong line, or a family that produced no mutant there
all simply match nothing, so the mutant still runs. Safe, but **silent**: the user thinks
they suppressed a mutant and didn't. `Mutare.Ignore.ineffective/2` closes that gap — it
returns every directive **no recorded site admits** (`Directive.applies_to?/2` false for
every occupied mutator on the directive's line). One rule covers all four failure modes;
there's no need to special-case typo vs. wrong-line vs. wrong-family.

It takes `{line, mutator}` pairs, not `Mutare.Site` structs, so `Ignore` stays unaware of
the site representation (same discipline as `directive_for/3` taking a bare `mutator` atom).
`Mutare.Schema.detect_ineffective_ignores/1` computes it per file into `ineffective_ignores`,
reusing the existing `Ignore.directives/1` re-parse — but only for files whose source
contains the literal `mutare:ignore` (a cheap `String.contains?` prefilter keeps every other
file off the parse path; a `sources` entry always parsed cleanly during transform, so the
re-parse can't raise). It runs **after `finalize/1` but before `restrict_lines`/`limit`**, so
detection sees the *full* mutation set — a `--line`/`--max-mutants` trim must not drop the
sites a directive matches and make it look ineffective.

The Mix task **warns** on each (one stderr line per directive, like `Mutare.Report.Live`'s
stderr discipline, so a stdout machine report stays clean), and `--strict-ignores`
(`:strict_ignores`) escalates them to a `Mix.raise` → non-zero exit — the CI gate counterpart,
modeled on the `--min-score` `gate/2` (both live in the task, not the runner). Nuance, left
documented rather than special-cased: detection is relative to the **active run**, so a family
disabled by `--mutators` yields no site and a directive naming only it is flagged. The simple
"admits no site" rule is predictable; distinguishing a *disabled* family from a *typo'd* one
would need the full valid-family universe and isn't worth the complexity (a CI strict run uses
the default set, where it can't arise).

### Scan is transform-bound, and the loop heap makes it worse `[deferred]`
After the manifest went lazy (above), the scan (`Schema.from_files` → `Transform`
per file) is dominated by `Sourceror.to_string` rendering each metamutant, and one
big file dominates the whole scan. Measured on this repo's own `lib/` (62 files,
~5.6k mutants): the scan is ~280 s, and `lib/mutare/transform.ex` (1500 lines →
39k-line metamutant) is essentially all of it.

The sharp surprise: that file transforms in **~30 s in isolation but ~220 s inside
the scan's `Enum.reduce`** — a ~7× penalty. The cause is the **accumulating loop
heap**: by the time the big file is reached, the process holds ~60 rendered
metamutant strings + ~5k `Site` structs live, and `Sourceror.to_string`'s heavy
allocation makes every GC scan that whole live set (superlinear in held state). So
the cost isn't intrinsic to the file — it's the company it keeps. (Independently
reproduced: ~24 s in isolation → ~167–180 s inside the accumulating reduce; the
sequential throwaway-process run below lands at ~24 s, matching the isolated sum.)

Measured ladder (same machine):
- eager manifest (old):            ~500 s+
- lazy manifest (done):            ~280 s
- sequential, transform each file in a **throwaway process** (accumulator stays in
  the parent, off the render's heap) — **`[done]`**: `safe_transform/5` runs the
  per-file `Transform.transform_string` inside a `Task.async`/`await`, so its
  transient ASTs die with the worker instead of inflating the loop heap. Exact
  `start_id` threading is preserved (each file is awaited before the next), and the
  `try/rescue` for unparseable sources moved *inside* the worker so a bad file still
  skips rather than crashing the scan. **Measured ~24 s** on this repo's `lib/`
  (down from ~180 s — the loop-heap penalty is gone; the scan now ≈ the isolated
  per-file sum).
- per-clause lifting — **`[done]`**: with the lifting blowup fixed (below) the big
  file's metamutant shrank ~4.6× (1.8 MB → ~0.4 MB), so its transform/render dropped
  from ~20 s to ~2.7 s and the **whole sequential scan to ~7.6 s** (~5.7k mutants).
- **parallel** across files (`Task.async_stream`, schedulers_online): **`[deferred,
  next]`**. With the loop heap gone *and* the metamutant shrunk, the sequential run
  is already ~7.6 s here (CPU-bound on one big file), so the win is mostly on
  many-core hosts / projects without one dominant file. The blocker is unchanged:
  mutant ids are baked into each metamutant's selector clauses, so concurrent files
  can't thread `next_id` sequentially. Needs the id assignment decoupled from the
  per-file render: either two-phase (id-free count/plan → prefix-sum id ranges →
  emit+render in parallel), or a count pre-pass then a parallel render pass with each
  file's `start_id` known up front. The plan/emit split already exists in the IR
  (`ModulePlan`/`FunctionPlan` are id-free; emission threads ids), so the decoupling
  is aligned with the design.

#### Why the metamutant was so big — lifting blowup on huge clause groups `[done]`
The loop heap above scans the *volume* of generated code, and one mechanism used to
dominate that volume. The old `emit_function_plan/1` emitted, **per lifted
candidate, a full copy of the *entire* clause group** (the old
`FunctionPlan.mutated_clauses/2` returned all clauses with one node changed, each a
`defp __mutare_…_m<id>`). Cost was `candidates × clauses` clause-defs, both factors
growing with clause count — ~quadratic for a big dispatcher. Mutare's own
`analyze/3` was the pathological case: 25 clauses × ~100 lift candidates (its heads
are wall-to-wall tuple destructuring → PatternSwap/PatternWildcard, plus guards and
clause-drops) ≈ 2475 generated clause-defs — ~85% of `transform.ex`'s metamutant,
which rendered to ~1.8 MB / 39k lines and took ~20 s to transform.

**Fixed by lifting per-clause.** A lifted candidate touches exactly one clause, so
emission now threads the active id as an extra arg (`mutare_active`) and emits each
source clause **once** (gated `when mutare_active !== <id>` for the mutants that
override/drop it) plus **one** gated clause per mutant (`when mutare_active === <id>
…`) — `C+M` clauses, not `C×M`. (`FunctionPlan.mutated_clause/2` returns the single
affected clause + index; `Transform.lifted_mutant/3`/`lifted_original/3` assemble
them; the dispatcher's coverage record moved out of the old `case` catch-all into the
dispatcher body.) `transform.ex`'s metamutant shrank to ~0.4 MB / 11k lines (~4.6×),
its transform/render to ~2.7 s, the whole scan to ~7.6 s. `Mutare.Manifest` maps a
lifted poison by the clause's `mutare_active === <id>` gate (no longer a `_m<id>`
name). Two sharp edges this surfaced (both fixed): a lifted clause must keep its
**source `meta`** (else Sourceror assigns stale lines to the `[]`-meta in-place
selector ids inside it and the formatter crashes), and every generated integer
literal must be clean-meta `{:__block__, [], [n]}` — a *bare* int gets a `:line` but
no `:token` from Sourceror's normalizer and crashes the formatter (`subject_ast/0`
and `record_ast/1`'s `0` were latently bare; now wrapped).

### Sandbox isolation & dependencies `[M4 / open question]`
`Mutare.Sandbox` copies the whole project (excluding `_build`/`.git`, keeping
`deps`) to a temp dir. Consequences:
- **Path deps don't resolve in the copy.** A target using `{:mutare, path: ...}`
  (or any local path dep) breaks in `/tmp`. That's why the examples are driven via
  `mix mutare examples/<name>` (positional root) rather than depending on Mutare.
  Hex deps are fine (they're under the copied `deps/`).
- We don't run `mix deps.get` in the sandbox; relies on the original having
  fetched deps already. Fine for the common case, revisit for robustness.
- The design's open question stands: full source copy vs per-worker
  `MIX_BUILD_PATH` against one shared schema build — measure on a large umbrella.

### Seed the deps' `_build` so "compile once" doesn't recompile deps `[done]`
`@excluded` keeps `_build` out of the project copy, so a *fresh* sandbox's one
`mix compile` rebuilt **every test-env dependency from scratch on every run** —
even though their sources are copied byte-for-byte from a project the user already
compiled (same `mix.lock`). Pure waste, and on a dep-heavy app (Phoenix/Ecto, or
anything pulling a `only: [:dev, :test]` linter like `credo`) it *dominates* the
compile-once step — exactly the cost the whole design exists to pay only once,
silently re-paid per run. Measured on Mutare's own deps: a cold sandbox compile is
~5.5 s, ~90 % of it dependencies (credo alone is 257 files); the app/metamutant
itself is ~1.7 s. (This is the `mix compile` of the metamutant — distinct from the
*scan*/transform-render cost tracked under "Scan is transform-bound".)

**Fix (`Sandbox.seed_dep_build/2`):** after materialising the copy, copy each
dependency's already-built dir (`_build/<env>/lib/<dep>`, i.e. `ebin` + its `.mix`
manifest) from the original into the sandbox. mix gates dependency staleness on the
**lock + manifest**, not per-source mtime — verified: the deps are *not* recompiled
even though `File.cp_r!` bumps their mtimes (the asymmetry with app sources, which
*do* recompile on an mtime bump, is why the `--keep-sandbox` notes warn about `cp`
but this seed is safe). End-to-end through the real `prepare/3`: 5.5 s → ~1.7 s, with
deps skipped and only the metamutant compiling.

Three load-bearing choices:
- **Deps only, never the mutated app(s).** We seed only the dirs named in the
  original's `deps/` (umbrella in-project apps live under `apps/`, never `deps/`, so
  this can't name a mutated app). Seeding an app's *own* original beam would risk it
  silently winning over the freshly-written metamutant — mutation testing as a no-op,
  the exact hazard `--keep-sandbox`'s `put_if_changed` guards. Leaving the app dir
  **absent** forces mix to compile the metamutant. (`mix compile` re-consolidates
  protocols after recompiling the app, so the seed needs no `consolidated` dir.)
- **Idempotent + best-effort.** Runs in both modes but only fills in deps the sandbox
  *lacks* (`not File.exists?(dst)`), so a `keep_sandbox` re-run's preserved `_build`
  is untouched — it seeds only the first kept run and every fresh run. A dep with no
  test-env artifact (`only: :dev` like `dialyxir`, or an original never compiled in
  test) is simply absent and skipped; a project with no `_build`/`deps` at all (fresh
  CI checkout) seeds nothing and falls back to a cold compile. Never an error.
- **`@mix_env` ("test") must track `Mutare.Sandbox.Command`,** which sets
  `MIX_ENV=test` on every sandbox `mix`; we seed `_build/test/lib`. We never seed
  across envs (a `dev` artifact is not valid under a test compile).

Not pursued (measured/considered, net-negative or low-value): disabling protocol
consolidation (one compile saved vs every one of N per-mutant runs paying slower
dispatch), and suppressing the mutant-induced compile warnings (`Mutare.Poison`
scans that output to map errors → ids). The remaining compile long-pole is a single
huge metamutant *module* compiling serially (Elixir parallelises across modules, not
within one) — not easily splittable; the volume drivers are already tamed by
per-clause lifting, `hoist_pipe` (see "lifting blowup"), and the hoisted per-site
active-id read (see "Hoist the per-site active-id read", now done).

### Compiler options for the one metamutant compile `[done]`
The metamutant compile is a single `mix compile`, dominated by `beam_ssa_opt` on
the biggest generated module (the long-pole above). Profiling that pass on Mutare's
own metamutant pinned the cost: `ssa_opt_alias` — the SSA alias-analysis sub-pass
(`beam_ssa_alias`, which proves term uniqueness to enable destructive in-place
updates) — is **~45% of `beam_ssa_opt`** on the tuple-heavy `transform.ex`
metamutant. The generated selectors and the tuple-the-scrutinee rewrites are
pathological for it: lots of artificial tuple data-flow to analyse, for an
optimisation whose runtime payoff (in-place binary/record updates in tight loops)
suite execution almost never collects.

**Fix:** `Mutare.Runner.compile/1` sets `ERL_COMPILER_OPTIONS=[no_ssa_opt_alias]`
for the one `mix compile` (`Mutare.Sandbox.Command.compiler_env/0` owns it, beside
the rest of the run-env contract). Measured, deps pre-seeded, Mutare-on-Mutare
(~9,100 sites):

  - whole-sandbox `mix compile`: **−15% on 2 schedulers** (a small CI box: 8.5 s →
    7.2 s), **−2% on 16 cores** (the alias-bound modules hide behind the type-bound
    long-pole `analyze.ex` once there are cores to spare, so the win shrinks as
    cores grow — but CI, where it matters, is core-starved).
  - **runtime: nil.** A 152-test pure-AST-rewriting workload run against the
    baseline metamutant compiled both ways was 2253 ms vs 2258 ms (+0.2%, noise) —
    the alias optimisation buys nothing for suite execution, so dropping it is free.

Two load-bearing properties:

  - **Safe on every OTP.** An unknown compiler option is silently ignored
    (verified), so `no_ssa_opt_alias` is a no-op before the pass existed
    (pre-OTP-25) and never breaks the single build.
  - **Merged, not clobbered.** `compiler_env/0` prepends our option to any inherited
    `ERL_COMPILER_OPTIONS` (`erl_compiler_options/1`, a pure, unit-tested merge that
    always emits a well-formed `[...]` term list — bare term, nested term, empty list
    all handled), so a user's own compiler options survive. Scoped to the `compile`
    call only: a per-mutant `mix test` doesn't recompile the lib (sources unchanged),
    so it carries nothing.

**Rejected for the same compile-vs-runtime reason as protocol consolidation:**
`no_ssa_opt` (all SSA optimisation off) is bigger on compile (−24% on 16 cores,
−40% on 2) but **+5.4% per mutant run** — paid N times, net-negative for any
non-trivial suite. Worth exposing only behind an explicit opt-in (a `--fast-compile`
mode) for compile-dominated runs, never as a default. `--no-debug-info` /
`--no-docs` move the needle ~0% and aren't worth losing `debug_info` for a target
that happens to want it.

### Hoist the per-site active-id read (`:persistent_term.get`) `[done]`
The long-pole above is volume-bound, and one untamed driver was the selector
*scrutinee*. Every in-place selector used to read the active mutant id with a fresh
`:persistent_term.get(:mutare_active, 0)` — `Transform.build_case` always spliced
`Mutare.Metamutant.subject_ast/0`, **once per site**. Measured on Mutare's own
metamutant: **~9,500 copies** across the tree (1,098 in `analyze.ex` alone, ~9,100
sites total), each a ~6-node remote call — tens of thousands of AST nodes that are
pure scaffolding. It was emitted even **inside a lifted function**, whose dispatcher
*already* binds `mutare_active = :persistent_term.get(...)` once and threads it as the
clause param (`ctx.active_var`) — so the read was re-done per selector when the value
was right there in scope.

The id is **process-constant** (`:persistent_term`, write-once, set once per run
before any test executes), so reading it once per function activation and having every
selector read that variable is semantically identical — a win on *both* axes (fewer
nodes for the frontend/SSA passes to chew, and the per-line lookups DESIGN.md flags as
the "per-site runtime tax" collapsed to one per function activation), with **no
tradeoff** (unlike the `no_ssa_opt*` options that buy compile time with per-run
runtime).

**Fix.** `Ctx.active_bound` records whether `mutare_active` is bound in the current emit
scope; `Transform.selector_subject/1` returns the bare variable `{var, [], nil}` when it
is, else `subject_ast/0`. It is `true` in two places, set by a head/body-split clause
emitter (`emit_clause/3`):

  - **lifted base clauses** — the dispatcher threads `mutare_active` as the first
    parameter, so it is in scope in the *whole* body (every block — `do`, and any
    `rescue`/`catch`/`else`/`after`, since a parameter is visible everywhere). The
    whole body emits with `active_bound: true`, no prologue.
  - **non-lifted functions** — the `:do` block is prefixed with a once-per-call prologue
    `mutare_active = :persistent_term.get(...)` (added only when the block actually splices
    a hoisted selector, else it would warn unused), and emits with `active_bound: true`.
    The other body blocks (`rescue`/`catch`/`else`/`after`) are siblings of `:do`, *not*
    inside its prologue's scope, so they keep `active_bound: false` (the self-contained
    read).

In **both** cases the **head's default values** keep the self-contained read
(`active_bound: false`): a `def f(x \\ <expr>)` default is evaluated in a generated head
clause (`f() → f(<expr>)`) where no body binding — neither the prologue nor the threaded
param — is in scope. Lifted defaults additionally *ride onto the dispatcher head*, the
same out-of-scope position. Module-level / `:scaffold` selectors (a metaprogrammed `def`
body, a DSL macro block) likewise keep the inline read — they have no function-emit hook,
and run once at compile time as baseline anyway. The split preserves id ordering (head
before body, block order kept), so Sites/coverage/poison-recovery ids are unchanged.

One more out-of-scope spot surfaced after the fact: a **runtime `defmodule` in a function
body** (`def build do defmodule Inner do def f, do: 1 + 2 end end`). Its inner `def` is a
*new* module scope — it can't see `build`'s hoisted binding — so a selector emitted there
must use the inline read, else `Inner.f` raises `undefined variable "mutare_active"` the
moment `build/0` runs and compiles the inner module (and `build`'s prologue, with nothing
in its own scope reading it, would be a dead binding). The inner code is walked *in place*
by the outer function's emit (it isn't separately planned/lifted), so `active_bound` would
otherwise leak straight through the `defmodule` boundary. Fix: `emit/2` is a
`Macro.traverse`, not a `postwalk` — it counts nested-module depth on the way down
(`Ctx.module_depth`, bumped on `defmodule`/`defimpl`/`defprotocol`), and `selector_subject/1`
gates the hoisted form on `module_depth == 0`; `references_var?/2` prunes the same subtrees
so the outer prologue is added only for a *direct*-body reference. A mixed body
(`a = x + 1; defmodule … ; a * 2`) hoists the direct sites and inlines the nested one, the
depth restoring to 0 after the `defmodule` so the trailing site re-hoists.

**The recognizers** were the load-bearing risk. `Mutare.Metamutant.subject?/2` and
`pattern_subject?/2` now recognise the hoisted bare-variable subject *in addition to*
the inline `:persistent_term.get` form — but only when the active-id variable name is
supplied (so a user's `case some_var do …` is never mistaken for a selector). The name is
per-file (and may be salted), and `Mutare.Manifest` already recovers it once per file:
`active_var/1` reads it off the first generated construct that binds it — a lifted
dispatcher's, or now a non-lifted `:do`-block prologue's, `<var> = :persistent_term.get`,
or a tupled-`case` clause's `{<var>, <pat>}` pattern — and threads it through **both** the
subject recognisers and the lifted/tupled gate matchers (`mutant_id/2`/`gate_id/2`/
`pattern_mutant/2`). So a poison inside a hoisted in-place selector maps back to its mutant
id; a user `case` is safe because the dispatch name is salted away from every identifier
the source uses, so it can never equal a user scrutinee's name. `hoist_pipe` recognises
both subject shapes directly (it has `ctx.active_var`), so a hoisted pipe-stage selector is
still lifted out of its illegal `x |> case` position. (This shares one recovered name with
the salt fix `active_var/1` was introduced for — the `<var> === <id>` gate match — rather
than re-discovering it per `case`: whenever a hoisted bare-variable subject exists, the
binding `active_var/1` anchors on does too, so the file-level name is always available.)

Measured on `analyze.ex` (1431 sites): inline `:persistent_term.get(:mutare_active, 0)`
reads dropped from ~1,098 to **107** (lifted dispatchers, non-lifted do-block prologues,
head-default + non-`:do`-block + module/scaffold selectors — all legitimately
self-contained), with 559 hoisted `case mutare_active do` body selectors + 11 hoisted
tupled `case {mutare_active, …}` reading the bound variable instead.

### Umbrella support `[M5 / in progress]`
Following the cargo-mutants precedent: **copy the whole umbrella, mutate a scoped
subset of apps.** The whole tree travels to the sandbox so `in_umbrella` sibling
deps and the shared `deps/`/`config/` keep resolving for free; only selected
`apps/*` get metamutants. The organising split is **copy-root** (what's
materialised — the umbrella root) vs **mutate-scope** (which apps are mutated),
resolved by `Mutare.Project` from the target path + `--app`/`--workspace` and
threaded as `Options.project`. The rest of the pipeline keeps treating its `root`
positional as authoritative — it's just the umbrella root now — and reads
`Options.project` only for scope. A non-umbrella project resolves to
`copy_root == root` with a single `%{dir: "."}` scope, so the single-app path is
byte-for-byte unchanged.

Verified Mix mechanics that shape the later steps (Elixir source):
- `mix test` is `@recursive`: **one OS process, one BEAM**, apps run sequentially,
  each via `Mix.Project.in_project` which `File.cd!`s into `apps/<app>`. So each
  app has its own cwd, but ETS/`:persistent_term` are shared across all of them.
- `mix test apps/foo/test/x.exs` **from the umbrella root** routes only to foo
  (other apps return `:ok`) — so per-mutant scoping needs no `cd`, just
  umbrella-root-relative paths.
- `mix compile` builds every app under `apps/` regardless of dep edges, and an
  umbrella `mix test` puts every app's ebin on the code path before recursing — so
  a generated `apps/mutare_support` is both compiled and **loadable from any app's
  run with no dep edge and no `Code.append_path`** (empirically confirmed; the
  cargo-research note that sibling ebins aren't auto-on-path was about per-`in_project`
  loadpaths, not the umbrella's global one). Its child `mix.exs` only needs
  `build_path: "../../_build"` to share the one build.
- A compiled module's `module_info(:compile)[:source]` is **absolute**, while each
  app's suite runs with cwd = its own dir — so the coverage helper writes the dump
  to an absolute path (`MUTARE_COV_DUMP`) and normalises test-file keys against the
  sandbox root (`MUTARE_COV_ROOT`), not cwd, or it would scatter N partial dumps
  with app-relative keys.

Staged delivery (each a commit): **(1, done)** copy-root/mutate-scope split +
detection + umbrella discovery + `--app`/`--workspace`; classification is inert
until the bootstrap is injected per app, so step 1 alone reports all-survivors.
**(2, done)** per-app bootstrap injection (every app's `test/test_helper.exs`) +
ETS create-once guard → baseline genuinely mutated, kills (incl. cross-app) work;
coverage still degrades to `:run_all` because the `:mutare_cov` helper isn't
reachable in the umbrella yet (the probe records nothing → run-all).
**(3, done)** generated `apps/mutare_support` child app holding `:mutare_cov`
(auto-compiled, auto-on-path) + absolute dump (`MUTARE_COV_DUMP`) + root-relative
test-file keys (`MUTARE_COV_ROOT`) → coverage selection works in umbrellas, keyed
by `apps/<app>/test/...`, and per-mutant runs already route to the owning app
(Mix scopes `mix test apps/foo/...` from the umbrella root).
**(4, done)** narrow the broad (`[]`, whole-umbrella) runs — `:run_all`, the
unattributed coverage case, and `:full` mode — to the mutant's owning app **plus
its transitive dependents**, passing those `apps/<app>/test` dirs instead of
running every app. The dependency graph is read **authoritatively** from the
compiled `.app` files' runtime `applications` lists (`:file.consult`), which
capture both `in_umbrella` and `path:` siblings, so it can't under-report a sibling
edge the way regex-parsing `mix.exs` could; an unreadable `.app` degrades to no
narrowing (whole umbrella). A killer must execute the mutant's code, and a sibling
only reaches it through a declared dep, so owning-app + dependents is a safe
superset — we never narrow below it. Attributed coverage selections (step 3) are
left untouched.

Former cosmetic artifact, now silenced `[done]`: because a mutated app does
**not** declare a dep on `mutare_support`, the umbrella may compile the app before
`mutare_support`, so each metamutant's `:mutare_cov.hit/1` call drew an "undefined
function" xref **compile warning** that `mix` then re-emits from the manifest cache
on every `mix test` *without* recompiling (so it leaked into per-mutant `output`).
It was always benign — coverage works regardless (the call resolves at runtime) —
but it is now suppressed at the source: `Transform` prepends
`@compile {:no_warn_undefined, {:mutare_cov, :hit, 1}}` to **every metamutant module
body** (the attribute AST is owned by `Coverage.Recorder.no_warn_attr_ast/0`, beside
the helper-module constant it references; a post-`transform_node` prewalk reaches
`defmodule` *and* `defimpl` — `defprotocol` has no bodies). The discarded
alternative was injecting `{:mutare_support, in_umbrella: true}` into each mutated
app's `mix.exs`: it would pin compile order too, but `deps` is arbitrary Elixir
(computed lists, inline, read-from-file), so no static rewrite is robust, and it
breaks the sandbox-edit boundary (we only ever generate metamutants + wrap the
trivial `test_helper.exs`, never rewrite the load-bearing `mix.exs`) — all for a
warning the attribute kills with zero risk. The attribute suppresses only the
compile-time check; it is a harmless no-op on single-app targets (helper
co-compiled, never warned) and where a module has no coverage call, so `Transform`
emits it unconditionally. Verified end-to-end: `Mutare.UmbrellaTest` asserts no
per-mutant `output =~ "is undefined"` **and** `!~ "Compiling"` (warning gone,
compile-once intact).
**(3)** generated `apps/mutare_support` coverage app + absolute dump path +
umbrella-root-relative coverage keys → coverage selection works. **(4)** scope
broad (`:run_all`/unattributed/`:full`) runs to the owning app + its dependents via
the umbrella dep graph, never below (a cross-app killer must live in a dependent).

### Sandbox ownership marker `[done]`
`prepare/3` used to `File.rm_rf!` the sandbox path unconditionally — fine for the
default temp dir, but a foot-gun for a user-supplied `--sandbox` (a typo could
wipe a real directory). It now `claim!`s the path first and only proceeds when
the path is **absent** (create), an **empty directory** (adopt), or a directory
carrying our **ownership marker** (a previous sandbox — wipe and reuse).
Everything else (a non-empty unmarked dir, a regular file, a symlink) is refused
untouched. The marker is `.mutare_sandbox`, whose first line is a fixed
signature; ownership is decided by reading the contents, not trusting the name,
so a coincidental dotfile can't authorise a deletion. `lstat` (not `stat`) keeps
a symlink from being followed to a directory we'd then clear. The reuse branch
(condition 3) is what keeps **across-run** reuse cheap — a re-run with a pinned
`--sandbox`, or `--keep-sandbox`'s deterministic digest path, re-claims the same
owned dir instead of refusing it. **Within** a run, poison recovery no longer
goes through `claim!` at all: see "Stable sandbox across poison retries" below.

### Fresh-sandbox naming: pid-salted, not just `unique_integer` `[done]`
`default_sandbox(_, false)` named the throwaway dir
`mutare_sandbox_#{System.unique_integer([:positive])}`. But `unique_integer/1` is
unique only within **one BEAM instance** — across separate `mix mutare` runs the
counter restarts and *repeats* (the first call from scheduler 1 tends to return
the same value every VM). Two runs sharing `/tmp` (concurrent invocations, or a
stale leftover — nothing ever cleans these dirs up) could therefore pick the same
path, and `claim!`'s condition-3 reuse turned that collision into **corruption**:
the second run's `reset!` wipes the first run's *live* sandbox mid-flight →
missing files, spurious compile failures, bogus verdicts ("weird conflicts").
This is the exact bug `Mutare.ChangesTest.fresh_tmp/1` already fixed for a test
fixture (see "Self-hosting" below); production had the same latent hole.

Fix: salt the name with the **OS pid** too —
`mutare_sandbox_#{System.pid()}_#{System.unique_integer([:positive])}`. The pid
disambiguates concurrent processes and isn't reused while this one is alive, so
the path is unique by construction. Kept mode keeps its deterministic
per-project digest (it *wants* a stable path for `_build` reuse).

Hardening: with the pid salt a fresh collision is effectively impossible, so
`claim!` now distinguishes **how the path was chosen** (`pinned?` = caller passed
`:sandbox`). An owned dir is still wiped-and-reused for a *pinned* fresh path
(the documented `--sandbox` reuse) and reused-in-place in keep mode, but an owned
dir found at an **auto-generated** fresh path is a stale leftover (or an
astronomically unlikely pid+counter collision) and is now **refused loudly**
(`refuse_autogen!`) rather than silently clobbered — the safer failure, matching
`fresh_tmp/1`'s "fail rather than mask a real collision" stance. Refusal can't
fire on the normal poison-recovery loop: `prepare/3` (and so `claim!`) runs
exactly once per run — retries re-render into the already-claimed sandbox via
`rematerialize/2` and never re-claim (see below).

### Stable sandbox across poison retries `[done]`
`Runner.prepare_compiling/6` recurses to recover from compile-poisoning: drop the
implicated mutant ids, `Schema.rebuild`, recompile. It used to call
`Sandbox.prepare/3` *every* attempt — which in the default fresh mode generated a
**new** `default_sandbox` path each time (a new `unique_integer`), re-copied the
whole project, re-seeded deps, and orphaned the previous dir. Pure waste, and it
meant the run's sandbox path wasn't even stable within the run.

Now `prepare_compiling` materialises (and claims) the sandbox **once**, on the
first attempt, then threads that path through the recursion. A retry calls
`Sandbox.rematerialize/2`, which rewrites only the metamutant *sources* — the
sole thing that differs between attempts; the copied project, bootstrap, coverage
helper, and seeded deps are identical — using `put_if_changed`, so unchanged
metamutants keep their mtime and mix recompiles the minimum. (`write_metamutants`
was switched from a blind `File.write!` to `put_if_changed` for this; on the first
fresh write the copied original always differs from its metamutant, so every
mutated file is still written.) Reusing the path also keeps the ownership claim a
once-per-run event, which is what lets the `refuse_autogen!` hardening above stay
strict without tripping on its own retries. Applies to every mode: keep mode
already reused its digest path, but now skips the full `sync` re-mirror on a retry
too.

### Default sandboxes are cleaned up at end of run `[done]`
Nothing ever removed a fresh sandbox, so the default temp dirs accumulated in
`System.tmp_dir!()` across runs (and, before the pid-salt, fed the collision
above). `Runner` now removes the sandbox once the run is done with it —
`cleanup_sandbox/2`, gated on `%Options{sandbox: nil, keep_sandbox: false}` so it
fires *only* for an auto-generated throwaway. A pinned `--sandbox` (the user's
chosen path) and `--keep-sandbox` (deliberately persisted for `_build` caching)
are both left untouched; that's the escape hatch for anyone who wants to inspect
the generated metamutant after a run. Cleanup runs on **every** exit path: the
post-compile work (baseline → probe → per-mutant) is wrapped in a `try/after`
around the bound sandbox (covering success *and* a red/flaky baseline or a
too-many-harness-errors abort), and a *terminal* compile failure cleans up inside
`prepare_compiling` (it owns the sandbox there and returns a bare error tuple no
`after` would see). It's best-effort (`File.rm_rf`, not `rm_rf!`) so a cleanup
hiccup never masks the run's real result. Safe because the report reads
`schema`/`results`, never the sandbox (the two-renderers split) — so `run.sandbox`
is informational only and may already be gone by the time the caller sees it.

### `--keep-sandbox`: incremental materialisation for CI caching `[done]`
The default sandbox is throwaway: a fresh dir per run, or an owned `--sandbox`
that `reset!/1` wipes (`rm_rf` + `mkdir`) and re-copies. So "compile once" was
**per run** — `_build` is discarded between runs and the metamutant recompiles
cold every time. `--keep-sandbox` (`Options.keep_sandbox`, default `false`) makes
the sandbox *survive* between runs so mix's incremental compiler does almost
nothing on a re-run. The precondition is already true: the metamutant is
deterministic for identical input (stable mutant ids), so an unchanged source
file produces a byte-identical metamutant.

`prepare/3` branches on the flag:
- `claim!/2` skips `reset!` on an owned dir (keeps `_build`/`deps`/sources).
- `default_sandbox/2` returns a **stable** per-project temp dir (a SHA-256 of the
  expanded root) instead of a random one, so `mix mutare --keep-sandbox` alone
  reuses the same path. CI usually pins `--sandbox <cache>` instead.
- `sync/3` re-materialises in place: `put_if_changed/2` rewrites a file **only
  when its bytes differ** (size-check, then compare), so an unchanged file keeps
  its mtime — which is the whole trick, since mix keys staleness on source mtime
  vs. the compile manifest (`File.cp_r!`/`File.write!` both bump mtime to now,
  verified, which is why a plain copy would defeat the cache even with `_build`
  preserved). `prune/2` deletes sandbox files Mutare no longer owns (a source
  deleted since last run), and **never descends `@excluded`** dirs, so
  `_build`/`cover` artifacts survive.

Subtleties the sync handles that a naive "don't wipe" wouldn't:
- The injected test helper is assembled from the **root's original** helper
  (`override_files/3`), never re-read from the already-injected sandbox copy —
  so re-runs don't stack bootstraps.
- The coverage helper goes to a **fixed** path (`@coverage_helper_rel`); the
  `_N` collision-avoiding suffix is a fresh-mode-only fallback. On reuse a second
  `coverage_helper_1.ex` would be a duplicate-module compile error; `prune/2`
  removes any stray one.
- Override keys are kept in the **same key space** as `Schema.metamutants`
  (`Path.relative_to(file, root)`), so a metamutant always overrides its original
  rather than the original silently winning (which would make mutation testing a
  no-op).
- Poison recovery (which re-`prepare`s the same path) becomes incremental too:
  only the dropped mutants' metamutant files change, so only those recompile.

CI pattern: `--sandbox <cache-dir> --keep-sandbox`, and cache `<cache-dir>/_build`
and `<cache-dir>/deps` keyed on `mix.lock`. tar-based caches (e.g. GitHub
`actions/cache`) preserve mtimes, which is what makes the cross-run incremental
compile work. Still out of scope: `mix deps.get` in the sandbox (unchanged), and
the `MIX_BUILD_PATH` worker-isolation question below.

### Keyword-`do:` normalization (Sourceror workaround) `[done, watch]`
Sourceror's formatter raises when rendering `def f, do: <case>` (keyword block
whose value is a multi-line `case`). `Mutare.Transform.Render` flips every
keyword-format key back to a plain atom key before rendering (and `block_wrap`s
a bare selector `case` for the same reason). Metamutant only; the report is
unaffected. Keep an eye on Sourceror releases in case this becomes unnecessary.

### Non-body operator positions
Context is classified *positively* by `Mutare.Transform`'s `analyze/3`, a
context-threaded recursive walk (see "Transform pipeline" below), not subtracted
by a blacklist. The positions:
- **Guards:** mutated via lifting (M2) — operators in a `when` are swapped in a
  duplicated clause group, since a `case` can't live in a guard. The analyzer
  returns the whole `when` untouched for *in-place*; this is position-independent,
  so `case`/`fn` clause guards are skipped too. (The clause *head's* literals are
  not mutated in place either, but they **are** mutated by the same lift path — see
  "Head-pattern literals are lifted" below.)
- **Module-attribute expressions** (`@x 1 + 2`): **excluded** (context
  `:compile_time`). Such a value is frozen at compile time — `persistent_term`
  reads the default → original — so a selector there could never activate (an
  inert/equivalent mutant). The analyzer prunes the whole `@<name> <value>`
  definition. (A bare attribute *read*, `@x`, has no value list and is not
  skipped.) Pinned by a transform_test.
- **Macro bodies** (`defmacro`/`defmacrop`): **excluded** (also `:compile_time`).
  A macro body runs at expansion time, before `MUTANT_UNDER_TEST` is set at test
  runtime, so a selector there is frozen on the default → inert — exactly the
  module-attribute problem. (A macro *can* `quote` runtime code, but per
  PHILOSOPHY "instrumenting macro-generated code is a different tool"; the whole
  macro is pruned.) Previously these mutants were emitted and silently wasted.
- **Lexical directives** (`import`/`alias`/`require`/`use`): **excluded** (also
  `:compile_time`). Their arguments are resolved at compile/expansion time, and
  some positions *must* be a literal — `import …, only: [f: 1]` requires a literal
  keyword list, so a selector `case` around the `[f: 1]` (or its `1` arity) is not
  inert but outright **illegal**, and would compile-poison the single build. The
  analyzer prunes the whole directive call. Found by the adversarial transform
  corpus (the `macros` and `aliases/imports` entries failed to compile until the
  classifier got this clause); pinned now by both the corpus and a transform_test.
  The default `literal`/`list` mutators are what reach the `only:` list, so the
  regression test must run with the default set — `@probe` (arithmetic+relational)
  doesn't touch it.
- **`quote` blocks**: **excluded** (also `:compile_time`). A `quote` *constructs
  AST* — its literals become part of the code the quote generates, which is out of
  scope (PHILOSOPHY: "macro-generated code is a different tool"), exactly like a
  `defmacro` body. And it is a *silent* poison if mutated: a selector `case`
  spliced into a quoted pattern/guard (e.g. `quote do: (case x do "" -> … end)`,
  as in `Selector.bootstrap_ast`) is valid *as a quote* — the metamutant compiles
  — but illegal where the AST is later expanded/`Code.eval_quoted`'d, so the
  pre-filter never sees it and it surfaces as a baseline failure. The analyzer
  prunes the whole `quote`. **Deferred:** `unquote(expr)` args are runtime
  sub-positions (they run when the quote is built) and are currently pruned along
  with the body; mutating them precisely (route `unquote` back to `:runtime`, like
  the `\\` default) is future work — losing them is acceptable per the philosophy
  above, and `bootstrap_ast`'s unquotes are inert (vars/atoms) anyway.
- **Bitstring type specifiers** (the right of `::` in `<<>>`): **excluded** from
  *in-place* mutation (context `:spec`), *except* `size(expr)` args. A `case` is
  illegal as a bare spec / in `unit(...)`, and swapping the `-` separator yields
  an illegal specifier (`integer-big` → `integer+big`) — both compile-poison the
  single build. The analyzer keeps separators / type atoms / `unit()` raw but
  recurses into `size(expr)` args (a `case` *is* legal in `size`), so a body's
  `<<x::size(n*8)>>` still yields a real, killable size mutant; in a pattern the
  size arg is pruned. The value side (left of `::`) mutates normally.
- **Unicode encoding/byte-order specifiers** (`Mutare.Mutators.BitstringSpec`):
  the *one* spec-position swap worth running, so it is **on by default** despite
  the blanket exclusion above. It mutates a segment's text encoding
  (`utf8 ↔ utf16 ↔ utf32`) and byte order (`big ↔ little`, utf16/utf32 only) —
  the cleanest swap family in the tool: **never-equivalent** and **compile-safe
  with a symmetric validity domain** (a surrogate / over-max value raises
  identically for all three encodings, so a swap only ever changes the bytes
  emitted, never crashes a previously-working segment). Never-equivalence is *not*
  free — it rests on a **literal-value equivalence filter** (`reject_equivalent/3`):
  for a literal value (an integer codepoint *or* a binary string, whose utf
  encoding is each codepoint in turn) it encodes the original and every variant and
  drops any whose bytes match. That catches both axes' coincidences — a
  byte-palindromic value reads the same in either order (`<<0::utf16>>`,
  `<<"\0"::utf16>>` are `<<0, 0>>`; `<<0x0101::utf16>>` is `<<1, 1>>`), and an
  **empty** value is `<<>>` under every width (`<<""::utf16>>`), so even its
  *encoding* swaps coincide. A *variable* value can't be decided, so its variants
  are kept (each killable by some input). One trap the filter must dodge: Sourceror
  preserves a string's source **escapes un-decoded** (`"\0"` stays the two-byte
  `"\\0"`, not the NUL the compiler emits), so the filter re-parses the rendered
  literal with the *standard* (escape-decoding) parser before encoding — reading
  the node directly would compare the wrong bytes and let an **equivalent** mutant
  survive as a phantom (the un-decoded `"\\0"` looks non-palindromic, so its
  byte-order swap wouldn't be dropped, though `<<"\0"::utf16>>` is `<<0, 0>>` in
  either order; the reverse — *false-dropping* a real mutant — can't happen, since
  an escaped value carries a backslash, never byte-palindromic). `native` is
  excluded as source and target (host-dependent → an
  equivalent-on-this-host mutant; and the filter resolves it to big-endian, the
  only equivalence it joins being the order-independent empty case, so the emitted
  set stays deterministic across hosts). The deprecated-but-compiling parenthesized
  modifier (`utf16-big()`, whose atom leaf parses with context `[]` not `nil`) is
  recognised as an explicit order, so a swap *flips* it rather than appending a
  conflicting second one (`utf16-big()-little` → "conflicting endianness", a
  build-poisoning mutant).
  **Zero transform plumbing**: it is an ordinary
  `mutate/1` family that the *existing* whole-`<<>>` `offer/3` (the one
  `BitstringLiteral` rides in a runtime body) hands the node to, and each mutant
  is a *complete* `<<…>>` with one segment's spec rewritten — so the in-place
  selector (a constructor body) or the lifted clause-guard replacement (a
  `when <<x::utf16>> == …` guard, delivered without a `case`) both work unchanged.
  The spec side is *not* offered in a **pattern** (a head/`case`/`=`-match `<<>>`):
  the head-lift's scalar-literal-only filter declines the non-scalar `<<>>` node,
  and no selector can wrap a pattern — so v1 catches **encoders, not decoders**
  (`<<cp::utf16, rest::binary>> = decode(x)`, the matching-bug side, is the
  documented gap). The value side still mutates via its own families.
- **Default arg values** (`def f(a \\ 1 + 2)`): mutated in place; live mutant.
  The head is a pattern, but `\\`'s default runs at call time, so the analyzer
  routes it back to `:runtime`. Such functions **are** lifted now (see "Default
  arguments are lifted" below) — the `\\` defaults ride on the public dispatcher,
  whose default-value selectors keep mutating at call time — so they also get
  guard / head-literal / clause-drop / pattern-structure mutants. (A default value
  cannot reference another argument — Elixir evaluates it in an isolated scope — so
  renaming the dispatcher's args to `mutare_arg_i` never breaks a default.)
- **Patterns** (clause heads, `=` match LHS): routed to `:pattern` and not
  mutated **in place** (a selector `case` is illegal in a pattern). Built-in
  arithmetic/relational operators can't legally appear in a pattern anyway, so this
  mainly shielded *custom* mutators — until the **atom** mutator (the first built-in
  that matches a bare-atom node) made the gap bite. (A `def`/`defp` *head* pattern's
  literals are nonetheless mutated — by **lifting**, not in place — see "Head-pattern
  literals are lifted" below; `=`-LHS and `case`/`fn`/… clause patterns stay
  unmutated, having no lift path.)
  **Now done** (was deferred): clause-pattern / generator routing for
  `case`/`fn`/`with`/`for`/`receive`/`try`. A generic `->` clause routes a
  clause's LHS to `:pattern` and the body to `:runtime`; a `<-` clause mirrors
  `=` (LHS pattern, RHS context). The sharp edge the old note warned of is handled
  by intercepting **`cond` first** (`analyze_cond_block/2`) so its `->` LHS stays
  *runtime* — a cond clause's left is a condition, not a pattern — while `for`/`with`
  filters (ordinary body positions) keep mutating untouched. Replaces the old
  reliance on poison recovery for those LHS literals (e.g. `case x do 1 -> …`'s `1`
  used to be mutated into an illegal `case`-in-pattern, then poison-dropped; now it
  is never offered). The `try`-in-a-def-head path still routes via the older
  `analyze_try_clause/2` (called from `analyze_do_blocks/2`); the generic `->`
  clause covers every *other* construct, including a `try` outside a def head.
  **`match?/2`** is the one *non-syntactic* pattern position: a macro whose first
  argument is a match context (it expands to `case expr do pattern -> true; _ ->
  false end`). It looks like an ordinary call, so without special handling its
  pattern arg was routed `:runtime` and a literal/tuple/string there was mutated in
  place — splicing a `case` into a pattern ("case not allowed in matches"). It is
  now a **known macro** (`Mutare.Macros`): arg 1 `:pattern`, arg 2 `:expression`.
  This generalises the old hard-coded clause (which matched the bare name only,
  leaving a qualified `Kernel.match?/2` to poison fallback): the registry resolves
  the call's module through the existing alias/import/displacement machinery, so
  the bare **and** qualified/aliased forms are both routed, and only when the call
  is genuinely `Kernel.match?` (a local `def match?/2` shadowing it is a compile
  error, so a compiling bare `match?` is unambiguous — the same soundness `Imports`
  rests on). See "Known-macro registry" below. Found dogfooding `plug` — see
  "Real-world poisons (plug/router)" below.

### Data keyword/map keys mutate; only block keys are labels `[changed]`
The pair routing (`block_key?/1` + the 2-tuple `analyze` clause) is what lets the
atom mutator reach a key. The original rule treated **every** keyword-shorthand key
(`format: :keyword`) as a structural label, so `%{a: 1}` / `[a: 1]` silently differed
from the arrow/tuple forms `%{:a => 1}` / `[{:a, 1}]` (whose keys always mutated) —
syntax sugar disabling a mutator for no reason. Now only a **block key** (`do:`/
`else:`/`rescue:`/`catch:`/`after:`, by reserved atom `@block_keys`, in either the
inline `format: :keyword` or the `do … end` no-marker shape) is a label. The reason is
narrow and real: a selector `case` spliced into a `do:` key is malformed and **crashes
`Sourceror.to_string` outright** (not a compile error, so *not* poison-recoverable; it
sinks the whole file's render). A *data* key has no such problem — Sourceror re-renders
the spliced selector as an arrow (`%{(sel) => v}`) or a list tuple (`[{(sel), v}]`),
both legal, so the `format: :keyword` marker left on the original key is harmless (no
need to strip it).

Two **compile-constrained** data-key positions can't go through the generic pair clause
and are excluded positively, *upstream* of it:
  * **Struct fields** (`analyze_struct_field/3`) — `%S{name: …}` → `%S{mutare: …}` is a
    *compile* error (unknown struct field), so the key stays raw. Covers the update form
    `%S{base | f: v}` too (its `:|` node carries the field list; a struct update with a
    bad key is likewise a compile error). Plain **map** updates `%{m | k: v}` are *not*
    excluded — there a wrong key is a runtime `KeyError`, compile-safe and a real (if
    weak) mutant.
  * **`for` options** (`analyze_for_arg/2`) — `into:`/`uniq:`/`reduce:`/`do:` are
    special-form keywords; `for …, mutare: x` is `unsupported option :mutare given to
    for`, a compile error. (The `:uniq` *value* is also held back — it must be a literal
    boolean.)

Everything else (free-form maps, keyword lists, a call's trailing options `foo(…,
timeout: x)`) mutates. Unknown **DSL** keyword options (e.g. Ecto `field …, default: x`
inside a macro `do` block that's analyzed as runtime) are left to the **poison
backstop** if the macro rejects the mutated key — the standard treatment for the
unknown; a macro that silently ignores the unknown key yields a (rare) equivalent
survivor instead. Module-level `defstruct name: 0` / `use Foo, opt: 1` keys are safe
for a different reason: the module body is `:scaffold`, which never offers anything.

### `call_option_keys: false` — a mutator opts out of call-trailing-keyword keys `[done]`
A keyword list passed as a *call's final argument* (`foo(x, timeout: 5, retries: 3)` —
the trailing-keyword sugar, the same AST as an explicit `[timeout: 5, …]` last arg) is
the one place key mutation most often turns into noise: the keys are usually *option
names* a function reads with `Keyword.get`, so mutating `timeout:` → `mutare:` either
survives (the option silently ignored) or is an equivalent-ish always-default. A project
switches *just those* off **per mutator** via the configurable-mutators `{module, opts}`
mechanism: `mutators: [{Mutare.Mutators.AtomLiteral, call_option_keys: false}, …]`. The
configured mutator still mutates option *values*, and keys of standalone `%{a: 1}` /
`[a: 1]` literals and `Map`/`Keyword` data everywhere else — only its call-option keys go
quiet.

Why per-mutator (not a global flag / CLI option), and why a transform-side gate rather
than `mutate/2`: the gate is **positional** (the call-key position is known only to the
transform, never to a position-agnostic mutator), so a mutator's `mutate/1`/`mutate/2`
can't decide it. But the *choice* is genuinely the mutator's config — so the candidate
carries its `Mutare.Mutator.Spec`, and the transform reads `spec.opts` at gate time. No
Options field, CLI flag, or `Ctx`/`Schema` plumbing; it composes with `{module, opts}` like
any other mutator option, and is per-mutator for free (configure `AtomLiteral` and an
integer key — `Literal`'s — is untouched).

  * **Detect + tag in `Analyze`** (it alone knows the call context): `recurse_runtime/3`
    post-processes its result with `mark_call_option_keys/1`, which — when the node is a
    real call (`call_form?/1`: a remote `{:., …}` or an atom form not in `@non_call_forms`,
    so a `%{}` map / `{}` tuple ending in a keyword-shaped list isn't mistaken for one) and
    its last arg is keyword-list-shaped — stamps each *key* candidate `call_option_key?: true`
    (a `Candidate.InPlace` field). Shallow: a nested map/list inside an option *value* keeps
    its own keys. Piped calls (`x |> foo(opt: 1)`) go through `recurse_runtime` too.
  * **Gate in `Transform`**: `emit`'s `gate_candidates/1` drops a `call_option_key?: true`
    candidate when its own `spec.opts` say `call_option_keys: false` (`call_option_keys_off?/1`)
    — *before* `claim_id`, so it consumes no id and records no site (unlike a poisoned id,
    which is recorded). Ids stay **contiguous** and stable: the mutator list (hence each
    spec's opts) is constant within a run, so poison rebuilds reproduce the same id sequence.
    The unconfigured path drops nothing (zero overhead).

### import resolution — bare imported calls mutate `[done]`
`Mutare.Transform.Imports` is the bare-call counterpart to the `alias` vocabulary: it stamps
each bare call that resolves to an imported module (`meta[:mutare_import]`), so a bare
`reject(xs, f)` after `import Enum` is mutated by Collection like `Enum.reject`. The unified
reader `Mutare.Transform.Calls.resolved_call/1` recognises both shapes (alias-remote and
bare-import) and the families switched to it (a one-line swap each); `Aliases.resolved_call`
moved there.

- **One walk, not two passes — aliases and imports interleave.** `alias`/`import` share one
  lexical scope and *interact*: `import Foo.B; alias A.B; import B` imports two different
  modules (the second `import B` sees the alias). So a single driver (`Mutare.Transform.Resolve`)
  folds *both* envs together in source order — `Aliases` and `Imports` are now pure vocabulary
  modules (env-building + stamping + reading rules), each cohesive, with no walk of their own.
  This also kills the redundancy of the original two-pass version (an `Aliases.annotate` then an
  `Imports.annotate`), where the second pass rebuilt the alias env just to resolve imports. The
  env threads `aliases`, `imports`, the `Kernel` selector, and a `piped?` flag (for effective
  arity); a `case`/body descent resets `piped?`, the `|>` clause sets it on the RHS.
- **Why this is safe without rebuilding the compiler.** We only ever resolve to a *module*,
  never a definition, and lean on the compiler: any **compiling** bare call is unambiguous.
  Verified against Elixir: `import Enum` + a local `def reject/2`, two whole imports of
  `reject/2`, and shadowing a `Kernel` name via a plain import are **all compile errors**
  ("conflicts with local function" / "imported from both … ambiguous"). So if the source
  compiles and `import Enum` is in scope and Enum exports `reject/2`, a bare `reject(x, y)`
  *is* `Enum.reject/2`.
- **Per-arity, so we reflect.** Resolution is strictly per-arity (`import M, only: [f: 1]`
  then `f(1, 2)` is a compile error; `import Enum` + bare `min(a, b)` is *ambiguous* with
  `Kernel.min/2` and won't compile, but `min(coll)` resolves to `Enum.min/1`). A whole/except
  import therefore needs the module's exported arities — learned by **runtime reflection**
  (`function_exported?`/`macro_exported?`). This is the one place the transform reads the
  loaded environment; it's deterministic for the stdlib (always loaded, and the only modules
  the families target) and conservatively skips an un-loadable module (a target/dep — never
  targeted), so a user-module import simply isn't resolved. `only:`-listed arities are read
  straight from the source (no reflection). A reflection-based decision can't silently
  miscompile: even if a wrong attribution slipped through, the selective path *qualifies* the
  swap, so a non-existent `Enum.fun/n` would poison rather than mis-behave.
- **bare vs qualified diff — and why bare is *narrow*.** The stamp carries the rebuild kind.
  `:bare` keeps the clean diff (`reject`→`filter`) but is only sound when the swap's *sibling*
  is unambiguously bare-callable to the same module, so it is used **only for a sole whole
  import with an unmanipulated Kernel** (`rebuild_kind/3`). Everything else qualifies
  (`reject`→`Elixir.Enum.filter`): a selective import's sibling may not be in scope, and — the
  subtle one — a *second* import can make a bare sibling ambiguous or wrong even though the
  original call was unambiguous. Two cases that motivated the narrowing (both verified):
    - `import Stream, except: [filter: 2]; import Enum, only: [filter: 2]; filter(xs, f)` — `filter`
      is the selective Enum one, but a bare `reject` would be `Stream.reject` (the *wrong* reject).
      Selective ⇒ already qualified, so this was fine; it's the reason a whole import isn't enough.
    - `import Stream, except: [filter: 2]; import Enum; filter(xs, f)` — `filter` is whole-Enum, but
      a bare `reject` is *ambiguous* (Stream's and Enum's) and won't compile. Two imports in scope
      ⇒ `map_size(imports) > 1` ⇒ qualify. (Under the old "any whole import → bare" rule this
      silently poisoned the mutant.)
  A bare sibling is never *wrong-but-surviving*: the mutator's sibling is always an export of the
  resolved module, so an unambiguous bare call resolves to that module (correct), and an
  ambiguous/Kernel-colliding one fails to compile (poison) — the residual under a sole import is
  a custom mutator swapping to a `Kernel`-colliding name, backstopped by poison.
- **The qualifier is alias-proof.** The import captured a specific module, but the generated
  qualifier names it at the *call site*, where a later `alias` may rebind that name — so
  `{:__aliases__, [], [:Enum]}` would compile under `alias String, as: Enum` as `String.filter`,
  not the intended `Enum.filter`. `Calls` prefixes the path with `:Elixir` (the alias-bypass
  escape hatch: `Elixir.Enum.filter`); an Erlang atom (`:binary.fun`) is never alias-expanded, so
  it needs no prefix. Regression-tested with `import Enum, only: [reject: 2]; alias String, as:
  Enum`.
- **Kernel is tracked, not reflected.** The default whole `import Kernel` is implicit, so
  reflection can't tell you "the default set"; the env tracks a `Kernel` selector instead.
  The **only** way to displace a `Kernel` function is `import Kernel, except:/only:` (a plain
  import can't silently shadow `abs`/`min` — it errors, verified), so a bare `Kernel`-named
  call is the `Kernel` one unless the selector says otherwise, in which case it's stamped
  `meta[:mutare_kernel_displaced]` and the bare-`Kernel` families (`Numeric`'s min/max/round,
  `CallRemoval`'s abs) skip it. Default-Kernel calls stay unstamped — zero change, zero
  reflection on the common path (no `import Kernel` narrowing).
- **Lifting comes for free.** The walk stamps guard call nodes too, so `import Integer; def
  f(n) when is_even(n)` mutates to `is_odd(n)` via the existing lift path — no `FunctionPlan`
  change. The metamutant keeps the source's `import Integer`, so the `is_odd` macro resolves.
- **Every `resolved_call` family gets bare imports for free — including `CallRemoval`.** The
  call-matching families all route through `Calls.resolved_call`, so a bare imported call is
  recognised wherever an aliased remote one is. `CallRemoval` was the lone holdout — it did its
  own `Aliases.resolved_module` lookup (ad-hoc, and blind to imports) — and now routes through
  `Calls.resolved_call` too, so `import Enum; sort(xs)` → `xs`.
- **Atom modules resolve uniformly too (`:binary`, `:string`, `:math`).** `alias :binary, as: B`
  and `import :binary` are both legal Elixir, and reflection works on an atom module exactly as
  on an Elixir one (`function_exported?(:binary, …)`). So `Calls.resolved_call` returns the
  *atom* (`:binary`) as the module key for a direct `:binary.split`, an aliased `B.split`, and a
  bare imported `split` alike — and a mutator keys its table on `{:binary, fun}` once and catches
  all three forms. This let `StringCall`, `Math`, and `CallRemoval` drop their bespoke `:string`/
  `:math` clauses (the last Erlang-handling ad-hoc) and gain aliased/imported support for free;
  the only shape left outside the reader is a bare `Kernel` call. The alias env binds an atom
  name to the atom (not a path), so `Aliases.resolve_path`/`resolved_module` and the import env
  (`module_key?`/`to_module`) accept an atom key beside a path. (`alias :binary` *without* `as:`
  binds nothing — an atom has no last segment.)
- **Out of scope (documented limitations).** Operator displacement (`import Kernel,
  except: [+: 2]` + a custom `+`) — Arithmetic/Relational/Logical don't read the stamp. Like
  `alias`, `use`/macro-injected imports are invisible.
- **Correctness boundary: sound for what we can *see*; the macro replacement hole is fail-loud.**
  For *visible* code the scheme is correct-or-poison-or-missed, resting on one Elixir fact
  (re-verified): calling a name provided by more than one visible source — two imports, an
  import + a same-arity local, or an import + Kernel — is a **compile error**, never a silent
  pick. (A local *definition* shadowing an import is allowed; only the *call* errors — so an
  uncalled local doesn't perturb resolution, and a different-arity local resolves distinctly.)
  Given that, for a swap `fun`→`sibling` resolved to `M`:
    - **Qualified** rebuild (`Elixir.M.sibling` / `:m.sibling`) names `M` unambiguously, immune
      to imports/aliases/locals — correct if it exists, else a compile error.
    - **Bare** rebuild (sole whole import + default Kernel): `M` always provides `sibling`, so a
      bare call resolves to `M` (correct) or hits a second provider and won't compile (poison) —
      never silently a *different* module.
- **The `use`/macro hole is fail-loud now.** We don't expand macros, so a `use` injecting
  `import Enum, except: [filter: 2]; import Hidden, only: [filter: 2]` defeats us: it
  *re-imports Enum to remove filter* and supplies filter from `Hidden`. We still see only
  `import Enum`, and reflection says Enum *exports* filter — but Enum no longer *provides* it
  (the hidden `except` subtracted it), so the bare `filter` is really `Hidden.filter`. We
  mis-resolve it to Enum, and qualifying the mutant does **not** save it: the error is
  mis-resolving the *original*, upstream of the rebuild. The mitigation is a generated
  **import witness** on stamped bare-import mutant branches: an unreachable `case false` branch
  re-imports the believed provider (`import Elixir.Enum, only: [filter: 2]`) and references the
  same name/arity through a generated `fn …args -> fun(args) end` closure. In normal visible-import
  code that compiles and is never run; in the hidden replacement shape Elixir reports "imported
  from both …", which Poison maps back to the generated mutant id. This does not make
  macro-generated imports visible, but it turns the known wrong-but-compiling shape into a poisoned
  mutant. (A *call* `fun(args)`, not a capture `&fun/arity` — though both trigger the ambiguity,
  even for guard macros: the original source was already a call, so a call is guaranteed legal
  wherever the original compiled, with no function-vs-macro case analysis.)
- **The witness is *complete* for compiling original code, not merely a mitigation** (re-verified
  against the compiler). The except-plus-hidden-*import* replacement is the **only** reachable way
  a hidden macro can silently redirect a *visible-module* bare call. The alternatives can't arise
  or are already caught: a hidden *local* `def fun/arity` replacement would need the source to
  *call* `fun` with both `import Enum` and the local in scope — itself a compile error
  ("imported … conflicts with local function"), so the original wouldn't compile; a hidden import
  that *adds* `fun` without an `except:` subtracting it leaves the original bare call ambiguous →
  poison. And it never *false*-poisons: re-importing a module already in scope is harmless (Elixir
  permits the duplicate), so the witness errors only when a genuinely-different second provider is
  present — which, for compiling original code, can only be the hidden one we mean to catch.
- **Same module imported multiple times — handled correctly (for visible imports).** Per Elixir
  (verified): a later `only:` *replaces* the selection, a plain `import` resets to all, and a
  later `except:` *subtracts from the prior selection* (not from all) — `import Enum, only:
  [a, b]; import Enum, except: [a]` leaves only `b`. The env models each module as `{base,
  except}` and `combine/2` folds these rules, so we neither over- nor under-estimate a
  re-imported module's in-scope set. (The old `Map.put`-replace + all-minus-except model
  over-estimated after a narrowing prior, which could itself mis-resolve — fixed.)
  Reflection reads the harness's stdlib, the same Elixir the sandbox compiles against — version
  skew is the only other residual, and benign.

### Known-macro registry — argument routing for macros `[done]`
A macro whose argument is a *pattern* or an *opaque DSL body* looks like an ordinary call, so
the positional analyzer would mutate literals inside it (a literal in `match?`'s pattern arg
is a pattern, not a value → splicing a selector there is "case not allowed in matches", which
poisons the single build). The fix generalises the old hard-coded `match?/2` clause into an
extensible **registry** (`Mutare.Macros` + `Mutare.Macro.Spec`): a spec declares, per argument,
a treatment — `:expression` (analyze `:runtime`, the default), `:pattern` (analyze `:pattern`),
or `:skip` (leave the arg **raw** — no descent, no mutation). `args` is a uniform atom or a
per-position list padded with `:expression`.

The mechanism reuses the resolution machinery wholesale — **no new walk**. `Resolve` already
resolves every call's module; it now also looks the call up in the registry and stamps a
matched call's meta with its per-position routing (`meta[:mutare_macro]`), which the analyzer's
generic runtime clause reads (one `case Keyword.get(meta, :mutare_macro)`, the `nil` arm is the
old path byte-for-byte — sigils/ordinary calls untouched). `Render` strips the stamp via its
allowlist (`@internal_meta_keys`), like the other `:mutare_*` stamps.

Three load-bearing decisions:

- **Soundness of identifying a macro is the *resolution's*, not a name match.** A bare
  `match?(p, e)` is `Kernel.match?` only when it isn't import-redirected (`:mutare_import`),
  isn't `kernel_displaced?`, *and* is a genuine `Kernel` export (`kernel_export?` reflection,
  Kernel always loaded) — so a local function of the same name resolves to `nil` (no match).
  This is exact, not heuristic: a local `def match?/2` shadowing the Kernel macro is a **compile
  error** (verified — "imported Kernel.match?/2 conflicts with local function"), so any
  *compiling* bare `match?` is unambiguous, the same foundation `Imports` rests on. A
  qualified/aliased `Kernel.match?`/`Q.from` resolves through `Aliases.resolve_path` — so the
  registry handles bare, qualified, and aliased forms uniformly (the old clause did bare only).
- **Three sources, merged later-wins.** Built-ins (`Kernel.match?/2`, `Kernel.destructure/2`),
  a declarative `:macros` option, and an optional **`macros/0` callback on `Mutare.Mutator`**.
  The last is the extensibility win: a library ships *one* module carrying both its custom
  mutator and the macro routing it relies on, and the user adds a single `:mutators` entry —
  Mutare core never knows about the library. The motivating case is Ecto: register
  `{Ecto.Query, :from, :any, :skip}` so core leaves the query DSL alone, while the same module's
  `mutate/1` rewrites the query (drop a `where`, flip `:asc`/`:desc`). `:skip` is also the
  mechanism behind "owned only by a custom mutator": core skips the args, but the **whole macro
  node is still offered to every mutator**, so the registering mutator fires on it.
- **Reflection-free config resolution.** `Mutare.Macros.resolve/1` (and the `:macros` validator
  in `Options`) never reflect on the module — module keys are purely syntactic (`Module.split`
  via `Macro.classify_atom` to tell an Elixir alias from an Erlang atom) — so a
  `{Ecto.Query, …}` entry validates even when `Ecto` is not a dependency of the Mutare process.
  Resolution at the *call site* still reflects (via `Imports`), where the target app's deps are
  loadable.

**Pipe-aware** (the query-builder shape `q |> where([p], p.x == 1) |> order_by(...)`, where each
stage is a piped macro and the piped value is effective arg 0). `Resolve.stamp_macro` matches on
the *effective* arity (`Mutator.effective_arity(args, env.pipe_mode)` = visible + 1 when piped —
`env.pipe_mode` is the `:piped`/`:unpiped` atom directly, built by `Resolve`'s `:|>` clause, no
boolean conversion) and splits the routing
across **two** stamps: the **visible** positions ride on `meta[:mutare_macro]` (lining up with the
stage node's own args, read by `analyze_pipe_stage` the same way the generic clause reads it), and
the **piped value's** treatment (effective position 0 — the `|>` LHS, *not* in the stage node's
args) is recorded separately on `meta[:mutare_macro_piped]`. Without the visible stamp, core would
descend into a piped `:skip` stage's DSL body and mutate/poison it — the bug that a naive "don't
stamp piped calls" introduced (a piped macro stage is the *common* DSL shape, not a rarity).

**The piped value reaches back to position 0** (`|> match?` and friends). `|>` pipes *anything* into
a macro — including syntax that is a pattern, or (for `:skip`) neither a valid expression nor a valid
pattern: `1 |> match?(1)` is `match?(1, 1)`, whose LHS is the **pattern**, and `{1 + 1, _, …} |>
silly()` is legal because `silly` discards its arg. Treating the `|>` LHS as ordinary `:runtime`
(the old `analyze` `:|>` clause) wraps it in a selector `case` in pattern/opaque position → compile
error → poison. So `Analyze.analyze_piped_value/3` reads `meta[:mutare_macro_piped]` off the stage
and routes the LHS through the **same** `route_macro_arg/3` as a visible arg — the piped value is
treated *exactly as if it were written as the macro's first positional argument* (`:pattern` →
descend-don't-mutate, `:skip` → raw, `:expression` → runtime). The head is stamped only when it is
**not** `:expression` (the common runtime LHS carries no stamp, falls through unchanged), so this is
zero-cost everywhere but a piped pattern/`:skip` macro. Soundness is free: a non-trivial LHS isn't a
valid pattern, so a `… |> match?(e)` that *compiles at all* already has a pattern-legal LHS — when
it reaches us, `:pattern` is always right. This is a *positive* exclusion (the project philosophy),
not leaning on the poison backstop, which would otherwise eat a wasted rebuild on this known shape.

**A registered macro resolves through a whole import even when its module can't be loaded**
(`Resolve.registered_macro_module/3`). `Imports.stamp` resolves a whole `import Mod` by
reflection (`Code.ensure_loaded?` + `function_exported?`), so a first-party DSL defined *only in
the target project* — which the Mutare process can't load — leaves a bare macro call unstamped,
and the macro is then misclassified as **unknown**. That is the worst place to lose the routing:
a `:skip` body is mutated as an ordinary runtime body (it *was* meant to be opaque), and the
unknown-block tag means a recurring compile poison makes `Runner.escalate_block_poison/3`
drop *every* sibling mutant in the block — silently skipping valid mutants despite the user's
`:macros` registration. The fix: when reflection can't resolve the call, consult the **registry**
directly — among the *whole*-imported modules in scope, find one registering `fun/arity` as a known
macro. Sound by the same compile-unambiguity rule `Imports` rests on: the user's `:macros` entry
asserts the module provides the macro, and a whole import of it makes the bare call unambiguously
its macro. Scoped to whole imports because a selective `import Mod, only: [m: 1]` resolves straight
from the source (no reflection), so it never reaches the fallback. This does **not** lift the
inherited `Imports` limit for *un*registered bare calls (the ordinary stdlib *function* families
still need reflection — but those modules are always loadable, and a real `mix mutare` run has the
target's deps loaded anyway). A known macro in a `:scaffold`/compile-time position isn't routed
(it's already non-mutating there, so `:skip` would be a no-op anyway). `test/support/macro_mutator.ex`
is the worked `macros/0` example (with a piped `where/2` stage).

**Structural pattern mutation of a binding-escaping macro arg (`:binding_pattern`)**
(`destructure([x, y], v)` → `[y, x]`/wildcard). A bare `:pattern`-routed macro arg is *safe* —
descended-not-mutated, so no literal is mutated in place and no selector is spliced into pattern
position — but on its own it gets **no** structural (`PatternSwap`/`PatternWildcard`) mutants. The
right delivery — and even whether a mutation is observable — depends on the macro's *binding
semantics*, which the plain `:pattern` treatment doesn't encode:

  - `destructure` binds into the **enclosing** scope (bindings escape). In fact `destructure([x, y],
    v)` expands to `[x, y] = Kernel.Utils.destructure(v, 2)` — a `=` match — so it is the `MatchPattern`
    case exactly, except the `=` only appears *after* macro expansion (which Mutare doesn't do), so the
    `=`-statement path never sees it. A swap must use the tuple re-export and only in a value-discarded
    position; an in-place selector copy would trap the bindings inside the branch (`x - y` after →
    unbound → poison).
  - `match?` binds **locally** (inside its `case` expansion), so a *swap* of distinct vars is an
    **equivalent mutant** (same boolean, nothing escapes) — pure noise — while a *wildcard* of a
    repeated var (`match?([a, a], v)` → `[_, a]`) *is* observable and, since match?'s value is used,
    wants the in-place selector delivery, not re-export.

So the binding semantics are declared per-macro, by a **fourth treatment** beyond `:pattern`:
`:binding_pattern` (`Mutare.Macro.Spec`) means "this pattern arg's bindings *escape*, and the call
sits where its value is discarded". `Kernel.destructure`'s arg 0 is flipped to it (a built-in), and a
user opts their own macro in via `:macros` / `macros/0` (e.g. `{MyDsl, :unpack, 2, [:binding_pattern,
:expression]}`). The treatment routes identically to `:pattern` for the in-place descent (still safe
everywhere); the *extra* structural mutants are delivered by the **`MacroPattern`** candidate — the
`MatchPattern` tuple re-export generalized from a `=` to running the macro itself inside each selector
branch (`{x, y} = case <sel> do <id> -> destructure(<mut>, v); {x, y} … end`). The shared discovery
(`Analyze.pattern_export/3`: `bound_var_names`, per-occurrence export tuple, forced-thin wildcard) is
factored out of the `=`-match path and reused verbatim. Both the directly-written `destructure([x, y],
v)` and the **piped** `[x, y] |> destructure(v)` form route (the pipe LHS is effective arg 0, read
back off the `:mutare_macro_piped` stamp); the mutant branch runs the *raw* call, the catch-all the
*emitted* one (so a mutation in the value arg, `destructure([x, y], Enum.reverse(v))`, still fires).

Position soundness mirrors `MatchPattern` with one extra exclusion. A block non-final statement and a
`with` bare clause are genuinely value-discarded (verified: a `with` bare clause does *not*
short-circuit on a falsy value), so the rewrite — whose value is the export tuple — is transparent.
But a **`for` qualifier** is *not* a safe home for a bare macro call: there a bare expression is a
**filter** (its truthiness selects iterations), so rewriting it to a `{vars} = …` binding qualifier
would silently drop the filter. So `analyze_for_arg` routes only the `=` shape (already a binding
qualifier) through the pattern path (`analyze_match_statement/2`); block/`with` use `analyze_statement/2`,
which additionally recognizes a `:binding_pattern` macro call. The contract the opt-in vouches for: the
macro binds *every* variable named in the pattern (so the export tuple is always fully bound) and
accepts pattern-legal swap/wildcard rewrites — both true for `destructure`; a mis-declared user macro
falls to the poison backstop.

Still deferred: the `match?`-style **local-binding, value-used** case (the in-place selector-copy
delivery, wildcard-of-repeat only). It is a *distinct* treatment from `:binding_pattern` (different
binding scope, different delivery, only the wildcard is observable) and is left unbuilt — `match?`'s
arg 0 stays plain `:pattern`.

#### Whole-call mutants on a binding macro, and why `=` needs no mirror `[done]`

The macro node is **offered to mutators** (`analyze_known_macro` → `offer`) so a *registering*
custom mutator (`macros/0`) can mutate the whole call — the Ecto-style use, where the library
ships both the macro registration and a DSL-aware rewrite. For a `:binding_pattern` macro that
whole-call mutation is a hazard, in two ways the original `MacroPattern` commit got wrong:

  - **It can't ride an ordinary in-place selector.** The macro's bindings *escape*, so a selector
    wrapping the call traps them inside the branch (`x - y` after → unbound → poison) — exactly the
    reason the pattern mutants use the tuple re-export.
  - **It was silently shadowed.** `attach_macro_pattern_candidates` prepended the pattern candidates
    with `put_candidates`, leaving the whole-call `InPlace` in a *second* `:mutare` entry — and
    `Transform.candidates_of/1` reads only the first, so the whole-call mutant vanished whenever the
    pattern also had a swap/wildcard.

Both are fixed by **re-homing** each whole-call `InPlace` into a `MacroPattern` branch of the *one*
tuple-export selector (`Analyze.rehome_call_mutations/2`): the branch runs the mutated call then the
export tuple (like a pattern mutant), and the candidate is stripped off the node so emission doesn't
*also* wrap it in a standalone selector. The **piped** form is the sharp case — the whole-call
mutation lands on the `|>` RHS *child*, which the child postwalk would otherwise emit as a selector,
making this site's baseline the illegal `pattern |> case … end` (a pipe into a `case`, which also
traps the bindings). The pipe clause of `rehome_call_mutations/2` pulls it off the child (the baseline
is then the bare `lhs |> stage`) and re-pipes the LHS into the mutated stage (`lhs |> <mutated>`).

The **`=`-match (`MatchPattern`) path looks like it needs the same mirror but does not**, and the
reason is worth recording because it's non-obvious and a later refactor could easily break it. A `=`
node is **never offered to mutators**: the dedicated `analyze({:=, …})` clause rebuilds it (LHS →
`:pattern`, RHS → context) *without* `offer`, and it precedes the generic runtime clause — so no
mutator, built-in or custom, can ever produce a whole-`=` `InPlace`. So `attach_match_pattern_candidates`'s
`put_candidates` has nothing to shadow, and there is no standalone-selector-traps-bindings case to
avoid. The asymmetry is deliberate: the macro node is offered *on purpose* (the `macros/0` feature),
the `=` operator has no "mutate the whole node" entry point. The invariant is guarded by a test
(`match_pattern_test.exs`, "a bare `=` node is never offered…"): a probe mutator that *does* match `=`
earns a site on an offered control node but **none** on the `=`. **If that test ever fails** — someone
makes `=` offerable (e.g. an assignment-mutator family) — a whole-`=` mutation of a value-discarded
binding match will then need the same re-home; the `mutant_expr`-carrying `MatchPattern` shape
(prototyped and reverted in this work) is the fix, mirroring `rehome_call_mutations/2` exactly.

### `use` expansion — surface directives hidden behind `use` `[done]`
Idiomatic Phoenix/Ecto hides `import`/`alias` behind `use`: `use MyAppWeb, :controller` injects a
bundle, `use Ecto.Schema` injects `import Ecto.Schema` (the `schema`/`field` DSL macros as **bare**
calls). Invisible to `Resolve`, this caused two pains on a real Phoenix app: (1) calls depending on
the injected directives don't resolve → **missed mutants**; (2) a bare `schema` resolves to
`module_key = nil`, so a registered `{Ecto.Schema, :schema, :any, :skip}` routing is **dead** (the
routing keys on the *resolved* module) — core descends into the DSL body, splices a selector into
`field :name, :string`, Ecto's macro rejects it → **the single build fails, nothing testable.** Both
are one root cause; `Mutare.Transform.Uses` is the positive fix (Phase 0 — graceful degradation so an
unroutable macro never sinks the build — is the separate floor).

**Mechanism (in-process, before `Resolve`).** `Uses.annotate/1` walks the parsed tree tracking the
enclosing module, and at each **module-level** `use` with **static-literal** args expands it and
stamps the harvested `import`/`alias`/`require …, as:` directives onto the node's
`meta[:mutare_use_directives]`. `Resolve.register/2` folds them through itself in source order, as if
written inline at the `use`. Why in-process is sound: the primary deployment is `{:mutare, …}` as a
dep run via `mix mutare`, so the app's deps are on the BEAM code path (NOTES "the target app's deps
are loadable"); the Mix task also best-effort-compiles the **current** project first so first-party
`use FooWeb` modules load (`ensure_host_compiled`, `copy_root == "."` only — an external-path target's
deps aren't on this process's path, so it degrades).

**Two non-obvious mechanics.** (a) `Macro.expand` is the wrong tool — it expands a `use` one level to
`require Mod; Mod.__using__(opts)` and stops (won't expand a remote macro call), and worse, fully
expanding the *result* turns a nested `use Bar` into `require Bar; Bar.__using__(...)`, which the
directive collector can't read. So we **`Macro.expand_once` the inner `Mod.__using__(opts)` call** (with
`Mod` added to `env.requires`, `env.module` = the using module for a faithful `__CALLER__`), leaving any
nested `use` intact for manual re-expansion (depth- + `seen`-capped). (b) The harvested directives are
**standard** quoted with bare module atoms (`{:import, _, [Ecto.Schema]}`) — a shape `Imports.register`
rejects — so each is **normalized back to Sourceror form** (`Sourceror.parse_string!(Macro.to_string(d))`),
making it indistinguishable from a textual directive; the existing register + live `function_exported?`
reflection + macro-routing then work unchanged (no new register clauses, no pre-normalizing imports to
`only:` sets). A `require …, as:` is rewritten to the equivalent `alias` (register doesn't read `require`).

**Mirror the caller env, not just `:module`.** `expand_using/4` builds the `Macro.Env` it expands
`__using__` under. Setting `:module` (for `__CALLER__.module`) and `:requires` (so the remote call is
expandable) isn't enough: a `__using__` may branch on **`__CALLER__.aliases`**, choosing an
import/alias from the caller's lexical bindings (`alias Enum, as: U; use AliasAware` → the macro reads
`U => Enum` and injects accordingly). Left at the default, `env.aliases` is *this module's own*
compile-time aliases (`AST`, `Aliases`), so the pre-pass harvested directives against the **wrong**
module and rewrote later bare calls accordingly — a real soundness bug. The fix threads the source
alias env (the `%{name => path | atom}` map the walk already folds for resolving the `use` *target*)
into the expansion env: `env_aliases/1` renders it into the `[{Elixir.Name, module}]` shape Elixir
builds (a single-segment name → its module atom via `Module.concat`; an Erlang atom module kept
verbatim — `[{U, Enum}, {B, :binary}]`). A **nested** `use`'s caller aliases are the source aliases
*merged with* the directives the enclosing body injected before it (`Map.merge(caller_aliases, env)`,
injected shadowing source), matching how the compiler expands a later nested `use` with earlier
injected aliases in scope. Only `:aliases` is mirrored — `__CALLER__.functions/macros/context_modules`
aren't, out of scope (the reported case is aliases). Tested in `uses_test.exs` via
`Mutare.Test.AliasAwareUsing` (a `__using__` that picks its import off `__CALLER__.aliases`).

**Mirror the implicit alias a nested `defmodule`/`defprotocol` introduces.** Elixir auto-aliases a
nested module's name when a body *defines* it: inside `Outer`, `defprotocol P` introduces `alias P =>
Outer.P`, so a later sibling resolves the short name. The walk's alias env recorded only explicit
`alias`/`require …, as:`, so two faithfulness bugs followed when a later `use`/`defimpl` referred to a
sibling by short name: `defmodule Outer do defprotocol P …; defimpl P, for: Integer do use X end end`
computed the caller as `P.Integer` instead of **`Outer.P.Integer`** (so a `__using__` deriving
imports from `__CALLER__.module` harvested for the wrong module), and `defmodule U …; use U` left the
`use` **unstamped** (`U` resolved to the unloadable top-level `U`, not `Outer.U`). Fix:
`register_defined_module/3` folds the implicit alias into the env for following siblings (via
`register_lexical/3`, the unified source-alias + implicit-alias fold used by both the module-body
walk and the top-level block). Subtlety verified against the compiler: the alias binds the **first**
written segment to the parent-prefixed first segment — `defmodule Foo.Bar` ⇒ `Foo => Outer.Foo`, *not*
`Bar => Outer.Foo.Bar` — so it is computed as `child_module/3` of just that first segment, stored as a
path so `resolve_path/2` extends it. Lexical (scopes only to following siblings, like an explicit
alias), and skipped for a dynamic/`Elixir.`-absolute/atom-named head. `defimpl` defines `P.T` but
introduces no short alias, so only `defmodule`/`defprotocol` are definers. Tested in `uses_test.exs`
(the `defimpl`-caller and short-name-`use` cases, plus the lexical-scope guard).

That implicit alias is in scope for **following siblings** *and inside the module's own body* —
`body_env/3` folds it into the env before `walk_body`, so in `defmodule Outer do defmodule Foo.Bar
do use Foo.Baz end end`, `Foo => Outer.Foo` resolves `use Foo.Baz` to `Outer.Foo.Baz` (and an
alias-sensitive `__using__` sees it via `__CALLER__.aliases`). Passing only the parent env would
resolve the body's short-name `use`/calls through an outer/top-level `Foo` or not at all.

**Normalize a harvested directive before folding it into the body env.** Within an expanded
`__using__` body, the env for later statements is advanced from the directives each statement
*yields* (so `alias … as: T; use T` resolves the `use`). Those harvested directives are **raw
standard-quoted**, where an `unquote(mod)`/`bind_quoted` alias carries its target as a **bare module
atom** (`{:alias, _, [Mutare.Foo, [as: T]]}`) — a shape `Aliases.register/2` silently no-ops on. So
`alias unquote(target), as: T; use T` bound nothing, `use T` didn't resolve, and the directives from
that nested `use` were dropped. Fix: `register_harvested/2` runs the same Sourceror `normalize`
(atom → `{:__aliases__, …}`) that `harvest` applies at the end *before* `Aliases.register`, so the
alias binds and the sibling `use` expands. (The stamped output already normalizes; only the in-body
*env fold* missed it.) Tested via `Mutare.Test.UnquoteAliasUsing`.

**Mirror the sandbox env without a fast-path data race.** The metamutant compiles/runs under
`MIX_ENV=test` but the scan often runs in `:dev`, so a `__using__` that branches on `Mix.env()` must
expand under `:test`. `with_sandbox_env/1` mirrors it: a `:test` base is the lock-free **fast path**
(nothing to swap), a non-`:test` base **swaps** the global `Mix.env` under a node-local `:global` lock
held for the whole expansion. The naive fast-path test `Mix.env() == :test` is a **race**: `Mix.env`
is node-global ETS state, so a `:dev`-base swapper's *transient* `:test` (set while it holds the lock)
can be read by a *second* concurrent transform, which then takes the unlocked fast path and keeps
expanding after the swapper restores `:dev` — harvesting the wrong-env branch. Fix: a node-local
**seqlock** (`@seq_key`, a one-slot `:atomics` counter) the swap bumps to *odd* on entry and *even* on
exit, **inside** the lock and bracketing the env mutation. A reader samples `seq → Mix.env() → seq`
and only trusts a `:test` reading when the seq was **even and unchanged** across it (no swap active
for even an instant). A transient `:test` is only ever visible while seq is odd, so it can't be
mistaken for the stable base. Crucially this keeps the **`:test` base lock-free** — there seq stays
`0` (no swap ever runs), so the high-concurrency test suite and property soaks pay only two atomic
reads, never the `:global` lock (whose retry backoff would serialize them). The atomics ref is created
once under a one-time `:global` init lock and shared via `:persistent_term`; correctness rests on ETS
(`Mix.State`) and `:atomics` each being internally synchronized, so the swapper's `odd` bump is
visible to any reader that observes its `:test`. Regression-tested by `Mutare.Test.SlowEnvSensitiveUsing`
(slow + env-sensitive) run concurrently in a `:dev` base across several rounds (the race is timing-
dependent, so rounds make catching it reliable; the fix passes every round deterministically).

**Degrades, never errors** (all wrapped in `try`): a non-loadable module (external target, or an aliased
`use Web` we can't statically resolve — `Uses` does no alias tracking), non-literal args (`use Foo, var`),
a `__using__` that raises (e.g. reads caller-module attributes), or an import gated behind a runtime
`if`/`unless` in the body — all become *no stamp* = the old unresolved behaviour. The stamp is stripped
before render (`Render.@internal_meta_keys`) and `use` is already pruned from mutation in `Analyze`, so
the directives are doubly invisible to the metamutant. `:expand_uses` (default `true`, `--no-expand-uses`)
toggles it; the default-on **changes mutant counts** on existing projects (new mutants; Ecto files that
failed to compile now compile). Tested via `test/support/using_fixtures.ex` (`__using__` fixtures, the
only vehicle — `examples/*` have no deps and are external) in `test/mutare/uses_test.exs`, including the
Ecto `:skip`-now-fires case with/without expansion.

**Isolate failure per `use`, not per bundle.** The "degrades, never errors" `try` was originally only
on `harvest/3` — the *per-top-level-`use`* boundary. But a bundle is recursive: idiomatic Phoenix's
`use MyAppWeb, :live_view` expands to a **block** that itself contains `use Gettext, backend: …`, whose
`__using__` runs `Module.put_attribute` on the (already-compiled) caller and **raises `ArgumentError`**.
That raise originates one level down, inside the *nested* `expand_and_collect(Gettext, …)`, and with the
catch only at the top it propagated through the enclosing block's `flat_map_reduce` and collapsed the
whole bundle to `{[], []}` — silently dropping the good `import Phoenix.LiveView` / `@behaviour
Phoenix.LiveView` sitting right beside the bad `use`. Fix: move the isolation onto **`expand_and_collect/6`**
itself — the recursion unit *and* the only site that runs a `__using__` (the only thing that can raise).
Now each `use` (top-level *and* every nested one) self-isolates: a raising `__using__` drops only its own
contribution while its siblings, harvested in the enclosing block, survive. Partial harvest is strictly
better than empty: every directive we keep expanded cleanly, and we never emit a half-baked one from the
failed `use` (the only loss is env-advancement for *its* injected aliases — already unavoidable, since it
couldn't expand at all). `harvest/3`'s outer `try` stays as a backstop for `standardize`/`normalize`. The
rescue is left **broad** (`rescue _` + `catch _, _`) on purpose: other `__using__`s raise other things
(`KeyError`, `RuntimeError`, …) for the same compiled-caller reason, so narrowing to `ArgumentError` would
be fragile. The bug was invisible precisely because the degradation is silent, so it's regression-guarded:
`Mutare.Test.BundleWithRaisingUsing` (a bundle mixing good directives with a nested `CallerMutatingUsing`
raiser that mirrors Gettext) in `uses_test.exs` asserts the siblings survive and only the raiser's own
directive is dropped.

### Behaviour detection — `@behaviour` set per module, surfaced to custom mutators `[done]`
A custom mutator often wants to fire *only* inside modules of a kind — the motivating case a
GenServer mutator that swaps a `handle_call` `{:reply, r, s}` to `{:noreply, s}`. The signal is the
module's `@behaviour` set, knowable two ways now that `Uses` expands `use`: **directly**
(`@behaviour Foo`) and **via `use`** (`use GenServer` injects `@behaviour GenServer` in its
`__using__` body). Goal: gather both, per module, and hand the set to custom mutators.

**Gather (`Transform.Behaviours`, a fourth pre-pass after `Uses`, before `Resolve`).** A small
module-scope walk folding an alias env (reusing `Aliases`), stamping each `defmodule`/`defprotocol`
with a `MapSet` on `meta[:mutare_behaviours]`: direct `@behaviour Foo` resolved through the alias env
in force (so `alias X, as: B; @behaviour B` records `X`, not the literal `B` — a *wrong* entry, not a
miss, if unresolved), Erlang atoms (`@behaviour :gen_statem`) kept as-is, unioned with the
`use`-injected set. The injected half piggybacks on the **existing** `Uses` expansion: a new `collect/6`
clause harvests `{:@, _, [{:behaviour, _, [mod]}]}` from the expanded `__using__` body (it appears as a
top-level statement there, reached by the same block/nested-`use` recursion that harvests
imports/aliases), tagged `{:mutare_behaviour, mod}` so `harvest/3` can split it from the
name-resolution directives and stamp `meta[:mutare_use_behaviours]` (read by `Behaviours.injected_behaviours/1`).
Only canonical `@behaviour` is recognised — Elixir **rejects** `@behavior` outright, so matching the
American spelling would be wrong, not lenient.

**Thread with zero new plumbing — the spec is already the universal carrier.** Behaviours are a
per-module fact, but the value threaded to *every* leaf where a mutator runs (`Mutator.mutations/3`,
the structural callbacks, `Tag`, `FunctionPlan`) is the `Spec` list. So we add a `behaviours` field
to `Spec` (empty default) and **re-bind it per module** at the few analyze/plan entry points
(`Transform.analysis_mutators/1` = `Enum.map(ctx.mutators, &%{&1 | behaviours: ctx.behaviours})`,
`ctx.behaviours` set save/restore per `defmodule`). The deep `analyze/3` recursion is untouched — it
already forwards the spec list opaquely; only `analysis_mutators/1` and `Mutator.mutations/3` (which
injects `spec.behaviours` into the `mutate/2` context, beside `:opts`) change. The alternative — a
threaded env bundling specs+behaviours — would have changed the *type* of the value passed through
~400 `mutators` references; the spec-field re-bind keeps the value a plain `[%Spec{}]` list, so every
existing `Enum`/`Spec.find` over it works unchanged. (It's a per-module fact on a per-mutator struct,
yes — but it rides the spec→context path *exactly* as `opts` does, so the framing holds.) Id stability:
behaviours are a deterministic function of the static source, so the same module re-binds the same set
across poison rebuilds — ids stay put.

**Structural callbacks get behaviour-aware arities.** `mutate/2` reads `context.behaviours` directly;
the structural hooks (`return_replacements`/`condition_replacements`/`pattern_mutations`) take only a
node, so each gains a `+1`-arity variant taking a `%{behaviours: …}` context. `Mutator` centralises
the dispatch (`return_replacements/2` etc. call the context arity when exported, else the base) and the
discovery (`implementing_any(specs, fun, [base, base+1])`), so a mutator implements *either* arity and
the four call sites stay one-liners.

A direct `@behaviour` named through an alias resolves correctly whether the alias came from
`alias X, as: B` *or* `require X, as: B` — `Aliases.register/2` now folds **both** (Elixir's `:as`
on `require` "sets up an alias"; this also closed the matching latent gap in `Resolve`, so a call
through a require-introduced alias resolves too, and let `Uses` drop its private require→alias rewrite).

**Scope / degradations (documented, not bugs).** `defimpl` bodies see the empty set (a defimpl is its
own module, rarely behaviour-bearing, and reaches mutation by a different path);
`--no-expand-uses` keeps direct behaviours but drops use-injected (same class as `Uses`'
directives vanishing). Tested in `test/mutare/behaviours_test.exs` (gathering: direct/aliased/require-as/Erlang-atom/
top-level-alias/`use GenServer`/custom+transitive `use`/union/no-inherit/`expand_uses: false`; delivery:
`mutate/2` + `return_replacements/2` fire only under the behaviour, via `test/support/behaviour_mutator.ex`
and the `Mutare.Test.Sample{Behaviour,Using}` fixtures).

### GenServer return mutator — the first behaviour-gated built-in `[done]`
The payoff of behaviour detection: `Mutare.Mutators.GenServer` (`:genserver`, default-on) mutates a
`handle_call`/`handle_cast`/`handle_info`/`handle_continue` **return tuple** into a *different but
still valid* OTP return, gated on `context.behaviours` containing `GenServer` (so inert everywhere
else). It complements `ReturnValue`: ReturnValue swaps a tail for a *sentinel* (the server gets a
malformed return and crashes — an uninformative kill), whereas this swaps the *control tag*
(`:reply`→`:noreply`, `:noreply`↔`:stop`, the 4-tuple stop-with-reply→reply) so the mutant is a
well-formed GenServer that *behaves* differently — a survivor pinpoints an unchecked reply/liveness
semantic.

Two non-obvious mechanics. (1) **Shape, not function name.** `return_replacements/2` sees only the
tail node + behaviours, never which callback it is in — but the return *shapes* are unambiguous by
`{tag, arity}` (`:reply` only ever appears in `handle_call`), so it dispatches on those and never
needs the function name (threading it would be a bigger API change for no gain). A `{:ok, _}`
(init), `{:stop, reason}` (2-tuple init form), or any non-OTP tuple simply doesn't match. (2) **The
2-tuple wrap.** A bare 2-tuple literal `{:noreply, state}` has no metadata slot, so I first feared it
couldn't carry a return candidate — but Sourceror **wraps every 2-tuple literal in a single-element
`__block__`** to anchor its line info (`{:__block__, meta, [{tag, state}]}`), which *does* have a
slot, so the candidate attaches and even multi-statement `{:noreply, s}` tails mutate. The mutator
unwraps a single-element block and recurses, then matches the 2-tuple (`{tag, state}`) or the
3/4-tuple (`{:{}, _, [tag | rest]}`). Results are built as explicit `{:{}, [], …}` nodes (renders as
a literal tuple at any arity) reusing the original `state`/`reply` operands + injected control atoms,
so every mutant compiles as a valid GenServer return. Registered default-on because GenServer is
dependency-free OTP core (unlike the Ecto example, which needs a dep and stays a custom mutator);
tested in `test/mutare/gen_server_test.exs` (full swap table, behaviour gate, multi-statement tail,
non-callback shapes untouched, metamutant compiles).

### Capture mutation — `&Mod.fun/N` is a call value `[done]`
A `&Mod.fun/N` **reference** capture is `fn a… -> Mod.fun(a…) end`, so the call-matching
families carry the same signal on it as on a written call: a rename (`&String.first/1` →
`&String.last/1`) or a removal (`&String.upcase/1` → `&Function.identity/1`, the capture
analogue of CallRemoval's "does this transparent transform matter?"). Previously the whole
capture was pruned (the `:capture_arity` clause returned the node raw); now
`Transform.Analyze.Captures.offer/4` mutates it.

**Reuse, don't re-list (the design constraint).** It does *not* re-encode CallRemoval's
`@removable` or any swap table. The capture is **probed**: synthesize the equivalent N-ary
call `Mod.fun(v1…vN)` (N from the `/arity`, args fresh placeholders), offer it through the
ordinary `Mutator.mutations/3` path every call position uses, and re-capture each mutant. So
every call-matching mutator — built-in *or* a custom CallRemoval-style one — participates with
its **existing** `mutate`/`mutate/2`, no capture-specific callback and no second list.

**Why it isn't "just eta-expanding them."** The synth call is a *transient probe* — never
emitted. The emitted selector keeps the **verbatim** `&Mod.fun/N` as its baseline branch, and
each mutant is a **re-built** capture, read off the probe's output shape:
- a rename's output is `Mod'.fun'(v1…vN)` reusing the placeholders in order (`swap_call`
  rebuilds with the arg list verbatim) → strip args, re-wrap `&Mod'.fun'/N`;
- a removal's output is the bare first placeholder `v1` (CallRemoval non-piped returns the
  first arg) → the arity-N first-arg projection: `&Elixir.Function.identity/1` for N = 1, or
  `fn a, _… -> a end` for N > 1 (no named "project first of N" exists);
- anything else (an arity change — CollectionArity/DefaultDrop reuse *fewer* args; a
  non-recapturable custom output) → dropped.

That recapture filter is the cohort selector — **no allow/deny list**. It admits exactly the
renames + removals and excludes the arg-manipulating families for free: an arity change can't
re-wrap at N, and ModeSwap never fires on a var placeholder.

**The identity invariant (why baseline must stay verbatim).** `&M.f/a` is an *external* fun,
compared by MFA, so the emitted baseline (the literal capture) is `==`/`===`/map-key/MapSet-
equal to a hand-written `&M.f/a` — identity is preserved at mutant 0. A rename mutant
(`&M'.f'/N`) is likewise a real external fun, so an identity-pinning test kills it for the
right reason; the N > 1 removal projection is an anonymous `fn` (unequal to *any* external
fun), but it lives **only** in a mutant branch — where a divergent identity is a legitimate
kill, never a baseline divergence. The one fatal move — eta-expanding the *baseline* into a
`fn` (`fn x -> M.f(x) end != &M.f/a`) — is exactly what the probe-then-recapture structure
avoids. This is also why coverage records at value-production (see "production-site coverage
recording"): a capture mutant is killable by identity comparison with the function *never
invoked*.

**Scope: remote only.** `&Mod.fun/N` (Elixir, alias-resolved through the synth call's own node
— `&E.first/1` for `alias String, as: E` keeps the `E.` in the diff) and `&:mod.fun/N` (Erlang
atom module) both route. A **bare/local** capture (`&reject/2` after `import Enum`, `&local/1`)
is deferred: its ref carries no import stamp (`Resolve` stamps bare *calls*, and a capture ref
is not one), so the synth bare call wouldn't resolve — `synth_call/2` returns `:error` and the
node is left pruned. Nested captures (a capture inside another `&`) are illegal source, so they
never reach the clause; `& &1 / 2` (the shorthand, not a reference) still recurses and mutates
its body unchanged.

**Runtime-context only.** `offer/4` is called *only* when the capture clause sees `:runtime`. A
genuine capture reached in a non-runtime context — a module-level **`:scaffold`** statement
(`for fun <- [&String.first/1] do def … end`) whose expressions run once at compile time with
mutant 0 — is left raw, exactly like every other scaffold position: a selector there could never
activate or record coverage at test time, so it would only mint an inert no-coverage mutant (the
very thing the scaffold context exists to avoid). A capture in a `def` *body* (or a `\\` default
value, which flips back to `:runtime`) reached *from* a scaffold still mutates — the def clause
restores `:runtime`. Originally `offer/4` ran context-blind and wrapped the scaffold capture too;
the guard is in the `analyze` capture clause, not in `Captures` (placement is positional, the
caller's job).

### Mutating inside a foreign-semantics DSL — the selector host (Ecto `from`/`where`)
The hard case a *deep* custom mutator hits: mutating **inside** a compile-time DSL (Ecto's
`from`/`where`) where you can't reach `:persistent_term` with a bare selector (the `case` would
poison the single build, since the DSL doesn't compile arbitrary Elixir), and whose body has **SQL
semantics, not Elixir's**. Worked against a hypothetical external Ecto library — a dep-bearing custom
mutator, never a built-in (unlike GenServer, dependency-free OTP). Most of what it needs already
existed (identity/skip of the DSL via the known-macro registry + `use`-expansion; plain call/behaviour
mutations via `Calls`/`context.behaviours`; a **basic** library works *today* by `:skip`ping the whole
`from` and returning the whole mutated query through the ordinary in-place selector). The two
extensions here are strictly about **localization + scale** — wrapping the *whole* query per mutant
duplicates it and blows up (`(mutants+1)^depth`, the pipe-hoist pathology). Both now exist:

**#1 — mutator-supplied selector host (the delivery seam, `c:Mutare.Mutator.host/2`).** You can't
splice `case :persistent_term.get(...)` into a query, but Ecto's `^` + `dynamic/2` injects a
runtime-chosen fragment the query *actually runs* (exactly one branch bakes in, the active id being
constant per run):

```
where: ^case mutare_active do
         123 -> dynamic([u], u.age >= ^min)
         mutare_active -> mutare_active == 0 and … and MutareCov.hit([123]); dynamic([u], u.age > ^min)
       end
```

The delivery is private to the emit layer (mutant **ids**, the selector **subject**, **coverage**,
the **Site**), so a library can't reach it. The fix opens the already-parameterized binding-export
seam (`emit_binding_site`, shared by the `=`-match/binding-macro tuple-export rewrites) to a mutator:
per **target** the host hands core `{logical original, logical mutants}` + two pure transforms — `wrap`
(each branch → `dynamic([bindings], _)`; default **identity**) and `splice` (a `(macro_node, case_node)
-> macro_node` weaving the woven `case` into a copy of the node, `^`-pinned). **Core builds the `case`**
from its own `subject_ast` + `<id> ->` clauses, assigns ids, records **one `:in_place` `Site` per
logical mutant** (the diff is `u.age > ^min` → `u.age >= ^min`, the `dynamic`/`^`/selector scaffolding
invisible — exactly as the tuple-export Sites hide theirs), emits the coverage catch-all, and hands the
assembled `case` to `splice`. The single rule that makes this safe to expose: *don't hand the mutator
ids and let it build its own `case`; hand it `wrap`/`splice` and let core build the selector.* That
keeps the four cross-cutting contracts in core — compile-once, contiguous poison-stable ids, coverage,
poison line-mapping — and makes poison/manifest work **for free**, because the emitted selector is still
`Metamutant.subject?/2`-recognizable (the `^` is just an outer node a `Macro.traverse` walks past). The
host is handed the **whole macro node** (not the leaf) so the library can pull the `from` bindings for
`wrap`. Binding-reorder rides the same seam (`where([a,b], …)`→`[b,a]` ≡ an alternative *body*, no
separate path). Lands as `Transform.Candidate.Hosted` + `Transform.emit_hosted_site/3` (the `:mutare_hosted`
meta key — a third emit alongside `:mutare`/`:mutare_case`) + `Mutator.host_targets/3` (the validate/
default-`wrap` normalizer). Multiple targets fold over the node (each `splice` replaces its own
position); a whole-node `:mutare` mutation on the *same* node still rides an ordinary selector wrapping
the spliced result (`emit_site/3`) — a no-op when there is none, the common case.

**#2 — a `:hosted` macro-arg treatment + shape-aware routing (`c:Mutare.Mutator.macro_routing/1`).**
Treatments were a closed set only core's analyzer reads. `:hosted` (now in `Macro.Spec.@treatments`)
means "don't splice a *bare* selector here (it'd poison the DSL) — route this position's mutations
through the mutator's host (#1)." It must also be chosen per **call shape**, which a static per-position
list can't express: `where(q, category: "Foo")` is plain data (`:expression`, mutate the value in place)
while `where(q, [u], u.x == u.y)` is `:hosted`. So `args` may be the **`:routing` sentinel**, deferring
the per-position routing to the mutator's `macro_routing(call_node)` — consulted by `Resolve` with the
concrete node, returning routing for the node's **visible** args (so it rides whole on `@macro_key` with
no piped split; a builder's piped value `q` is an ordinary `:expression` analyzed by the `:|>` LHS
clause). `Resolve` rewrites each `:hosted` → `{:hosted, host}` (the hosting mutator, stamped on the spec
by `Macros.from_mutators/1`, so the analyzer can reach the right `host/2`); `route_macro_arg/3` leaves a
`{:hosted, _}` position **raw** (like `:skip`), and `analyze_known_macro` attaches the host's targets.
A declarative `:macros` entry can't use `:hosted`/`:routing` (no host to deliver/answer) — `Macros.build/2`
raises (`Macro.Spec.host_required?/1`). Both shapes (direct + piped builder) route; the fixture
(`test/support/host_mutator.ex`, `Mutare.Test.{HostDSL,HostMutator}`) and `test/mutare/hosted_test.exs`
prove the full machinery — classifier, host seam, core-built selector + ids + Site + coverage + poison —
without an Ecto dependency (a fake `filter/2` macro whose woven `case` is spliced straight into the
condition, no real `^`).

**The trap — do NOT reuse core mutators inside the fragment (rejected, on purpose).** Tempting ("run
Relational's `>`→`>=` table inside the query via `wrap`"), but the core mutators encode **Elixir**
semantics and cannot vouch for SQL's. Concretely `a < b or a > b` — under *equivalent-sibling
suppression* — is judged constant and a redundant sibling dropped: sound under two-valued logic, **wrong**
under SQL's three-valued logic, where it is `NULL` whenever either operand is. A reused mutator thus
silently drops a *real* mutant — a false negative manufactured at a semantic boundary core never
targeted. So the host owns the whole catalog: core exposes the delivery seam (#1) and the routing (#2),
and **none** of its mutation logic. (This is *why* the host returns logical `mutants`, not why core
mutates the raw fragment — `:hosted` leaves it raw.)

**Four sharp edges — one made correct, the other three made loud rather than silent.**

  * *A hosted macro that **also** binds escaping variables.* A `:hosted` argument and a
    `:binding_pattern` argument can land on the *same* known-macro call in a value-discarded position
    (`pick([a, b], x > 1)` — arg 0 the escaping pattern, arg 1 the hosted comparison). That node then
    carries **both** a `Candidate.Hosted` (under `:mutare_hosted`) and a `Candidate.MacroPattern`
    (under `:mutare`, attached by `MatchPatterns.attach_macro_pattern_candidates/4`). The bindings
    *escape*, so the MacroPattern can't ride an ordinary node-wrapping selector (which would trap them
    in a branch and emit a bare mutated-pattern AST — `[b, a]` — as the branch body, referencing
    unbound vars: the metamutant won't compile). So after weaving the hosted selector into the
    fragment, `emit_hosted_site/3` dispatches the leftover `:mutare` candidates exactly as the
    un-hosted path does (`emit_hosted_inplace/3`): a `MacroPattern` head routes to the tuple-export
    rewrite (`emit_macro_pattern_site/3`), whose **baseline branch is the spliced macro** — so the
    hosted comparison mutants still fire there while the pattern mutants re-export the bindings through
    `{a, b} = case … end`. Everything else (an ordinary whole-call `InPlace`, or none) rides the
    ordinary `emit_site/3` selector wrapping the spliced result. (A macro node is never a `=`, so
    `MatchPattern` can't occur on this path.) Without the dispatch the hosted path sent the
    MacroPattern straight through `emit_site/3` and broke any binding-escaping hosted macro.

  * *Duplicate-configured host mutator.* A host is a **module**, but a configurable host mutator may
    be enabled under several `Mutare.Mutator.Spec`s with distinct `:as` names / `opts`
    (`{Host, as: :a}`, `{Host, as: :b}`). Each is its own family (own name on its Sites, own `opts`
    into `host/2`), exactly as the ordinary path runs every spec in `Mutator.mutations/3`. So
    `attach_hosted_candidates/5` hosts **every** spec whose `module` matches the stamped host
    (`Enum.filter` + `Enum.flat_map`), not just the first (`Enum.find`) — else a duplicate config
    silently drops every instance past the first, and all hosted Sites mis-carry the first's name.

  * *A static `:hosted` at the piped-value position is undeliverable.* `host/2` is handed the **macro
    node**, whose args are the *visible* ones — never the `|>` LHS. So a static `args` routing
    effective-position-0 as `:hosted` can't be hosted the moment that macro is piped (`frag |>
    rotate()`), and silently leaving the LHS raw would drop the mutation without a trace.
    `Resolve.reject_piped_hosted!/3` raises instead, pointing at the supported escape hatch — the
    `:routing` classifier rides on the **visible** args (never the piped value), so a
    shape/position-dependent host belongs there. (Direct calls host argument 0 fine — it is visible.)

  * *A `:routing` classifier routes `:hosted` but the mutator omits `host/2`.* A `:routing` spec is
    **not** required to implement `host/2` at *build* (`Macros.build/2` only demands `macro_routing/1`
    of it) — a classifier may legitimately route every position to `:expression`/`:pattern` and never
    host. But the moment `macro_routing/1` *does* route a position `:hosted` with no `host/2` to
    deliver it, `route_macro_arg/3` would leave the fragment raw and the intended mutation would
    vanish without a trace. `Resolve.reject_undeliverable_hosted!/2` (the classifier-path analogue of
    `reject_piped_hosted!/3`) raises at resolve — the first point the undeliverable `:hosted` is
    known — naming the missing `host/2`. (A *static* `:hosted` without a `host/2` is caught earlier
    still, at build, by `Macros.validate_host!/3`.)

  * *Per-keyword-pair routing — `{:keyword, value_treatments}`.* Routing is per *visible argument*, so a
    keyword-list argument is one routing decision: `:expression` mutates its keys **and** values (and
    every pair), `:skip` mutates nothing. Ecto's keyword-shorthand `where(q, category: "Foo", deleted_at:
    nil)` needs neither — mutate `"Foo"` (core's literal families) but **not** the column-name key
    `category`, and skip the `deleted_at: nil` pair (it is `IS NULL`, not `= nil`). `call_option_keys:
    false` is all-or-nothing per mutator, not per pair. So the `:routing` classifier may return, for a
    keyword-list position, `{:keyword, value_treatments}`: `route_macro_arg/3` routes each pair's *value*
    by its own treatment (positional, missing → `:skip`) and leaves every *key* raw. A value treatment may
    itself be `{:keyword, …}`, so a nested shorthand (`from(S, where: [x: v])` — a keyword list whose
    values are keyword lists) routes too, and `route_keyword/3` unwraps the Sourceror `{:__block__, _,
    [list]}` a list takes in a keyword *value* position (vs. the bare list of a trailing keyword argument).
    Classifier-only (a static `args` can't produce it — `Spec.routing/2` only emits validated atoms), and
    a non-keyword argument under it falls back to raw, so a mis-classification never splices into a
    non-pair. This is the third foreign-DSL extension after the host (#1) and `:routing`/`:hosted` (#2):
    it unblocks `mutare_ecto`'s shorthand-split + `nil`-pair exclusion without the plugin re-implementing
    core's literal families. Tested via the `set/2` fixture macro (`Mutare.Test.HostDSL`/`HostMutator`).
    A keyword *value* is narrowed to `t:Mutare.Mutator.keyword_value_treatment/0` — every treatment
    **except `:hosted`**. The recursive arm originally reused the full `routing_treatment` (which
    *includes* `:hosted`), but a keyword value can't be hosted: hosting delivers through `host/2`,
    which weaves into the **whole macro node** (#1), and core has no per-keyword-value host delivery, so
    `inject_host/2`/`hosted_host/1` only recognise a *top-level* `{:hosted, host}`. A `:hosted` nested in
    a `{:keyword, …}` would slip past both — left raw and never hosted (a silent miss), or, but for the
    `route_macro_arg/3` raw-`:hosted` backstop, spliced as a bare selector into the DSL value (poison).
    Rather than make injection/detection recurse for an untested, marginal capability (host the *whole*
    keyword argument `:hosted` if you must reach a value inside it), the type is narrowed and the
    classifier output is validated at stamp time (see *classifier output is validated* below), fail-loud
    over silent-drop. A deeper `{:keyword, [{:keyword, [:hosted]}]}` is caught too (the validator
    recurses). Tested via `Mutare.Test.KeywordHostedMutator` (`hosted_test`).

  * *Classifier output is validated — `Resolve.validate_routing!/2`.* A `:routing` classifier's return
    is **untrusted input**, but only its hosted corners were originally checked. An unrecognised or
    mis-shaped treatment (`:expresion` typo, `{:keyword, non_list}`, a non-list return, or a keyword-value
    `:hosted`) would otherwise fall through `route_macro_arg/3`'s `:expression` catch-all and *silently
    mutate* a position core was asked to skip/host/pin — a wrong-position mutation or a poison.
    `validate_routing!/2` (the classifier analogue of `Macro.Spec.validate_args/1`'s build-time check for
    static `args`) recurses the **raw** output (pre-`inject_host`) and raises with the offending value;
    its one positional rule is that `:hosted` is valid for a whole argument but not a keyword value (the
    keyword-hosted case above folds into it). The recognised atom set is derived from `Spec.treatments/0`
    (+ `:pinned`) so it can't drift. It subsumes the old `reject_keyword_hosted!/2`. Tested via
    `Mutare.Test.UnknownTreatmentMutator` and a non-list-returning classifier (`hosted_test`).

  * *`:pinned` — `^`-pinned in-place mutation.* Per-pair routing alone isn't enough for the shorthand
    split: a shorthand value sits **inside** Ecto's query macro, which rejects a bare selector `case`
    (`where(q, category: case … end)` → "unbound/`case` not supported") but accepts the interpolated
    `where(q, category: ^(case … end))`. So core can't mutate a shorthand value with its ordinary
    in-place selector — the same wall the host (#1) climbs for *conditions*, but here the mutants are
    core's literal families, not the plugin's catalog. New value treatment `:pinned`
    (`route_macro_arg/3`): analyze the value as ordinary runtime so the configured families attach
    their `Candidate.InPlace`s (their **own** family name reaches the Site — `:string`/`:literal`, not
    the host), flag those candidates `pin?`, and `emit_site/3`'s `pin_if_needed/2` wraps the built
    selector in `{:^, [], [case]}`. Contained: `pin?` defaults false and is set only by `:pinned`, so
    every existing site is byte-identical; a bare `^` is a compile error elsewhere, so `:pinned` is
    routed only where the macro interpolates. Scalar-only — `pin_inplace_candidates/1` pins only the
    value node's **own** candidates, so a compound value (`[1, 2]`, `%{…}`) attaches candidates to
    *descendant* nodes that pinning misses, where an inner bare `^`-less selector still poisons. This
    scalar-only contract is **enforced**, not just documented: `reject_non_scalar_pinned!/2` walks the
    analyzed value and raises if any in-place candidate sits below the top node (the offending value in
    the message), rather than silently degrading those inner mutants to `:poisoned` (the recall-loss the
    classifier-trust audit surfaced). A non-literal value with no candidate at all (a bare variable) is
    fine — nothing to pin. This is why the DESIGN's "shorthand values are plain interpolated Elixir,
    *not* hosted" was half-right: the value *mutation* is core's (not the SQL catalog), but the
    *delivery* must be pinned, not a bare selector. Tested via `Mutare.Test.CompoundPinnedMutator`.

  * *Per-mutant report note — `Site.note`.* A hosting mutator may want to flag a *live, scored* mutant
    with advisory text the report shows on a survivor — `mutare_ecto` tags its equivalence-sensitive
    families (`:comparison`/`:connective`/`:null_predicate`) "kill may require NULL/boundary data", so a
    survivor reads as honest SQL-three-valued-logic signal, not a plain test gap. Distinct from
    `ignore_reason` (which *suppresses* a mutant). New optional `Site.note` (default `nil`), set via
    `Site.in_place/7`. The channel is per-mutant on the **host target**: a target's `mutants` entry is
    now a bare node *or* a `%{node:, note:}` map (`Mutator.normalize_target/1` → `{node, note}` pairs on
    `Candidate.Hosted.mutants`; `weave_hosted_target`/`hosted_site` thread the note to the Site). The map
    form is used (not `{node, note}`) because a quoted 2-tuple AST (`{a, "str"}`) would be ambiguous with
    a `{node, note}` pair; a map never collides. `Mutare.Report.header/1` appends `  — <note>` to the
    `SURVIVED` line (mirroring `ignored/1`'s reason suffix) and the JSON report emits it as `description`.
    Fourth foreign-DSL extension; contained — `note` defaults `nil`, the non-host `in_place/6` callers are
    unchanged, and a bare-node host mutant still works. Tested via the `filter` fixture noting its
    boundary flip but not its reversal (`hosted_test`).

**Explicitly not needed.** `context.uses` — every Ecto target self-identifies *node-locally* (a resolved
call or a known macro), unlike a GenServer return tuple (shape-ambiguous, *does* need module context); the
node never has to ask the module who it is. `opts` for `macros/0` — Ecto's macro set is fixed. Caveat
inherited from `Uses`: an external-path target whose deps aren't on the task's code path won't expand
`use Ecto.Schema`, so schema-skip silently degrades and the body poisons — run mutare **as a dep of the
app under test**, the supported deployment.

### Module aliases mutate only as a value (AliasLiteral)
`AliasLiteral` (`:alias`, default-on) rewrites a module alias used **as a value**
(`apply(Foo, …)`, `is_struct(x, Foo)`, `[A, B]`, a behaviour/strategy arg) to the
sentinel `Mutare.Mutant`. The "as a value, not as a name" rule is almost entirely
*free* from existing positional routing:

  * **Call-module position** (`Foo.bar()`) — the `{:., _, [mod, fun]}` dot lives in
    the call node's *form* position, and `recurse/3` only descends into `args`, never
    `form` (the same reason `:erlang.foo()`'s `:erlang` is untouched). So the call
    module is never reached — no special case needed.
  * **Struct name** (`%Foo{…}`) — the `:%` clause keeps the alias arg raw (it already
    did, for the struct-map exclusion).
  * **`defmodule` name** — handled at `transform_node` (only the body is transformed).
  * **Directives / `@behaviour` / specs** — already pruned (`:compile_time`).

The one *new* exclusion alias forced: `defimpl`/`defprotocol`/`defdelegate` carry
compile-time module references (protocol name, `for:` type, `to:` target) that a
selector can't legally replace — they'd poison (and, in protocol-heavy code, risk
exhausting `@poison_attempts`). `defprotocol`/`defdelegate` are pruned whole (no
runtime body lost); `defimpl` keeps its **body** mutating (`analyze_defimpl_arg/2`
analyzes only the `do:` value, passing the protocol alias and `for:` type through
raw — handling both the block and inline keyword shapes). Alias mutation is more
aggressive than the literals (it makes nonexistent-module references that crash when
invoked), but it stays compile-safe: an alias-as-value is just an atom, so a
reference to a missing module compiles and only fails when actually called — the kill.

### Bitstring collapse and the sigil non-descent (BitstringLiteral)
`BitstringLiteral` (`:bitstring`, default-on) collapses a non-empty `<<…>>` to `<<>>`,
the binary sibling of List/Map/Tuple emptying. To offer the `<<…>>` *node* (not just
its segments) the `<<>>` analyze clause gained a runtime arm that builds a candidate
from the raw node while keeping the analyzed segments underneath (so byte/string/expr
selectors stay reachable); a pattern `<<a, b>>` is the non-runtime arm and is only
descended.

Three constructs share the `{:<<>>, …}` shape, and only the first should collapse:

  * a real `<<…>>` literal — *no* `delimiter` in its meta → collapse;
  * an **interpolated string** `"a#{x}b"` — a `<<>>` *with* `delimiter: "\""` →
    skipped by *this* mutator (the empty-bitstring collapse is the wrong shape); it
    is StringLiteral's domain, which mutates the whole interpolated string to
    `""`/`"mutare"`. Its inner expressions still mutate either way (the node is
    descended);
  * a **sigil's content** `<<>>` (inside `~r/…/`, `~D[…]`) — *also* has no delimiter,
    so it is indistinguishable from a real literal at the node. The fix is in the
    analyzer, not the mutator: the generic runtime clause recognises a sigil
    (`sigil?/1`, an atom-prefix test covering `~r`/`~D`/`~w`/custom), offers the whole
    node to the sigil mutators, then descends *surgically* via `descend_sigil/2` —
    it analyzes the content `<<>>`'s **segments** (so an interpolated expression like
    `~r/a#{b}c/` still mutates `b`, and a genuine bitstring written *inside* an
    interpolation still collapses) but never offers the content `<<>>` **wrapper**
    itself. A selector spliced into sigil content (or BitstringLiteral collapsing it)
    is illegal; routing through the segments instead of the wrapper keeps interpolated
    sub-expressions mutating while the wrapper stays safe.

### Type-pin binary-valued bitstring segments as `::binary` `[done]`
A bitstring segment's *default type* is decided syntactically, and only an **untyped
literal** binary defaults to `binary` — `<<"x">>` ≡ `<<"x"::binary>>`. The moment a
mutation wraps that segment in a selector `case` (StringLiteral on the string,
StringSigilLiteral on a `~s`, or the segment being an interpolated string) it stops being
a literal, so Elixir reverts it to the **integer** default and construction raises
*"expected an integer"* — at the **baseline too** (`<<"x">>` → `<<(case … end)>>`, whose
catch-all is still `"x"`). This is a baseline-equivalence break, the worst kind: it sinks
the whole "compile once" run, not just one mutant.

Fix lives in the analyzer, not the mutators (placement is positional — a mutator must not
know it sits in a bitstring): the runtime `<<>>` *construction* arm routes each segment
through `analyze_construction_segment/2`, which pins `::binary` on a **binary-valued
literal** segment (`binary_valued_literal?/1`: a string `{:__block__, _, [bin]}`, a
`delimiter`-marked interpolated `<<>>`, or a `~s`/`~S` sigil). The sigil arm keys on the
parser's `:delimiter` meta, **not the head atom** — a call to a *function* named
`sigil_s`/`sigil_S` (a local sigil shadowing `Kernel`'s) parses to the same `{:sigil_s, …}`
head but carries no `:delimiter` and may return an integer, so `<<sigil_s("ab", [])>>`
(≡ `<<2>>`) must stay an integer segment; pinning it would itself break the baseline.

The **same `:delimiter` gate** is needed one level up, on sigil *routing*: `analyze`'s sigil
arm (`sigil?/1` → `descend_sigil/2`) was head-atom-loose, so a call like `sigil_r(<<"x">>, [])`
(a function literally named `sigil_r`, bitstring arg) was descended as if the `<<"x">>` were
*sigil content* — its inner string segment getting a StringLiteral selector with **no**
`::binary` pin (sigil content is descended via `analyze_segment`, not the construction arm),
breaking the baseline exactly as above. The routing now also requires `:delimiter`, so a
sigil-named *call* falls through to `recurse_runtime`, which analyses its `<<…>>` arg as the
real construction it is (pinned). `StringSigilLiteral` carries the same `:delimiter` guard for
the same reason (the other sigil families are already shielded by their `is_binary(content)`
shape guard — a hand-written `<<"x">>` segment is a *wrapped* `{:__block__, …}`, not the bare
binary a real sigil's content is). All three checks — the pin, the routing, the `~s` mutator —
key on the one parser-authoritative "this is sigil syntax" signal. Semantically a no-op
(`<<"x">>` ≡ `<<"x"::binary>>`), so the baseline and every mutant construct correctly; the
report still diffs the bare value (it patches the original source, not the metamutant). An
already-typed segment (`::utf8`/`::binary`/`size(expr)`) is passed through untouched, and an
integer/float/expression segment is left alone — its integer default is correct (and an
*untyped* non-literal binary/float, e.g. `<<some_str>>`/`<<1.0>>`, is already invalid source
that raises without any mutation, so there is nothing to protect). The pin is scoped to the
**runtime construction** arm only: a pattern `<<a, b>>` never gets a selector, so pinning
there would be wrong and is not done. The `delimiter` discriminator splits the two `<<>>`
arms — a real bitstring (construction, pin) vs an interpolated string (string content,
descended as ordinary segments). See `transform_corpus_test.exs`
("bitstrings: … stay binary-typed under a selector") and the `bitstring_gen` /
`interp_string_gen` property generators.

### Guard tagger is now bitstring-spec-aware `[done]`
`tag_targets/3` (the lifted-guard path) used to be a blind descent that ran
mutators on every guard node. A multi-specifier bitstring *construction* is a
legal guard (`def f(x) when <<x::integer-size(8)>> == <<0>>`), so the walk would
offer the `-` separator to Arithmetic and lift `<<x::(integer + size(8))>>` — an
"unknown bitstring specifier" that poisons the whole build. Exotic and
poison-backstopped, but a wasted rebuild cycle, so it is now fixed at the source.

`tag_walk/3` gained a `{:<<>>, …}` clause plus `tag_segment/3` / `tag_spec/3`,
the mechanical twins of `analyze/3`'s `analyze_segment/3` / `analyze_spec/3`: a
segment's *value* side is tag-walked, the *spec* side stays raw except `size(expr)`
args (the one runtime sub-position — a literal/operator there still lifts a mutant).
The `<<…>>` node itself is still offered (BitstringLiteral collapses it to `<<>>`).
Not literally *shared* code — the two walkers have incompatible accumulator shapes
(the analyzer returns a node and attaches `Candidate.InPlace` to meta; the tagger
threads `{node, acc}` and tags nodes) — but parallel clauses cross-referencing each
other, the same deliberate mirroring already established for `tag_walk` vs the
analyzer's `recurse` (descend args, never the form).

### Head-pattern literals are lifted `[done]`
A literal in a `def`/`defp` *head* — `def f(1)`, `def f(%{1 => 2})`,
`def f(:go)` — can't be mutated in place (a selector `case` is illegal in a
pattern), so for a long time heads were left untouched (the in-place `:pattern`
routing skips them). Now they are mutated by the **same lift machinery as guards**:
`FunctionPlan.build_pattern_literals/3` tags each mutatable head literal in the
shared tagged clause group (continuing the guard tag counter so tags are unique
group-wide), and each `Candidate.Pattern` materializes a `__mut` copy with that one
literal swapped — `def f(2)`, etc. The `Site` is a `:lifted` replace, identical in
shape to a guard's (`Site.lifted_replace/6`), with the literal mutator's name.

Consequences worth knowing:
- A function now lifts if it admits a guard swap, a head-pattern literal swap, **or**
  a clause drop — so a single-clause, unguarded `def f(1)` lifts solely to carry its
  head mutant (the dispatcher widens the public function's domain, but the observable
  result — a `FunctionClauseError` for an unmatched input — is preserved, exactly as
  for any other lifted function).
- **Only literal-valued mutations** are admitted in a head: `tag_pattern_targets/3`
  offers a node to the mutators *only* when it is a scalar literal and keeps a
  mutation *only* when its replacement is also a scalar literal. That selects exactly
  the literal families (Literal/Float/String/Atom, and any future literal mutator —
  no registry edit needed) and fences out a custom mutator that would splice a
  pattern-illegal node (e.g. `1` → `n + 1`) into a head, which would poison the
  single build.
- Unlike the guard tagger above, this pattern walk **is** spec-aware: it descends
  explicitly (not a blind `Macro.postwalk`), skipping the spec side of a bitstring
  `::` (a `unit(0)` swap would not compile) and keyword/map *keys* (labels, not
  values) — mirroring `analyze/3`'s `:pattern` routing. Both the key and value of a
  `%{1 => 2}` map pattern mutate (neither is a `format: :keyword` label).
- **A negative literal in a pattern is mutated by *value*, not magnitude.** Sourceror
  parses `-0.5` as a unary minus over its positive magnitude
  (`{:-, _, [{:__block__, _, [0.5]}]}`). The naïve descent reaches the magnitude `0.5`
  and a literal family mutates *it* — but `0.5 - 1.0 == -0.5` is negative, so the
  replacement lands back under the parent minus as `-(-0.5)`. That **parses but won't
  compile in a match** — `-(...)` in a pattern needs a literal operand, and a nested
  minus is `:erlang.-/1` *inside* a match (illegal). So `tag_pattern_targets/3` has a
  dedicated clause for `{:-, _, [{:__block__, _, [n]}]}` that tags the **whole** node
  and offers mutations of the literal *value* `-n` (`value_literal_mutations/2`):
  `-0.5` → `0.5` / `-1.5` / `0.0`, each a clean self-contained literal that replaces
  the whole `-0.5` — never a nested `-(-x)`. The value block is built directly
  (`{:__block__, [], [-n]}`), *not* via `AST.literal/1`: that helper re-wraps a
  negative as `{:-, …}`, which the literal families' `mutate/1` (matching a bare
  `{:__block__, _, [v]}`) wouldn't recognise. This covers every pattern position the
  walk serves — `def` heads (lifted) and `case`/`receive`/`fn`/container-nested clause
  patterns — and gives the same effective mutant *values* as the (broken) magnitude
  walk, just rendered legally. The **guard** path keeps the magnitude walk
  (`guard_targets/3` → `tag_walk`), since `x == -(-0.5)` *is* a legal guard expression;
  so a negative literal renders differently in a guard than in a match, but both
  compile. (`AST.literal/1`'s `{:-, …}` shape and `Tag.literal_node?/1` recognising it
  are the companion fixes — together they let a *positive* literal mutate to a clean
  negative in a head, e.g. `def f(0.0)` → `def f(-1.0)`. Regression:
  `test/mutare/negative_float_test.exs`.)
- Not lifted ⇒ no head mutants: operator-named functions fall back to in-place (so
  their head literals are unmutated), same as their guard/clause-drop mutants.
  Default-arg functions **are** lifted (see "Default arguments are lifted" below),
  so their head literals lift too — a head literal under a `\\` (`def f(0, b \\ 1)`)
  is reached because `tag_pattern_targets/3` descends a `{:\\, _, [pattern, default]}`
  node's *pattern* (the default is the runtime value, kept raw).
- **Duplicate map keys are caught directly, not via poison.** Mutating one map key
  to equal a sibling (`%{1 => a, 0 => b}` → `%{0 => a, 0 => b}`) is a compile error,
  so the map clause of `tag_pattern_targets/3` filters each key's mutations against
  the map's full key-value set (`map_key_values/1`) before tagging — covering arrow
  keys *and* keyword keys (`%{:x => …, mutare: …}`), since a mutated arrow key
  colliding with a keyword key is just as illegal. A mutation never reproduces the
  original value, so "in the full set" means "equals a *sibling*". This avoids the
  poison round-trip for the common case; only a collision through a *structured* key
  (`%{{1, 2} => a, {0, 2} => b}` — that key descends generically) stays
  poison-backstopped.

### Pattern-structure mutators (head + `case`/`receive`/`fn`) `[done]`
Two families restructure a *whole pattern*, beyond the literal swaps above:
**`PatternSwap`** (`:pattern_swap`) exchanges two distinct-named variables inside a
container (`{x, y}`→`{y, x}`, `[a, b]`→`[b, a]`, a map's *values*); and
**`PatternWildcard`** (`:pattern_wildcard`) replaces one occurrence of a repeated
variable with `_` (`equal?(x, x)`→`equal?(_, x)`), dropping the non-linear equality
constraint. Both are **structural** like `ReturnValue`/`clause_drop` (the target is a
whole-pattern shape, not a node a `mutate/1` could match), **registered** and on by
default. They cover several pattern positions, by two deliveries:

- a `def`/`defp` *head* pattern — **lifted** (`Candidate.PatternStructure`), like head
  literals;
- a `case` *clause* pattern — **in place** per-clause via tuple-the-scrutinee
  (`Candidate.CaseClause`; see "Clause-pattern mutation" below), alongside the literal/guard
  families;
- a `receive`/`fn` *clause* pattern — **in place** via the whole-construct selector
  (`Candidate.CasePattern`), since neither has a scrutinee to tuple; and
- a runtime **`=`-match LHS in a value-discarded position** (a non-final block statement, a
  `for` qualifier, or a `with` clause) — **in place** (`Candidate.MatchPattern`, see the next
  note).

The `receive`/`fn` in-place path shares one analyze core (`attach_clause_pattern_candidates/4`)
parameterized by *the clause list* and *a rebuild closure* — the only things that differ
(`receive` has a `do` block plus an optional `after` whose timeout is **not** a pattern and is
skipped; `fn` *is* its clauses, with multi-argument heads). Each clause's pattern *positions*
are iterated, so a single-pattern `receive` clause and a multi-arg `fn` clause are handled
uniformly; a duplicate *across* fn arguments (`fn x, x -> …`) is not seen (each position is
mutated independently), only a duplicate *within* one argument (`fn {x, x} -> …`) — a small,
rare gap.

A `<-` generator/clause LHS, `with`/`try` `else` clause patterns, and `try` patterns are
deferred. The shared discovery primitives (`mutators/1`, `used_names/1`, `bound_var_names/1`,
`node_mutations/3`) live in `Transform.PatternStructure`, used by every path.

### `=`-match LHS in a value-discarded position `[done]`
The old note here said `=`-LHS was *excluded* because "a selector `case` around a match
would lose its bindings." It now mutates — by the rewrite the user proposed: a `<pat> = e`
binds variables that *escape* to the enclosing scope (unlike a `case` clause's, which are
local to its body), so wrapping the whole match in a selector would strand them. Instead
**re-export the bound variables through a tuple and rebind them outside** the selector:

```
{x, y} =
  case <sel> do
    <id> -> case <raw_rhs> do {y, x} -> {x, y} end       # mutant: swapped binding
    mutare_active -> <record ids>; case <rhs> do {x, y} -> {x, y} end   # baseline
  end
```

The outer `{x, y} =` (and the `{x, y}` each inner case returns) is one shared **export
tuple** built from `PatternStructure.bound_var_names/1`, so every branch binds the same
variables — that consistency is the whole trick. Discovery reuses `node_mutations/3` (the
`case`-path primitive) and the diff reuses `Site.in_place/6` (`original`/`mutated` are the
LHS pattern before/after), so only **emission** is new (`Transform.emit_match_site/3`): the
existing in-place selector can't host it, because wrapping the *node* would put the binding
`=` inside the selector branches where its bindings no longer escape. Mutant branches match
the **raw** rhs (no nested selectors — only one mutant is ever active); the catch-all
matches the **emitted** rhs, so a nested mutation in the matched expression still fires when
*its* id is active (the match selector then takes its baseline branch).

Three deliberate constraints keep it sound:

* **Value-discarded positions only.** The rewrite is applied where the match's value is thrown
  away (only its bindings matter), so swapping it for the export tuple is value-transparent.
  Three routes, all via `analyze_statement/2`: a runtime block's **non-final statement**
  (`:__block__` clause), a **`for` qualifier** (`analyze_for_arg/2`), and a **`with` clause**
  (the `:with` clause). A `for` qualifier / `with` clause is *always* value-discarded (it only
  binds/filters), so no position check is needed there; only a block needs the non-final test. A
  *trailing* block `=` (whose value *is* the block's) is left a plain match: a partial pattern
  (`%{a: v} = e`) reconstructs a *different* value than the matched RHS, which a value-position
  consumer would see. A `with` `=` clause's non-match raises `MatchError` (it is **not** routed
  to `else` — only `<-` is), which the rewrite's trailing raise clause preserves exactly.
* **Bound-set-preserving mutations only.** The export tuple must be bound identically in every
  branch, so the wildcard family is forced into **thin** mode (one occurrence → `_`, the
  variable stays bound) by passing the full bound set as `used_outside`; swaps preserve the
  set inherently. Orphan-fix (`{x, x}`→`{_, _}`, dropping the binding) is therefore never
  emitted here.
* **Bare matches and pin-only patterns drop out for free** — a bare `var = e` has no
  container to swap / repeat to wildcard (`node_mutations/3` returns `[]`); a *pin-only*
  pattern (`{^a, ^b} = e`) does admit a swap but **binds nothing** to re-export, so the
  empty-bound guard (`bound_var_names/1` → `[]`) skips it (the assertion-only mutation an
  empty `{} = case …` would express is left to the poison-free common case — a small,
  deliberate gap).
* **The export set is the *exact* binding set, including `_`-prefixed names.** This is why
  `bound_var_names/1` can't reuse `var_name/1`: that drops both bare `_` *and* `_`-prefixed
  names, which is right for a swap/wildcard *target* (you don't reorder `_x`) but wrong for
  the *export* — `_x` is a genuine binding the rest of the scope can read (`{_x, y, z} = t;
  _x + y - z`), so omitting it leaves `_x` undefined after the rewrite, a hard **compile
  error**. Only bare `_` (which binds nothing usable) is dropped.
* **The export repeats each variable by its pattern *occurrence count*** (`occurrence_counts/1`),
  not once. A variable used only to *constrain* the pattern — a repeated binding (`{a, a} = t`)
  or a bitstring size var (`<<n, r::size(n)>> = t`) — has its "unused variable" warning
  suppressed in the original by that self-use (the 2nd+ occurrence is a read). A flat
  single-occurrence export (`{a} = …`) would lose it and warn whenever the rest of the scope
  never reads the var; repeating it to match the source (`{a, a} = …`) keeps the self-use, so
  the metamutant's warning profile matches the original's. Sound because every repeated
  position comes from the *same* binding, so the rebind's `{a, a} = {v, v}` constraint is
  trivially satisfied and never re-imposes the original `t[0] == t[1]` one the mutant drops
  (and forced-thin keeps the var bound in every branch, so the repeats always resolve).

Non-match semantics are preserved exactly: each inner case carries a trailing `u ->
Elixir.Kernel.raise(Elixir.MatchError, term: u)` clause, so a value that doesn't match raises the
*same* `MatchError` the original `=` did (not a `CaseClauseError`) — keeping the baseline
identical and still a clean kill on a mutant whose pattern stopped matching. (The pattern is
always a refutable container — a bare `var`/pin-only LHS is never offered — so that clause is
always reachable; the binding is clause-local, so a fixed `mutare_unmatched` name can't
capture or collide.) The raise is spelled to be **immune to the target's lexical
environment**, since a real `=` always raises `Elixir.MatchError` regardless of imports or
aliases: *both* names are the **absolute** form (`__aliases__` led by `:Elixir`, which alias
resolution never rewrites). `Elixir.Kernel.raise` survives `import Kernel, except: [raise: 2]`
(an unqualified `raise` there breaks the metamutant baseline compile) *and* `alias Foo, as:
Kernel` (a plain `Kernel.raise` would be redirected to `Foo.raise`); `Elixir.MatchError`
likewise can't be redirected by `alias Foo, as: MatchError` or a nested `MatchError` module.
(Originally `Kernel.raise` was only plainly-qualified — import-proof but not alias-proof — and
was promoted to the absolute form for consistency with `Elixir.MatchError`; see "Absolute-qualify
every generated cross-module name" below.)

Known edge, **only** a warning (harmless under the default warnings-tolerant metamutant
compile; poison-recoverable under `--warnings-as-errors`, where the whole-`case` fallback range
in `Manifest` maps it to the rewrite's ids — as for `PatternWildcard`'s "cannot match"): when
the LHS has an `_`-prefixed binding alongside a real swap/wildcard target (`{_keep, y, z} = t`),
the inner case's return tuple **reads** `_keep` — an "underscored variable used after being set"
warning the original may not have had. Suppressing it would mean aliasing every `_`-binding to a
non-underscore temp in the inner patterns/returns (fiddly around pins), not worth it for a
build-artifact warning; the `_keep` binding itself must still be re-exported (omitting it is the
compile error above). (The *other* former edge — a `{x, x} = e` whose `x` is unused gaining a
spurious "unused variable" warning — is gone: the occurrence-count export above repeats `x`, so
its self-use carries over.)

Several design choices worth remembering:

- **Structural via an optional callback, discovered by export.** `mutate/1` is `:skip`;
  the real entry point is `Mutare.Mutator.pattern_mutations/2` (`@optional_callbacks`),
  taking `(head_args, used_outside)` and returning mutated arg lists. It is discovered by
  `function_exported?(_, :pattern_mutations, 2)` — so no hard-coded list, toggling is just
  list membership, and a custom mutator can opt in. (The `ReturnValue`/`IfCondition`
  enablement was the *opposite* — a hard-coded `Spec.find(mutators, Mutare.Mutators.X)` by
  module — until "Structural in-place mutators generalized to callbacks" below brought them
  onto the same export-discovered footing.) The head path (`FunctionPlan.build_pattern_structures/2`) calls it with the
  full arg list; the `case` path wraps a single clause pattern as `[pattern]` via
  `PatternStructure.node_mutations/3` (the contract never changes the list length, so the
  single result is unwrapped). A function now also lifts if it admits a swap/wildcard (so a
  single-clause `def f({x, y})` lifts solely to carry its swap mutant, like head literals).

- **Whole-clause replacement (head), whole-construct wrap (`case`/`receive`/`fn`) — not
  tagging.** Guards/head-literals tag *one* node via `meta[:mutare_tag]` and `replace_tag`
  it in the `__mut` copy. A swap/wildcard spans *two* sibling positions or repeated
  variables — and a 2-tuple/list has no taggable meta (Sourceror keeps small tuples/lists as
  raw `{a, b}`/`[…]` with no `{f, m, a}` wrapper). So in a **head**,
  `Candidate.PatternStructure` carries the mutated head args and is applied by
  `List.replace_at` on the clause (the same index-based mechanism as `Candidate.Drop`), via
  the existing `put_head_args/2`; the `Site` records at the **head-call level**
  (`original`/`mutated` = `f(x, x)`/`f(_, x)`), always rangeable. In a **`case`/`receive`/`fn`**,
  `Candidate.CasePattern` is delivered by the *in-place selector*: the whole construct is
  wrapped in a `case :persistent_term.get(:mutare_active, 0) do <id> -> <mutated construct> ;
  _ -> <original construct> end`, where `replacement` is a copy with one clause's pattern
  restructured (sound — these clause bindings never escape their body). The diff stays
  focused on the **clause pattern** (`{x, y}`→`{y, x}`), which *is* rangeable here (Sourceror
  block-wraps a clause pattern with meta, unlike a bare head arg). The mutant branch is the
  raw mutated construct (no nested selectors — first-order, like a lifted `__mut` copy); the
  selector's catch-all holds the fully-transformed construct, so nested body mutants stay
  reachable. `branch_node/1` picks `replacement` for a `CasePattern`, `mutated` for every
  other in-place candidate.

- **Compile-safety — swap is total, wildcard is `used_outside`-guided.** A swap only
  reorders existing variables: the bound-name set and its usage are invariant (no
  unbound/unused var), and refutability is preserved (`{x,y}`/`{y,x}` both need a
  2-tuple), so it never shadows a later clause — always clean. Wildcard must not strand a
  binding, so `FunctionPlan.clause_used_outside/1` collects the variable names read in the
  clause's guard+body (**over-collecting is the safe direction** — it can only keep a
  binding we didn't need, never remove one a body reads, which would be an *unbound*
  hard error). The rule: a duplicate used elsewhere, or appearing ≥3 times, **thins** one
  occurrence per mutant (a binding survives); a duplicate appearing exactly twice and read
  nowhere gets the **orphan-fix** — *both* occurrences → `_` (`equal?(x, x), do: true`→
  `equal?(_, _)`), since thinning to one would leave an unused var.

- **WAE shadowing is poison-backstopped, not pre-excluded.** Broadening a non-final
  clause to an irrefutable pattern (`f(_, x)`/`f(_, _)` match anything) makes later
  same-arity clauses unreachable — a *warning* ("this clause cannot match"), and an
  unused-var is likewise only a warning. Both fail **only** under `--warnings-as-errors`,
  where poison-recovery drops them: a compile collects *all* such warnings at once and a
  `__mut` copy's whole range maps to its id, so a batch recovers in ≈1 rebuild (far under
  `@poison_attempts`). We deliberately *don't* pre-skip these (they're valid Elixir that
  runs fine without WAE, and the wildcard's whole point is broadening the match), matching
  the project's "poison is the backstop for the genuinely-uncompilable" stance. The only
  residual exotic case is a head variable *rebound* (not read) in the body — `used_outside`
  over-counts it as used → a thin mutant with an unused var → WAE poison; rare, documented,
  bounded. **Single-clause functions are always clean** (nothing to shadow). The same holds
  for `case`/`receive`/`fn`: broadening one clause can shadow a *later* clause (e.g. a
  trailing `_ ->`) — WAE-poison-dropped, harmless otherwise; a construct with a single clause
  is always clean.

### Clause-pattern mutation — tuple-the-scrutinee (`case`), whole-construct (`receive`/`fn`) `[done]`
`case`/`receive`/`fn` clause patterns used to get *only* the structural families (swap/wildcard)
via the whole-construct selector. They now also get **literals** and **guards**, so a clause
pattern is mutated as fully as a function head. Two deliveries, picked by whether the construct
has a scrutinee to tuple:

- **`case` → tuple-the-scrutinee** (`Candidate.CaseClause`, `Transform.emit_case_pattern_site/3`).
  The subject is tupled with the active id and each mutant adds **one** clause —
  `{mutare_active, <mut_pat>} when mutare_active === <id> [and <guard>] -> <raw_body>` — placed
  before its original, which is gated `when mutare_active !== <its ids>` to step aside when the
  mutant is active. This is the per-clause **C+M** scheme (the same one head lifting uses; reuses
  `exclusion_guard`/`and_into_guard`/`merge_guards`), *not* the whole-construct **C×M** copy — which
  matters now that literals+guards multiply the mutant count (the lifting-blowup lesson, applied to
  `case`). Verified behaviorally exact: clause precedence is preserved (a mutant sits immediately
  before its own original, so a changed/broadened pattern shadows exactly what the source mutant
  would), mutant clauses use the **raw** body (only one mutant is ever active, so a body selector
  there could never fire) and originals keep their **emitted** body. Every clause binds
  `mutare_active` and *uses* it (originals via the coverage record, mutants via the gate) — note an
  *unused* `case`-clause pattern variable **warns** (unlike a function param), so the bind-and-use
  is load-bearing.
- **`receive`/`fn` → whole-construct selector** (`Candidate.CasePattern`). Neither has a scrutinee
  to tuple (`receive` matches the mailbox; `fn` matches its call arguments), so each mutant wraps
  the whole construct in `case <active> do <id> -> <full copy with one clause changed>; _ ->
  <original> end`. That re-introduces C×M, but `receive`/`fn` are rare and small, so it is
  acceptable — and the existing selector emit / `Manifest` / coverage all apply unchanged.

**Coverage subtlety (the reason originals record the *full* id-set).** The probe runs at
**baseline**, where only the original clauses match. A pattern mutant can be killed by a value that
matches a *different* clause at baseline (e.g. `1 -> :one` mutated to `2 -> :one`: a test passing
`2` matches the catch-all at baseline but clause 1 under the mutant). So per-clause-matched
recording would *under*-attribute and break test selection. Each original clause therefore prepends
`Recorder.record_ast(<all the case's mutant ids>, var)`; whichever original matches at baseline
records them all (idempotent union) — consistent with the function-head dispatcher, which records
all of a group's ids on every call.

**Non-exhaustive `case` (the unmatched fallback).** Tupling the subject changes what a *miss* does.
A non-exhaustive source `case` raised `CaseClauseError` on the **bare** subject; the rewritten
`case {active, subject} do …` instead falls through as `{active, subject}` — raising on the *wrong*
term **and**, fatally, running **no** clause body, so the coverage record never fires. The probe
runs at baseline: if the suite exercises this `case` *only* with values that match no original
clause (a function tested purely for its error path), nothing records its ids and a pattern mutant
that *would* re-target a clause to match that value is wrongly scored `:no_coverage` and never run —
a false negative. (When the suite also hits *some* matching value, the full-id-set record above
already covers every mutant, so the gap is exactly the match-nothing case.) Fix: a trailing
`{<active>, mutare_unmatched} -> <record all ids>; Elixir.Kernel.raise(Elixir.CaseClauseError, term:
mutare_unmatched)` clause (`case_unmatched_clause/2`) restores both — it attributes the ids and
re-raises the original error on the bare subject (`Elixir.Kernel.raise`/`Elixir.CaseClauseError`
both spelled in the absolute, import/alias-proof form, like the `=`-match `MatchError` raise). It is **omitted** when an original clause
is already an unconditional catch-all (`exhaustive_clauses?/2` — an irrefutable pattern, no source
guard, no exclusion ids), since the subject can then never fall through and the clause would be
unreachable (Elixir warns "this clause cannot match"). Detecting irrefutability is sound-by-narrowness:
a bare `_`/var (`{atom, _, atom}`) counts, **and** a *match chain* `a = b = … = z`
(`{:=, _, [lhs, rhs]}`, recursively) counts when every operand does (`x = _ = y` binds three names and
matches anything, but `x = {1, 2}` or `^x = y` is refutable); anything else structured is assumed
refutable, so at worst the fallback is added where unneeded — never wrongly omitted. (Originally only
the bare `_`/var was recognised, so an exhaustive `case` whose catch-all was a match chain wrongly got
a second — unreachable — fallback.)

**`Manifest`/poison.** The tupled `case`'s subject is `{<subject_ast>, <scrutinee>}`, recognised by
`Metamutant.pattern_subject?/1` (it sees through the `:literal_encoder`'s `:__block__` wrap of the
2-tuple). A tupled mutant clause's id is in its `when mutare_active === <id>` gate (reused
`gate_id/1`), and its generated code (the mutated pattern/guard) lives in the **head**, so the
**whole clause** range is recorded (not just the body, as for an in-place selector). Plus the usual
whole-`case` fallback.

**Known limitation — `fn` clause-pattern coverage is tied to *construction*, not invocation.**
The whole-construct selector records in its catch-all (`build_case`/`catch_all_clause`):
`<active> -> <record ids>; <original construct>`. For `case`/`receive`/`try` the record fires when
the construct *runs* — fine. But a `fn` is a **value**: the selector evaluates (and so records) when
the closure is *constructed*, not when it is *called*. So a `fn 0 -> … end` that is merely returned
or stored — and whose clauses are never invoked in a distinguishing way — has its literal/guard/
structural clause-pattern mutants scored **covered**, so they *run and survive* instead of being
`:no_coverage`. (This is **pre-existing**, not new with literals/guards: swap/wildcard already flowed
through this selector. And it is `fn`-specific — `receive` blocks until a message matches and `try`
runs its body on entry, so for them construction ≈ execution.) It is **fail-loud** (a false
*survivor*, never a false *kill*), which is why it's tolerated for now.

The fix is feasible but a *trade*, deliberately deferred. Mechanism: move the clause-pattern record
out of the catch-all and into **each clause body** of the original `fn` — the closure captures
`mutare_active` from the enclosing `case` binding, so the gated record fires on invocation
(prototyped: construction records nothing, `f.(x)` records the ids). Why it's not a clear win:
  * it **reintroduces** a gap construction-tied recording handles correctly — a closure invoked
    *only* with args matching no clause (raising `FunctionClauseError`) records nothing, so a mutant
    that *broadens* a clause to capture that arg becomes a false `:no_coverage` (the `fn` analogue of
    the tupled-`case` unmatched fallback above, but a faithful `FunctionClauseError` —
    module/function/arity/args — is hard to synthesize, so the fallback is uglier here);
  * a **return-position** `fn` (`def h, do: fn :a -> 1 end`) can carry *both* a `Candidate.Return`
    (replace the whole `fn` with `nil` — an effect observed at construction, so correctly
    construction-tied) and `CasePattern`s, so the records would have to **split** by kind (or the
    inject restricted to the pure-`CasePattern` site, falling back otherwise).
So it swaps a common, visible false survivor for a rarer, hidden false `:no_coverage`. If revisited,
the same "record where the clause *runs*, not where the construct is *built*" principle also applies
to `try`/`rescue` (a `try` entered without raising over-covers its `RescueType` mutants) — decide the
principle once and apply it to both.

**Shared taggers (`Transform.Tag`).** The guard-operator and pattern-literal tagging walks (the
explicit descents that keep a remote call's *form* opaque and a bitstring spec / keyword-map *key*
unoffered, with map-key-collision filtering) were extracted from `FunctionPlan` into
`Transform.Tag` so both the lift path and the new clause-pattern discovery use them — one home for
those subtleties. `replace_tag/3` materialises one mutant from the tagged copy (leftover tags on
sibling nodes are stripped by `Render`).

Deferred (still routed `:pattern`, unmutated): the `<-` generator/`with`-clause LHS, the `with`/`try`
`else` clause pattern, and `try` patterns.

### Rescue narrowing + clause drop (`Mutare.Mutators.RescueType`) `[done]`
A `rescue` clause is **not** a standard Elixir pattern: it matches on exception *types* in one of a
few shapes (`Type`, `var`, `var in [Type, …]`, or the **bare list** `[Type, …]` — a list with no
`var in` binding), and — crucially — **cannot carry a `when` guard** (the compiler rejects it: "the
clause should match on an alias, a variable or be in the `var in [alias]` format"). So none of the
pattern families apply, and the per-clause gating that `case` uses (a `when active === id` guard) is
*impossible* here.

`RescueType` narrows a ≥2-type list by **dropping one type** (`[A, B]`→`[A]`/`[B]`; never to `[]`, so
the metamutant always compiles), asking "does any test rely on each rescued exception being caught?".
It is structural/positional (recognised only at a rescue-clause head by `Transform.Analyze`'s `:try`
clause; `mutate/1` is `:skip`, the list logic is `RescueType.drops/1`), registered, on by default.

**Both list-bearing head shapes are narrowed**: the bound `var in [A, B]` *and* the bare `[A, B]`
(`rescue [RuntimeError, ArgumentError] -> …`, a valid form that catches the listed types without
binding). They parse differently — `{:in, _, [var, list]}` vs. a bare list head (Sourceror-wrapped
`{:__block__, _, [list]}`) — so `Analyze.narrowable_types/1` returns the type list plus a
head-rebuilder for each (the bound form rewraps the `in`, the bare form rebuilds the list directly),
and the single shared `rescue_type_drops/4` matches `[[head], body]` once and works off that. The
diff is the clause **head** before/after, so the bound form shows `var in [A, B]`→`var in [A]` and
the bare form `[A, B]`→`[A]`. `rescue_types/1` handles the `:__block__`-aware list extraction/rebuild
for both and returns `nil` for the non-list shapes (`Type`, `var`, `var in Single`), which fall
through to no mutation. (The bare-list form was a real gap before — only the `in` shape was matched,
so bare lists went un-narrowed despite being the same compile-safe drop.)

Because a rescue clause can't be guard-gated, the **only** delivery is the **whole-construct
selector** — the whole `try` is wrapped in `case <active> do <id> -> <try with the narrowed rescue
list>; _ -> record; <try> end` (`Candidate.CasePattern`, exactly like `receive`/`fn`). Sound: a
rescue binding is local to its body. This reuses the existing selector emit, `Manifest`, and
coverage unchanged. Verified end to end: dropping `ArgumentError` makes it propagate while
`RuntimeError` is still caught, and vice versa — for both head shapes. It composes with body and
return-value mutations on the same `try` (each gets its own selector branch — the whole-`try` rescue
mutant uses a first-order copy, the catch-all the fully-emitted `try`).

**Multi-branch rescues drop a whole clause.** The idiomatic way to handle several exception types
*differently* is one clause each (`rescue e in A -> …; e in B -> …`). Each branch catches a single
type, so there is no list for `rescue_type_drops/4` to narrow — the type-narrowing path would emit
**nothing** at all on this very common shape. The structural twin closes the gap:
`Analyze.rescue_clause_drops/3` drops each whole `rescue` branch in turn (`Candidate.RescueDrop`,
`replacement` = the `try` with that clause removed), asking the same question one level up. It reuses
the exact "≥2, never to empty" invariant — offered **only when the `rescue` has ≥2 clauses** (a `try`
can't carry an empty `rescue`), so every result compiles — and the head shape is irrelevant (a
bare-variable catch-all clause among others is droppable too, which narrowing can't touch). Delivery
is the same whole-`try` selector; the only new wiring is a `:delete`, `:in_place` `Site`
(`Site.in_place_drop/5` — like the lifted `clause_drop/4` but in place, since a rescue clause isn't
lifted), so the diff is a `-` deletion of the dropped branch. Both operations are recorded under the
one `:rescue_type` family (a clause drop *is* narrowing what the rescue catches, just forced to
whole-clause granularity by the single-type-per-branch syntax). Verified end to end: dropping either
branch makes its exception propagate while the other is still caught. (`Site.in_place_drop/5` renders
the bare `->` clause node in arrow syntax for `describe/1`; `Sourceror.to_string/1` would otherwise
emit the call form `->(head, body)`.)

**The `def … rescue …` shorthand is mutated too** (`host_def_rescue/3`). The shorthand is sugar for
wrapping the body in a `try`, but it carries its rescue/catch/else/after as **def-body blocks**, not a
`try` node — so the `:try` clause never sees it. The fix hosts the body in a **synthesized `try`**: the
`def` clause runs `analyze_do_blocks/2` + `annotate_returns/3` as before, then — *only* when the body
has rescue candidates — replaces the whole body keyword with `[do: try]`, the `try` carrying those
candidates so the same whole-construct selector wraps it. The key ordering insight that dissolves the
feared collision: `annotate_returns/3` runs **first**, on the original rescue-form keyword, so the
shorthand's *granular* per-clause-tail return mutants are attached to the body's inner tails *before*
the body is wrapped — the catch-all `try` is that already-analyzed body, so nothing is lost (verified:
a shorthand keeps both its do-tail and rescue-tail return mutants). The mutant branches are raw tries
with one rescue clause narrowed/dropped. Lifting needs **zero** special-casing: the relocated original
clause's body becomes `[do: <selector>]` like any other in-place body (the rescue ids are body-selector
ids, not lifted-candidate ids), while the guard/pattern mutant clauses keep the raw shorthand — both
are valid base clauses. `def f do b rescue r end` ≡ `def f do try do b rescue r end end`, and a `try`
leaks no bindings, so the rewrite is value-transparent.

One rendering wrinkle: a `[]`-meta synthesized `try` over the source's `{:__block__, …, [:do]}` block
keys renders the **invalid inline keyword form** (`try do: …, rescue: …`); empty `do:`/`end:` block
markers in the `try` meta (`[do: [], end: []]`, threaded to the candidates' rebuilt mutant tries too)
force the block form. `super`/quote and the rest compose unchanged, since the synthesized `try` is just
another in-place body node.

A parsing wrinkle on the **inline keyword** spelling of the shorthand (`def f, do: …, rescue: (p ->
b)` — the `rescue:`/`catch:`/`else:` value written in `(…)` keyword form): Sourceror wraps the clause
list in a `{:__block__, _, [clauses]}`, whereas the block form (`def f do … rescue … end`) yields the
bare list every consumer expects. Left unnormalized this missed in **three** places at once — the
clause routing in `analyze_do_blocks/2` (an `is_list` guard) fell through and analyzed the whole rescue
as a *runtime expression*, so the clause **list** drew a `:list`→`[]` mutant and a selector `case` was
spliced around the `->` clauses (**poison**, not just a missed mutant); `annotate_returns/3` skipped the
rescue-clause-body return tails (same `is_list` guard); and `host_def_rescue/3` →
`rescue_type_candidates/3` found no `:rescue` list to narrow, so the form produced no `:rescue_type`
mutants. `Analyze.normalize_clause_blocks/1` unwraps the wrapper for the clause-block keys **once**, at
the top of the `def`/`defp` clause, before all three run — so the inline spelling reads exactly like its
block-form twin. It's a no-op on the block form (values already bare lists) and never touches `:do`/
`:after`. Bonus: with the rescue value a bare clause list, Sourceror renders the whole `def` in block
form regardless of the keys' lingering `format: :keyword` markers — so even the no-candidates path (the
body returned un-hosted) emits valid Elixir.

### Transform pipeline — explicit stages `[refactor, done]`
`Mutare.Transform` is an explicit pipeline rather than a walk-everything-then-
subtract design. Stages: **analyze + classify** (`analyze/3` is a single
context-threaded recursive descent: it *names the context* of each position as
it descends and attaches a typed `Candidate.InPlace` to each mutatable node's
own `meta[:mutare]`), **plan** (a statement sequence becomes a
`Transform.ModulePlan` of classified items; each liftable clause group a
`Transform.FunctionPlan` carrying its lifted candidates — id-free), **assign +
emit** (`emit/2`, a bottom-up `Macro.postwalk`, plus `emit_function_plan/2`, hand
out ids in post-order DFS; the counter advances for `:skip_ids` so ids stay
stable across poison-recovery rebuilds), and **render** (strip the
`:mutare`/`:mutare_tag` annotations, then `Sourceror.to_string`).

`analyze/3` threads two contexts — `:runtime` (mutate) and `:pattern` (don't
mutate, but keep descending so nested runtime escapes like default-arg values
and `size()` args are still reached). The other contexts are *recognised and
pruned* by dedicated clauses: `:compile_time` (module-attribute values, macro
bodies), `:spec` (bitstring type specifiers, via `analyze_spec/3`), `:guard`
(`when`, owned by the lift path), `:capture_arity` (`&fun/arity`). Routing is
positional, which a single `Macro.traverse` accumulator can't express (it can't
send the spec side of a `::` one way and the value side another) — that
limitation is what forced the earlier `skip`-depth blacklist.

Three things this bought, vs. the prior implicit version:
- The growing **blacklist** (`unsafe_keys`/`guard_keys`/`capture_arity_keys`,
  then the `skip_node?/1` depth counter) is gone — context is *named positively*
  in `analyze/3`. To classify a new context, add a clause (route its children);
  don't reintroduce a subtractive key set or a flat skip-depth.
- **Untyped lifted maps** (`%{type: :guard, …}` / `%{type: :drop, …}`) are now
  **typed candidate variants** — one struct per legal kind (`Candidate.InPlace`,
  `Candidate.Guard`, `Candidate.Drop`), shared by in-place and lifted alike.
- **`{line, column}` node identity** is gone. In-place candidates ride in the
  node's intrinsic `meta[:mutare]`; guard targets are tagged with a unique
  `meta[:mutare_tag]` so emission never re-finds the node. Metadata survives
  `Macro` rebuilds and can't collide across duplicate subtrees — the reason the
  positional key existed.
- Mutators are invoked **once** per in-place site (in `annotate`'s walk), not
  twice (the old `capture_ranges` + `wrap_site` pair). `Mutator.mutations/2` is
  the single "run the mutator set over a node" helper both `analyze/3` and
  `FunctionPlan` call.
- **Shared vocabulary lives in its own files.** The plan structs
  (`Transform.ModulePlan`, `Transform.FunctionPlan`, the `Transform.Candidate.*`
  variants), `Transform.Ctx` (threaded through every stage) and `Transform.Render`
  (the Sourceror workarounds: `to_source/1` strips annotations + normalizes
  keyword blocks; `block_wrap/1` shields a bare selector `case`) are split out of
  `transform.ex` so the semantic pipeline isn't interleaved with vocabulary and
  rendering friction. The plan modules own *discovery* (chunking clauses, finding
  guard/drop candidates); the *emission* machinery (id assignment, site recording,
  building the selector `case` and dispatcher) stays in `Transform` — it shares
  the `Ctx` id-threading discipline across in-place and lifted paths too tightly
  to separate cleanly (`claim_id/4` is the single owner of that dance).

### Transform IR — typed candidate variants + plan structs `[refactor, done]`
The earlier `%Candidate{}` was one struct that stored `context` *and* its two
consequences (`kind`, `operation`) as separate fields, so the type admitted
illegal combinations (a `:clause_drop` claiming to be `:in_place`/`:replace`)
that only discipline kept out — and every **guard** candidate carried a full
copy of the clause group with its one guard pre-swapped (`mutated_clauses`), N
near-identical copies for N guard mutants. Both are fixed:
- **One struct per legal kind.** `Candidate.{InPlace,Guard,Drop}` — the
  `context`/`kind`/`operation` triple is gone; the variant *is* the kind, and the
  matching `Site` constructor is chosen by pattern-matching the struct at emit
  (`in_place_site/3` / `lifted_site/3`). Illegal states can't be built.
- **The clause group is stored once.** `FunctionPlan` holds a single *tagged*
  clause group (every mutatable guard operator marked with a unique
  `meta[:mutare_tag]`, the tag counter threaded across clauses so tags are
  group-unique); each `Candidate.Guard` carries only its `tag` + replacement.
  `FunctionPlan.mutated_clauses/2` reconstructs a copy on demand
  (`replace_tag/3` for a guard, `List.delete_at/2` for a drop). Leftover tags on
  sibling operators are stripped before rendering, so the rendered metamutant is
  identical to the old per-candidate-copy output.
- **`ModulePlan` is the module-planning stage.** `build/3` chunks a statement
  sequence into `{:lift, FunctionPlan}` / `{:in_place, clauses}` / `{:statement,
  node}` items (run chunking, non-consecutive detection + the warning), and owns
  `clause_signature/1`. `Transform.emit_module_plan/2` walks the items in order.

### Analyze split — candidate-builders out of the descent `[refactor, done]`
`Mutare.Transform.Analyze` had grown to ~2000 lines — the clear outlier in an
otherwise 40–450-line directory. The split was warranted **only for a specific
subset**, decided by coupling, not by line count: the test is whether a section
participates in the recursive `analyze/3` descent (called ~80× across the file)
or merely *builds candidates* the descent hands off to.

- **What stays (the core, ~1830 lines).** The `analyze/3` dispatch and the
  helpers that recurse constantly — redundancy suppression, known-macro routing,
  call-option keys, bitstring/spec/sigil — *are* the recursive walk. Pulling any
  of them out would create a thick two-way cycle (each calls `analyze`/`offer`/
  `recurse` a dozen+ times) for no gain. So the core can't drop below ~1000 lines,
  and chasing that would be cosmetic. The core is now one honest unit: the descent
  plus its inseparable helpers.
- **`Analyze.Returns`** (return-value mutation, ~150 lines). The clean win: it
  builds `Candidate.Return`s for each return-path tail and **never recurses back**
  (no `analyze`/`offer`/`recurse`), so the dependency is strictly one-way
  (Analyze → Returns), no cycle. It classifies its own return-path keys
  (`[:rescue, :catch, :else]`, fixed Elixir semantics) rather than reaching back —
  `Mutare.AST` documents that `Analyze` owns the *canonical* block-key set, and the
  core keeps its own `do_key?`/`clause_block_key?` for clause-block routing
  (`normalize_clause_blocks/1`, `analyze_do_blocks/2`), so the two classify the
  same atoms independently with no shared source to drift.
- **`Analyze.ClausePatterns`** (`case`/`receive`/`fn`/`try`-rescue clause-pattern
  builders, ~450 lines — the single biggest section). Dominated by `Tag` /
  `PatternStructure` machinery, it touches the descent only through **three**
  callbacks, all in `attach_clause_pattern_candidates/4`: it analyzes a
  `receive`/`fn`/`try` node normally before attaching its clause candidates. Those
  three (`recurse/3`, `build_candidates/2`, `put_candidates/2`) were promoted from
  `defp` to a small **public sub-walk API** on `Analyze` (documented as such); the
  resulting Analyze ↔ ClausePatterns cycle is a thin, idiomatic child→parent call,
  not the heavy descent entanglement that kept the core sections home. The descent
  routes `case` (→ `case_clause_candidates/2` + `put_case_candidates/2`),
  `receive`/`fn` (→ `receive_do_clauses/2` + `attach_clause_pattern_candidates/4`),
  and `try`/`def…rescue` (→ `rescue_type_candidates/3`) into it.

Two further candidate-builders followed, in a second pass:

- **`Analyze.Conditions`** (`if`/`unless`/`cond` condition analysis, ~400 lines —
  the binding-ancestor prune, the IfCondition decision attach, and the `if`/`unless`
  *hoisting* path that lifts a spine binding out so a binding-free condition can still
  carry the decision). The descent routes `cond` (→ `analyze_condition/2`) and
  `if`/`unless` (→ `hoist_if?/2` + `hoist_if/6`, else `finish_condition/3`) into it.
  Its `@short_circuit_ops`/`@branch_forms`/`@binding_isolating_forms` moved with it
  (used nowhere else).
- **`Analyze.MatchPatterns`** (the `=`-match LHS → `MatchPattern` and the
  binding-escaping-macro pattern arg → `MacroPattern`, ~335 lines). The two share the
  tuple-re-export discovery (`pattern_export`/`export_tuple`/`strip_comments`), so they
  belong in one module. Routed via `analyze_statement/2` (block stmt / `with` clause)
  and `analyze_match_statement/2` (`for` qualifier).

The clean part of this pass: **neither needed new public API**. Every callback into
the descent uses the `:runtime` context, which is exactly the existing public
`Analyze.annotate/2` (`= analyze(node, :runtime, mutators)`), and MatchPatterns reuses
the already-public `Analyze.put_candidates/2` — so no further `defp`→`def` promotion
beyond the sub-walk API the `ClausePatterns` pass added. MatchPatterns keeps a private
copy of the trivial `macro_routing/1` (`meta[:mutare_macro]` accessor) rather than
depend on core for a one-liner.

The axis throughout is **by kind of candidate built**, mirroring the sibling modules
already outside `analyze.ex` (`Tag`, `PatternStructure`, `FunctionPlan`) — not by
chopping the recursion. Net across both passes: `analyze.ex` 2092 → ~1090 lines (the
recursive descent and its inseparable helpers), with the candidate-builders in four
focused sub-modules under `analyze/` (`Returns`, `ClausePatterns`, `Conditions`,
`MatchPatterns`).

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
- **Not lifted (fall back to in-place):** operator-named functions (`def a ~> b` —
  can't be spelled `__mutare_~>_2_…`) and functions with non-consecutive clauses
  (see the dedicated note below). Default-arg functions **are** lifted now — see
  "Default arguments are lifted" below.
- **Non-consecutive clauses are not lifted (for now).** When a function's
  clauses are split across more than one run — something (another definition, a
  module attribute) appears between them — Transform refuses to lift the whole
  signature and falls back to in-place for every clause
  (`non_consecutive_signatures/1`, fed by `chunk_clause_runs/1`'s run chunking).
  Two reasons it can't safely lift: a public dispatcher is a catch-all, so
  lifting only one consecutive run would make the other clauses unreachable; and
  lifting *every* run as one unit (the previous behaviour) relocated each
  clause's body to the dispatcher's position, which silently changes semantics
  when a compile-time `@attr` read between the heads resolves to a different
  value there. The motivating break:

  ```elixir
  @a 1
  def f(0), do: @a    # reads @a == 1
  @a 2
  def f(1), do: @a    # reads @a == 2 — but a copy emitted at the dispatcher
                      # (first occurrence) would read @a == 1
  ```

  Cost: such functions get no guard/clause-drop mutants (body in-place mutants
  still apply). The skip is **not silent** — `warn_non_consecutive/2` logs a
  `Logger.warning` once per non-consecutive signature (file + `name/arity`),
  pointing at the fix (group the clauses) — **except** when the same signature is
  *also* metaprogrammed (see the next note): there the metaprogrammed warning
  wins, because grouping the literal heads can't enable lifting (the generated
  clauses still force in-place), so "group the clauses" would mislead.
  `non_consecutive_only/2` drops those names from the non-consecutive warning set
  and `metaprogrammed_signatures/2` warns them instead — exactly one accurate
  warning, never both. **Deferred:** the cases we *can* lift
  safely — e.g. heads separated only by another `def`, with no compile-time read
  whose value differs across the split — are worth recovering later
  (normalize/relocate the reads, or detect attribute-independence and lift). For
  now the blanket refusal is the conservative, always-correct choice.
- **Metaprogramming-augmented clauses are not lifted either.** Same hazard as
  non-consecutive, different source: a function whose clause set is *grown at
  compile time* by a module-level `for`/macro that `def`s the same name. The
  generated clauses are invisible to the planner (they live inside an `{:other}`
  statement, not as literal top-level `def`s), so the literal run looks complete
  and consecutive and would be lifted — installing a catch-all dispatcher that
  shadows every generated clause and forwards to an `__orig` missing them, a
  guaranteed `FunctionClauseError` on baseline. The real break (plug
  `Plug.Conn.Status.code/1`):

  ```elixir
  def code(integer) when integer in 100..999, do: integer
  for {code, atom} <- statuses do
    def code(unquote(atom)), do: unquote(code)   # code(:ok) → 200, etc.
  end
  ```

  `metaprogrammed_def_names/1` collects every name `def`/`defp`'d *inside* a
  non-clause statement (pruning nested `defmodule`/`defimpl`/`defprotocol`, a
  different scope), and `plan_clause_group/4` refuses to lift any clause group
  whose name is in that set — falling back to in-place exactly like the
  non-consecutive case. Keyed by **name only** (not name/arity): a generated
  head's arity can be obscured by metaprogramming, and over-refusing only costs
  guard/clause-drop mutants, never correctness. Not silent —
  `warn_metaprogrammed/2` logs once per blocked signature (it is not
  user-fixable; the generated clauses are intentional). Note the sibling functions
  `reason_atom/1` / `reason_phrase/1` in the same file were *already* safe via the
  non-consecutive path (their two literal clauses straddle the `for`), so this
  closes the remaining hole where the literal clauses happen to be consecutive.
- **Module-level compile-time statements are scaffolded; def bodies still mutate**
  `[done]`. Lifting is out for a `def` created inside a module-level
  `for`/`if`/`unless`/… (see the two notes above), but the generated function's
  *body* is ordinary runtime code and should mutate. It already did — the def clause
  re-enters `:runtime` for its body regardless of the surrounding context — but the
  surrounding **scaffold** was mutated too: a `for tier <- [:gold, :silver, :bronze]`
  offered atom/list mutants on the generator, an `if cond` on its condition. Those
  are **inert**: a module body runs *once*, at compile time, with mutant 0 active, so
  a selector spliced into the scaffold's own expressions can never activate at
  runtime — pure no-coverage noise that also burns poison-recovery rounds.

  The fix is a third analyze context, **`:scaffold`** (`body_context/1`, entered from
  `Transform.transform_statement/2` for known compile-time module statements;
  parenthesized/semicolon `__block__` statements keep their shape but classify each
  child individually): descend but never offer a candidate — *except* a `def`/`defp`
  body, which flips back to `:runtime`. This covers both metaprogrammed definitions
  and compile-time-only module statements with no definitions
  (`if true do Module.put_attribute(..., 1 + 2) end`, `for n <- [1, 2]` doing
  compile-time work, `(1 + 2; 3 + 4)`, etc.). It propagates through arbitrary nesting
  (`for` in `if` in …) and through `case`/`cond`/`with`/`fn` arms (the `->`/`cond`
  clauses inherit liveness via `body_context/1`, so a scaffold-wrapping construct
  keeps its own arms inert). Unknown module-level macro calls with block keywords
  are the conservative exception: their shell and non-block args stay compile-time,
  but the block bodies are analyzed as runtime because a DSL may unquote them into
  generated functions. A **registered known macro overrides that guess** per argument:
  `analyze_module_macro_block/2` reads the `meta[:mutare_macro]` stamp, and a `:skip`
  arg (`{DSL, :schema, 1, :skip}`) is left **raw** — no descent, no mutation. Without
  this, the runtime-body guess mutates an opaque `schema do … end` DSL body (`:age`,
  `default:`, `1 + 1`) and can poison the very DSL the registry was meant to exclude;
  the generic runtime clause honoured the stamp, but this module-level path didn't until
  it read the same stamp. Only `:skip` is honoured here (the other treatments are
  compile-time-context-sensitive and the default already does the right thing —
  `:expression` *is* the runtime-body guess; `:pattern` has no module-level use).
  The unquoted head pattern (`def code(unquote(atom))`) is
  analyzed `:pattern` and never mutated — correct, since these are not lifted.
  **Crucially**,
  the *mixed* case works for free: when a function has both a normal top-level head
  and metaprogrammed heads (`def code(0), do: 53` beside the `for`), the top head
  falls back to in-place via `metaprogrammed_def_names` and the `for` heads route
  through `:scaffold` — both bodies mutate in place, independently (no dispatcher, so
  no shadowing). Still **out of scope**: mutating inside `unquote(expr)` (compile-time
  splice; deferred, as for `quote`), and lifting any of these
  (head-pattern/guard/clause-drop mutants).
- **Private names** are `<prefix><name>_<arity>_g<group>_{orig,m<id>}`. The
  group counter keeps generated names unique *among themselves*, and `?`/`!`
  (legal only at a name's end) are replaced so they can sit mid-identifier. The
  public dispatcher keeps the real name.
- **The generated names are collision-checked, not fixed strings.** Both the
  private-function `<prefix>` (normally `__mutare_`) and the dispatch variable
  (normally `mutare_active`) are picked from one per-file scan of every identifier
  the source mentions — def-like names (`@def_forms`) *and* variables —
  (`Transform.generated_names/1`). A clash is catastrophic and *silent* either way:
  a duplicate `defp` sinks the one metamutant build, and a captured variable
  mis-dispatches (`def f(mutare_active, mutare_active)` is legal Elixir — an
  equality match — so it compiles wrong with no error). So:
  - the prefix shifts to `__mutare_0_`, `__mutare_1_`, … (the first stem no source
    identifier starts with) when the target uses a `__mutare_`-prefixed name;
  - the dispatch variable shifts to `mutare_active_0`, `mutare_active_1`, … (a
    numeric suffix, *not* the `__mutare_` prefix — a leading-underscore variable
    that's then *read* warns "used after being set") when the target uses the
    `mutare_active` identifier.

  Common case (neither name appears in the target): zero change. The dispatcher's
  `mutare_argN` params are fresh locals in a generated head and can't collide. The
  selector's `:persistent_term` *key* `:mutare_active` is a separate global and
  stays fixed — a key can't collide with a source variable. (`Manifest` recognises
  a lifted mutant by its `<active_var> === <id>` *gate*, not a name, so the salt is
  invisible to it.)
- **Lifting adds one gated clause per mutant** (`C+M`, not `K+1` full copies — see
  "lifting blowup"), so code size / single-compile time grows linearly with
  mutation density rather than multiplicatively.

### `super` in a lifted body — forward through a dispatcher closure `[done]`
`super` is a special form legal **only** inside the overriding function (it invokes
the function it overrides). Lifting relocates a clause body into a private
`defp __mutare_…`, whose name is **not** the overridden one — so a `super` there is a
compile error ("super is undefined"), which (the lib compiles once) would sink the
whole metamutant build for *every* lifted override that calls `super`. Real Phoenix /
behaviour-heavy targets do this constantly (`def render(...), do: super(...)` over a
`defoverridable`).

The fix keeps the rewrite local and is **off unless a lifted body actually calls
`super`** (the common path is byte-for-byte unchanged). The key facts:

  - The public **dispatcher keeps the original name**, so it *is* the overriding
    function — `super` is legal there, **including inside a closure** (verified).
  - `super` must be called with **exactly** the function's full formal-parameter
    count ("super must be called with the same number of arguments as the current
    definition" — verified; even with default args, where the legal arity is the
    *max*, i.e. the head's `length(args)`, which is exactly the `FunctionPlan`
    signature arity). So **one fixed-arity closure forwards every legal `super`
    call.**

So when `Mutare.Transform.Super.in_clauses?/1` finds a `super` in any clause **body**,
the dispatcher binds

```elixir
mutare_super = &super/arity
```

(exactly `fn a1, …, aN -> super(a1, …, aN) end`, but the capture needs no synthesised
arg list of its own — `super`'s only legal arity is the full param count) and threads
it to the base as the **second** argument (after `mutare_active`); each `super(args)`
in the relocated body is rewritten to `mutare_super.(args)` (`Super.rewrite/2`). Sharp
edges, all handled:

- **Per-clause unused param.** The base's arity is shared across clauses, so *every*
  base clause takes the closure param — but only the clauses whose own body calls
  `super` use it. A clause that doesn't names the param a **bare `_`** (each base
  clause is a separate `defp`, so the name can differ per clause), dodging the
  unused-variable warning that would otherwise poison a `--warnings-as-errors` target.
  It must be a bare `_`, **not** a salted `_mutare_super`: that underscored name could
  *duplicate* a source variable already in the same head — a super-free sibling clause
  whose head reuses `_mutare_super` (`mutare_super` is salted away from the read form,
  but the *underscored* form is not, and `Names.salted/2` only checks the bare
  `mutare_super`). A repeated underscored name both **warns** ("appears more than once
  in a match") *and* silently turns the head into an **equality match** (`_mutare_super
  == _mutare_super`, i.e. closure == arg), so the baseline never matches that clause and
  dispatch raises `FunctionClauseError`. `_` never binds, so it can neither collide nor
  constrain however many appear — provably safe without a second salt.
- **Collision-free name.** `mutare_super` is salted per-file exactly like
  `mutare_active` (`Names.salted/2`, canonical `:mutare_super`) — it is *read* in the
  base body, so it can't be underscore-prefixed (a read underscore var warns), and a
  source variable named `mutare_super` would otherwise be captured (a `super(x)`
  rewritten to `mutare_super.(x)` would call the user's value). Salts to
  `mutare_super_0`, … when taken.
- **Captures are rewritten too.** A `super` *capture* `&super/arity` (not a call) is
  rewritten to the bare `mutare_super`, because `super` can only ever be captured at the
  function's full param count — its single legal arity, the very arity the closure is
  bound at — so `&super/arity` is value-identical to the variable. **Not** `&mutare_super/
  arity`: `mutare_super` is a *variable* holding the function, and `&name/arity` captures
  a *function* of that name, so `&mutare_super/arity` would fail to compile. The capture's
  `super` node carries an atom context (not an arg list), so the call-rewrite clause
  skips it — and so would detection: without the dedicated clause a **capture-only** body
  (never a direct `super(...)`) would read as super-free, lift without a closure, and
  leave an uncompilable `&super/arity` in the base. A `super` *called* inside a capture
  (`&super(&1)`) is the ordinary call form and rewrites to `&mutare_super.(&1)` by descent.
- **`quote` is level-aware, not pruned.** A `super` inside `quote do … end` is usually
  quoted *data* (it names whatever context the AST is later spliced into, not a live
  call), so it is left untouched, and a body with only such `super`s reads as super-free
  and lifts **without** a closure. But a quote can *evaluate* a `super` while building
  the AST: `unquote(super(x))` (the unquote escapes the quote) and
  `bind_quoted: [x: super(x)]` (a quote *option*, evaluated at construction) both run
  the `super` now — so pruning the whole quote (the old behaviour) left those raw in the
  relocated base and the metamutant failed to compile for valid source. The walk threads
  a **quote-nesting level** (`walk/3`): a `super` is live (rewriteable) only at level 0;
  `quote` raises the level for its *block* values (`do`/`else`/`after`/`catch`/`rescue`),
  `unquote`/`unquote_splicing` lower it, and a quote's *option* values stay at the
  quote's own level. So `unquote(super(x))` / `bind_quoted:` supers are detected and
  rewritten, a plain quoted `super` stays data, and a `super` in an inner quote that one
  `unquote` can't escape (level still > 0) correctly stays data. (Keyword keys are bare
  atoms under `Code.string_to_quoted` but `{:__block__, _, [k]}` under Sourceror —
  `block_key?/1` handles both.) Out of scope, like the analyzer: `quote unquote: false`
  — a `super` in an `unquote(...)` there is data but would still be rewritten; harmless
  unless that exact shape appears. Detection and rewrite share one walk (`Super` is
  `{ast, found?}`) so they can never disagree on what counts as a live `super`.
- **Defaults / heads are not scanned.** Only the body is inspected: a `super` in a
  default value rides on the dispatcher (the override, which may call `super`
  directly), and `super` can't appear in a head/`when`. Heads (bodiless or otherwise)
  thus never trip detection.
- **In-place functions need nothing.** A function that *isn't* lifted keeps its name,
  so its `super` is already in the overriding function — untouched.

`Mutare.Transform.Super` owns recognising/rewriting the `super` nodes (pure,
testable); `Mutare.Transform` owns building the closure + threading the extra arg
(`super_closure_binding/2`, `super_param/2`), since that shares the dispatcher /
lifted-clause emission. Alternative considered and rejected: **skip-lifting** any
`super`-using function (simpler, but costs it all guard/head-literal/clause-drop
mutants — and these override functions are exactly the ones worth mutating).

### Default arguments are lifted `[done]`
Default args (`def f(a, b \\ 1, c, d \\ 2)`) were left in-place for a long time —
they "expand to multiple arities", which sounded like it needed a normalize pass
first. It doesn't. A default-arg function lifts cleanly with one observation:

  **`\\` defaults ride on the public dispatcher; the lifted base takes the full
  arity with the defaults stripped.** The dispatcher head is the only place a `\\`
  may legally appear, and it keeps the source's defaults verbatim — so the public
  function's whole arity range (`f/2`, `f/3`, `f/4` for the example) still resolves.
  Its body forwards the *resolved* args (`__mutare_f_4_g1(id, a, b, c, d)`) at the
  full arity, so the base never needs defaults. The base clauses strip `\\` to the
  bare pattern (`clause_parts` / `Transform.strip_arg_defaults`).

What makes the arg-renaming safe: **a default value cannot reference another
argument** — Elixir evaluates each default in an isolated scope (`def f(a, b \\ a)`
is "undefined variable a"). So the dispatcher is free to rename every position to a
catch-all `mutare_arg_i` (which it must, to widen the domain so a head-literal
mutant in the base is reachable) without ever breaking a default expression — the
defaults only reference module-level things (attributes, imports), all still in
scope on the dispatcher. The default *expression* is still a runtime position: it
keeps its in-place selector (lifted off the already-emitted clause in `orig_clauses`
by `Transform.clause_defaults/1`), so a `def f(x \\ 1 + 2)` still gets its `1 + 2`
arithmetic mutant — now living on the dispatcher head, firing only on the defaulted
call path.

Sharp edges handled:
- **Multi-clause + header.** With multiple clauses Elixir requires the defaults on a
  separate **bodiless header** (`def f(a, b \\ 1)` then `def f(a, b) when …`). The
  header supplies the dispatcher's defaults but is **not** a base clause — it has no
  body. `bodiless_header?/1` skips it in base emission (it formerly became a bodiless
  `defp` *header* for the base, which also compiled, but emitting it was needless).
  A header can only hold variables + defaults (Elixir rejects a literal pattern in a
  function head), so it never carries a head-literal / guard / structure candidate —
  discovery naturally finds nothing on it, and `build_drops` already skipped it.
- **Head literals under a default.** `tag_pattern_targets/3` descends a
  `{:\\, _, [pattern, default]}` node's *pattern* (so `def f(0, b \\ 1)`'s `0` lifts)
  but keeps the default raw — it is the runtime value, mutated in place, not a
  pattern literal.
- **Pattern structures under a default.** `pattern_structures_for/2` strips defaults
  before offering the args to `PatternSwap`/`PatternWildcard` (so `def f({x, y}, fmt
  \\ :short)` can swap `{x, y}`), then re-attaches each `\\ default` to its (same)
  position — structural mutations never move top-level args, so the zip is exact.

Out of scope still: operator-named functions (can't be spelled `__mutare_~>_…`) and
non-consecutive / metaprogramming-augmented clause groups (those are about *grouping*,
orthogonal to defaults).

### Timeouts — portable self-halt (M4 done) `[refine]`
A mutation can turn a terminating loop infinite. Each mutant run gets a
wall-clock cap (`baseline × :timeout_multiplier`, default 3.0, floored; or an
explicit `:timeout` ms), and a timeout counts as a kill (`:timeout`).

The cap is enforced **portably, with no process-killing**: the injected sandbox
watcher (a quoted AST owned by `Mutare.Sandbox.Command.watcher_ast/0`, rendered
into the bootstrap by `Mutare.Sandbox`) spawns a process that `System.halt(124)`s
after the deadline. The BEAM preempts a looping process, so the watcher always runs (even
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

### Per-worker DB partitioning (`:partition_env`) `[done]`
A suite with shared mutable state — the common case: an Ecto repo — can't have N
mutant `mix test` processes hammering one database concurrently; they corrupt each
other and manufacture false kills/survivors. `:partition_env` (off by default,
`--partition-db` for the `MIX_TEST_PARTITION` default, `--partition-env NAME` for a
custom var) hands each concurrent run a **distinct** partition id under a named env
var, which the target's `config/test.exs` reads to pick a per-worker database —
deliberately the `mix test --partitions` convention, so a project already set up for
partitioned tests needs **zero** code change (`database: "app_test#{System.get_env
("MIX_TEST_PARTITION")}"`). The user pre-creates `--workers` databases, the same
prerequisite `--partitions` has.

**Why a checkout/checkin pool, not `rem(index, workers)`.** `Task.async_stream`
hands each item no stable lane index, and modulo-index is *unsafe*: tasks don't
finish in index order, so task `0` (→ partition 1) can still be running when task
`workers` (→ partition 1) starts — two live runs on one DB, the exact collision the
feature exists to prevent. So `Mutare.Runner.Partitions` is a pool of `workers`
tokens (partitions `1..workers`): a task checks out a free partition before
spawning `mix`, runs it (harness retries included — they recurse in the same task,
so one checkout covers them), and checks it back in (`try/after`, so a raise can't
leak a slot). Checkout never blocks by a counting argument: a checking-out task is
itself alive, so the *other* ≤ `workers-1` alive tasks hold ≤ `workers-1` tokens,
leaving ≥ 1 free. The pool is a tiny `Agent`; the runner owns its lifecycle. The
**one compile**, the baseline, and the coverage probe all run sequentially *before*
the pool, so they take a **fixed** partition (`1`) via the pure `entry/2` — there's
no concurrency to isolate there, but a partitioned suite still needs *some* valid DB
to green-check against. The compile is in that set deliberately: `mix compile`
evaluates the target's config under `MIX_ENV=test`, so a partitioned config that
reads the var without a default (`System.fetch_env!("MIX_TEST_PARTITION")`, no
`||`-fallback) would raise at config-eval and fail the *one* build with
`:compile_failed` — before the baseline/probe ever set the var. Threading the fixed
entry into the compile `Command.mix` (concatenated with `compiler_env/0`) closes
that gap; it also overrides any *stale ambient* `MIX_TEST_PARTITION` the harness
happened to inherit.

**Delivery is just the existing `:env` plumbing.** `Mutare.Sandbox.Command.mix/4`
already appends an `:env` list onto every sandbox `mix`; the partition entry rides
that, threaded through `timed_mix`/`timed_test` (new trailing `env` params,
defaulted `[]` for back-compat) and through `Baseline.run/3`/`CoverageProbe.run/4`.
`Command` stays partition-agnostic — the env is opaque extra to it; the runner owns
all "partition" semantics. Inert by default: `partition_env` `nil` → `Partitions`
`:disabled` → `[]` everywhere → byte-identical to the old behaviour.

Because the partition entry is *appended* to that base env, a `:partition_env`
naming a key Mutare itself sets (`MIX_ENV`, `MUTANT_UNDER_TEST`, the coverage
vars…) would land a duplicate key in the `System.cmd` env list, where Erlang's
resolution is unspecified — silently clobbering, say, `MIX_ENV`. So `Options`
rejects such a name up front, validated against the authoritative
`Command.reserved_env_names/0` (sourced from the very accessors that build the env,
so it can't drift). The pool-size↔`max_concurrency` coupling the non-blocking
checkout depends on is the other thing a future refactor could break silently —
flagged with an `INVARIANT:` comment at the `Task.async_stream` call.

**Distinct from the parked "shard mutants across machines" idea** (the early-exit
note below): that wanted to *split mutants* across runners and rejected
`--partitions` as the wrong axis (it filters *test files*). This is the opposite —
we run the *whole* selected suite per mutant and only want each concurrent worker
on its own DB. Reusing `MIX_TEST_PARTITION` here is purely to name a slot the user's
config already understands, not to filter tests.

### Kill detection stops at the first failure (`--max-failures 1`) `[done]`
A mutant is killed the moment *any* test fails — the verdict is killed-vs-survived,
not *which* test — so `Mutare.Sandbox.Command.timed_test/4` forces `--max-failures 1`
onto every per-mutant `mix test` (alongside the `--exit-status` kill code). ExUnit
then stops scheduling tests at the first failure: a strict speedup on the **kill
path**, the common case for a healthy suite, where the old behaviour ran the whole
suite to completion only to throw the rest away. A **survivor** run never reaches the
cap (0 failures), so it still runs the whole selected suite — survival genuinely
requires every test to pass, and that cost is unavoidable.

Safe against the exit-code contract: `mix test`'s exit status is driven *solely* by
`failures > 0` (verified in `Mix.Tasks.Test`), and `--max-failures 1` guarantees ≥1
failure on the failing path, so a kill still exits `failure_exit/0` → `:failed`. A
harness error (compile error / missing dep → 0 *test* failures, exit 1) and a timeout
(the watcher's `System.halt`) are both orthogonal to the flag. The argv is built by
the pure, unit-tested `Command.test_argv/1`, so the contract is checked without
spawning `mix`.

Scoped to the kill path *only*. The baseline (`Runner.Baseline`, a whole-suite green
check and the `baseline_ms` timing source) and the coverage probe
(`Runner.CoverageProbe`, which must run every test to record coverage) bypass
`timed_test/4` (they call `timed_mix`/`mix` directly), so neither is truncated — both
run the suite to the end as before. The per-mutant timeout cap is still scaled from a
*full*-suite baseline, which stays conservative (a killed mutant now finishes earlier,
not later).

Adjacent idea, **not** pursued: distributing mutation testing by sharding *mutants*
across machines (stable ids + the mergeable Stryker-schema JSON make this the natural
axis); `mix test --partitions` is the wrong tool — it only filters test files (no
build-path effect, verified), multiplies per-mutant process boots by the machine
count, and forfeits this first-failure early-exit. Out of scope for now.

### Mutations that break the *test suite's* compilation are kills `[done]`
Surfaced mutation testing on the plug library's `lib/plug/router`: 17 of 187
mutants landed as `:harness_error` (≈9%), all on `Plug.Router.Utils` functions
(`build_path_clause`, `parse_suffix`, `split`). Root cause — and it is **not** a
worker race (proven: `workers: 1` reproduces the exact same 17): these functions run
at the *test modules'* **compile time**, because the plug test scripts `use
Plug.Router` and the `get`/`match` route macros call them via `Plug.Router.__route__`
while the `.exs` test file is being compiled. `.exs` test files are re-evaluated every
`mix test` run, so the mutated helper runs each time; when the mutation makes it raise
(an empty `:binary.compile_pattern("")` → `ArgumentError`, a mutated guard → `nil`
`MatchError`/`FunctionClauseError`, AliasLiteral's `raise Mutare.Mutant` sentinel),
the **test module fails to compile** and `mix test` exits `1`.

Exit `1` is the one ambiguous code in the contract — a real harness failure (missing
dep, infra compile error) *and* this. But they are different verdicts: a mutation that
stops the suite from even building **was detected** — that is a kill, the standard
mutation-testing reading, not an infra failure dropped from the score. The two are
tellable apart because the **metamutant lib compiles exactly once** before any mutant
runs (poison handled at baseline), so a *fresh* compile error during a per-mutant `mix
test` cannot come from the lib — only from a re-evaluated `.exs` test script the
mutation broke at load time.

So `Command.outcome/2` refines `outcome/1`'s exit-`1`→`:harness_error` case with the
run's output: a `== Compilation error in file <path> ==` banner whose `<path>` is a
`.exs` under a `test/` dir (`suite_compile_error?/1`) → `:suite_compile_error`, which
`Runner.status_for/1` maps to `:killed`. Anything else — a lib-file compile error, a
missing dep, no banner — **stays `:harness_error`** (fail safe: an ambiguous failure
is never charged as a kill). This is the **only** place the contract reads output
rather than just the exit code; the split is deliberate and confined to this one case.
A `:suite_compile_error` never reaches the reporters — it becomes `Result.status ==
:killed` in the runner — so the `Result`/Stryker status vocabulary is untouched. It is
also not retried (only `:harness_error` is) and skips the per-mutant harness warning.
Effect on the plug run: 83.7% (128 killed, 17 harness-error) → 85.3% (145 killed, 0
harness-error), and the misleading "fix your sandbox" warnings vanish.

Deferred: the same shape exists for *any* compile-time-executed code (compile-time
`@attr` expressions, `EEx`/`use`-time calls, custom route DSLs). The discriminator is
general (any test-script compile error), so those are covered too — but if a target
compiled lib modules *lazily* per-run (it doesn't today; the metamutant is built
once), a lib compile error here could be a real kill we conservatively keep as a
harness error. Acceptable while "lib compiles once" holds.

### Test selection — self-recorded coverage (M3b done, race-free redesign) `[done]`
Coverage-driven *test selection* is done at **test-file** granularity from a
**single instrumented `mix test` run** at baseline (`MUTARE_COVERAGE=1`). A mutant
runs only the files that covered its line (`:no_coverage` if no test ran it at
all). `test_selection: :full` (or `--full`) reverts to whole-suite-per-mutant
(no-coverage detection only). `:cover` is gone entirely.

**How the capture is race-free.** The metamutant self-records. Every selector
catch-all runs at baseline, *in whatever process runs the line* — including the
test process, synchronously. So under a tracking flag the catch-all writes the
site's mutant ids into shared ETS:
`mutare_active == 0 and :persistent_term.get(:mutare_track, false) and MutareCov.hit(ids)`
(`Mutare.Coverage.Recorder` owns this; `MutareCov` is a dependency-free helper
`Sandbox` writes into the sandbox). Three keys, accumulate-only, **never reset** →
no race:
- **aggregate** `{id}` — written by any process → process-agnostic no-coverage
  detection.
- **attribution** `{{label, id}}` — `label` is resolved in three tiers (`label/0`)
  → maps to the test *file* → per-file selection:
  1. the test process's own `Process.set_label({case, name})` (proc-dict
     `:"$process_label"` on OTP 26, `:proc_lib.get_label/1` on 27+);
  2. for a `Task` (no own label), the owning test's label recovered from the
     `$callers`/`$ancestors` chain — read cross-process (`:proc_lib.get_label/1` on
     27+, the target's `:dictionary` via `Process.info/2` on 26) — so a task spawned
     from a test still attributes to that test's file;
  3. for a `setup_all` (no label, no caller chain), the owning *module* recovered
     from the `{module, __ex_unit__, 2}` frame on its own `current_stacktrace`
     (`stacktrace_label/0`): a `setup_all` runs in an unlabeled, caller-less process
     but synchronously inside the test module's generated `__ex_unit__/2` dispatch,
     so the module is right there on our stack. Module granularity == file
     granularity, all selection needs. *Soundness*: this captures every test that
     observes the mutation through the `setup_all` **context** (module-scoped — the
     common case), but NOT a different module's test that fails only because the
     `setup_all` had a cross-module global side effect (a seeded DB, a
     `:persistent_term`) — that id, run only against its own file, could survive.
     That is the same cross-file-dependency limitation `:coverage` already has for
     ordinary attribution (`:full` is the escape hatch); the change is that
     `setup_all` no longer gets the *extra* whole-suite conservatism the unlabeled
     bucket used to give it. See "setup_all stacktrace recovery" below.
- **unlabeled** `{id}` — written when *no* tier recovers a label: `on_exit`/a
  bare-spawned process, or the rare `setup_all` whose work ran off-stack in a `Task`
  it spawned (a fresh stack with no `__ex_unit__/2` frame). The line ran, but no test
  owns it. The reconciler runs the **whole suite** for such an id (below).

**Why the record sits at value *production*, not behavioural execution — essential
for captures.** The catch-all records when the *selector expression evaluates* (i.e.
when the mutated node's value is produced), then yields the verbatim original
(`record(ids); <original>` — the record is a discarded statement, so the branch value
is byte-identical to the source). For an ordinary call this placement is invisible:
producing the value *is* running the behaviour, so "record at the expression" and
"record when the mutation's effect runs" coincide and no test can tell them apart.
**Captures are the one construct where the two pull apart** — the value is created in
one place and *invoked* in another, or never invoked at all. A mutated function
capture (`&String.first/1` → `&String.last/1`, the planned capture-mutation family) is
killable by **identity comparison alone** — `&String.first/1 == &String.last/1` is
`false`, external funs comparing by MFA — with the captured function *never called*.
Recording at production keeps that test visible (the comparison sees the produced
value); recording *inside* the captured function, on invocation, would miss it,
mis-score the mutant `:no_coverage`, and silently drop a killable mutant from the
denominator. So anchoring coverage **outside** the captured function (at the
value-production site), not **within** it, is what preserves the identity-kill path.
This isn't a special case for captures — the general design records at the mutated
*node's* evaluation, and the can't-splice-inside-`&…/arity` rule forces the mutated
node to be the *whole* capture expression (whose evaluation is value-production); the
capture analysis just exposes *why* that anchor is the correct one. (Same root reason
the baseline branch must stay the **literal** capture, never an eta-expanded `fn`:
`fn x -> String.first(x) end != &String.first/1`, so a rewritten baseline would break
identity at mutant 0 — the record-as-statement form keeps the branch value verbatim.)

The bootstrap is split around the target's `test_helper.exs`: the setup half is
prepended before user helper code creates the ETS tables and flips
`:mutare_track`, so app startup or helper setup that touches mutated code is
captured; the dump half is appended after the helper, because
`ExUnit.after_suite/1` is only registerable after `ExUnit.start/0`. The helper
module itself is written under a generated `lib/__mutare__/…` path with an
Erlang-style atom module name, so a target's own `lib/mutare_cov.ex` /
`MutareCov` source is neither overwritten nor redefined.

Why not the obvious thing — one `--cover` run with a formatter snapshotting per
test: **ExUnit formatter events are async casts**, so a formatter's
`:cover.reset/analyse` races test execution (confirmed once: the first test saw
every line, the second saw none — fast `async: false` modules lose coverage). The
only *synchronous* per-test code is `setup`/the test body, which we can't inject
into the target's modules — but the metamutant *is* code we generate and that runs
there. So the capture lives in the metamutant, not in an external observer of a
global table. (The previous workaround ran each test file as its own `--cover`
subprocess — N boots, race-free but slow, and lost coverage driven by `setup_all`
to a false `:no_coverage`; the aggregate-vs-attribution split fixes that too.)

Gate cost: per-mutant runs short-circuit on the integer compare (`active != 0`) →
~zero hot-loop overhead; the baseline green run and Mutare's own unit tests
short-circuit on the persistent-term read (`:mutare_track` unset) so `MutareCov` is
never *called* there. `MutareCov.hit/1` returns `true` so the `and` chain stays
boolean (an `:ets` write returns an int/`true` → would raise `BadBooleanError`).

The probe's decision is **typed** (`Mutare.Runner.CoverageProbe`): `selection` is
`:run_all | {:selective, %{id => outcome}}`, `outcome` is `{:run, test_args} |
:no_coverage`. The `{:selective, _}` map is **total** — every mutant id has an
explicit outcome, so `:no_coverage` is *named*, never implied by a missing key.
Reconciliation, per id: never ran → `:no_coverage`; ran in **an unlabeled
process** → `{:run, []}` (whole suite); else ran with attributed files →
`{:run, files}`. The unlabeled check **dominates attribution** on purpose — this
is the fix for a real false survivor. An id can be attributed to file A (a test
there touches the line) *and* be covered via an unlabeled process. The old rule
"ran with attributed files → those files" trusted the partial attribution, ran only
A, and missed the unlabeled killer → the mutant survived. So a single id hit even
once in an unlabeled process now runs the whole suite, regardless of what attributed
it. `Task` and `setup_all` coverage are *exempted* by the caller-chain and
stacktrace recoveries above (tiers 2 and 3), so the common "spawn a task in a test"
and the common module-scoped `setup_all` both attribute and stay tight; only
genuinely owner-less coverage (`on_exit`/a bare spawn/a `setup_all`-spawned `Task`)
goes whole-suite. `:run_all` is the single conservative fallback: a non-zero probe exit (the dump may
be partial — e.g. `max_failures` aborts before later files), an unreadable dump, or
an empty dump (the capture recorded nothing → it likely failed). The rule
throughout: never skip on doubt — run everything rather than silently drop a mutant
from the score's denominator.

**setup_all stacktrace recovery (done).** Originally `setup_all` coverage went
straight to the unlabeled bucket → whole suite, on the premise that an unlabeled,
caller-less process carries *no* recoverable owner. That premise is too strong:
`setup_all` is dispatched **synchronously inside the test module's generated
`__ex_unit__(:setup_all, _)`**, so a `{module, __ex_unit__, 2}` frame is on the
recording process's own `current_stacktrace`. Tier 3 of `label/0`
(`stacktrace_label/0`) reads it and attributes the id to that module's file — and
since `setup_all` is per-module, module granularity is exactly the file granularity
selection wants. This is strictly tighter than whole-suite *and* still fixes the
original false survivor (the motivating case: file B's `setup_all` builds a value
B's own test asserts → attributing to B and running B kills it). Why this is sound
where the general worry isn't: the `setup_all` **context** is module-scoped, so only
the owning module's tests can observe the mutation *through it* — except for a
`setup_all` with **cross-module global side effects** (a seeded DB, a
`:persistent_term` another module's tests read without touching the line). That id
now runs only its own file and could survive — but that is the *same*
cross-file-dependency hole `:coverage` already has for ordinary per-file attribution
(`:full` runs every covered mutant whole-suite and is the documented escape hatch).
Net: we dropped the *extra* conservatism `setup_all` alone got, making it consistent
with every other attribution in `:coverage` mode. Boundaries: `:setup` needs nothing
(it runs in the labeled test process — tier 1); a `setup_all` whose work runs in a
spawned `Task` has a fresh stack with no `__ex_unit__/2` frame and *no* labeled
ancestor (its caller is the unlabeled `setup_all` process), so it correctly falls
to unlabeled → whole suite. Cost is only paid when tiers 1–2 miss (i.e. exactly the
`setup_all`/`on_exit`/spawn cases), never on the labeled-test hot path. Found while
investigating why `setup_all`-heavy suites ran the whole suite for so many ids;
considered (and rejected) rewriting test files to label these processes — too much
blast radius for the trust anchor, and stacktrace recovery gets `setup_all` for free
without touching tests. `on_exit` stays unrecoverable (detached runner-loop process,
TCO erases the callback frame).

**The `hit([ids])` argument must render as a list, never a charlist.** The catch-all
splices `MutareCov.hit([<ids>])` into the metamutant, where `<ids>` is a list of
mutant ids. A *bare* list of small integers triggers Elixir/Sourceror's "small-int
list is a charlist" printer heuristic: `[91, 92]` renders as `~c"[\"` (char 91 =
`[`, 92 = `\`) — and there the trailing `\` escapes the closing quote, leaving an
**unterminated charlist** that breaks the metamutant's re-parse (`Manifest.from_source`
→ `Sourceror.parse_string!` crash) and takes down the whole run. It only bites when
ids land on `\`/`"`/control chars, so it stayed hidden until a real target
(`plug`) accrued ids in that range. `Recorder.record_ast/1` now wraps each id in a
`{:__block__, [], [id]}` node (`ids_literal/1`), which keeps them ordinary integers
at compile time but forces a list rendering. Any future hand-built integer-list
literal spliced into generated code has the same trap — wrap, don't pass a bare
list. (Note `inspect/1` charlists too, so tests assert against
`inspect(ids, charlists: :as_lists)`.)

### Baseline split from the coverage probe (done)
The probe used to *double* as the green baseline check, which conflated two
concerns and got both subtly wrong. `Mutare.Runner.Baseline` now runs the whole
suite once (no `--cover`) as the authoritative green check and the source of
`baseline_ms`; `Mutare.Runner.CoverageProbe` runs afterwards and only decides test
selection. Two bugs the split fixes:
- **Inflated timeout cap.** The old `:coverage` probe summed each per-file `mix
  test` run's wall-clock into `baseline_ms` — so `baseline_ms` carried N process
  boots, and `baseline × multiplier` produced a cap far larger than one real suite
  run. The cap is scaled from a *single* whole-suite run now.
- **Suite never confirmed green together.** Running files one at a time never
  exercises the suite as a whole, so a cross-file dependency could pass file-by-file
  yet the suite's real state went unchecked. The baseline run checks it once,
  together. Because the green check is now separate, a probe file that's red *in
  isolation* is no longer a baseline failure — coverage degrades to `:run_all`
  instead of aborting the run.
Cost: one extra whole-suite `mix test` per run (the baseline), negligible against
the hundreds of per-mutant runs, bought for correctness and a clean contract —
`Baseline.run/1` is the only thing that can abort with `:baseline_failed`;
`CoverageProbe.run/3` can't fail (it returns a bare `selection`).

### Configurable mutators — `{module, opts}` `[done]`
A custom mutator can be **parametrized**: a `:mutators` entry may be `{module, opts}`
(not just a bare module/family atom). `Mutare.Mutators.resolve/1` now resolves every
entry to a **`Mutare.Mutator.Spec`** `%Spec{module, name, opts}` — a bare built-in is a
spec with empty opts and `module.name()`; idempotent on an already-resolved spec.

Two design decisions, both load-bearing:

- **How opts reach the mutator.** The behaviour's callbacks are pure functions over a
  node, with no slot for config — except `mutate/2`, which already takes a
  `context` map (`%{pipe_mode: …}`). So opts ride **in the context**: `mutations/3` builds a
  per-spec context with `:opts` = the spec's opts and passes it to `mutate/2`. (At the time,
  `owned_args/2` shared this channel too; it has since been removed — see "Overlap resolution"
  below.) A configurable mutator therefore implements **`mutate/2`** (which is invoked
  on every node, not just pipe stages) and reads `context.opts`. `mutate/1` is left
  untouched (no context, no opts) — this avoided bumping every existing callback's arity and
  reused the one channel that was already threaded. `pattern_mutations/2` is **not** opts-aware
  (structural head-pattern mutators stay unconfigurable for now — out of scope, not a use case
  yet). The change is backward-compatible: existing `mutate/2` clauses match `%{pipe_mode: m}`,
  which still matches a map that *also* has `:opts`.

- **Identity.** `name` defaults to `module.name()`, but a reserved **`:as`** key in `opts`
  overrides it (and is stripped before opts reach the mutator). This matters because the
  recorded name is what reports show *and* what the `# mutare:ignore[...]` filter matches —
  so configuring the same module twice (`{M, as: :a, …}`, `{M, as: :b, …}`) needs distinct
  names or the two would be indistinguishable. The `Spec` (not the bare module) is what
  `Mutator.mutations/3` tags each mutation with, so `name`/`opts` travel through the candidates
  into `Site` (which records `spec.name`).

Plumbing: `Transform.transform_string` normalizes its `:mutators` opt through `resolve/1` at
the boundary (so tests passing bare modules, the default set, and the Options/Config path all
become specs); every internal consumer (`Mutator.mutations/3`, `analyze`'s structural-mutator
discovery via `Mutator.implementing/3` (`return_replacements`/`condition_replacements`) and
`RescueType` enablement via `Spec.find/2`, `PatternStructure`, `FunctionPlan`,
`Site.replace`) reads `spec.module`/`spec.name`/`spec.opts`. The CLI's `--mutators` CSV can't
express opts (strings only) — configured mutators are a `.mutare.exs`/`Mutare.run/2` feature.

### Overlap resolution — diff-derived, replacing `owned_args` `[done]`
A *call-rewriting* mutator (`ModeSwap`) and a *leaf* mutator (`AtomLiteral`) can target the
same node: `DateTime.truncate(dt, :second)` → ModeSwap rewrites the call to `:millisecond`
(a useful mutant), while AtomLiteral would *also* turn `:second` into the sentinel `:mutare`
— an always-raising, trivially-killed, zero-signal mutant (a wasted suite run). We want the
call rewrite to win and the redundant leaf mutant gone.

The old mechanism was an optional `owned_args(node, ctx) :: [visible_index]` callback:
ModeSwap returned the argument positions it swaps, `analyze`'s `owned_arg_indices/3` unioned
them, and `recurse_runtime/3` routed those args through a non-mutating `:owned` context (so the
leaf was never offered). It was **unprincipled** in four ways, two of them real bugs:

- **Two callbacks that must agree.** `owned_args/2` and `mutate/2` had to claim the *same*
  positions; nothing enforced it (kept in sync only by both reading `swap_sites/4`).
- **Granularity mismatch (a bug).** Ownership was *position*-granular, but for a `shift`
  duration the mutation is *key*-granular within a keyword list — so the transform applied a
  blanket "own all keys, leave values" policy (`analyze_owned_keywords/2`). A key ModeSwap
  does **not** swap (`microsecond:`, excluded from its ladder) was then suppressed anyway
  **iff** a swappable sibling (`minute:`) shared the list. Empirically: `shift(dt,
  microsecond: {5,6})` alone → AtomLiteral fired; `shift(dt, minute: 10, microsecond: {5,6})`
  → AtomLiteral suppressed on `microsecond:` too. Same key, opposite treatment, decided by a
  neighbour.
- **Duplicate shape predicates** (`keyword_list_shaped?`/`owned_keyword_list?` in analyze vs
  `keyword_pairs`/`duration_list` in mode_swap) and **double computation** (the swap logic ran
  for `mutate/2`, again for `owned_args/2`).

The fix derives "what a mutant covers" **from the mutation itself**, in a new pre-emit pass
`Mutare.Transform.Overlap.resolve/1` run at the top of `emit/2` (before id assignment, so a
dropped candidate leaves no id/site and ids stay contiguous — same property as
`gate_candidates/1`; it *can't* live in the emit postwalk because that's post-order, visiting
the leaf before its enclosing call).

> **Superseded mechanism, kept for the "why".** The next several paragraphs (through "Residual
> contingency") describe the *original* range-based version of this pass — the one the
> `[done]` "node identity, not range" entry below eventually **replaced**. It is preserved
> because it is exactly the chain of empirical patches whose fragility motivated the nid fix;
> read it as the predecessor design, not the live code. Concretely: the live pass no longer
> uses `Sourceror` ranges at all — it stamps a per-node `meta[:mutare_nid]` in `Resolve` and
> prunes on nid-equality (see below). Wherever the text says "range", the code now says "nid",
> and the three denylist rules (rangeable / proper-sub-range / non-list) collapse into "carries
> a nid". The *behaviour* is identical; only the identity proxy changed.

A candidate's **footprint** was the source range of the
*minimal changed subtree* between its `original` and `mutated` (`footprint/3`, a meta-
insensitive lockstep diff that stops at the rangeable `{:__block__, _, [literal]}` wrapper, not
the bare value, and ranges the **original** side — the mutated literal has fresh `[]` meta and
no range). A candidate is **covering** when that minimal changed subtree is a genuine
single-node substitution: rangeable, a *proper sub-range* of the host (`footprint_range !=
host_range` — a **range** comparison, *not* a structural `sub === original` test), and **not a
list**. Both qualifiers are load-bearing and each fixed a real bug (below): the diff's minimal
subtree can be a *different term* from the host (or a list) that Sourceror nonetheless ranges
*identically* to the host (or to a single element). Any **non-covering** candidate whose host
range equals a covering footprint is dropped — exactly the redundant leaf mutation. It is:

- **exact** — distinct source nodes have distinct ranges (`NodeRange.get/1`), and the leaf
  candidate and ModeSwap's footprint derive from the *same* original subtree term, so their
  ranges are equal by value;
- **node-granular** — `microsecond:` (no swap → no covering footprint) keeps its AtomLiteral
  mutant **consistently**, alone or beside `minute:`; the `shift` amount (untouched by the
  swap) keeps Literal's; the duplicate predicates and the keyword special-case are gone;
- **zero-API** — no callback, so any future minimal-rewrite call mutator gets it for free.

**What's actually "covering" — and why only ModeSwap *drops* anything.** "Covering" needs the
minimal changed subtree to be a genuine single-node substitution: a proper, **rangeable**,
**non-list** descendant. **Two** built-ins produce one — but only the first matches a leaf, so
only it resolves to a drop:

- **ModeSwap** substitutes one rangeable literal arg/key → footprint = that literal, which
  AtomLiteral also hosts → the **only overlap that resolves to a real drop**.
- **`String.equivalent?(a, b)` → `Elixir.Kernel.==(a, b)`** (StringCall) changes **both** the
  module (`String` → `Elixir.Kernel`) *and* the fun (`equivalent?` → `==`) of the
  `{:., _, [mod, fun]}` callee while reusing both args, so the two changes climb to their common
  parent — the callee's `[mod, fun]` **list**, which carries no nid → **non-covering**. The reused
  args therefore keep their own leaf mutants (a literal `"x"` keeps both StringLiteral mutants).
  Both the direct and piped forms behave identically (the swap is the same shape at either arity).
  *Historical note:* when the direct form emitted a bare `a == b`, it replaced the whole callee
  with one atom — a `.`-dot-node footprint that *was* covering, but **inert** (the `.` node spans
  `Mod.fun`, a form position no value mutator hosts a candidate at). Promoting the emission to the
  *absolute* `Elixir.Kernel.==` (for shadow-safety — neither a local/imported `==` nor a rebound
  `Kernel` alias can redirect it; see "Absolute-qualify every generated cross-module name") changed
  *both* module and fun, turning the footprint into a nid-less list — non-covering rather than
  covering-but-inert. Either way it prunes nothing, so `ModeSwap→AtomLiteral` is now the **sole**
  covering footprint *and* the sole leaf-dropping case. Locked in by a transform test
  ("StringCall's equivalent? -> Elixir.Kernel.== is non-covering: it prunes no leaf").
- **Operator swaps / function renames** (Arithmetic, Relational, Collection, StringCall's
  *renames*, …) change a bare **form/name atom** — the operator (`:+`, the node's *form*) or the
  `fun` in a `{:., _, [mod, fun]}`. A bare atom in form position carries no metadata, so
  `NodeRange.get/1` is `nil` → **non-covering**. *This is the load-bearing property* that keeps
  every operator swap and rename from accidentally suppressing its leaf siblings — verified
  empirically (`Enum.take(xs, 5)` keeps Literal on `5`; `5 + 3` keeps Literal on both operands).
  It rests on Sourceror **not** ranging bare form-position atoms; if that ever changed, these
  would join the covering set (still harmless only because the analyzer keeps a call's form
  position opaque, so nothing hosts a candidate there).
- **Arity changes and operand permutation** (DefaultDrop, CollectionArity, CallRemoval's
  arg-drop; `OperandSwap`, `a - b` → `b - a`) — the differing subtree is the whole **argument
  list** (a drop changes its length; a permutation changes ≥2 of its elements). A list is never
  a value position a leaf mutator targets, so a **list-valued footprint is non-covering**
  (`{:diff, sub} when is_list(sub) -> nil`). Two shipped regressions made this necessary, both
  from a list ranging like something it shouldn't suppress:
  - *Infix `OperandSwap`*: Sourceror ranges `[a, b]` *identically* to `a - b`, so the args-list
    footprint equalled the **host** range and pruned the `Arithmetic`/`List` operator-swap
    sibling. (First fixed narrowly by the `footprint_range != host_range` proper-sub-range test;
    the broader `is_list` rule subsumes it — and the test stays, since it also excludes leaf
    swaps and whole-node replacements where `sub` *is* the host scalar.)
  - *Piped one-arg `DefaultDrop`*: `xs |> List.first(0)` has one visible arg, so the drop turns
    `[0]` into `[]`; Sourceror ranges the one-element list `[0]` *identically* to its element
    `0`, so the footprint equalled the **default's** range and pruned the `Literal 0` mutant
    (`AtomLiteral :none` for `List.last/2`). The proper-sub-range test did **not** catch this
    (`0`'s range is strictly inside the stage host), only `is_list` does.
  A real substitution (ModeSwap) descends *into* a same-length list to the one changed
  scalar/key, so its footprint is never a list — these rules leave it untouched.

**Covering mutators must yield a clean single-subtree diff — and `Calls` has to uphold that.**
The diff can only isolate a target when the mutant is "original with one subtree replaced". A
second shipped regression broke this for **bare imported calls** that `Calls` rebuilds as
`:qualify` (`import DateTime, only: [truncate: 2]; truncate(dt, :second)`): ModeSwap's rebuild
*requalified* the whole call (`truncate(...)` → `Elixir.DateTime.truncate(...)`) **and** swapped
the mode atom, so the diff saw two changes (form + arg) → whole-host footprint → non-covering →
the `:second`/`minute:` leaf's redundant AtomLiteral `:mutare` came back (the very thing
`owned_args/2` used to suppress). Rather than teach the diff to ignore form changes (fragile —
cross-shape operand diffs would mis-resolve), the fix is at the **`Calls`** layer: requalification
only disambiguates a *renamed/re-aritied* sibling, so a **value-only** swap (same name *and*
arity — ModeSwap, OperandSwap's date/time call forms) now stays **bare**, resolving exactly as the
compiling original did. That keeps the mutant minimal (`truncate(dt, :millisecond)`, a cleaner
report diff too) and single-node, so Overlap covers the atom. `Calls.resolved_call/1`'s `:qualify`
rebuild keys on `new_fun == fun and length(new_args) == length(args)`.

**Residual contingency.** Earlier this entry flagged the single-element-args-list case
(`foo(0)` → `[0]` ranged like `0`) as a *latent* edge "no built-in triggers". That was wrong —
piped `DefaultDrop` triggers it (above), now closed by the `is_list` rule. The remaining
contingency is the **`nil`-footprint shield** for operator/function-name atoms: it relies on
Sourceror not ranging bare form-position atoms. If that changed, operator swaps and renames
would acquire footprints — harmless only because the analyzer keeps a call's form position
opaque (nothing hosts a candidate there), but worth knowing.

**The structural fix, now implemented: node identity, not range `[done]`.** Step back and the
three regressions above (infix `OperandSwap`, piped `DefaultDrop`, `:qualify`) were *one* bug: the
original mechanism used **`Sourceror` range-equality as a proxy for node identity**, and
`get_range/1` is **not injective** — distinct AST terms can share a range (`[a, b]` ≡ `a - b`; a
one-element call-arg list `[0]` ≡ its element `0`). The `nil`/whole-host/`is_list` rules were a
*denylist* of the non-injective shapes. A collision scan over a varied corpus was reassuring:
**every** distinct-node range collision puts a **list** (a container borrowing its element/sibling
range, → `is_list`) or a **form/machinery node** (operator, `.` dot, interpolation `::`, a `:do`
key — none of which host a value candidate, → the `nil`-shield / form-opacity) on at least one
side. Never two value-leaves, never a covering non-list footprint vs a value-leaf. So the denylist
was *empirically complete* for those families and that Sourceror — but **empirical, not proven**:
it rested on two external invariants (Sourceror never ranges bare form atoms; every collision is
list/machinery-shaped) that a Sourceror upgrade, an unprobed construct (`with`/`try`/exotic
sigils), or — most realistically — a **custom call-rewriting mutator** (which the moduledoc
invites: "any future minimal-rewrite call mutator gets it for free") could violate. The failure
mode is the worst kind for a mutation tool: a *false prune* = a **silently missing mutant**,
inflating the score with no error.

The once-and-for-all fix stops bridging the *raw* original subtree (in a candidate's `original`)
and the *annotated* host node with a **range** — the only reason ranges were used is that those
two aren't `===` (annotation rewrites `meta`), but they *do* share a range. `Mutare.Transform.Resolve`
now stamps a stable unique token `meta[:mutare_nid]` on every metadata-bearing node, in a single
DFS-counter prewalk (`stamp_nids/1`) run at the end of its `annotate/2` pre-pass — *before*
`analyze` attaches candidates, so a candidate's `original` carries the nid and a call rewrite's
footprint subtree (drawn from that same `original`) carries the matching one. `Overlap` reads it
via `Resolve.nid/1`, collects the nids of covering footprints (a footprint is covering iff its
minimal changed subtree is a *proper, nid-bearing descendant* — `sub_nid && sub_nid != host_nid`),
and prunes any non-covering candidate (footprint `nil`) whose host nid is covered. Lists and bare
atoms carry no meta → no nid → never covering, so **nid-identity subsumes all three denylist rules
*and* both unproven invariants** — the diff (`diff/2`, `reduce/2`) is kept verbatim (still
meta-insensitive, so the nid the wrapper carries never makes two equal nodes diff), but the
`NodeRange.get/1` lookups, the `host_range != sub_range` proper-sub-range test, and the explicit
`is_list(sub) -> nil` rule are all gone, replaced by the single `Resolve.nid/1` lookup. The bug
category is now unrepresentable. (`NodeRange` itself stays — the `Site`/report still ranges the
`original` for the diff; only `Overlap` stopped depending on range-as-identity. `:mutare_nid` joins
the render strip-list, like the other `mutare_*` bookkeeping keys.) The 18-way
`{call-family × leaf-family}` sweep and the per-key `shift` tests pin the behaviour unchanged.

Guards: scoped to `Candidate.InPlace` (ModeSwap is never lifted — date/time calls aren't
guard-legal — so no `Lifted`/`CaseClause`/… kind is touched), and drops **only** non-covering
candidates (a covering one is never pruned — a shield if a second call-rewriter's footprint ever
equalled another's host nid). Kept **separate** from `gate_candidates/1` (the
`call_option_keys` self-opt-out): that one is local, opts-driven, needs no cross-node info, and
post-order-insensitive — folding them would share a name, not logic. Both are members of one
informal "pre-id candidate pruning" phase. (A `shift` duration key is, incidentally, *both* a
ModeSwap-covered position and a call-option key — the two agree on a swapped key, and the
`call_option_keys` config governs the excluded ones; they compose without conflict.)

The one **intended behaviour change**: a `shift` with an excluded unit beside a swappable one
now emits one extra (harmless, guaranteed-killed) AtomLiteral mutant the old blanket policy
suppressed — the price of consistency, score-neutral.

### Absolute-qualify every generated cross-module name `[done]`
Generated code (the selectors, lifted clauses, and synthetic fallbacks the transform splices
into the metamutant) lands in the **target module's** lexical environment, which Mutare doesn't
control — the user may `import Kernel, except: [...]`, define a same-named local function, or even
`alias Foo, as: Kernel`. So any *cross-module* call we *emit* (not one we resolve from the source
and rebuild in its written form) must name its module in a way no environment can redirect.

The rule: **emit the absolute `Elixir.`-led alias** (`{:__aliases__, [], [:"Elixir", :Mod]}`),
which alias resolution never rewrites. Three levels of robustness, from weakest to this:

  * a **bare** name (`byte_size(s)`, `a == b`, `raise …`) resolves to a same-named local def or
    selective import if one shadows it — *wrong, silently*;
  * a **plainly-qualified** `Kernel.byte_size` / `Kernel.==` / `Kernel.raise` survives a shadow
    but a later `alias Foo, as: Kernel` redirects it — *wrong, or a compile error*;
  * the **absolute** `Elixir.Kernel.byte_size` is immune to both.

This was always the policy for *resolved-then-requalified* names (`Calls.qualifier`'s
`Elixir.Mod.fun`, the `=`-match/`case` `Elixir.MatchError`/`Elixir.CaseClauseError`, the
`witness_module` helper). It is now applied uniformly to **every freshly-constructed cross-module
emission**:

  * `Mutare.Mutators.StringByte`: `String.length(s)` → `Elixir.Kernel.byte_size(s)`;
  * `Mutare.Mutators.StringCall`: `String.equivalent?(a, b)` → `Elixir.Kernel.==(a, b)` (was a
    bare `a == b`);
  * `Mutare.Mutators.CallRemoval`: the piped no-op → `Elixir.Function.identity()` (was
    `Function.identity()`);
  * `Mutare.Transform`'s `=`-match and `case`-pattern fallbacks: `Elixir.Kernel.raise(...)` (was
    `Kernel.raise(...)` — only import-proof; the error module was already absolute).

`Elixir.Kernel.raise` is worth a beat: `raise` is a **macro**, and a macro *is* callable through
an absolute alias (`Elixir.Kernel.raise(...)` expands fine), so the same rule applies. The one
deliberate exception is `Mutare.Sandbox.Command`'s own `… |> Kernel.++(env)` — that is *first-party
harness* code in a module whose scope Mutare controls, not generated-into-the-target code, so a
plain qualifier (or even a bare one) is collision-free there.

Side effect on overlap: emitting `Elixir.Kernel.==` (vs bare `a == b`) changes *both* the callee's
module and fun, so the `equivalent?` footprint is now a nid-less `[mod, fun]` **list** —
*non-covering* rather than the old *covering-but-inert* `.`-dot-node. No behavioural change (it
pruned nothing before and prunes nothing now), but it makes `ModeSwap→AtomLiteral` the **sole**
covering footprint. See "Overlap resolution" above.

### Expanded default mutator set `[done]`
The built-ins grew from arithmetic+relational to a fuller catalog, **all on by
default**: **arithmetic** (now also unary `-x`→`x`), **relational**, **logical**
(`and`↔`or`, `&&`↔`||`, strip `not`/`!`), **literal** (integers `n`→`{n±1, 0}`,
`true`↔`false`), **conditional** (a boolean-valued node → `true`/`false`,
"remove conditionals"), **list** (`++`↔`--`, non-empty list literal → `[]`),
**collection** (complementary `Enum`/`List` call swaps — `filter`↔`reject`,
`all?`↔`any?`, `min`↔`max`, `min_by`↔`max_by`, `take`↔`drop`,
`take_while`↔`drop_while`, `sum`↔`product`, `List.first`↔`last`,
`List.foldl`↔`foldr`), **collection_arity** (arity-*changing* `Enum` calls:
`sort`/`sort_by`→`reverse`, `count/2`→`count/1`, `count_until/3`→`/2`,
`reverse/1`↔`sort/1` — pipe-aware via `mutate/2`), **string_call** (complementary
`String` call swaps — `starts_with?`↔`ends_with?`, `upcase`↔`downcase`,
`trim_leading`↔`trim_trailing`, `first`↔`last`, …; the `String` sibling of
`collection`), **map_keyword** (the conditional-write lattice for `Map`/`Keyword`:
`put`↔`put_new`↔`replace`↔`replace!` along the insert-new / overwrite-existing /
raise-on-absent axes; all `/3`, arity-blind; `:map` is taken by `MapLiteral`),
**call_removal** (remove a transparent transform — `Enum.sort`/`reverse`/`uniq`/
`dedup`/`shuffle`, `List.flatten`, `String.trim`/`downcase`/…, and `Kernel.abs`
(`abs(x)`→`x`) — leaving its first arg; in a pipe, replace the stage with
`Elixir.Function.identity()` (absolute-qualified so a rebound `Function` alias can't
redirect it); pipe-aware via `mutate/2`. The remote targets are arity-blind;
a bare `abs` is removed only at effective arity `/1` — the safeguard that a bare
unqualified `abs` is the `Kernel` one, mirroring Numeric's bare-`Kernel` path — and,
being guard-safe, reaches `when` guards via lifting), **default_drop** (drop a trailing default/fallback — `Map.get`/`pop`/
`Keyword.get`/`Enum.at`/`List.first`/`last` `/n`→`/n-1`, `get_lazy`/`pop_lazy`→base;
skips a literal-`nil` default as equivalent; pipe-aware via `mutate/2`), **string**
(a string → `""` *and* the sentinel `"mutare"`, dropping whichever already matches),
and **float**.
`Mutare.Mutators`'s `@registry` is the single ordered source of truth; `all/0`
returns every registered module, so registering a family makes it default.
(We briefly split a `:default`/`:optional` tier mirroring PIT's default-vs-
extended set, then dropped it as overly conservative — every built-in earns its
place by default; a user narrows via `:mutators`.)

Four non-obvious things settled here:

- **`collection`/`string_call` stay arity-blind; arity-*changing* call mutations
  live in `collection_arity`, and need pipe-context.** A rename that keeps the arg
  list (`filter`↔`reject`) is valid at every arity, piped or not — that's why
  `collection` is built that way. But an arity-changing mutation (`Enum.sort/2` →
  `Enum.reverse/1`, dropping the comparator; `count/2`→`count/1`) must know the
  call's *effective* arity, and that is **ambiguous from the node alone in a
  pipe**: Elixir doesn't expand `|>` until after Mutare sees the AST, so a stage's
  node carries one fewer argument than the source reads (the piped value is the
  `|>` LHS). `xs |> Enum.sort(:desc)` reaches a mutator as a 1-arg `Enum.sort(:desc)`,
  indistinguishable from a non-piped `Enum.sort(list)`. A first, node-local attempt
  mis-mutated the dominant pipe idiom three ways (a piped `sort/1` silently skipped,
  a piped `sort/2` rewritten to `reverse(xs, :desc)` garbage, a piped `reverse/2`
  wrongly swapped to `sort/2`). The fix is to **thread pipe-context to the mutator**:
  the `Mutare.Mutator` behaviour gained an optional `mutate/2` callback that
  `Transform` invokes at every runtime call position with `%{pipe_mode: :piped | :unpiped}` (a
  dedicated `:|>` analyze clause routes the RHS through `analyze_pipe_stage/2` with
  `pipe_mode: :piped`; everywhere else defaults to `:unpiped`). The mutator computes the
  effective arity via `Mutator.effective_arity(args, pipe_mode)` — the context carries the
  `:piped`/`:unpiped` atom directly (`length(args)`, plus one when `:piped`) — and emits a normal
  `Candidate.InPlace` — so the existing selector + `hoist_pipe` machinery delivers
  it unchanged, and the diff stays honest (`xs |> Enum.sort(:desc)` → `xs |>
  Enum.reverse()`, no shim). With effective arity in hand it even *correctly skips*
  `Enum.reverse/2` in a pipe (the case the naive version botched). The earlier
  alternative — a runtime shim module (`reverse/2` ignoring its 2nd arg) — was
  rejected: it needs a build-critical injected module and forces the diff to diverge
  from what runs. `collection_arity` is on by default.
- **Literal mutators must emit clean metadata.** Sourceror parses a literal as
  `{:__block__, meta, [value]}` and renders it back from a `:token` string in
  `meta`. Reusing the original meta would render the *original* text (`token:
  "1"` prints `1`) even after changing the value — a silent equivalent no-op
  that defeats the mutant. `Literal`/`FloatLiteral`/`StringLiteral` therefore
  build `{:__block__, [], [value]}` with fresh meta. (Verified: reuse-meta
  renders `1`, clean-meta renders `2`.)
- **Guard-safety is free for the new families, by two different routes.** Every
  mutator also runs on `when`-guard nodes (the lift path tags them), so a new
  family must stay guard-legal there. `logical`'s `and`/`or` and the stripped
  `not`, plus `literal`/`conditional` constants, are all guard-legal; the rest
  (`&&`/`||`/`!`, `++`/`--`, `Enum`/`List` calls) are *forbidden in guards by
  the parser*, so a source guard can never contain one and the mutator is only
  ever asked to swap them in a body. Either way: no guard poison.
- **`Site.original_op`/`mutated_op` are `:__block__` for literal sites** (they
  come from `elem(node, 0)`), which is fine — reports use the rendered
  `original_code`/`mutated_code` (`1 → 2`), not the op atom; the op fields are
  only used by tests/lookups that key on real operators.

Knock-on test work: the routing-focused `transform_test`/`schema_test`/
`lift_test`/runner fixtures that asserted exact site counts now **pin
`mutators:`** to the operator-swap families (`@probe`) — they test context
routing and lifting mechanics, not the default set, so pinning keeps their
counts stable while positive coverage of the new defaults lives in
`mutators_test` and one dedicated `transform_test`.

### Math + Integer families `[done]`
Two more remote-call families, both on by default:

- **`math`** (`Mutare.Mutators.Math`) — the Erlang `:math` module:
  `pi()`→`3.0`, `tau()`→`6.0` (a fresh float literal of the right shape, wrong
  value), the co-function swaps `sin`↔`cos` / `asin`↔`acos` / `sinh`↔`cosh` /
  `asinh`↔`acosh`, and the logarithm trio `log`↔`log2`↔`log10` (each maps to the
  other two). `:math` is an **atom module** — it cannot be aliased or shadowed — so
  matching the literal `:math` (Sourceror-wrapped `{:__block__, _, [:math]}`) is
  unambiguous, and every function in a swap group exists at the same `:math` arity,
  so the renames are arity-blind. All `:math` calls are remote → never guard-legal →
  always in place.
- **`integer`** (`Mutare.Mutators.Integer`) — `mod`↔`floor_div` (the two halves of
  floored division) and `is_even`↔`is_odd`; a Collection-style arity-blind remote
  rename keyed on `{[:Integer], fun}`.

**The non-obvious part: a guard-legal *qualified* macro broke the old "guard-safety
is free" assumption.** The expanded-set note above argued no built-in can poison a
guard because each is either guard-legal (constants, `and`/`or`) *or* parser-
forbidden in guards (`Enum`/`List` calls, `++`). `Integer.is_even`/`is_odd` are the
first family members that are **guard-legal qualified remote macros** — they *do*
appear in `when` clauses (the source's existing `require Integer` carries to the
lifted copy, so `is_odd` compiles). That exposed a latent bug in the guard lift
path: `FunctionPlan.tag_targets` used a context-free `Macro.postwalk`, which visits
the `{:__aliases__, _, [:Integer]}` node sitting in the call's *form* position and
offered it to `AliasLiteral` — minting a `when Mutare.Mutant.is_even(n)` mutant that
is **illegal in a guard** ("cannot invoke remote function … inside a guard") and
poisons the single build. The in-place analyzer never hit this because its `recurse`
descends a node's *args* only, never its *form*, keeping a remote call's module
opaque (the same reason `:erlang.foo()`'s module is untouched). The fix makes the
guard tagger mirror that: `tag_targets` is now an explicit post-order `tag_walk`
(args only, never form), so the whole call node and its arguments are still offered
(the `is_even`→`is_odd` swap, a literal argument) but the module alias is not. This
is *positive* compile-safety — fixing it at the classifier rather than leaning on
poison recovery, per the project's standing preference. (`:math`'s atom module never
reaches a guard — `:math` calls aren't guard-legal — so only the `Integer` path
needed the fix, but the fix is general: any guard-safe qualified macro is now safe.)

### OperandSwap — operand-order swap for non-commutative operators `[done]`
The operand-order sibling of the operator-swap families (`Arithmetic`/`List`): it
**keeps the operator and transposes the operands** of a non-commutative binary
operator — `a - b`→`b - a`, plus `/`, `**`, `<>`, `++`, `--`, and the `div`/`rem`
call forms. It catches the symmetric bug class the operator swaps miss: right
operator, wrong argument order (`elapsed = finish - start` written `start - finish`).
On by default; a plain node→node in-place mutation, so it needs no new `Site`
constructor and no `Transform` change — `mutate/1` returns the transposed node and
the existing in-place/lift routing delivers it.

The infix operators (`-`/`/`/`**`/`<>`/`++`/`--`) are always arity 2, never piped, so
`mutate/1` handles them arity-blind. `div`/`rem` are bare `Kernel` *calls*, so they go
through the pipe-aware `mutate/2` gated on **effective arity 2** — the same bare-`Kernel`
safeguard `Numeric` uses (confirms the builtin over a same-named user `div/3`), which
also guarantees the node holds *both* operands. A piped `x |> div(b)` draws its first
operand from the pipe, so there's nothing local to transpose — skipped (it has only one
visible arg, failing the `[left, right]` match). This differs from `Arithmetic`'s
`div`↔`rem`, a *rename* that keeps the arg list and so works piped too; both share the
arity gate, but only Arithmetic's variant is pipe-valid.

**Compile-safe by construction** — the mutant reuses both original operand subtrees,
just transposed, so whatever type-checked still does. Guard-safety is free the usual
way: `-`/`/`/`div`/`rem` are guard-legal and reach `when` guards via lifting like
Arithmetic; `**`/`<>`/`++`/`--` are parser-forbidden in guards, so they never reach
one.

**The two non-obvious exclusions (both about not minting useless mutants):**
- **Comparisons (`>`/`>=`/`<`/`<=`) are excluded** even though they're
  non-commutative — because an operand swap there is *semantically the direction
  flip* `Relational` already produces (`b > a` ≡ `a < b`). Including them would only
  duplicate Relational's mutant, inflating the denominator with no new signal.
- **Commutative operators (`+`/`*`/`==`/`!=`/…) are excluded** as guaranteed
  equivalent no-ops, and **`in` is excluded** because the swap (`[1,2] in x`) is
  generally not compile-safe (the RHS of `in` must be enumerable) — the one operator
  here where transposing isn't type-safe. `=`/`|>` likewise change binding/data-flow
  and are out.

Structurally identical operands (`x - x`, `5 / 5`) are skipped via a meta-stripping
compare (`Macro.update_meta` then `==`) — the transpose is a no-op there, so emitting
it would be an equivalent survivor. See `Mutare.Mutators.OperandSwap`.

### Return-value mutators `[done]`
PIT's largest, highest-yield group, now implemented: replace a function clause's
**return value** (its body's tail expression) with a fixed constant. Very high
signal — it asks directly "does any test pin what this function returns?". On by
default (`:return_value` family).

**Why it's structural, not a `Mutare.Mutator`.** Node-level mutators (`mutate/1`)
rewrite a matched node *wherever it occurs*; a return-value mutation targets the
*tail expression of a clause body*, a position only the transform knows. So the
real work is the `return_replacements/1` callback (a pure tail→constants function),
which `Transform` discovers by export and invokes once per `def`/`defp` `:do`-block tail it
finds (`annotate_returns/3`) — see "Structural in-place mutators generalized to callbacks"
below for the export-discovery generalization. The module still implements the behaviour — `name/0` is
`:return_value`, `mutate/1` is `:skip` — purely so it sits in the `Mutare.Mutators`
registry and inherits everything that follows from membership: on-by-default,
named in reports, selectable/validatable via `:mutators`, filterable by
`# mutare:ignore[return_value]`. (Contrast `clause_drop`, the *other* structural
built-in, which is always-on and not in the registry — return-value is registered
because it is high-volume and users will reasonably want to toggle it.)

**Delivery reuses the in-place selector.** A tail is a body position, so the
constant goes behind the same tail-position `case` as an operator swap — no new
emission machinery. The candidate (`Candidate.Return`) is *appended* to the tail
node's `meta[:mutare]`, so when the tail is also an operator site (`a + b`) one
selector hosts both mutants (`… -> a - b ; … -> 0 ; _ -> a + b`). It rides through
the in-place clause path, so it applies to non-lifted clauses *and* the `__orig`
copies of lifted ones (the `__mut` copies reuse the original body, exactly like
in-place body selectors).

**Compile-safety is free.** A bare constant is legal in any tail position, and the
original tail is kept in the selector catch-all, so variables the clause binds stay
used (no unused-variable poison under `--warnings-as-errors`).

**Which constants (a contrasting *pair*, shape-directed).** Mis-inferring the
shape is only cosmetic — *any* constant compiles and is valid signal — so
inference stays small and unambiguous, defaulting to `nil`. Each eligible tail
yields **two** replacements (mirroring `StringLiteral`'s `""`+`"mutare"` pair):
the shape's empty/zero value, and a non-empty/non-nil **sentinel**:

  - a numeric expression (`a + b`, `x * 2`, `div(a, b)`, `-n`) → `0` and `1`
  - a string concatenation (`a <> b`) → `""` and `"mutare"`
  - a list expression (`a ++ b`, `xs -- ys`) → `[]` and `[:mutare]`
  - anything else the tests might pin (variable, call, tuple, map, `:ok`/`:error`
    atom, an opaque-macro result, …) → `nil` and `:mutare`

The two halves catch *opposite* weak assertions. The empty/zero value dies to a
test that checks the result is present/non-empty/non-nil but survives one that
pins the exact value; the sentinel is the mirror — it dies to a test pinning the
value but survives one that only checks `!= nil` / truthiness / "list non-empty".
A result the suite never constrains leaves *both* alive (a doubly-loud survivor).
A sentinel equal to the original tail — reachable only for a bare-atom tail like
`def f, do: :mutare` — is dropped as an equivalent no-op, exactly as
`StringLiteral` drops the half equal to its source string (`Mutators.ReturnValue`'s
`equivalent_to?/2`; literal tails can't reach here, so only atoms can collide).

**What it deliberately *skips* (no redundant or low-value mutant):**
  - **boolean-valued tails** (a comparison/logical operator) — `Conditional`
    already forces them to `true`/`false`; mutating here would just duplicate that.
    The "boolean-valued op" test is `Conditional.boolean_op?/1`, the single
    definition shared between the two families.
  - **bare literals a value family already mutates** — integer/float/string/list
    literals and booleans (`Literal`/`FloatLiteral`/`StringLiteral`/`List` cover
    the node). A bare *atom* like `:ok` is **not** in this set (no family mutates
    arbitrary atoms), so `def save(_), do: :ok` *does* get `:ok → nil`.
  - **a `nil` tail** — `nil → nil` is equivalent; `nil → other` is low signal.
  - **a `quote` block** — macro-AST construction, which the analyzer already keeps
    whole (PHILOSOPHY: "macro-generated code is a different tool"); keeping
    return-value off it too is the simpler, consistent boundary.

**All return paths, not just `:do` (done).** A `def`/`defp` body has more return
paths than its `:do` block: each `rescue`/`catch`/`else` clause body also returns
(a rescued/caught error, or an `else` match on the do result). All four are now
targeted (`Transform.annotate_returns/3` → `annotate_block_returns/3`): the `:do`
tail via `attach_return/2`, and each clause body tail via `map_clauses/3` (the same
clause walk a `try` *expression* uses — a `def … rescue …` is an implicit `try`).
**`:after` is deliberately excluded** — `try` discards the after block's value, so
its tail is *not* a return path (a mutant there would be unobservable). The after
*body* still mutates in place; only its return-value candidate is withheld.

**Control-flow branch tails, not just the construct (done).** A clause tail that is
itself a `case`/`cond`/`if`/`unless`/`with`/`try`/`receive` used to be a *single*
leaf: the old `map_tail` returned the whole construct, so `ReturnValue` mutated
`case … end` as one node (→ `nil`/`:mutare`) and the **shape-aware GenServer mutator
saw a `case`, not the return tuples inside it, and fired on nothing**. That was the
dominant reach gap — idiomatic GenServer callbacks branch, and all their
`{:reply, …}`/`{:noreply, …}` tuples live in branch bodies. `map_tail` is now
`map_return_tails/3`: tail position is **transitive**, so a control-flow construct
*in tail position* propagates it into each branch body, and `return_replacements/{1,2}`
is offered at every branch's *leaf* tail instead of the construct. A branchy callback
now gets one return mutant per branch (finer signal: "is *this path's* result
checked", not "is the result used at all"), and the GenServer mutator finally fires
on the per-branch tuples (probe: 1 → 5 sites on a two-`case`/one-`if` server).

**One unified walk over `@return_blocks`.** All seven forms route through a single
generic `map_return_tails/3` clause keyed by a per-form map of which block keys are
return paths and of what kind (`:value` = a single tail; `:clauses` = a `->` clause
list). The keyword-block list is the **last** argument in every one of them (the
`case` scrutinee, the `if` condition, the `with` qualifiers all precede it), so the
walk splits it off uniformly. The map encodes the two asymmetries that matter:
`try`'s `:after` is omitted (its value is discarded) while `receive`'s `:after` is a
`:clauses` path (its timeout body *is* the construct's value); and a `with`/`try`
`:do` is a `:value` while a `case`/`receive` `:do` is `:clauses`. The def-level
`rescue`/`catch`/`else` handling folds into the same `map_clauses/3` the `try`
expression uses — a `def … rescue …` is an implicit `try`, so there is now one clause
walk, not two.

Three properties make it sound and self-limiting:
  - **Whitelist, not blacklist.** Only the seven `@return_blocks` forms are
    descended; every other node (an unknown block macro, a `quote`, a call, a
    literal) is a *leaf* — exactly the prior behaviour — so the change can't wander
    into compile-time / DSL territory. The **keyword form** of a clause-bearing
    construct (`with …, else: (c -> …)`, `case x, do: (… -> …)`) wraps its clause
    list in an extra `:__block__`; descending a sibling value would force Sourceror
    to re-render the whole construct in block form, where that wrapper renders as an
    illegal `[ -> ]` list — so `descendable_blocks?/3` leaves a non-canonical
    construct a leaf (mutated whole, which renders fine), exactly as before.
  - **Tail position is self-limiting.** A multi-statement block descends only its
    *last* statement, so a `case` that is bound (`y = case … end; baz(y)`) or a
    non-final statement is never reached — its branches are correctly *not* return
    paths. The recursion preserves this transitively.
  - **Delivery is unchanged.** A branch tail is an ordinary runtime body position,
    so the `Candidate.Return` rides the same in-place selector — no emission/`Site`/
    lifting change. The walker navigates the analyzed (operator candidates already
    attached) and raw (clean, for the diff `original`) trees in lockstep, bailing to
    the leaf clause on any structural surprise, so the diff still renders just the
    branch tuple. The condition of an `if`/`unless` is left untouched (wrapping it is
    the binding-escape machinery's job, not the return walk's).

One deliberate consequence: when *every* branch tail is a bare literal a value
family already mutates (`case x do :a -> 1; :b -> 2 end`), `ReturnValue` now returns
`[]` per branch (each is a `redundant_literal?`), so the old coarse whole-`case`
`nil`/`:mutare` mutant disappears. The per-branch `Literal` swaps cover the same
tests at finer grain, so this is a net improvement, not a loss.

**Anonymous-function clause tails (done).** A `fn`'s every clause returns its body's
tail when the closure is called — the same "function return" notion as a `def`
clause, one level down. Previously only the *enclosing* `def`'s tail was a return
path, so `def f(xs), do: Enum.map(xs, fn x -> foo(x) end)` mutated the whole
`Enum.map(…)` call but left the closure's `foo(x)` result unconstrained — a real
gap, since `fn` bodies are where map/reduce/filter logic lives. `analyze`'s `:runtime`
`fn` clause now pipes the analyzed node (the one `ClausePatterns` already built the
clause-pattern candidates onto) through `Returns.annotate_fn_returns/3`, which runs
the *same* per-clause `map_clauses/3` → `map_return_tails/3` walk the def-level
`rescue`/`catch`/`else` blocks use — so control-flow in a `fn` body (`fn x -> case …
end`) descends to each branch leaf tail too, and a guard (`fn x when … -> body`)
stays untouched (it rides in the clause's pattern list, not the body). Nothing new
in emission: the return candidates ride the tail nodes *inside* the clause bodies
while the clause-pattern candidates ride the `fn` node's own meta — different nodes,
so the body's in-place return selector and the whole-`fn` clause-pattern selector
nest cleanly in emit's post-order walk (the original branch of the outer selector
holds the already-emitted bodies; the mutant branches are raw copies). The hoisted
active-id read just works: a `fn` is a closure, so an enclosing `def`'s
`mutare_active` binding (dispatcher param or `:do`-prologue) is in scope inside the
body, and `references_var?/2` already descends `fn` to add the prologue when a body
selector needs it; persistent_term is process-constant, so a captured value is always
the live active id even if the closure runs in another process. Scoped to `fn`
**only** — `receive` (which shares `attach_clause_pattern_candidates/4`) is *not* a
function, so its clause tails are return paths only when the whole `receive` sits in
a `def` tail (already covered by `@return_blocks`), not standalone.

This surfaced (and fixed) a **latent pattern-context bug**. `rescue`/`catch`/`else`
are clause lists whose *left side is a match*, but the old `analyze_do_blocks/2`
analyzed every block value in `:runtime` — so a mutator could splice a selector
`case` into a rescue/else *pattern* (e.g. `e in RuntimeError` got a `Conditional`
`true`/`false`, a literal `1` pattern got a `Literal` swap), which is **illegal
Elixir** and poisoned the single build. It was *masked* by poison-recovery (the
runner dropped the ids and rebuilt), so results were correct but a rebuild was
wasted and a legitimately-impossible mutation was mislabeled `:poisoned`. The fix
(`analyze_try_clause/2`) routes each try-clause's patterns to `:pattern` and only
its body to `:runtime` — exactly how a function head/body split works. The routing
is unambiguous *only* because these blocks always pattern-match; `cond`, whose
clause left *is* runtime, is handled generically and must not be folded in.

  > **Resolved** (was deferred): the same `:runtime`-pattern issue affected
  > `case`/`fn`/`with`/`receive`/`for` clause patterns reached through ordinary
  > body recursion. The general fix anticipated here is now in place — a generic
  > `->` `analyze` clause pattern-routes the LHS, with `cond` intercepted first so
  > its genuinely-runtime condition keeps mutating (exactly the "no blanket `->`
  > rule" caveat). See the "Patterns" note above. The atom mutator forced the
  > issue: an atom in such a pattern is *very* common (`case x do :ok -> …`), so
  > leaning on poison-recovery would have risked exhausting the bounded
  > `@poison_attempts` budget — and, for a `do:` key, would have render-crashed
  > before compile even ran.

The `Site` each return mutant records (`Site.return_value/6`) has `kind: :in_place` and
`nil` ops (there is no operator), shaped like the clause-drop site that also carries no op;
its `mutator` name comes from the producing spec (see the next section).

### Structural in-place mutators generalized to callbacks `[done]`
Head-pattern structural mutators (`PatternSwap`/`PatternWildcard`) were always discovered by
export (`pattern_mutations/2`), so a third party could write one. The two structural
*in-place* families — `ReturnValue` (clause return tails) and `IfCondition` (`if`/`unless`/`cond`
conditions) — were the asymmetry: each was invoked by **hard-coded module name**
(`Mutare.Mutators.ReturnValue.replacements/1`) and gated by `Spec.find(mutators, <that module>)`,
so you could not write a custom return/condition mutator. (Foreseen in "Structural via an
optional callback" above.)

The fix mirrors `pattern_mutations/2`: two optional callbacks `return_replacements/1` and
`condition_replacements/1`, discovered by `Mutare.Mutator.implementing/3` (the shared "enabled
specs exporting `fun/arity`" helper, which `PatternStructure.mutators/1` now also uses). The two
`attach_return`/`attach_if_condition` sites ask **every** implementer instead of one built-in;
`ReturnValue`/`IfCondition` simply renamed `replacements/1` → the callback name. Each candidate
now carries the *producing* spec, so a custom mutator's name reaches the site:

- `IfCondition` already threaded its spec into `Candidate.InPlace`, so condition-position was
  nearly free.
- `Candidate.Return` had **no** `:mutator` field (the name was hard-coded at `Site.return_value/5`,
  which became `/6` taking the spec) — it gained one, so multiple return mutators coexist, each
  named (built-in `ReturnValue` 0/1 *and* a custom one on the same tail).

`RescueType` stays special — its mutation isn't a `(node) → [replacement]`; it rebuilds the whole
`try` (narrow a type list, drop a clause), so no clean callback fits and it keeps its
`Spec.find`-by-module gate. Fixture: `test/support/structural_mutator.ex`.

**Call resolution exposed too (`#2`).** `Mutare.Transform.Calls.resolved_call/1` — the helper the
8 built-in call families use to match aliased/imported/Erlang-atom calls and rebuild a swap in the
written form — was `@moduledoc false`. A custom call-matching mutator that pattern-matched the raw
`Mod.fun(...)` node would silently miss `alias`/`import` forms. It is now a documented public API
(the node a mutator receives in `mutate/1` already carries `Resolve`'s stamps, so it Just Works);
fixture `test/support/resolved_call_mutator.ex` matches `String.reverse` through both an alias and
an import.

**AST constructors exposed too.** `Mutare.AST` was `@moduledoc false`, yet it's what every
literal-producing mutator needs — and CLAUDE.md *told authors to hand-roll* `{:__block__, [],
[value]}`, which is wrong for strings (a bare `{:__block__, [], ["x"]}` renders as the charlist
`~c"x"` — `literal/1` adds the `delimiter`). Now public: `literal/1`, the `sentinel_*` markers
(so a custom survivor reads like a built-in one in reports), and the node predicates
(`nil_literal?/1`, `key_atom/1`, `keyword_label?/1`, `empty_collection_literal?/1`). Also advertised
`Mutare.Mutators.Conditional.boolean_op?/1` — the single "is this a boolean-valued operator"
definition `ReturnValue`/`IfCondition` already reuse — so a custom mutator can skip a node
`Conditional` already forces `true`/`false` rather than emit a duplicate. `test/mutare/ast_test.exs`
doctests the public surface and locks the string→`~c"x"` trap.

### IfCondition — force an `if`/`unless`/`cond` condition `[done]`
The "remove the decision" mutation for conditions, asked directly: *is each branch
this condition gates actually exercised?* On by default (`:if_condition`).

**Why it exists alongside `Conditional`.** `Conditional` already forces a
*boolean-valued node* — a comparison/membership/logical operator — to `true`/`false`
wherever it occurs, which incidentally covers `if a > b`. But that fires only where
the *node* proves it is boolean. A bare condition (`if user`, `if valid?(x)`,
`if is_nil(v)`, `if Map.has_key?(m, k)`) carries no such proof at the node, so
`Conditional` never touches it — yet *positionally* it is a boolean decision. That
gap is exactly what `IfCondition` fills.

**Why it's structural (like `ReturnValue`).** A condition *slot* is invisible to a
node mutator — a `mutate/1` that forced any node to `true`/`false` would fire
everywhere. So `mutate/1` is `:skip` and the real logic is the
`condition_replacements/1` callback, which `Transform` discovers by export and calls at
the positions only it knows: the runtime `if`/`unless` analyze clause and
`analyze_cond_clause` (`attach_if_condition/3`). Registered for the usual membership benefits
(on-by-default, reportable, selectable, `# mutare:ignore[if_condition]`).

**Delivery reuses the in-place selector**, appending a `Candidate.InPlace`
(mutator = the producing *spec*, since `Site.in_place/6` calls `.name()` on it)
to the *analyzed condition node*, after any operator candidate already there — so
`if String.starts_with?(s, x)` gets one selector hosting the StringCall swap *and*
the `true`/`false` pair. `original`/`range` come from the raw condition for a clean
`if foo?(x)` → `if true` diff.

**What it skips, and why each matters.** `condition_replacements/1` returns `[]` for:
  - a **boolean operator** (`Conditional.boolean_op?/1` — the shared definition, reused
    exactly as `ReturnValue` reuses it). This is what makes "`&&`/`||` need no special
    handling" true: they're boolean ops, already `Conditional`'s, so skipping them
    avoids a duplicate `true`/`false` pair.
  - a **literal `true`/`false`/`nil`** — degenerate (forcing `if true` to `true` is a
    no-op; this also drops a `cond`'s `true ->` catch-all cleanly).
  - a **binding condition** — `if user = fetch() do use(user) end`. An `if` condition's
    bindings *leak* into its body, so replacing the condition with a constant strands an
    unbound variable → the single build won't compile. (A parenthesised `(x = a; b)`
    sequence is skipped for the same reason, via the multi-statement `__block__` clause.)
    This `replacements/1` skip only catches a **top-level** `=`; the nested case is owned
    by the transform — see below.

Only `:runtime` conditions are offered — a module-level (`:scaffold`) `if`/`cond` runs
once at compile time with mutant 0, so a selector on its condition could never activate
(the `analyze_cond_clause` guard and the `:runtime`-only `if`/`unless` clause enforce
this).

**Binding-escape prune — the nested-`=` hazard, resolved at the transform `[done]`.** The
`IfCondition` skip above only sees a *top-level* `=`. The real-world break (`mix mutare` on
`Mutare.Transform.Aliases`) was a binding **nested under an operator** —
`(name = as_name(opts)) != nil -> Map.put(env, name, …)` in a `cond` arm. The trap node is
the `!=`, mutated by `Conditional` (`→ true`/`false`) and `Relational` (`!= → ==`), not
`IfCondition` (a boolean op, which it skips). The in-place selector is a `case`, so wrapping
the `!=` scopes `name = as_name(opts)` to a branch — and the body's `name` is unbound *in
every branch, including the unmutated catch-all*. So this is **not** a per-mutant poison: the
error is present even at mutant 0, identical across rebuilds, so the `Mutare.Poison`
skip-ids-and-recompile loop can never clear it (it would skip the implicated ids forever and
still fail) — it surfaces as a hard "metamutant failed to compile". This is exactly the
"`Conditional` … leans on poison-recovery" hazard the previous revision of this entry flagged
as deferred; poison-recovery turned out to be no recovery at all.

The fix is positional and cross-mutator, in `Analyze.finish_condition/3` (the shared
`if`/`unless`/`cond`-condition post-analysis step): after the normal runtime analysis,
`prune_binding_ancestors/1` strips the in-place candidate (`meta[:mutare]`) from every node
that is a **proper ancestor** of an escaping `=` — exactly the nodes whose selector would
trap the binding — and skips `attach_if_condition` whenever any binding escapes within the
condition. A binding-free sibling sub-expression (`length(opts) > 0` in the same `cond`) and
the clause **body** still mutate fully; only the binding's ancestors go un-wrapped. The taint
is a bottom-up walk returning `{node, subtree_has_binding?}`; the `=` node itself is never
stripped (it has no in-place candidate, and it is not its own ancestor), it only reports its
subtree as binding-bearing. **Binding-isolating forms** (`fn`/`for`/`with`/`try`/`quote`) stop
the taint — a `=` scoped inside a closure never reaches the clause body, so the surrounding
condition still mutates (`Enum.any?(xs, fn x -> (y = f(x)) > 0 end)` keeps its `IfCondition`
pair). Everything else (operators, calls, `case`/`cond`/`if`, `&&`/`||`, blocks) leaks
bindings outward, so the taint propagates through it. Compile-safe **by construction**, per
the layered-compile-safety rule, rather than the poison backstop that couldn't help here. The
analogous escape on a *value-discarded* `=` (a block statement / `for`/`with` qualifier) is a
different problem with a different fix — the tuple re-export `MatchPattern` (it *mutates* the
pattern); here we just *avoid wrapping* a binding we don't mutate.

**Loosening it for `if`/`unless`: hoist the binding instead of pruning `[done]`.** Pruning is
*sound* but lossy — a binding condition gets no decision mutant ("is this branch ever taken?",
the highest-value condition mutation). For an `if`/`unless` we can do better than `cond`: the
condition is evaluated **once and unconditionally**, so the binding can be **hoisted** into a
preceding statement, leaving a binding-free condition that hosts the decision selector without
trapping anything. `if (name = f()) != nil do use(name) …` becomes `name = f(); if (case <sel>
do <id> -> true; <id> -> false; _ -> name != nil end) do use(name) …`. The `if`/`unless` clause
detects a hoistable condition (`hoist_if?/2`) and emits a `__block__` (`hoist_if/6`); `cond`
stays prune-only (its clauses short-circuit in order, so a clause binding can't move out without
changing *when* it runs).

The non-obvious parts:
  - **Report fidelity needs a report/delivery split.** The metamutant delivers the decision on
    the *rewritten* (binding-free) condition, but the report diffs against the *original* source.
    So the decision `Site` is synthesized from the **raw** condition (`original`/`range` =
    `(name = f()) != nil`) while the selector's catch-all is the rewritten `name != nil`. Because
    the decision mutant is a **constant** (`true`/`false`), the same node serves both the branch
    and the Site — no separate delivery field needed (unlike `Relational`'s `name == nil`, which
    *would* differ and so is **not** recovered: an operator swap on a binding-ancestor stays
    pruned, its mutant still embedding the binding). The diff stays `(name = f()) != nil → true`.
  - **Refutable patterns keep `MatchError`.** `if {:ok, v} = f() do` lifts as `mutare_cond = f();
    {:ok, v} = mutare_cond; if … mutare_cond …` — the match value (always `f()`, *not* the
    pattern's bindings) goes to a temp, and the pattern is re-matched against it (so a non-match
    still raises the same `MatchError`). The temp can't be named in the id-/name-free analyze pass
    (the salted `cond_var` lives in `Ctx`), so analyze leaves a `Names.hoist_placeholder/0` (a var
    with an impossible hygiene *context*, uncapturable) that emit substitutes once at the top.
  - **Only the spine; at most one refutable.** Hoist only when *every* escaping binding is on the
    unconditional spine — `spine_rewrite/1` recurses the left of a short-circuit and stops at
    branch (`case`/`cond`/`if`) and binding-isolating forms; `offspine_escaping_binding?/1` vetoes
    a binding under a short-circuit RHS or in a nested branch (hoisting it would change *when* it
    evaluates). A binding on an `and`'s *LHS* (`(x = f()) != nil and g(x)`) **is** hoistable —
    the LHS is unconditional. Bare-variable bindings reuse their own name, so any number hoist;
    a refutable one needs the lone `cond_var`, so `refutable_spine_count/1 <= 1` is required.
  - **No reordering past a side-effecting sibling.** A binding hoists to *before the whole `if`*,
    so an expression evaluated *before* it in the original would end up *after* it on the baseline
    — and mutant 0 must be behaviorally identical to the original (else a sensitive suite goes red
    as `:baseline_failed`, or — worse, silently — the file's other mutants run against reordered
    code). `check(state) == (x = f())` evaluates `check(state)` first, so hoisting `x = f()` ahead
    of it reorders the call. `spine_reorders?/1` vetoes this: `eval_steps/1` flattens the condition
    into left-to-right evaluation order as `:binding` / `:pure` (literal or bare-var read, safe to
    reorder around) / `:other` (a call, an operator application, a short-circuit/branch/isolating
    subtree — conservatively side-effecting), and it is unsafe iff an `:other` precedes a
    `:binding`. The off-spine veto runs first, so the spine holds every binding; the common shapes
    evaluate their binding(s) first (`if x = e`, `(x = e) != nil`, `(x = first(a)) != (y =
    first(b))`, `0 < (x = f())`) and stay hoistable.
  - **The block leaks like the original.** A `__block__` where an `if` sat renders with parens and
    **leaks its bindings** in every position (statement, assignment RHS, call argument) — verified
    — so `name`/`v` escape past the `if` exactly as the source's would.
  Net: the bare-variable cases (`if x = expr`, `(x = expr) != nil`, the overwhelmingly common
  shapes) recover the full decision; refutable whole-condition matches too; everything off-spine
  or multi-refutable falls back to the sound prune. Swept over every `lib/**/*.ex`: all 85
  metamutants still compile.

### Membership: `in` ↔ `not in`, and the `not(in)` redundancy `[done]`
`Relational` flips membership polarity, `x in y → x not in y` — the membership
analogue of `== → !=`, and the one swap whose replacement isn't a sibling
operator but a `not`-wrapped node (`x not in y` parses as `not(x in y)`, so the
mutation wraps the original `in` node in a fresh-meta `:not`; the formatter
renders it back). It's compile- and guard-safe (`not in` is legal wherever `in`
is), so it reaches `when` guards via lifting for free, like the other relational
swaps. The reverse direction is *not* a Relational swap: `Logical` already strips
the `not` from a `not in` (`not in → in`), so emitting it here would duplicate
that.

The interesting part is the **redundancy under a `not`**. Because `x not in y`
is `not(x in y)`, both the `:not` and the inner `:in` are boolean-valued, and the
*only* families that match an `:in` node are `Conditional` and `Relational`.
Offering the inner `in` produces purely redundant mutants:

- `Conditional` forcing the inner `in` to `true`/`false` yields `not true`/`not
  false` — exactly the outer `not` forced to `false`/`true` (which `Conditional`
  already emits). A pair that always shares a verdict with the outer pair.
- `Relational`'s `in → not in` on the inner `in` yields `not(x not in y)` ≡ `x in
  y` — exactly `Logical`'s strip of the outer `not`.

So an `:in` node that is the *direct operand* of a `:not` is **never offered to
any mutator** (its operands still descend, so a literal in `x` / `y` still
mutates). This drops exactly the redundant mutants and nothing of value: a plain
`x in y` keeps its three (`not in`, `true`, `false`); a `x not in y` keeps its
three (`in`, `true`, `false`) instead of six. The suppression lives in **two**
parallel descents — `Transform.analyze` (the `{:not, _, [{:in, …}]}` runtime
clause, for bodies) and `FunctionPlan.tag_walk` (the matching guard clause) —
because guards offer nodes through a separate path and the same redundancy arises
there. The rule is uniform (any mutator, not just the two built-ins) so a future
membership mutator inherits it. This is the first of a family — see
"Equivalent-sibling suppression, generalized" next.

### Equivalent-sibling suppression, generalized `[done]`
The `not(in)` redundancy above is one instance of a wider class: **two distinct
mutations whose resulting programs are semantically equal**, so only one is worth
running. This is *sibling equivalence* — distinct from the *containment* dedup in
`Transform.Overlap` (a leaf swap covered by a call rewrite, derived from footprints).
We collapse it exactly as the `not in` precedent always did: at analysis time, descend
the operands but do **not** offer the inner/redundant node — leaving no id/site/selector,
so ids stay contiguous (the same property as `Overlap`/`gate_candidates`). (Cases 1 and 4
below instead *offer* the node and drop *specific* mutations — a per-mutation filter, the
same shape as the `in`-RHS empty-collection drop; cases 2–3 and the `not in` precedent don't
offer the inner node at all.) Four new
cases, each mirrored across the two parallel descents — `Transform.Analyze` for bodies,
`Transform.Tag` for `when` guards (`!`/`&&`/`||` are guard-illegal, so the guard side
handles only `not` and `and`/`or`):

1. **`not`/`!` over an equality operator** (`==`/`!=`/`===`/`!==`) — the `in` rule
   generalized. Each equality op is its own *exact polarity complement*, so under the
   negation Relational's flip (`!(a != b)`) ≡ Logical's strip (`a == b`), and Conditional
   on the inner (`!true`/`!false`) ≡ the outer's `true`/`false`. The ordering operators
   (`<`/`>`/`<=`/`>=`) are **excluded**: Relational mutates them to a *boundary/reversal*
   (`> → >=`, `> → <`), never the complement (`<=`), so under negation those are
   genuinely new mutants (`!(a >= b)` ≡ `a < b` ≠ the strip `a > b`). That is precisely
   *why* only the four equality operators join `in` in the suppressed set.

   This one is a **per-mutation** filter (like case 4), *not* a whole-node suppression —
   a distinction that earns its keep once `StrictEquality` exists. That family relaxes a
   strict equality (`===` → `==`, `!==` → `!=`), and under a negation `not (a == b)` ≢
   `a === b` (≢ the strip), because a strictness relaxation is **not** a polarity
   complement. So the inner node *is* offered, and only its negation-redundant mutations
   are dropped: the polarity complement (Relational, recognized by shape against a small
   complement map) and the `true`/`false` constants (Conditional). The relaxation then
   survives as a genuinely new mutant — whereas the original whole-node suppression (sound
   when only Relational/Conditional could fire there) would have silently dropped it. The
   filter is `drop_negation_redundant_candidates/2` in `Analyze`, `offer_negation_survivors/4`
   in `Tag`.

2. **`x in <collection literal>`** — a mutation that *empties* the RHS collection makes
   `x in <empty>` constantly `false`, which `Conditional` already produces on the `in`
   node. This covers `List` (`→ []`), `MapLiteral` (`→ %{}`), `WordListLiteral` (`→ ~w()`)
   and `CharlistLiteral` (`→ ~c""`) uniformly, via one recognizer
   `AST.empty_collection_literal?/1`. The `in` clause routes its RHS through
   `analyze_in_rhs`, which analyzes it *normally* (keys/values/elements still mutate) then
   drops — **from the top node only** — any candidate whose result is an empty enumerable.
   Two properties earn their keep:
   - **per mutation, not per node** — a word/charlist sigil keeps its non-empty *sentinel*
     (`~w(mutare)`/`~c"mutare"`, a genuine membership test) and loses only its empty
     sibling; `List`/`MapLiteral` have a single empty mutation, so they vanish from the RHS.
   - **top-node scoped** — a *nested* empty (`x in foo([a, b])` → `foo([])`, or
     `x in [a, [1, 2]]` → `[a, []]`) is **not** constantly false, so it is left alone.
   Non-list/map collections (tuple, bitstring) are excluded — they aren't enumerable, so
   `x in {…}` raises rather than testing membership. The rule holds under `not(x in …)`
   too (`not(x in <empty>)` ≡ `true` ≡ the outer Conditional), and in **guards** for the
   collections legal there — lists and word/charlist sigils; a *map* RHS is illegal in a
   guard `in`, so it can't occur — via the same recognizer in `Transform.Tag`.

   **Extensible.** A *custom* mutator that empties a non-standard collection — its own
   sigil, or a builder like `MapSet.new([])` — declares the result empty through the
   optional `Mutator.empty_collection?/1` callback, and earns the same in-RHS drop. The
   drop site already knows the *producing* mutator (every mutation is tagged with its
   `Mutator.Spec`, which carries the module), so dispatch needs **no registry or
   plumbing** — unlike the `:macros` path it isn't a pre-pass that stamps the AST, just a
   question asked at drop time. `Mutator.empty_collection?/2` ORs the shape-based
   `AST.empty_collection_literal?/1` (standard literals, any mutator) with the producing
   module's callback (its own shape) — so a custom mutator emitting a *standard* `[]`/`%{}`
   is covered for free and only needs the callback for a non-standard shape. Trusting the
   callback can only lose recall (drop a real mutant), never manufacture a false kill, so
   it's a "trusted contract" extension like `mutate/1`'s compile-safety. Fixture:
   `test/support/collection_mutator.ex`.

3. **Double negation `not not x` / `!!x`** — the **same** operator twice. Both Logical
   strips yield the identical single-negation, and Conditional on the inner duplicates the
   outer's `true`/`false`. Restricted to the same operator: a *mixed* `not !x` is left
   fully offered, because the two strips can diverge on a non-boolean operand (`not x`
   raises where `!x` coerces to `false`) — not equivalent, so not collapsed.

4. **A short-circuit connective whose left operand is itself a boolean op** —
   `Conditional`'s self-overlap on nested boolean ops. On `and`/`&&`, forcing the whole
   node to `false` (Conditional) is the **identical program** to forcing the *left*
   operand to `false`: both evaluate *neither* operand (`false and R` short-circuits R, and
   the false left is itself never evaluated), so they are equivalent **unconditionally** —
   no purity assumption. So the connective-node `false` is dropped; the operand's own
   `L → false` (the survivor it duplicated) stays, as does the node's `true` (`(L and R) →
   true` evaluates R — distinct) and Logical's `and`↔`or`. `or`/`||` is the mirror: the
   node's `true` is dropped (`(L or R) → true` ≡ `L → true`). The drop is gated on the
   **left** being a Conditional-eligible boolean op (`boolean_op_node?/1`), since that is
   exactly when the subsuming `L → false`/`L → true` sibling is generated — `is_binary(a)
   and R` has no `is_binary(a) → false`, so its node `→ false` is genuine and kept (and is
   *not* equivalent there: forcing the left false would still run `is_binary(a)`). Unlike
   cases 1–3 this *offers* the node and drops a single mutation (`drop_constant_candidate/2`
   in `Analyze`, `offer_without_constant/4` in `Tag`) — the per-mutation shape of the
   `in`-RHS empty-collection drop, because we keep the sibling constant and the swap. `&&`/
   `||` are body-only; the guard twin handles `and`/`or`. It composes down a chain:
   `a > 0 and b > 0 and c > 0` parses `(… and …) and …` and each `and` (whose left is a
   boolean op — the inner `and` is one) drops its own `false`.

   The **purity-dependent residual is deliberately left alone**: for *pure* operands,
   forcing the *right* operand false (`L and false`) also makes the node false, so `L →
   false` and `R → false` are themselves mutually equivalent — but only because comparisons
   are pure, which the analyzer can't cheaply prove (forcing `R` evaluates `L`'s effects).
   Only the unconditional node≡left equivalence is collapsed; the rest stays, erring toward
   recall as the philosophy requires.

Why **targeted** suppressions and not a general normalize-then-dedup pass: collapsing
errs only toward *recall loss* (never a false kill), but a boolean/constant-folding
normalizer is a real maintenance surface that risks over-collapsing genuinely-distinct
mutants. These four are each provably lossless (the dropped mutant has a named,
equivalent survivor), so they stay positive suppressions in the analyzer — consistent
with the `not in`, `ReturnValue`-skips-boolean, and `IfCondition`-skips-boolean-op
precedents.

### Guard removal (`Mutare.Mutators.GuardDrop`) `[done]`
The "delete a clause's `when` guard" operator — `def f(x) when is_binary(x)` →
`def f(x)` — asking *is this guard load-bearing at all?* It fills a real gap: a
single type-guard like `when is_binary(x)` was previously mutated by **nothing**
(it has no operators for Relational/Logical, no literal, and isn't a swap-family
call), so it always survived. Structural and positional (like `ReturnValue`/
clause-drop), registered as `:guard_drop` so it's on by default, toggleable, and
`# mutare:ignore[guard_drop]`-able.

**The dedup rule — "incidentally covered".** A removal is offered only for an
**inert** guard, one *no other enabled mutator already mutates*. Every guarded path
already computes `Tag.guard_targets/3` (the guard tagger that offers each node to
the mutators); an **empty** result means the guard is untouched by every family, so
removal is the only signal. Any target (`x > 0` → Relational+Literal,
`Integer.is_even(x)` → Integer, `a and b` → Conditional/Logical) means the guard is
already probed, so no removal piles on. This makes guard-swap and guard-removal
**mutually exclusive per clause**, derived from the mutations themselves — no
hard-coded "coverable guard" list, and the rule tracks the *enabled set* (disable
Integer and `Integer.is_even(x)` becomes removable). It also subsumes the
equivalence case for free: a sole boolean-operator guard is already turned to
`when true` ≡ guardless by Conditional, and it has a target, so it's skipped.

**Delivery reuses the three existing guarded-clause mechanisms**, one per construct,
with **no new `Site` constructor** — `original` is the `{:when, …}` head (rendering
`f(x) when g`) and `mutated` the bare head (`f(x)`), so the diff drops just the
` when g`:
- `def`/`defp` heads — **lifting** (`Candidate.GuardDrop`, the tag-less twin of
  `Candidate.Lifted`/`Candidate.Drop`): the mutant clause is the source clause with
  its `when` stripped, gated only `when mutare_active === <id>` so it matches
  unconditionally when active. A single guarded clause now lifts *solely* for this
  (like the unguarded `def f(1)` that lifts only for clause-drop). `Site.lifted_replace`.
- `case` clauses — the **tuple-the-scrutinee** path (a `Candidate.CaseClause` with a
  `nil` mutant guard), so the gated mutant clause carries the original pattern with no
  guard. `Site.in_place` (the `{:when, …}` LHS → bare pattern).
- `receive`/`fn` clauses — the **whole-construct selector** (a `Candidate.CasePattern`
  whose `replacement` is the construct with this clause's guard stripped). `Site.in_place`.

**Warnings — two kinds, handled differently.**
1. *Unused variable — accepted, never masked.* A guard-only variable
   (`def f(x) when is_binary(x), do: :ok` — `x` read only by the guard) becomes unused once
   the guard is gone, which warns. We **leave the head exactly as written** and accept the
   warning. Warnings don't fail the single metamutant build; under `--warnings-as-errors`
   the warning becomes a poison, recovered by dropping the mutant and rebuilding — the same
   benign path as the "cannot match" case below.

   We deliberately do **not** rename the lone unused binding to `_`, and this is *not* an
   oversight — it is forced. A macro in the body can read a bound variable **by name**, with
   no syntactic mention the transform could detect: `Kernel.binding/0,1` reflects every bound
   variable into a runtime keyword list, and *any* custom macro can do the same (call
   `binding()` in its expansion, splice a `var!`/`Macro.var` reference, …). Renaming `x` to
   `_` would silently drop it from whatever such a macro observes — a behaviour change the
   diff never shows. And no "is the body using `x`?" analysis can rule this out: detecting an
   arbitrary macro's reads requires *expanding* it, which the transform (working on parsed,
   unexpanded source for diff fidelity) does not do. Looking for `binding` by name is both
   unsound (misses custom macros) and pointless (you'd still have to keep the name). So the
   only sound choice is to keep the original name, **always**.

   (History: an earlier design masked the lone unused binding to bare `_`, gated on a
   scope-/quote-aware free-variable analysis of the body — `runtime_used_names/1`, with
   careful handling of quoted data, inner-scope shadows, and same-named module attributes.
   The whole apparatus, and that analysis, were removed: the analysis can never be complete
   against custom macros, and the warning it avoided is harmless. `mask_unused_bindings/2`
   and `runtime_used_names/1` are gone; `drop_clause_guard`/`strip_clause_guard` now strip
   only the `when` and emit the head verbatim.)
2. *Cannot match.* Stripping a **non-final** clause's guard can make its pattern
   irrefutable, shadowing later clauses — but **only** in the `receive`/`fn`
   whole-construct copy; the `def` and `case` mutant clauses are id-gated, so they're
   never an unconditional catch-all. This is the same benign warning `PatternWildcard`
   documents (only poisons under `--warnings-as-errors`, where poison recovery drops
   the mutant and rebuilds). Intrinsic to the mutation — not "fixed".

**Deferred.** A **multi-pattern `fn`** clause (`fn x, y when g ->`) is skipped: its
`{:when, …}` LHS holds the patterns spread (`[x, y, g]`, a 3-arg `when` that renders
`x when y when g`, context-free), so there's no single node that diffs cleanly to
`x, y`. (`def` heads are always one call node, and `case`/`receive` clauses are
single-pattern, so only multi-pattern `fn` hits this.) The `<-`/`with`/`try`-clause
guard positions follow whatever those clause-pattern paths grow next.

### Convention atoms (`Mutare.Mutators.ConventionAtom`) `[done]`
Swap a **status/result tag** for its convention sibling — `:ok` ↔ `:error`,
`:cont` ↔ `:halt`, `:lt` ↔ `:gt` — instead of `AtomLiteral`'s generic `:mutare`.
Leans on Elixir idiom the way `ModeSwap` leans on stdlib signatures: it's the
*semantic* atom family (a result tag), where `ModeSwap` is the *mode/unit* atom
family. Family `:convention`, on by default.

**Why a sibling beats `:mutare` (the whole point).** `:mutare` is a guaranteed-
never-real value, so wherever a `case` handles both `{:ok, _}` and `{:error, _}`,
the mutant `{:mutare, _}` matches **no** clause → `CaseClauseError` → killed
trivially, telling you nothing. `:error` is a *plausible* value the error branch
**handles**, so a *surviving* `:ok` → `:error` mutant pinpoints a genuinely untested
success/error distinction. The more-realistic mutant is the higher-signal one
precisely because it's harder to kill by accident.

**Same-shape only — the pairing rule.** A sibling is paired *only when it preserves
the surrounding shape*, so the mutant is a plausible alternative, not a malformed
value: `{:ok, payload}`/`{:error, reason}` (both 2-tuples), `{:cont, acc}`/`{:halt,
acc}` (both 2-tuples), `:lt`/`:gt` (bare atoms). OTP return tags
(`:reply`/`:noreply`/`:stop`) **fail** this test — `:reply` implies a 3-tuple, so a
bare-atom swap yields a malformed `{:reply, state}` that just crashes (no better than
`:mutare`) — and are excluded. 3+ member conventions carry only their **polarity
pair** (`:lt`/`:gt`, mirroring Numeric/Relational's "pairs, not a mesh"); `:eq`, the
middle, is unpaired and keeps its `AtomLiteral` `:mutare` mutant. So `@pairs` stays a
flat list and `@swaps` a compile-time map.

**Replace, not add (the ownership split).** The two mutants are ~100% correlated for
*killing* — any test that pins `:ok` kills both `:error` and `:mutare`, any that
ignores it survives both — so keeping both nearly doubles cost on those nodes for no
extra scoring signal, and `:mutare` is the *worse* survivor (crashes vs. is handled).
So `AtomLiteral` **excludes** the convention atoms by guard (`a in @convention`, where
`@convention = ConventionAtom.members()` — the `@sentinel AST.sentinel_atom()` pattern,
single source of truth), exactly as it defers `true`/`false`/`nil` to
`Literal`/`Conditional`. As with that split, disabling `:convention` leaves these atoms
unmutated by `:atom` too — accepted, precedented.

**`mutate/2`-only — one table path, configurable for free.** Logic lives in `mutate/2`
(`mutate/1` is `:skip`, like `ModeSwap`): `mutations/3` always runs `mutate/2` when
exported (with `opts: []` when unconfigured), so the built-ins always fire *and* a
`{ConventionAtom, pairs: [[:active, :inactive]]}` config merges its `:pairs` with the
built-ins — no second code path, no double-emit. It needs no `pipe_mode` (an atom's
identity is position-independent); it reads only `context.opts`.

**Reach is identical to `AtomLiteral`** — both go through `Mutator.mutations/3`, and the
pattern/guard tagging path (`Tag.literal_pattern_mutations/2`) keeps an atom-valued
replacement (`literal_node?` accepts `is_atom`). So a convention swap fires in value
positions (analyze), `def`/`defp` **head literals** (by lifting — `def handle({:ok, v})`
→ `{:error, v}`), and `case` **clause patterns** (by tuple-the-scrutinee). Only
`{:__block__, _, [atom]}`-**wrapped** atoms are matched, never a *bare* atom (a function
name/operator the analyzer never offers as a value — `:upcase` in `String.upcase`),
exactly like `AtomLiteral`. No new transform code.

**The one sharp edge.** In a **value-position** keyword/map literal `%{ok: c, error: c}`,
swapping `ok:` → `error:` collides with the existing key (a "key will be overridden"
warning that poisons under `--warnings-as-errors`, silent otherwise) — the lone place
the *unique* sentinel is safer than a real sibling. Rare (needs both keys in one
literal); left to the poison backstop. In **pattern** map keys it can't arise —
`Tag.tag_map_pair/4` already filters a key's mutations so none equals a sibling key.
A user-configured extra pair is *not* in `AtomLiteral`'s compile-time exclusion list, so
those atoms get both mutants (a minor double-cover on user extras only; the built-in
common case is clean) — excluding them would need `AtomLiteral` to read runtime opts in
a guard, which it can't.

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

The regex `u`-modifier drop (`~r/…/u` → `~r/…/`) *looks* like an `a * 1`-style
equivalent on an all-ASCII pattern — `~r/[a-z]/u` and `~r/[a-z]/` match the same
bytes at the same offsets on valid input — but it is **not** an equivalent mutant,
because it is *killable*: a `/u` regex **raises** on invalid UTF-8 where the no-`u`
form byte-matches (`Regex.match?(~r/[a-z]/u, <<0xFF>>)` raises `ArgumentError`; the
no-`u` form returns `false`). So we **emit it unconditionally**. A surviving
`u`-drop is a genuine finding, not noise: either the `/u` is dead cruft (delete it)
or its one real effect — rejecting invalid UTF-8 — is untested. This is exactly
where it parts from `a * 1`: `a / 1`'s result is `==`-invisible *by construction*,
so no input can ever kill it (a true equivalent, fair to treat as noise), whereas
the `u`-drop raises an exception on some input, so suppressing it would hide a real,
reachable mutant and wrongly shrink the denominator. `# mutare:ignore[regex]` stays
the per-case opt-out for a `/u` the author deems intentional-but-untestable.

The neighbouring `~r/\s+/` → `~r/\s*/` case is the same lesson from the other side:
it's equivalent only under `String.replace(s, _, "")` / `Regex.replace` with an
empty replacement (deleting the empty `\s*` matches changes nothing), and *not*
under `replace(_, "_")` / `match?` / `split`. That equivalence lives in the
**enclosing call**, not the regex literal — so a node-local mutator can't see it
without inspecting its consuming expression, which crosses the mutator/transform
boundary. It stays emitted, a `# mutare:ignore[regex]` / suspected-equivalent case.
The general rule both cases share: **suppress only a mutation no input can ever
kill** (a true equivalent like `a * 1`, `==`-invisible by construction); **surface
everything else** — even when the kill needs an unusual input (invalid UTF-8) or
only manifests through the enclosing call. "Looks redundant" is a finding to
report, not a mutant to hide.

`# mutare:ignore` (done) is the manual escape hatch: a trailing comment ignores
its line, a standalone comment the next line; matching mutants are recorded
`:ignored` — not run, kept out of the score's denominator (`killed / (total −
no_coverage − ignored)`), surfaced in the summary. Parsed from Sourceror's
comment metadata (`Mutare.Ignore`), not a raw-text scan — each comment's
`previous_eol_count` (`0` ⇒ trailing, `≥ 1` ⇒ standalone) drives the
classification, and a literal `"# mutare:ignore"` *string* is never mistaken for
a directive (the old text scan accepted it). It still *generates* the (unused)
selector for an ignored mutant, so it does **not** rescue a compile-poisoning
mutant — that's the compile-poisoning pre-filter's job, not ignore's.

**Granular ignores + reasons (done).** The directive grew two optional parts
after the keyword (a `[family, …]` filter, then free-text), so `Mutare.Ignore`
now returns `%{line => [%Ignore.Directive{}]}` instead of a bare line set, and
`Transform` decides per `{line, mutator}` (a `Directive` carries `mutators :: :all
| MapSet`, matched against `site.mutator` by name). The reason rides onto
`Site.ignore_reason` and `Report` prints an `IGNORED  — reason` roll-call between
the survivors and the summary. Two deliberate design calls worth remembering:

* **The bracket is the *only* thing that makes a token a filter.** Without it,
  every trailing word is prose — so a reason can never accidentally suppress a
  family (`# mutare:ignore arithmetic is fine here` ignores *all* mutants, reason
  "arithmetic is fine here"; only `[arithmetic]` scopes). This is what keeps the
  "extra explanatory text" and "granular filter" features from colliding.
* **Filtering fails safe toward *running* the mutant.** An unknown family (a
  typo) or an empty `[]` matches nothing, so the mutant runs and can surface as a
  survivor — the self-correcting failure mode — rather than being silently
  hidden. We deliberately *don't* validate filter tokens against the active
  mutator set: custom mutators have arbitrary `name/0` values that `Ignore` (which
  sees only source) can't know, so a warning there would false-positive. If we
  ever want typo-warnings, cross-check in `Transform`, which knows the live set.

Suspected-equivalent auto-reporting is still future work.

### Self-hosting: tests that touch `:mutare_active` `[fixed — private suite key]`
Mutation-testing Mutare *with Mutare* had a trap: many of Mutare's own tests
(`selector_test`, `integration_test`, `lift_test`, `transform_corpus_test`,
`pattern_*_test`, `return_value_test`, `if_condition_test`) call `Selector.put/1`
on `:mutare_active` — the very key the runner uses to hold the active mutant.
Since `:persistent_term` is global and the whole suite shares one BEAM, those
tests reset the active mutant mid-run (each resets to *baseline*, not back to the
harness id, so the clobber **persists** for the rest of the run), so any mutant
whose killing test runs *after* the first saboteur registered a **false
survivor** (confirmed: `runner.ex`/`baseline.ex` mutants survive in the full
suite but die when their file runs alone — and the verdicts are seed-dependent,
since ExUnit's order decides who clobbers whom). The same clobber also corrupts
the **coverage probe** (its record gate is `mutare_active == 0`, so a saboteur
setting a non-zero id mid-probe suppresses recording → spurious `:no_coverage`).
Normal targets never touch this key, so it was a self-hosting artifact only.

**The fix (a private selection key for the suite-under-test).** The runtime key
is now configurable: `Selector.key/0` returns `default_key/0` (`:mutare_active`,
the harness key) unless the `MUTARE_SELECTOR_KEY` env var (`Selector.override_env/0`)
names another. `Mutare.Sandbox.Command` sets that var (to `Selector.suite_key/0`,
`:mutare_active__suite`) on **every** sandbox `mix` it spawns. So inside the
sandbox the suite-under-test reads/writes its own private slot — `Selector.put/1`,
`active/0`, and any fixture it builds via `Transform` (whose selector subject is
`Metamutant.subject_ast/0` → `Selector.key/0` resolved *at runtime*) all land on
`:mutare_active__suite` — while the **real** metamutant keeps reading
`:mutare_active`. The two key-spaces are disjoint, so a test calling `put/1` can
no longer clobber the mutant under test. Why this works without dogfood detection:
the real metamutant's sites and the bootstrap bake `default_key/0` as **literals**
at transform time, in the harness process where the override is unset; only the
suite-under-test's *runtime* `Selector.key/0` calls (in the sandbox, where the env
is set) see the override. On a normal target there is no `Mutare.Selector` compiled
in, so the env is inert. (The `subject?/1` recognizer reads `key/0` too, so
producer and recognizer always agree within a process — needed for the
`Manifest`/`Poison` round-trip in either context.)

Verified end-to-end: a clean (`workers: 1`, generous cap) dogfood of `baseline.ex`
flipped its in-process `classify/1` victims (`Enum.max→Enum.min`, `== []` polarity,
`true→false`, `take(-20)→drop(-20)`, `20→19`) from **false survivors → clean
kills** (8 killed/12 survived → 11/9). The unit guard is `selector_test`'s "under a
suite-key override, `put/1` leaves the harness key untouched".

What else is in place (unchanged):
- **Sandbox skips `:runner` tests.** `test/test_helper.exs` calls
  `ExUnit.configure(exclude: [:runner])` iff `MUTANT_UNDER_TEST` is set — true on
  every per-mutant run (and the baseline) but never on a normal `mix test`. Those
  tests shell out to nested `mix test`; running them per mutant would be a fork
  bomb. This is *orthogonal* to the key collision — it bounds cost. Its cost is
  that code reached **only** by `:runner` tests (e.g. `Baseline.collect/2`,
  `CoverageProbe.outcome/3`) has no in-process coverage and so survives rather than
  scoring `:no_coverage`; that's a separate, accepted tradeoff, not the collision.
- **`selector_test` now save/restores the harness slot.** It necessarily pokes
  `:mutare_active` directly (it tests `bootstrap_ast/0` and `default_key/0`), so
  unlike the `put/1`-based saboteurs it can't be fixed by the key split alone — it
  captures `:mutare_active` (and the env vars) in `setup` and restores them in
  `on_exit`, leaving the slot exactly as found. The remaining mid-test window is
  safe because it is `async: false` (ExUnit runs a sync module in isolation).
- **`Selector.put/1` is no longer `# mutare:ignore`d.** It used to be excluded
  because exercising it overwrote `:mutare_active`; now it writes the suite key, so
  its guard is honestly killable under dogfooding.
- **`Selector.bootstrap_ast` / `Command.watcher_ast` no longer break the
  baseline.** Both build a `quote` containing a `case … "" -> …` clause; the
  transform used to mutate the `""` *pattern* inside the quote and wrap it in a
  selector `case`. That compiles fine *as a quote* but is an illegal pattern where
  the AST is later compiled (`selector_test` evals `bootstrap_ast()`), so the
  **baseline run failed and aborted the whole dogfood** — a poison the pre-filter
  can't see (the metamutant itself compiled). Fixed by classifying `quote` as
  compile-time (pruned whole, like `defmacro`); see "Non-body operator positions".

Footnote (cost, not correctness): dogfooding Mutare's own heavy suite with the
default `:workers` can clip slow survivor runs to `:timeout` (the per-mutant cap
floor is 10 s; N parallel `mix test`s contend for CPU). That inflates the "kill"
count with timeouts and is unrelated to the key collision — drop `:workers` to 1
or raise `:timeout` for a clean self-run.

### Self-hosting: the coverage helper module clashes with its test stand-in `[fixed — private fixture name]`
The selector-key collision above has an exact twin in the **coverage helper**.
`Mutare.Sandbox` writes the real helper (`Mutare.Coverage.Recorder.helper_source/0`,
the atom module `:mutare_cov`, with `hit/1` **and** `dump/1`) into every sandbox.
But Mutare's own source also ships `test/support/mutare_cov.ex` — a stand-in that
defines the *same* atom module `:mutare_cov` (only `hit/1`), so that Mutare's unit
tests can compile bare metamutants (whose selector catch-alls call `:mutare_cov.hit/1`)
in the main VM where no real helper exists. When the target *is* Mutare, the sandbox
compiles **both** (the stand-in lives under `test/support`, which `elixirc_paths(:test)`
includes), so two modules claim `:mutare_cov` — a "redefining module" clash the
stand-in (no `dump/1`) can win. The coverage **probe** registers
`ExUnit.after_suite(&:mutare_cov.dump/1)`; a remote capture resolves lazily, so it
fails not at registration but when the suite ends and the hook fires:
`** (UndefinedFunctionError) function :mutare_cov.dump/1 is undefined or private`.
The probe exits non-zero, `CoverageProbe` degrades to `:run_all`, and you get the
warning *"coverage probe exited 1; falling back to run-all selection"*. Correct
verdicts, but no coverage selection and no `:no_coverage` classification — and only
when dogfooding (a normal target ships no `:mutare_cov`). The path de-collision
(`lib/mutare_cov.ex` → `lib/__mutare__/coverage_helper.ex`) does **not** help: the
clash is on the *module name*, not the file path, and the stand-in is a different
file under `test/`.

**The fix (a private name for the suite-under-test's stand-in).** Mirrors the
selection-key split exactly. The stand-in's module name is now configurable:
`Recorder.fixture_module/0` returns `helper_module/0` (`:mutare_cov`) unless
`Recorder.fixture_override_env/0` (`MUTARE_COV_FIXTURE_MODULE`) names another, in
which case the stand-in compiles under `Recorder.suite_fixture_module/0`
(`:mutare_cov__suite_fixture`). `Mutare.Sandbox.Command` sets that env var on every
sandbox `mix` (beside the `MUTARE_SELECTOR_KEY` override), so inside a sandbox the
stand-in cedes `:mutare_cov` to the real written helper and the probe's `dump/1`
resolves. The real helper, the metamutant's baked `hit/1` calls, and the bootstrap
all keep `helper_module/0` (the override is unset in the harness process; a normal
target has no stand-in, so it is inert). Implementation wrinkle: `defmodule` rejects
a *remote-call* name expression ("invalid module name"), but accepts a **variable**
bound to an atom — so the stand-in does `name = Recorder.fixture_module(); defmodule
name do …`. Verified: under the probe env the after-suite hook now writes a real
`mutare_cov.terms` dump with no `UndefinedFunctionError`.

This `dump/1` fix **unmasked** two further self-host probe breakers (the probe used
to die on `dump/1` before reaching them; both pre-date this change and are orthogonal
to the helper name) — now also fixed:

1. **`Mutare.ChangesTest` flaky `File.CopyError`.** Its `setup` `cp_r`s a git-repo
   template into a fresh tmp dir per test. The dir name used only
   `System.unique_integer/1`, which is unique within *one* BEAM but yields the same
   small integers across separate `mix test` BEAMs — and self-hosting runs this
   module in many parallel mutant processes sharing `/tmp`, with timed-out mutants
   `System.halt`ed past their `on_exit`, littering stale dirs. A reused name made
   `cp_r` copy *over* a leftover read-only `.git/objects/*` file → `EACCES`. Fixed by
   salting the name with the **OS pid** (`fresh_tmp/1`); it does **not** `rm_rf` a
   pre-existing path (that could mask a real collision) but **raises** if one exists,
   leaving cleanup to `on_exit`.
2. **`Mutare.CoverageTest` tearing down shared probe state.** Its `setup_ast/0` test
   blindly deleted the `:mutare_cov_agg`/`:mutare_cov_attr` ETS tables, the
   `:mutare_track` flag, and `MUTARE_COVERAGE` in `on_exit`. Under the probe the
   bootstrap *already* created those (and the metamutant records into them across the
   whole suite), so the teardown suppressed coverage for every later test. Fixed with
   the same save/restore discipline as `selector_test`: capture prior state, undo only
   what the test introduced (drop a table only if it didn't pre-exist).

Verified end-to-end: a self-host `mix mutare --only lib/mix` now runs real coverage
selection — `25 killed / 1 timeout / 39 survived / 76 no-coverage` (the dump carries
65 ids across 8 files) — versus the run-all fallback's `57 killed / 82 timeout / 2
survived / 0 no-coverage`. The honest score replaces one inflated by charging every
uncovered mutant's whole-suite timeout as a kill.

### Report diff fidelity for call-final keyword args `[fixed]`
A `mix mutare --only lib/mutare/ignore.ex` surfaced two *corrupt survivor diffs* on
`|> String.split(re, trim: true)` — both in `Mutare.Report`, **not** the metamutant
(which is built from the AST, compiles, and runs fine; only the diff a human reads
was wrong):

1. **`literal` `true → false` ate the closing paren** — `…, trim: false` (no `)`).
   The site's recorded `range` was one column too wide. Root cause is upstream:
   `Sourceror.get_range/1` sizes an atom literal as its name **plus one for a colon**
   (`range.ex` `do_get_range/1`, the `+1` "Just the colon" branch) — correct for a
   written `:foo` (leading colon) and a keyword key `foo:` (trailing colon), but
   `true`/`false`/`nil` are written **bare**, so their range overshoots by one and the
   textual patch eats the next char. Fixed with `Mutare.Transform.NodeRange.get/1`, a
   `get_range` wrapper that trims the phantom column for a bare (non-`format: :keyword`,
   no-delimiter) `true`/`false`/`nil` block. Every candidate-range site in `Analyze`
   and `FunctionPlan` now goes through it (no-op for every other node), so the lifted
   head-pattern case (`def f(true)` → `def f(false)`) is covered too.

2. **`atom` keyword-key `trim: → :mutare` broke keyword syntax** — `…, :mutare true)`.
   Here the range was *right* (it spans `trim:`, colon included); the *replacement*
   was wrong. `Sourceror.to_string/1` of the bare mutated atom node gives `:mutare`,
   and a standalone keyword-format block still renders `:mutare` (keyword form only
   applies inside a pair). Fixed in `Mutare.Site`: when the **original** node is a
   `format: :keyword` atom key, render `original_code`/`mutated_code` with
   `Macro.inspect_atom(:key, atom)` → `trim:` / `mutare:`, so the splice stays legal
   (`mutare: true`). The decision reads the *original* node because the mutated atom
   carries fresh, format-less meta (the clean-meta rule). Arrow-form keys (`%{:a => 1}`)
   and `nil:`/`true:` keys are untouched (the former isn't `format: :keyword`; the
   latter keep their real trailing colon).

Both are pure report-rendering fixes; the regression tests assert the diff text *and*
that the patched source re-parses (`report_test.exs`, `transform/node_range_test.exs`).

### Report diff fidelity for sigils that escape their delimiter `[fixed]`
A `mix mutare` survivor on `|> String.replace(~r/[\/\\:\*\?\"<>\|]/u, "-")` rendered a
diff with **no change at all** — the `-` and `+` lines byte-identical — even though the
compact progress line correctly read `…]/u → …]/` (drop the `/u` flag). Same class as the
keyword-arg fix above (a wrong *range*, the metamutant fine), but the opposite sign: an
**under-count**, and the symptom is an empty diff rather than an eaten character.

Root cause is again upstream in `Sourceror.get_range/1`: it sizes a sigil from the
**stored** content length (`range.ex` `get_end_pos_for_interpolation_segments/3`,
`String.length` of the `<<>>` segments). The tokenizer keeps a sigil's body raw —
`\n`/`\\`/`\t` stay two-char sequences — *except* it collapses an escaped **closing**
delimiter: `\/` → `/` in `~r/…/`, `\}` → `}` in `~r{…}`. So the stored content is one byte
shorter per such escape and the range ends that many columns early. `Sourceror.patch_string`
over the short range then leaves the sigil's tail in place; when the mutation only drops a
*trailing* flag (`~r/…/u` → `~r/…/`), the patch lands **exactly** on the dropped `u` and the
line comes back unchanged. (For `~r/[\/\\…\|]/u` only the *first* `\/` collapses — `\\`,
`\*`, `\?`, `\"`, `\|` keep their backslashes — so it is off by one, and the `/u`-drop is
the mutant that happens to expose it.)

Fixed in `Mutare.Transform.NodeRange.get/1` (the same wrapper as the bare-atom fix): for a
single-line sigil it adds back one column per collapsed closing delimiter, counted as the
number of closing-delimiter chars in the **binary segments after the last interpolation**.
Three subtleties make that count exact: (a) only the *closing* char collapses — an opening
escape `\{` keeps its backslash, so `~r{a\{b\}c}` is off by one (the `\}`), not two; (b) in
a *parseable* sigil every bare closing-delimiter char in the content must have come from a
`\<close>` (an unescaped one would have ended the sigil, and Sourceror rejects unescaped
balanced pairs like `~r{a{b}c}` outright), so counting them needs no source; (c) an escaped
delimiter *before* the last interpolation is already correct — its absolute `closing`
position is baked into the segment metadata — so only the trailing binary segments are
counted (`~r/a\/b#{x}c/u` is already right; `~r/a#{x}b\/c/u` is off by one). Non-interpolated
patterns (all the literal mutators ever touch) reduce to "count the whole single segment".

A pure report-rendering fix; regression tests assert the per-sigil corrected width and that
each regex mutant's patch is a *visible*, re-parseable change (`transform/node_range_test.exs`,
`report_test.exs`).

### Report diff fidelity for multi-line fragments — line-based, not positional `[fixed]`
A `mutare_ecto` survivor that drops one `where:` from a big `from` block (a `:hosted` mutation,
so a multi-line `:replace`) rendered a hideous diff: every line *after* the removed one came back
as a spurious `-old`/`+new` pair (and the last one corrupted), even though only one line actually
changed. Same family as the two fixes above — the *report*, not the metamutant (which is built from
the AST and runs fine) — but the bug was in the **diff algorithm**, not a `Sourceror` range.

`Mutare.Report.diff/2` paired original line `n` with patched line `n` positionally:

    site.range.start[:line]..site.range.end[:line]
    |> Enum.flat_map(fn n -> ["-" <> orig[n], "+" <> patched[n]] end)

That is correct only when the patch preserves the line count. Removing a `where:` deletes a line, so
every line after the gap **shifts up by one**, and the positional pairing then reports each shifted
line as a bogus change (and `+patched[last]` reads past the fragment, hence the corrupted tail). It
was a latent bug for *any* multi-line `:replace` whose patch changes the line count — e.g. a
`ReturnValue` collapsing a multi-line expression to `nil` — not just Ecto; the `:hosted` case is
simply the one that produces big multi-line fragments routinely.

Fixed by making the diff **line-based**: `List.myers_difference/2` between the original and patched
text *within the fragment's line span*, with the patched span derived from the line-count delta
(only bytes inside `site.range` change, so the tail shifts by exactly
`length(patched) - length(original)` — `patched_last = last + delta`). Myers aligns the unchanged
lines (rendered as ` ` context) and shows only the genuinely removed/added ones as `-`/`+`. A
single-line swap is unchanged: Myers returns `[del, ins]` for a fully-different line, so the old
clean `-old`/`+new` pair (and every existing single-line diff assertion) still holds. The
`:delete` (clause-drop) path is separate and untouched.

A pure report-rendering fix; the regression test asserts the where-drop shape shows just the dropped
line with context and that the patched source re-parses (`report_test.exs`).

### Surface skipped files more loudly `[soon]`
`Schema`/`safe_transform` skips a file that fails to transform (good — one bad
file shouldn't sink the run) and the task prints `skipped <file>: <reason>` in
its banner. But that's easy to miss, and it's exactly how the two
compile-poisoning bugs below hid. Consider a `--strict` mode that fails on any
skip, and/or making poisoning structural exclusions (below) the norm.

### Live human progress (`Mutare.Report.Live`) `[done]`
The human run used to print a test-runner stream of symbols (`.`/`S`/`T`/…) via a
bare `IO.write` in the Mix task. It's now a cargo-mutants-style live display: phase
notes as the run advances, a permanent line left behind for each survivor (the
product) plus timeouts and harness errors (problems worth surfacing live), and — on
a tty — a bottom status block (spinner + the in-flight mutant + a counter with an
ETA) that animates via an internal tick timer. Design decisions worth remembering:

- **It's a `GenServer`, because the hooks fire concurrently.** `:reporter`/`:on_start`
  are called from many `Task.async_stream` workers at once, so every terminal write
  must funnel through one owner. Reports/starts/phases are `cast`s (workers never
  block on rendering); `finish/1` is a `call`, and since all casts were *sent* (mailbox
  delivery complete) before the stream returned, FIFO guarantees `finish` sees the
  final state and clears the block before the after-the-fact `Mutare.Report` prints.
- **stderr, always; animation, conditionally.** Output goes to stderr so a machine
  report piped to stdout (`--format json > f`) is never corrupted. Animation is gated
  on `detect_ansi/0` = a real **stderr** tty (`:io.columns/1` succeeds) *and*
  `IO.ANSI.enabled?`. We key on stderr (not stdout) deliberately; the cost is that
  redirecting stdout (which flips `IO.ANSI.enabled?` off at boot) drops us to plain
  mode even if stderr is a tty — acceptable (safe, just less fancy). Plain mode =
  phase notes + leave-behind lines as ordinary scrollback, no cursor codes, no spinner
  — exactly what CI logs want.
- **Three hooks on the runner, which knows nothing of the display.** Added `:on_phase`
  (`:compiling` → `:baseline` → `:coverage_probe` → `{:running, total}`) and `:on_start`
  (each `Site`) alongside the existing `:reporter`, all 1-arity/optional/`nil`-default,
  validated in `Options`. The runner fires them; the Mix task binds them to `Live`.
  `:on_start` exists only so the activity line shows an *actually in-flight* mutant
  rather than the last completed one.
- **Rendering is pure, IO is a thin shell.** `status_block/2`, `leave_behind/1`,
  `humanize_secs/1`, `eta_secs/3`, `truncate/2` take a plain state map / scalars and
  return strings (clock passed in as `now_ms`), so the visible output is unit-tested
  with no terminal and no time. The server only wraps them in cursor codes
  (`\r\e[2K` + `\e[1A\e[2K` per extra line to erase, then redraw) and a
  `System.monotonic_time` read.
- **Known caveat:** `Mutare.Runner.warn_harness_error/2` logs to stderr too, so a
  harness-error warning mid-run can interleave with the status block and nudge the
  cursor accounting for one frame (self-heals on the next redraw). Rare path; left as-is.
- **Scan progress, before the runner.** The pre-run scan (mutant discovery —
  `Mutare.Schema` transforming every source) used to be a silent gap before the live
  display started; now it's the first live phase (`:scanning`), showing a spinner +
  per-file progress + a running mutant tally (`scanning for mutants — 3/12 file(s) ·
  47 found`). The scan runs in the Mix task (not the runner), so it's driven directly:
  the task enters the phase, `Mutare.Schema.from_files/4` fires a new optional
  `:on_scan` hook (a `%{done, total, found}` map) per file, bound to `Live.scanned/2`.
  Two wrinkles: (1) **poison recovery re-scans**, and we don't want the display yanked
  back to a scan mid-run — `Schema.rebuild/4` clears `:on_scan`, and the runner's
  options never carry it. (2) The "N mutants across M files" count prints to **stdout**
  (`Mix.shell`) while the scan block sits on **stderr**; writing the count then would
  splice it onto the scan line. So the task calls `Live.clear/1` (a *non-terminal*
  erase, distinct from `finish/1` — it drops to idle but keeps the tick alive) to wipe
  the block, leaving the cursor at column 0 for a clean stdout write; the runner's
  first phase (`:compiling`) then redraws fresh. In plain mode the scan note prints
  once and per-file ticks stay silent (no CI-log flooding).
- **Deferred touches:** a per-worker multi-line in-flight view (chose aggregate +
  one activity line), and a permanent "baseline green in Ns" timing note (would need
  threading `baseline_ms` through `:on_phase`).

### `--max-mutants N` — cap the number of mutants tested `[done]`

A quick-smoke / time-box knob: `mix mutare --max-mutants 50` (or `max_mutants: 50`
in `.mutare.exs`) tests at most the first N mutants in source order, rather than
the whole population. The dominant cost is the per-mutant suite run, so bounding
*how many run* bounds the run — useful for a fast confidence check or a CI shard.

Design choices, and why:

- **Cap the run, not the generation.** The flag truncates `Mutare.Schema`'s `sites`
  list to the first N (`Schema.limit/2`); the per-file metamutant *sources* still
  embed every mutant. Limiting generation instead would mean stopping the staged
  transform mid-stream and would entangle the globally-unique, stable id threading —
  far more invasive for a knob whose whole point is the *run* (we still "compile
  once"; only the suite-per-mutant loop shrinks). The runner, coverage probe, and
  report all read `schema.sites`, so they bound themselves with no extra plumbing.
- **Applied inside `from_files/4`, so it survives a poison rebuild.** Poison recovery
  regenerates the schema from scratch (`Schema.rebuild`), so a cap applied only at
  the `build/2` boundary would silently *un-cap* after a recovery. Threading it
  through the one `from_files` chokepoint (it reads `options.max_mutants`) keeps every
  schema — initial and rebuilt — bounded. Because the metamutant still embeds every
  mutant, poison detection is unaffected; a poisoned site *within* the first N is just
  backfilled by the next mutant on rebuild (the rebuilt prefix shifts down by one).
- **First N, deterministic.** Not a random sample (reproducible > spread, and the
  workflow has no seed to thread); the first N happen to cluster in the first
  file(s), which is fine for a smoke run. A spread/sharded selection is a possible
  later refinement.
- **`Mutare.Options` validates it** (positive integer or `nil` = no cap), same as
  every other knob, so a bad `--max-mutants 0` fails at the edge. The Mix task's
  announce notes `(--max-mutants N)` so the smaller count isn't a surprise.

### `--line FILE:LINE` — scope the run to one file:line's mutants `[done]`

A *narrow rerun* knob: `mix mutare --line lib/billing/invoice.ex:42` (repeatable;
or `only_lines:` in `.mutare.exs`) tests only the mutants whose original location is
that `file:line`, instead of the whole population. The motivating workflow is
re-checking a single result the report named — you killed (or want to recheck) one
survivor and don't want to pay for a full run to confirm it. `FILE:LINE` is *exactly*
the prefix `Mutare.Report.header/1` prints (`lib/x.ex:42  [relational, …]  SURVIVED`),
so you copy-paste the location straight from the report.

Design choices, and why:

- **Two effects, both pointing at "narrow".** (1) `Mutare.Schema.restrict_lines/2`
  filters `sites` to the matching `{file, line}` — the part that actually scopes the
  *run* (the per-mutant suite loop is the dominant cost, and this is what shrinks it).
  (2) `Mutare.Schema.restrict_to_line_files/3` also prunes discovery to just the named
  files, so the metamutant and the one compile stay small — the same "compile only
  what we run" the `--only <file>` form already gives. The site filter is the
  load-bearing one; the file narrowing is a cheap bonus (a mutant in file A lives only
  in A's metamutant, so compiling A alone is sound — exactly what `--only` relies on).
- **Line granularity, not a single mutant.** A source line can host several mutants
  (`a + b - c`); `--line` keeps *all* of them. The user asked for a *line*, and the
  report identifies a survivor by `file:line` + diff, not by the internal
  `MUTANT_UNDER_TEST` id (which isn't user-visible and *shifts* when discovery is
  narrowed — see below). Column-level scoping would buy little and break the
  copy-from-report ergonomics.
- **Filter applied inside `from_files/4`, file-prune inside `build/2`.** Same split as
  `:max_mutants` vs `:only_files`: the site filter lives in the one `from_files`
  chokepoint so a **poison rebuild** (`Schema.rebuild`, which regenerates the sites)
  reapplies it; the file prune is a discovery-time concern (`build/2`), and `rebuild`
  replays the already-pruned recorded file list. Order is filter-then-`limit`, so
  `--line` composes with `--max-mutants`.
- **Ids shift when discovery narrows — and that's fine.** Restricting to file B means
  B's mutants get the ids they'd have if B were scanned alone (no offset from earlier
  files). The ids are an internal runtime switch, never the user's handle on a mutant,
  so the shift is invisible. (Within a *full* run the ids are globally-unique/stable;
  `--line` is explicitly a different, narrower run.)
- **`Mutare.Config` parses `FILE:LINE`, `Mutare.Options` validates the pairs.** The
  split is on the *last* colon (a path may contain one), the trailing segment must be a
  positive integer, and a malformed value raises an `ArgumentError` the Mix task
  surfaces as a clean failure (it rescues `Config.merge/2`) — `--line lib/foo.ex` with
  no line errors at the edge rather than silently matching nothing. A line with no
  mutants scopes to zero sites and hits the existing `:nothing_to_mutate` fast path
  (before any compile/subprocess).

## Dogfooding findings (M1)

Running `mix mutare` on Mutare's own `lib` (24 mutants, 14 killed) surfaced:

- **Compile-poisoning #1 (fixed):** a `case`-valued map/keyword field
  (`%{ms: div(x, 1000)}`) crashed Sourceror's formatter → file silently skipped.
  Fixed by block-wrapping the selector + generalising keyword-key normalization.
- **Compile-poisoning #2 (fixed):** the `/` in a `&fun/arity` capture is an
  arity separator, not division; mutating it produced an invalid `&(case …)`.
  Fixed by excluding capture-arity `/` (and guard operators) from in-place sites.
  More poisoning shapes may lurk — but the compile-poisoning pre-filter (now
  done, below) is the backstop that catches unknowns without us enumerating them.
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

## Real-world poisons (plug/router) `[done]`

Running `mix mutare --only lib/plug/router` on the plug library surfaced three distinct
poison shapes — none Mutare-specific, all idiomatic Elixir. The goal each time was
to **catch it positively at the transform stage** so poisoning stays a fallback for
the genuinely-unknown (e.g. custom mutators), not a routine outcome on real code.

- **Coverage-id charlist (crash, fixed):** the very first symptom wasn't even a
  poison — it was a *hard crash* in `Manifest.from_source` (`Sourceror.parse_string!`
  on the rendered metamutant), because `Coverage.Recorder.record_ast/1` spliced the
  site's mutant ids as a **bare integer list** that the renderer printed as a
  charlist (`~c"…"`), and ids like `92`/`10` then produced un-re-parseable source.
  Fixed by `ids_literal/1` (wrap each id in `{:__block__, [], [id]}`); see "The
  `hit([ids])` argument must render as a list, never a charlist" above for the full
  mechanism. (Latent until a file accrued enough ids to land on those byte values.)
- **`match?/2` pattern arg (5 of the 7 poisons, fixed):** `match?("_" <> _, x)` and
  `match?({"_" <> _v, _m}, x)` — `match?/2`'s first arg is a *match context*, but it
  reads as an ordinary call, so the string/tuple literals there were mutated in
  place, splicing a selector `case` into a pattern ("case not allowed in matches").
  Fixed by routing `match?/2`'s first arg `:pattern` (now via the **known-macro
  registry** — see "Known-macro registry" — which originally landed as a hard-coded
  `analyze` clause). Two of the "7" were *collateral*: poison maps a compile
  error's line → every mutant id whose generated code spans it, so the valid
  `Enum.reject`→`Enum.filter` swaps sharing those lines were dropped too. Handling
  the root cause both removed the 5 real poisons and recovered the 2 valid mutants.
- **Selector as a pipe target (2 of the 7, fixed):** the recovered `reject`→`filter`
  swaps then revealed a second, independent shape — a mutated **pipe stage**.
  `x |> Enum.reject(f)` puts the call right of a `|>`; wrapping it in the selector
  yields `x |> case … end`, which *parses* but fails `Kernel.|>/2` expansion
  ("misplaced operator `->`") — so `Code.string_to_quoted` was not enough to catch
  it (the regression tests `Code.compile_string`). Fixed by hoisting the pipe into
  the selector (`hoist_pipe/1`): each branch becomes `lhs |> <branch>`, leaving a
  standalone `case` that is itself a valid pipe LHS, so chained pipes nest. Two
  spots needed it: the parent `|>` in the emit postwalk (a plain pipe stage), and
  `emit_site`'s catch-all default (a tail pipe that *also* carries a ReturnValue
  candidate, so the `|>` node goes through `emit_site` rather than the postwalk's
  pipe branch). The bare stage stays the Site's recorded node, so diffs are clean.

  - **Follow-up — that first form was exponential (`hoist_pipe/1` → `/2`).**
    "Each branch becomes `lhs |> <branch>`" copies the *entire* `lhs` — which, for a
    chained pipe, is the already-emitted selector for every upstream stage — into
    each of a stage's `(mutants + 1)` branches. So a chain of N mutated stages
    rendered as ≈`(mutants+1)^N`: a 9-stage `Enum.reverse()` chain ballooned to
    **6.8 MB / 137k lines** (≈3.2× per stage), and a long pipe of stdlib calls could
    OOM the compiler/formatter. Fixed by lifting the selector into a **one-shot
    closure on the piped value** instead of distributing `lhs`:
    `lhs |> (fn mutare_piped -> case … (each branch pipes `mutare_piped`) … end).()`.
    The piped value stays the pipe's LHS (computed once, the upstream chain appears
    once) and is bound to the closure param; each branch references that cheap
    variable. Size is now **linear** in N — the same 9-stage chain is **4.8 KB**, and
    doubling the stage count ~doubles (not ~1000×'s) the output. `(fn … end).()` is
    itself a valid pipe LHS, so chains still nest. The closure param is **salted**
    per file (`Names.generated_names` → `Ctx.piped_var`, like `active_var`/`super_var`)
    so a stage argument mentioning `mutare_piped` isn't captured by the param. The
    selector `case` is unchanged structurally, so `Manifest`/`Poison` (a full
    `Macro.traverse` keyed on `Metamutant.subject?/1`) still map a compile error in a
    nested-in-closure clause back to its mutant id. The `then/2` alternative was
    rejected for the same reason `super`'s closure uses a bare `fn` — no need to
    depend on `Kernel.then/2` and the diff/Site stay on the bare stage.

Net: `lib/plug/router` went from 7 poisons to 0; the two pipe-stage swaps now run
as real (killed) mutants. The 5 illegal `match?`-pattern "mutants" are correctly
never generated (site count drops), since they were never legal mutations.

A second sweep over the rest of plug (`lib/plug/conn` and ultimately all of `lib`,
~6k sites) surfaced two more — both in the **lift path**, both confirmed real by
reproducing the single function in isolation (the scope scan over-reports: one
"implementation not provided" error in `Plug.Conn.Utils` dragged 18 line-adjacent
ids — valid `conditional`/`list` guard mutants in *other* functions — down with it
as poison-recovery collateral, all of which came back once the real cause was fixed):

- **`pattern_wildcard` on a bitstring segment specifier (fixed):** `<<binary::binary>>`
  parses its type specifier `binary` as a node identical to the value variable
  `binary` (`{:binary, [], nil}`). `PatternWildcard` counted both → a phantom
  "duplicate" → wildcarded it, emitting `<<binary::_>>` ("unknown bitstring specifier
  `_`") or `<<_::binary>>` (stranding the body's `binary` → "undefined variable").
  Fixed by walking only the *value* side of a `::` segment (`walk_vars` clause),
  mirroring the `:spec` exclusion the in-place path already applies. (`PatternSwap`
  is unaffected — it only swaps siblings inside explicit tuple/list/map containers,
  never a `::` segment.)
- **`clause_drop` orphaning a bodiless function head (fixed):** `Plug.Conn.Utils`
  declares `def validate_utf8!(binary, exception, context)` (a bodiless header, for
  docs/grouping) followed by one body-bearing clause. `build_drops` counted the
  header as a droppable clause, so `length == 2` offered drops — and the mutant that
  drops the *impl* left a bodiless `defp …(args)` with no body ("implementation not
  provided for predefined …"). Fixed by counting only **body-bearing** clauses
  (`[head, body | _]`, vs a header's lone `[head]`): a header is never a drop target,
  and ≥ 2 *impls* are required, so a drop always leaves a real implementation behind.

After both fixes the entire plug `lib` (~6k mutation sites) renders and compiles as
a metamutant with **zero** poisons.

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
- **Dependency-free bootstrap.** `Mutare.Selector.bootstrap_ast/0` is the
  canonical env→`:persistent_term` activation code. The sandbox renders that AST
  into `test_helper.exs`, so targets need nothing added to their deps and there
  is no second env-parsing implementation to drift. The timeout watcher is the
  symmetric second half: `Mutare.Sandbox.Command.watcher_ast/0` is its canonical
  quoted AST, owned next to the timeout env var and exit code, and the sandbox
  renders it the *same* way (`Macro.to_string`). Both halves are therefore parsed
  at build time and owned next to their constants — neither is assembled here as
  an interpolated string (the watcher used to be a raw heredoc concatenated to the
  rendered selector, an asymmetry now removed).
- **Compile-poisoning pre-filter (done).** Rather than the design's "compile
  each candidate in isolation" (N compiles, and a candidate isn't compilable in
  isolation anyway — it needs its context), Mutare **recovers** from the one
  metamutant compile it already does: on failure, `Mutare.Poison` maps the
  error's `file:line` to the offending mutant id(s) via the stored
  `Mutare.Manifest` (see the manifest entry below), the transform drops them
  (`:skip_ids` — record the site `:poisoned`, emit no selector; the id counter
  still advances so ids stay stable across rebuilds), and we recompile, bounded.
  Zero extra cost when nothing poisons (the common case); a few recompiles when
  it does. `:poisoned` mutants are reported and excluded from the denominator.
  So this — not `# mutare:ignore` — is what rescues a poisoning mutant. Caveats:
  line→id mapping is still best-effort (if a line lands in no generated range it
  falls back to the old abort); the whole-`case` fallback over-drops (every
  mutant the `case` hosts) for a structural error it can't pin to one clause; and
  `:skip_ids` drops by id, which is only stable because the counter advances for
  skips.
- **`--since <ref>` (done).** `Mutare.Changes.since/2` runs `git diff
  --name-only --relative <ref>` with `root` as cwd, giving root-relative changed
  files (committed + uncommitted); `Schema`'s `:only_files` intersects discovered
  files with that set, so it composes with `--only`/paths. Limits: untracked new
  files aren't reported by `git diff` (commit them); only the changed files
  themselves are mutated, not files that transitively depend on them; `--since`
  assumes `root` is inside the repo.
- **Custom mutators (done).** `Mutare.Mutator` is the public extension point:
  `mutate/1` + `name/0`. `:mutators` in `.mutare.exs` accepts built-in family
  atoms *and* any module implementing the behaviour (validated, with a helpful
  error otherwise). Dropped the old `kind/0` callback — it was vestigial and
  misleading: placement (in-place selector vs lifting into a guard) is decided
  by the node's *position*, not declared by the mutator. Limit: `mutate/1` does
  node-level mutations; structural mutations (clause-drop) remain built-in only,
  not expressible by a custom mutator. CLI `--mutators` CSV is for built-in
  families (short names); custom modules go in `.mutare.exs`.
- **Validated options struct (done).** The shared keyword list that threaded
  through `Config → Schema → Runner → Sandbox` is now `Mutare.Options`, built and
  validated once by `Options.new/1` at each public entry point (idempotent on a
  struct, so the pipeline normalizes once and passes the struct down). Validation
  was previously scattered (the `:timeout` positive-int check lived inline in the
  runner) or absent (`:workers`, `:test_selection`, `:paths`, `:sandbox` shape) —
  an invalid `:test_selection` silently fell through to the coverage probe, a
  zero/negative `:workers` reached `Task.async_stream`. `new/1` now rejects
  unknown keys and bad values up front with `ArgumentError`, surfaced by the mix
  task as a clean failure (same path that already caught unknown mutators).
  Deliberately *not* options: per-file transform plumbing (`:file`, `:start_id`,
  `:skip_ids`) stays a keyword list internal to `Schema`, and `skip_ids` (poison
  recovery state) is threaded as an explicit `Schema`/`Runner` argument rather
  than a config field; the sandbox **disjointness** check stays in `Sandbox`
  (it's relative to `root` — `Options` only validates the path's shape).
- **Harness errors are not kills (done).** The runner used to treat *every*
  non-zero `mix test` exit as a kill (`classify_status/1`: `0 → survived`,
  timeout-code `→ :timeout`, everything else `→ :killed`). But "everything else"
  conflated a real test failure (the mutation was caught) with the harness never
  reaching a verdict at all — a compile error, a missing dependency, a broken
  `test_helper`, a filesystem race. Those exit `1` (or a signal code), and
  counting them as kills silently inflates the score with infrastructure noise.
  The fix makes the two separable: every mutant `mix test` is now run with
  `--exit-status 101` (`Mutare.Sandbox.Command.failure_exit/0`), the code mix
  uses **only** on its `failures > 0` path; harness failures still exit `1`. So
  the exit-code contract `Mutare.Sandbox.Command` owns becomes total —
  `0 → :passed`, `101 → :failed`, `124 → :timeout`, *anything else* →
  `:harness_error` (decoded by `outcome/1`, returned in the typed
  `Mutare.Sandbox.Command.Result` from `timed_test/4`). The runner maps
  `:harness_error → :harness_error`, a new `Mutare.Result` status excluded from
  the score's denominator (like `:no_coverage`/`:ignored`/`:poisoned`) and
  surfaced in the summary (`E` in the progress stream). **The gotcha that pins
  the design:** `ExUnit.configure(exit_status: …)` in `test_helper.exs` does
  *not* work — `mix test` re-configures ExUnit from its own options *after*
  loading the helper (`"so the task options override test_helper.exs"`), so the
  helper's value is discarded; the `--exit-status` CLI flag is the only lever,
  and it lives at the run side (`Command`) next to the timeout exit code, not in
  the injected bootstrap.
- **Harness-error retry + abort threshold (done).** Two knobs harden the above
  against flakiness and systemic breakage, both configurable via `.mutare.exs`
  and CLI (`--harness-retries`, `--max-harness-error-rate`):
  - **Retry** (`:harness_retries`, default `1`). A harness error can be
    *transient* (a filesystem/lock race under parallel workers), so the runner
    re-runs a harness-erroring mutant up to N times before recording it — a fresh
    `mix` boot is its own natural backoff. Only `:harness_error` is retried; a
    real verdict (passed/failed/timeout) never is. Retry lives in the runner's
    `run_mutant/5`, *not* in `Command` — `Command` does one clean run and reports
    its outcome; whether to re-run is an orchestration decision. (So
    `Command.timed_test/4` and `harness_test.exs` see exactly one run.)
  - **Abort threshold** (`:max_harness_error_rate`, default `0.5`, `nil`/`1.0`
    disables). After the per-mutant phase, if *persistent* harness errors exceed
    this fraction of the mutants that **ran** (`:killed`/`:survived`/`:timeout`/
    `:harness_error` — skipped ones never launched a run, so they don't dilute
    the rate), the run aborts with `{:error, :too_many_harness_errors, detail}`
    instead of reporting a score over a denominator the broken sandbox has
    hollowed out. The denominator is "ran", not "total", on purpose: a project
    full of `:no_coverage` mutants shouldn't mask a high error rate among the few
    that executed. A *uniformly* broken sandbox fails the baseline first
    (`:baseline_failed`) and never reaches this guard; the guard catches the
    *partial* case where baseline passed but many per-mutant runs then failed.
    The decision is pure and tested (`Report.harness_errors_exceed?/2`, mirroring
    `passes_gate?/2`); the runner owns the abort + message.
  - **Per-mutant warning** (`warn_harness_error/2`). Each *persistent* harness
    error (retries exhausted) emits a `Logger.warning` naming the mutant
    (`file:line`, id) and its exit code, so infrastructure breakage is loud
    during the run, not just a count in the summary. Fires once per mutant at the
    point of recording, never per retry attempt; the full `mix` output stays on
    the `Mutare.Result` for diagnosis.
  **Testing the post-baseline path.** A real post-baseline harness error can't
  come from a broken sandbox (that fails the baseline first and never reaches the
  per-mutant phase), so `harness_test.exs`'s `through the runner` tests *simulate*
  one deterministically: the target test reads the public `:mutare_active` key and
  `System.halt`s with an off-contract code for exactly one mutant, leaving the
  baseline (id 0) green. That drives the warning, the abort guard, the retry-warns-
  once behaviour, and the score exclusion end to end through `Mutare.run/2` — on
  top of the pure-decision tests (`harness_errors_exceed?/2`) and the
  classification tests (a broken compile → `:harness_error`).
- **Machine-readable output (done).** Three reporters join the human console
  report, as pure renderers under `Mutare.Report.*` (`(results, sources, opts) ->
  String.t()`, mirroring `Mutare.Report`); all IO stays in `Mix.Tasks.Mutare`,
  which iterates `options.reporters` (`[{format, path | nil}]`, `nil` = stdout).
  The pipeline is untouched — this is a pure additive output stage over the
  existing `run.results` + `run.schema.sources`.
  - **JSON is the foundation, in the Stryker schema.** Rather than invent a
    Mutare-shaped JSON, `Mutare.Report.Json` emits the standardized, versioned
    [mutation-testing-elements](https://github.com/stryker-mutator/mutation-testing-elements)
    report schema. The payoff is large: it drops into the Stryker dashboard, and
    it lets HTML ride for free (below). The fit is almost suspicious — our
    `Mutare.Result.status/0` maps **7-for-7** onto the schema's `MutantStatus`:
    `:killed→Killed`, `:survived→Survived`, `:no_coverage→NoCoverage`,
    `:timeout→Timeout`, `:ignored→Ignored`, `:poisoned→CompileError`,
    `:harness_error→RuntimeError` (the one place the two vocabularies meet, a
    single map in `Json`). Everything the schema needs is already on `%Site{}`
    (`id`, `mutator`, `mutated_code`→`replacement`, `range`→`location`) and
    `schema.sources` (the per-file `source`, root-relative keys = the schema's
    file keys). We emit **all** mutants, not just survivors, and `schemaVersion`
    `"1.0"` (no v2-only feature is used). Thresholds: we have one gate
    (`:min_score`), not a band, so a set gate collapses both bounds onto it
    (`{high: n, low: n}`); absent, Stryker's conventional `{80, 60}`.
  - **HTML is the JSON in the official viewer, not a bespoke renderer.**
    `Mutare.Report.Html` embeds the `Json` document into the
    `mutation-test-report-app` web component (pinned unpkg bundle) by setting its
    `.report` property in an inline script. So the interactive report (file tree,
    inline annotations, score) costs ~30 lines and stays in sync with the schema.
    The one sharp edge: a `</script>` inside embedded source would close our
    inline `<script>` early, so we neutralise `</`→`<\/` — a valid JSON string
    escape, so the payload stays both inert-as-HTML and decodable-as-JSON.
    Tradeoff: viewing fetches the bundle from a CDN (vendoring is a later toggle).
  - **SARIF is survivors-only.** A killed/skipped mutant is not actionable; a
    *survivor* is a located gap, which is what SARIF models — so
    `Mutare.Report.Sarif` emits one `warning`-level result (rule `surviving-mutant`)
    per `:survived`, reusing `Site.describe/1` verbatim as the message and the
    site range as a 1-based `region`. GitHub code scanning then annotates the PR.
  - **Built-in `JSON`, not a new dependency.** Encoding uses the stdlib `JSON`
    module (Elixir 1.18+), so the project floor bumped `~> 1.15 → ~> 1.18` — no
    new dep (keeps the one-dep, dependency-free ethos), and no CI matrix existed
    to break.
  - **`:reporters` vs `:reporter`.** Deliberately distinct: `:reporters` is the
    output-format list (validated in `Options`, the single source of truth for
    format validation); `:reporter` is the pre-existing live per-mutant progress
    callback. The collision rule lives in `Config.resolve_reporters/2`: `--format`
    with `--output` writes the machine format to a file *and* keeps the human
    report on the console; `--format` alone takes stdout and drops the human
    report (they'd interleave). `.mutare.exs` `reporters:` is the multi-format
    path (a bare atom normalises to stdout). The `--min-score` gate is orthogonal
    to format (it's an exit code) and runs after all reporters regardless.
- **Baseline flakiness detection (done).** A flaky test — one that passes/fails
  nondeterministically *regardless of the mutant* — manufactures **false kills**:
  when it goes red during a mutant's run that mutant is scored `:killed`, hiding a
  real survivor. The dangerous direction, since the diff is the product and we
  must never lie. Flakiness is a property of the *suite*, not of any one mutant,
  so we catch it at the **baseline** — `O(N)` runs, independent of the mutant
  count — rather than re-running every mutant. `--baseline-runs N` (`:baseline_runs`,
  default **1** = unchanged behaviour, opt-in, zero added cost) runs the suite up
  to N times; `Mutare.Runner.Baseline.classify/1` (pure, unit-tested, mirroring
  `Report.harness_errors_exceed?/2`) decides: all green → `{:ok, slowest_green_ms}`
  (the slowest green run keeps the timeout cap conservative); all red →
  `:baseline_failed` (unchanged); **mixed** → `:baseline_flaky`, aborting and
  naming the disagreeing tests (best-effort `*_test.exs:NN` parse, falling back to
  the output tail — message-only, so brittleness is harmless). Collection
  short-circuits the instant a pass and a fail are both seen. Wiring mirrors
  `:harness_retries` exactly (mix `@switches` → `Config.merge` → `Options` field +
  `validate_baseline_runs!` (≥ 1, *not* ≥ 0 — you always need one green check) →
  `Runner` → new `format_error(:baseline_flaky, _)`). The end-to-end `:runner` test
  makes a suite deterministically flaky via a counter file persisted in the reused
  sandbox cwd (red on run 1, green on run 2).
  - **Decision: abort-and-name, not quarantine.** Matches DESIGN's "abort loudly"
    and "mitigate, don't pretend": we refuse to score a flaky suite rather than
    guess which tests to drop. **Deferred** as a follow-up: *quarantine* the flaky
    tests and proceed over the stable subset (needs the exclusion threaded through
    the baseline re-measure, the coverage probe, *and* every per-mutant run — and a
    reduced-suite score is a soundness caveat to surface).
  - **Deferred — Layer 2 (`--runs`/rerun-kills).** A residual flake only visible
    under one mutant's timing escapes a green baseline. The fix: re-run each
    *killed* mutant up to N times and demote to `:survived` if any re-run fails to
    kill (**unanimous-kill** — the honest combine rule; "any-kill" defends the
    wrong direction). Under unanimous-kill only kills need re-running, so the honest
    rule is also the cheap one; it's a near-copy of the `:harness_retries` machinery
    in `run_mutant/5`. Orthogonal to harness retries (that's infra flakiness, this
    is test flakiness). Not built here.

## Consolidations weighed and left as-is

A refactoring pass folded most of the cross-module duplication — shared AST/resolution/suppression
helpers (`Mutare.AST.literal_value`/`absolute_call`, `Aliases.resolve_node/2`,
`Transform.Suppression`), the `Uses` split (`EnvMirror` + `Harvest`), the `emit_*` id-claim fold
(`claim_clauses`/`ids_from_clauses`), and making `mutate/1` an optional callback. Three near-
duplications were measured against the cost of unifying them and **deliberately kept** — the merge
buys less than the duplication costs:

  - **`Mutare.Mutators.RegexLiteral`'s two byte-walks** (`scan/6` and `alt_walk/6`). Both consume the
    Elixir regex string and share the escape-pair / character-class handling, but their *accumulators*
    differ fundamentally — `scan` threads a `prev_quant` for quantifier detection, `alt_walk` a frame
    stack for alternation spans. A shared driver would have to thread both states through pluggable
    callbacks; the combined state is *more* tangled than the two focused walks, and the module is
    already well-tested. Revisit only if a *third* walk appears or the escape grammar grows (`\Q…\E`).
  - **`Mutare.Transform.Analyze.Conditions`' parallel spine-walks** (`spine_rewrite`, `spine_bindings`,
    `eval_steps`, `offspine_escaping_binding?`, `prune_binding_ancestors`). All share one structural
    skeleton (stop at `@binding_isolating_forms`, recurse-left at `@short_circuit_ops`, flag at
    `@branch_forms`, special-case `:=`) and differ only in what each accumulates. A generic
    `spine_walk(node, acc, handlers)` would collapse the skeleton — but these walks are subtle (the
    binding-escape analysis is correctness-critical and the tests lean on surviving-equivalent
    reasoning, so a generalisation mistake wouldn't obviously fail). Pin each with property tests
    *before* attempting it; until then, the explicit walks are safer than one clever one.

The other two items from that pass are documented where they live: the `Uses` env-mirror **seqlock
invariant** in `Mutare.Transform.Uses.EnvMirror`'s module comment (the home the extraction gave it),
and the **harness-retry contract** — only `:harness_error` is retried, because the kill outcomes
`Command.outcome/2` recovers (`:suite_compile_error`, `:atom_exhausted`) are already distinct by the
time `Runner.run_mutant/5` reads `result.outcome` — at that guard.
