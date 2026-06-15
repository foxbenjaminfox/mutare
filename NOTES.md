# Implementation notes & deferred work

A running log of decisions made and limitations discovered while building Mutare.
`DESIGN.md` is the vision; this file tracks reality and what's intentionally left
for later. Items are tagged with the milestone that should resolve them.

## Deferred / known limitations

### Metamutant line preservation — RESOLVED (avoided) `[M3, done]`
In-place selectors and lifted copies shift line numbers in the metamutant, so we
worried the coverage probe would need a metamutant↔original line map. It doesn't.
The probe works **entirely in metamutant line space**: each mutant id maps to the
line of its selector's catch-all (`_ ->`) branch (read from the stored
`Mutare.Manifest`, see below) and intersects with `:cover`'s per-line hits on the
baseline. The original line is only ever used by the report (which patches the
original source), so the two never need to be related. No line preservation required.

Two `:cover` gotchas worth remembering (both handled in `Mutare.Coverage`):
- `:cover.analyse(:coverage, :line)` returns `{:result, ok, fail}` (3-tuple) on
  this OTP, not the documented `{:ok, _}`.
- cover does **not** count the `case` keyword line of a selector nested on a
  continuation line (`acc +\n  case … end`); it counts the catch-all body line.
  So we key coverage on the catch-all body line, which is hit iff the selector
  ran at baseline.

### Per-mutant metamutant manifest `[done]`
`Mutare.Manifest` is the per-file, per-mutant readback of *where each mutant lives
in its rendered metamutant*. `Schema` builds one per mutated file (once, from the
rendered source) and stores it under `:manifests`; `Coverage` and `Poison` read it
instead of each re-parsing the metamutant (Coverage on every probe, Poison on every
compile error). It carries two things per mutant: the **coverage location**
(`{module, catch-all line}`) and the **generated line ranges**.

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
- Ranges only exist *after* rendering, so the manifest re-parses with
  `Sourceror.parse_string!` (for `Sourceror.get_range/1`) — not `Code.string_to_quoted`.
  Sourceror wraps every literal in `{:__block__, _, [literal]}`, so
  `Mutare.Metamutant.subject?/1` was made tolerant of that wrapping (one recognizer,
  both parsers); the integer clause patterns are likewise unwrapped.
- A lifted private copy is attributed to its id by name (`~r/\A__mutare_.*_m(\d+)\z/`);
  `…_orig` and user code never match, so they're left out.
- `Mutare.Metamutant` shrank to just the selector-subject AST contract
  (`subject_ast/0` + `subject?/1`); the metamutant *walk* now lives in `Mutare.Manifest`.

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
is what keeps poison recovery cheap: the runner rebuilds the *same* sandbox path
repeatedly, and each rebuild is condition 3.

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
  returns the whole `when` untouched for in-place (its head patterns included);
  this is position-independent, so `case`/`fn` clause guards are skipped too.
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
- **Bitstring type specifiers** (the right of `::` in `<<>>`): **excluded**
  (context `:spec`), *except* `size(expr)` args. A `case` is illegal as a bare
  spec / in `unit(...)`, and swapping the `-` separator yields an illegal
  specifier (`integer-big` → `integer+big`) — both compile-poison the single
  build. The analyzer keeps separators / type atoms / `unit()` raw but recurses
  into `size(expr)` args (a `case` *is* legal in `size`), so a body's
  `<<x::size(n*8)>>` still yields a real, killable size mutant; in a pattern the
  size arg is pruned. The value side (left of `::`) mutates normally.
- **Default arg values** (`def f(a \\ b + 1)`): mutated in place; live mutant.
  The head is a pattern, but `\\`'s default runs at call time, so the analyzer
  routes it back to `:runtime`. Note such functions are *not lifted* (defaults
  expand to multiple arities; normalize-then-lift is deferred), so they get no
  guard/clause-drop mutants.
- **Patterns** (clause heads, `=` match LHS): routed to `:pattern` and not
  mutated. Built-in arithmetic/relational operators can't legally appear in a
  pattern anyway, so this mainly shields *custom* mutators. **Deferred:**
  clause-pattern / generator routing for `case`/`fn`/`with`/`for`/`receive`/
  `try`/`cond` — those `->`/`<-` LHS positions still walk as `:runtime` (a
  custom mutator there is poison-backstopped). Beware when adding it: a `cond`
  `->` LHS and `for`/`with` filters are *runtime* and must keep mutating; only
  `case`/`fn`/`receive`/`try` and `<-` generator LHS are patterns.

### Guard tagger is not bitstring-spec-aware `[deferred]`
`tag_targets/3` (the lifted-guard path) is a context-free `Macro.postwalk` that
runs mutators on every guard node. A multi-specifier bitstring *pattern* inside a
`when` guard could therefore lift a `-`-separator swap that compile-poisons (the
`size()`-arg subcase only produces a legal direct swap — lifting never emits a
`case`). Exotic and poison-backstopped, so left as-is. The clean fix shares the
`analyze_spec/3` spec-exclusion descent between `analyze/3` and `tag_targets/3`.

### Transform pipeline — explicit stages `[refactor, done]`
`Mutare.Transform` is an explicit pipeline rather than a walk-everything-then-
subtract design. Stages: **analyze + classify** (`analyze/3` is a single
context-threaded recursive descent: it *names the context* of each position as
it descends and attaches a typed `Transform.Candidate` to each mutatable node's
own `meta[:mutare]`), **assign + emit** (`emit/2`, a bottom-up `Macro.postwalk`,
hands out ids in post-order DFS; the counter advances for `:skip_ids` so ids
stay stable across poison-recovery rebuilds), and **render** (strip the
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
  the typed `Transform.Candidate` struct (`context`/`kind`/`operation`), shared
  by in-place and lifted alike.
- **`{line, column}` node identity** is gone. In-place candidates ride in the
  node's intrinsic `meta[:mutare]`; guard targets are tagged with a unique
  `meta[:mutare_tag]` and the mutated clause group is materialized once at
  analysis time (`Candidate.mutated_clauses`). Metadata survives `Macro`
  rebuilds and can't collide across duplicate subtrees — the reason the
  positional key existed.
- Mutators are invoked **once** per in-place site (in `annotate`'s walk), not
  twice (the old `capture_ranges` + `wrap_site` pair).
- **Shared vocabulary lives in its own files.** `Transform.Candidate` and
  `Transform.Ctx` (the typed structs threaded through every stage) and
  `Transform.Render` (the Sourceror workarounds: `to_source/1` strips
  annotations + normalizes keyword blocks; `block_wrap/1` shields a bare
  selector `case`) are split out of `transform.ex` so the semantic pipeline
  isn't interleaved with vocabulary and rendering friction. The lift/clause and
  in-place machinery stays in `Transform` — it shares the `Ctx` id-threading
  discipline too tightly to separate cleanly (cohesion is the feature here).

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
- **Not lifted (fall back to in-place):** functions with default args,
  operator-named functions (`def a ~> b` — can't be spelled `__mutare_~>_2_…`),
  and functions with non-consecutive clauses (see the dedicated note below).
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
  pointing at the fix (group the clauses). **Deferred:** the cases we *can* lift
  safely — e.g. heads separated only by another `def`, with no compile-time read
  whose value differs across the split — are worth recovering later
  (normalize/relocate the reads, or detect attribute-independence and lift). For
  now the blanket refusal is the conservative, always-correct choice.
- **Private names** are `__mutare_<name>_<arity>_g<group>_{orig,m<id>}`. The
  group counter keeps generated names unique, and `?`/`!` (legal only at a
  name's end) are replaced so they can sit mid-identifier. The public dispatcher
  keeps the real name.
- **Lifting duplicates whole functions** (K+1 copies for K lifted mutants), so
  code size / single-compile time grows with mutation density on overloaded
  functions — the accepted cost (first-order ⇒ no copy sharing).

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
with cross-file dependencies (a test relying on state another file set up) can't
gather clean per-file coverage. That no longer fails the baseline (see below) — a
probe file that's red in isolation just degrades the whole run to `:run_all` (you
lose selection but stay correct). Use `:full` to keep coverage-based no-coverage
skipping in that case.

The probe's decision is **typed**, not an overloaded value
(`Mutare.Runner.CoverageProbe`): `selection` is `:run_all | {:selective, %{id =>
outcome}}`, where `outcome` is `{:run, test_args} | :no_coverage`. The
`{:selective, _}` map is **total** — every mutant id has an explicit outcome, so
`:no_coverage` is *named*, never implied by a missing key. `:run_all` is the single
conservative fallback: it covers an unreadable coverdata (don't risk a false
`:no_coverage` for a file we couldn't read), a probe file that isn't green in
isolation, *and* an all-empty hit set (`:cover` recorded nothing → it likely
failed, so don't skip the world). Both modes share it. The rule throughout: never
skip on doubt — run everything rather than silently drop a mutant from the score's
denominator.

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
no_coverage − ignored)`), surfaced in the summary. Line-based, but parsed from
Sourceror's comment metadata (`Mutare.Ignore`), not a raw-text scan — each
comment's `previous_eol_count` (`0` ⇒ trailing, `≥ 1` ⇒ standalone) drives the
classification, and a literal `"# mutare:ignore"` *string* is never mistaken for
a directive (the old text scan accepted it). It still *generates* the (unused)
selector for an ignored mutant, so it does **not** rescue a compile-poisoning
mutant — that's the compile-poisoning pre-filter's job, not ignore's.
Suspected-equivalent auto-reporting is still future work.

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
    `passes_gate?/2`); the runner owns the abort + message. **Note:** the abort's
    trigger (intermittent post-baseline breakage) isn't deterministically
    reproducible without mocking, so it's covered by the pure-decision tests
    rather than an end-to-end one. **Still deferred:** a `Logger.warning` per
    persistent harness error (loud per-mutant surfacing beyond the summary count).
