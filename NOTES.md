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
is what keeps poison recovery cheap: the runner rebuilds the *same* sandbox path
repeatedly, and each rebuild is condition 3.

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
- **Bitstring type specifiers** (the right of `::` in `<<>>`): **excluded**
  (context `:spec`), *except* `size(expr)` args. A `case` is illegal as a bare
  spec / in `unit(...)`, and swapping the `-` separator yields an illegal
  specifier (`integer-big` → `integer+big`) — both compile-poison the single
  build. The analyzer keeps separators / type atoms / `unit()` raw but recurses
  into `size(expr)` args (a `case` *is* legal in `size`), so a body's
  `<<x::size(n*8)>>` still yields a real, killable size mutant; in a pattern the
  size arg is pruned. The value side (left of `::`) mutates normally.
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
  false end`). It looks like an ordinary call, so without a dedicated `analyze`
  clause its pattern arg was routed `:runtime` and a literal/tuple/string there was
  mutated in place — splicing a `case` into a pattern ("case not allowed in
  matches"). Now routed like `=`: arg 1 `:pattern`, arg 2 the surrounding context.
  Only the bare `match?/2` form (how it is always written); a qualified
  `Kernel.match?/2` is left to poison fallback. Found dogfooding `plug` — see
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
- **bare vs qualified diff.** The stamp carries the rebuild kind: a whole import (`:all`) →
  `:bare` (the swap's sibling is importable too, clean diff `reject`→`filter`); any selective
  import (`:only`/`:except`/`only: :functions`) → `:qualify` (`reject`→`Enum.filter`, always
  compile-safe since the sibling may be out of scope). `except:` qualifies too — the sibling
  could be the excepted name.
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
- **Out of scope (documented limitations).** Erlang atom-module imports (`import :lists`) and
  bare imported `:string`/`:math` calls — those families match the literal atom form and
  don't route through `resolved_call`; the import isn't tracked. Operator displacement
  (`import Kernel, except: [+: 2]` + a custom `+`) — Arithmetic/Relational/Logical don't read
  the stamp. Bare-imported transparent-transform *removal* (`import Enum; sort(xs)` →
  `xs`) is also not covered: `CallRemoval` doesn't route through `resolved_call`. Like
  `alias`, `use`/macro-injected imports are invisible.

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
    skipped by the mutator (it is StringLiteral's domain, which itself skips
    interpolations); its inner expressions still mutate (the node is descended);
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
- a `case`/`receive`/`fn` *clause* pattern — **in place** (`Candidate.CasePattern`), since
  none is a function clause group to lift; and
- a runtime **`=`-match LHS in a value-discarded position** (a non-final block statement, a
  `for` qualifier, or a `with` clause) — **in place** (`Candidate.MatchPattern`, see the next
  note).

The three in-place constructs share one analyze path (`attach_clause_pattern_candidates/4`)
parameterized by *the clause list* and *a rebuild closure* — the only things that differ
(`case` has a subject + a single `do` block; `receive` has a `do` block plus an optional
`after` whose timeout is **not** a pattern and is skipped; `fn` *is* its clauses, with
multi-argument heads). Each clause's pattern *positions* are iterated, so a single-pattern
`case`/`receive` clause and a multi-arg `fn` clause are handled uniformly; a duplicate
*across* fn arguments (`fn x, x -> …`) is not seen (each position is mutated independently),
only a duplicate *within* one argument (`fn {x, x} -> …`) — a small, rare gap.

A `<-` generator/clause LHS and `try` patterns are deferred. The shared discovery primitives
(`mutators/1`, `used_names/1`, `bound_var_names/1`, `node_mutations/3`) live in
`Transform.PatternStructure`, used by every path.

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

Non-match semantics are preserved exactly: each inner case carries a trailing `u -> raise
MatchError, term: u` clause, so a value that doesn't match raises the *same* `MatchError`
the original `=` did (not a `CaseClauseError`) — keeping the baseline identical and still a
clean kill on a mutant whose pattern stopped matching. (The pattern is always a refutable
container — a bare `var`/pin-only LHS is never offered — so that clause is always reachable;
the binding is clause-local, so a fixed `mutare_unmatched` name can't capture or collide.)

Known edges, both **only** warnings (harmless under the default warnings-tolerant metamutant
compile; poison-recoverable under `--warnings-as-errors`, where the whole-`case` fallback range
in `Manifest` maps them to the rewrite's ids — as for `PatternWildcard`'s "cannot match"):

  * a `{x, x} = e` whose `x` is *unused afterward* gains an "unused variable" warning the
    original (where the repetition counts as a use) didn't; and
  * when the LHS has an `_`-prefixed binding alongside a real swap/wildcard target
    (`{_keep, y, z} = t`), the inner case's return tuple **reads** `_keep` — an "underscored
    variable used after being set" warning the original may not have had. Suppressing it would
    mean aliasing every `_`-binding to a non-underscore temp in the inner patterns/returns
    (fiddly around pins), not worth it for a build-artifact warning; the `_keep` binding itself
    must still be re-exported (omitting it is the compile error above).

Several design choices worth remembering:

- **Structural via an optional callback, discovered by export.** `mutate/1` is `:skip`;
  the real entry point is `Mutare.Mutator.pattern_mutations/2` (`@optional_callbacks`),
  taking `(head_args, used_outside)` and returning mutated arg lists. It is discovered by
  `function_exported?(_, :pattern_mutations, 2)` — so no hard-coded list (unlike the
  `ReturnValue in mutators` check), toggling is just list membership, and a custom mutator
  can opt in. The head path (`FunctionPlan.build_pattern_structures/2`) calls it with the
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
  pointing at the fix (group the clauses). **Deferred:** the cases we *can* lift
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
  generated functions. The unquoted head pattern (`def code(unquote(atom))`) is
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
mutare_super = fn a1, …, aN -> super(a1, …, aN) end
```

and threads it to the base as the **second** argument (after `mutare_active`); each
`super(args)` in the relocated body is rewritten to `mutare_super.(args)`
(`Super.rewrite/2`). Sharp edges, all handled:

- **Per-clause unused param.** The base's arity is shared across clauses, so *every*
  base clause takes the closure param — but only the clauses whose own body calls
  `super` use it. A clause that doesn't names the param `_mutare_super` (each base
  clause is a separate `defp`, so the name can differ per clause), dodging the
  unused-variable warning that would otherwise poison a `--warnings-as-errors` target.
- **Collision-free name.** `mutare_super` is salted per-file exactly like
  `mutare_active` (`Names.salted/2`, canonical `:mutare_super`) — it is *read* in the
  base body, so it can't be underscore-prefixed (a read underscore var warns), and a
  source variable named `mutare_super` would otherwise be captured (a `super(x)`
  rewritten to `mutare_super.(x)` would call the user's value). Salts to
  `mutare_super_0`, … when taken.
- **`quote` is pruned.** A `super` inside `quote do … end` is quoted *data* (it names
  whatever context the AST is later spliced into, not a live call here), so it is left
  untouched — mirroring the in-place analyzer, which treats `quote` as `:compile_time`
  and never descends it. Such a body reads as super-free, lifts **without** a closure,
  and the quoted `super` rides along verbatim. (`super` only inside a `quote` is valid
  source — verified.) Detection and rewrite share one walk (`Super` is `{ast, found?}`)
  so they can never disagree on what counts as a live `super`.
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
`Sandbox` writes into the sandbox). Two keys, accumulate-only, **never reset** →
no race:
- **aggregate** `{id}` — written by any process → process-agnostic no-coverage
  detection.
- **attribution** `{{label, id}}` — `label` is the test process's
  `Process.set_label({case, name})` (proc-dict `:"$process_label"` on OTP 26,
  `:proc_lib.get_label/1` on 27+) → maps to the test *file* → per-file selection.

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
Reconciliation, per id: never ran → `:no_coverage`; ran with attributed files →
`{:run, files}`; ran but **unattributed** (covered only by an unlabeled process —
`setup_all`/`on_exit`/a spawned task) → `{:run, []}` (whole suite), *not*
`:no_coverage`. `:run_all` is the single conservative fallback: a non-zero probe
exit (the dump may be partial — e.g. `max_failures` aborts before later files),
an unreadable dump, or an empty dump (the capture recorded nothing → it likely
failed). The rule throughout: never skip on doubt — run everything rather than
silently drop a mutant from the score's denominator.

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
  node, with no slot for config — except `mutate/2`/`owned_args/2`, which already take a
  `context` map (`%{piped: …}`). So opts ride **in the context**: `mutations/3` builds a
  per-spec context with `:opts` = the spec's opts and passes it to `mutate/2`; `owned_args/2`
  gets it too. A configurable mutator therefore implements **`mutate/2`** (which is invoked
  on every node, not just pipe stages) and reads `context.opts`. `mutate/1` is left
  untouched (no context, no opts) — this avoided bumping every existing callback's arity and
  reused the one channel that was already threaded. `pattern_mutations/2` is **not** opts-aware
  (structural head-pattern mutators stay unconfigurable for now — out of scope, not a use case
  yet). The change is backward-compatible: existing `mutate/2` clauses match `%{piped: p}`,
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
become specs); every internal consumer (`Mutator.mutations/3`, `analyze`'s `owned_arg_indices`
+ `ReturnValue`/`IfCondition` enablement via `Spec.find/2`, `PatternStructure`, `FunctionPlan`,
`Site.replace`) reads `spec.module`/`spec.name`/`spec.opts`. The CLI's `--mutators` CSV can't
express opts (strings only) — configured mutators are a `.mutare.exs`/`Mutare.run/2` feature.

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
`Function.identity()`; pipe-aware via `mutate/2`. The remote targets are arity-blind;
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
  `Transform` invokes at every runtime call position with `%{piped: boolean}` (a
  dedicated `:|>` analyze clause routes the RHS through `analyze_pipe_stage/2` with
  `piped: true`; everywhere else defaults to `false`). The mutator computes
  `effective_arity = length(args) + if(piped, do: 1, else: 0)` and emits a normal
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
real work is `Mutare.Mutators.ReturnValue.replacements/1` (a pure tail→constants
function), invoked by `Transform` once per `def`/`defp` `:do`-block tail it finds
(`annotate_returns/3`). The module still implements the behaviour — `name/0` is
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
    atom, `if`/`case`/`with` result, …) → `nil` and `:mutare`

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
tail via `attach_return/2`, and each clause body tail via `attach_clause_returns/2`.
**`:after` is deliberately excluded** — `try` discards the after block's value, so
its tail is *not* a return path (a mutant there would be unobservable). The after
*body* still mutates in place; only its return-value candidate is withheld.

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

The `Site` each return mutant records (`Site.return_value/5`) has
`mutator: :return_value`, `kind: :in_place`, and `nil` ops (there is no operator),
shaped like the clause-drop site that also carries no op.

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
everywhere. So `mutate/1` is `:skip` and the real logic is
`IfCondition.replacements/1`, called by `Transform` at the positions only it knows:
the runtime `if`/`unless` analyze clause and `analyze_cond_clause`
(`attach_if_condition/3`). Registered for the usual membership benefits
(on-by-default, reportable, selectable, `# mutare:ignore[if_condition]`).

**Delivery reuses the in-place selector**, appending a `Candidate.InPlace`
(mutator = the `IfCondition` *module*, since `Site.in_place/6` calls `.name()` on it)
to the *analyzed condition node*, after any operator candidate already there — so
`if String.starts_with?(s, x)` gets one selector hosting the StringCall swap *and*
the `true`/`false` pair. `original`/`range` come from the raw condition for a clean
`if foo?(x)` → `if true` diff.

**What it skips, and why each matters.** `replacements/1` returns `[]` for:
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
    `Conditional` has the same latent hazard on `if (a = 1) > 0` but leans on
    poison-recovery; `IfCondition` excludes it up front to stay **compile-safe by
    construction**, per the layered-compile-safety rule.

Only `:runtime` conditions are offered — a module-level (`:scaffold`) `if`/`cond` runs
once at compile time with mutant 0, so a selector on its condition could never activate
(the `analyze_cond_clause` guard and the `:runtime`-only `if`/`unless` clause enforce
this).

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
membership mutator inherits it.

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
  Fixed by routing `match?/2`'s first arg `:pattern` (see "Non-body operator
  positions" → Patterns). Two of the "7" were *collateral*: poison maps a compile
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
