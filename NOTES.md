# Implementation notes & deferred work

A running log of decisions made and limitations discovered while building Mutare.
`PHILOSOPHY.md` is the vision; this file tracks reality and what's intentionally left
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
  > **OUTDATED (deferred-work audit, 2026-06-30):** cause #1 is no longer open.
  > Per-clause lifting changed the generated volume from `C×M` to `C+M`; see
  > *Why the metamutant was so big — lifting blowup on huge clause groups* below.
- The old lifted private-copy attribution by `_m<id>` name is also **outdated**.
  Per-clause lifting now attributes a lifted mutant through its
  `mutare_active === <id>` clause gate; `Manifest.gate_id/1` is the current reader.
- `Mutare.Metamutant` shrank to just the selector-subject AST contract
  (`subject_ast/0` + `subject?/1`); the metamutant *walk* now lives in `Mutare.Manifest`.

### Unknown block macro_routes: poison the whole block, not one mutant at a time `[done]`
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
in `Hint`, not with `Sandbox.Command.Output`'s verdict-forming patterns: it's read only for human remediation,
never to form a verdict. The `HintTest` unit-tests the parsing; a `:runner` poison test bridges
to the *real* compiler output (so a `expanding macro:` format drift is caught). At the time,
`:skip` was the only fix: ignores applied after rendering. Ignores now withhold generated code
too; see "Ignored mutants reserve IDs but emit no code" below.

### First-run UX on unknown DSLs: narrate recovery, suggest routes, `--check` preflight `[done]`
Aiming Mutare at a macro-heavy project it doesn't recognise (Absinthe, NimbleParsec, an
in-house DSL) had a slow, silent, forgetful feedback loop. Three coupled fixes, all built on
one new thread: a `Mutare.Runner.Recovery` struct carried through `compile_with_recovery`, and a
`t:Mutare.Run.recovery/0` summary on the completed `Mutare.Run`.

  * **Narrate recovery.** Each poison-recovery round is a *full recompile*, and up to 25 of them
    ran behind the single "compiling metamutant (once)…" spinner — indistinguishable from a hang.
    The runner now fires a `{:poison_round, info}` `:on_phase` event per round (dropped ids +
    escalated blocks); `Mutare.Report.Live` leaves a permanent `⟳ compile-poison: …` line in
    **every** mode (not just `--verbose`, unlike the `✓` phase details), so a wrong DSL guess is
    visible while it happens.
  * **Suggest routes after escalation.** The in-memory `skip_ids`/block escalation is rediscovered
    from scratch on every run (it is deliberately *not* persisted — id caches are fragile across
    edits in exactly the way name-based routes aren't, see "Unknown block macro_routes"). So on a
    run that *recovered* by escalating an unknown block macro, `Mutare.Poison.Hint.escalation_note/1`
    prints a copy-pasteable `{:*, :name, :skip}` `:macro_routes` snippet — the durable, name-based
    fix — making the **user** the persistence layer. Only *escalations* earn a note (a stable
    per-macro fact); an id-specific drop is a one-off (a custom mutator's bad code), not worth
    pinning. Module-wildcard `:*` because an unknown DSL's module isn't resolved.
  * **`--check` preflight.** `--dry-run` never compiles, so it can't tell a first-run user whether
    their DSLs will build. `--check` runs the one compile (with the same recovery) and stops before
    the baseline/per-mutant phase (`Runner.check_with_schema/3`, sharing the compile prelude
    `with_compiled_sandbox/3` with a full run), reporting *how* it compiled and printing the route
    suggestion. It also surfaces **degraded `use` expansions** — the failure mode where a
    module-level `use` Mutare can't expand in-process leaves a `:skip` route keyed on its injected
    macros dead. `Harvest.run/4` returns a degradation reason for the two *module-known,
    unambiguous* cases only (`:not_loadable`, `:nonstatic_args`); a `use` that loads and expands to
    genuinely nothing is **not** flagged (the "expanded but empty" and "raised" cases are
    indistinguishable at the top level, and false positives here would be pure noise). `Uses` stamps
    it under a stripped-before-render meta key; `Uses.degraded_uses/2` reads it back, computed only
    for `--check` so a normal run pays nothing. *(Since superseded: the count pass reads the stamps
    off the tree it already annotated — `Uses.degraded_uses/1` → `Schema.degraded_uses` — so `--check`
    re-parses and re-expands nothing; see "The count pass is the scan's only parse".)*

### Macro-expansion poison fallback: recover an inline DSL macro (`from`-style) `[done]`
Block macros were handled (escalation on a second strike); the harder, more common case is an
*inline* macro that rewrites its argument at compile time — `Ecto.Query.from/2`, a `Size.megabytes/1`
needing a literal, any unknown in-house `query(a > b)`. Splice a selector `case` into its argument and
the macro raises *while expanding*. The empirical finding that drove the design: **the compiler blames
the macro-*call* line, one line above the selector `case`** the `Manifest` records (Sourceror renders
`query(` and the `case` on separate lines), so line-based `Poison.ids/2` maps nothing, `poison ⊆ skip_ids`
holds trivially, and the run *aborted* — poison recovery was never even invoked for the case it most
needs to handle.

The fix is a **fallback attribution path** in `recover_compile_poison/5`, taken only when line attribution
stalls: parse the `expanding macro: Mod.fun/arity` frame the compiler *does* emit (already extracted by
`Hint.expanding_macros/1`, previously only to print an abort-time hint) and map it to mutant ids through the
**metamutant** (`Poison.macro_poison/2` → `Manifest.ids_in_named_calls/2`): find every call of that name in
the rendered metamutant of the file(s) the error touches, take its full range, and drop every mutant region
inside it. Key decisions:

  * **Attribute in metamutant space via the manifest, not the *original* source via `%Site{}`.** The first
    cut re-scanned original sources and matched against `schema.sites` — wrong twice. (1) Under
    `--line`/`--max-mutants` `schema.sites` is *filtered* but the metamutant still reserves/renders every id,
    so an *unselected* macro mutant still poisons yet has no site to match → abort. (2) A literal argument on
    its own line (`Size.megabytes(\n 5\n)`) gets no `:line` metadata from `Code.string_to_quoted`, so a
    child-metadata line-set misses it. Both vanish in metamutant space: the manifest carries *every reserved*
    id (like the line-based `ids/2` it backs up), and `Sourceror.get_range/1` ranges to the closing delimiter
    (a true span, not child lines). No scan-time `macro_context` tag, no `%Site{}` change, no loadability
    requirement — the compiler *named* the culprit, so a bare-name match is safe (not a guess).
  * **Bare-name match + range containment**, deliberately conservative. Two same-named macros are skipped
    together and every mutant inside a poisoning macro call is dropped — the same *bounded over-drop* blocks
    already accept, and only ever on a real failing compile. But a bare-name match needs two guards against
    *wrong*-drop, both because a macro defined in the target project surfaces extra same-named shapes:
    (a) scan only the **call-site file** — the frame *after* each `expanding macro:` marker, not every
    stacktrace location, since the frames *before* it are the macro's own implementation file (a same-named
    call there is unrelated); (b) **neutralise definition heads** — `def query(a \\ 1)` parses identically to
    a `query(...)` call, so the manifest walk opens a def head's outer call node to a `:__block__` (the head
    name can't match) *while still traversing its default/guard expressions* — a function sharing the macro's
    name is spared, yet a real literal-only macro inside a default (`def limit(n \\ Size.megabytes(5))`) is
    still found.
  * **Piped calls** (`(a > b) |> query()`): after pipe expansion the LHS is the macro's first argument, but
    its selector renders on the pipe's *left*, outside the RHS call node — so a `{:|>, _, [_, rhs]}` whose
    RHS names the macro is ranged as a whole, covering the piped value and every earlier stage.
  * **Inline-macro attribution beats line attribution** (`recover_compile_poison/5`). With default mutators a
    tail-position `query(a > b)` is *also* wrapped by an outer return-value selector; the macro rejects the
    inner argument selector, the compiler blames the macro-call line, and line attribution maps that line to
    the **outer** selector's whole-`case` fallback — wrongly dropping the innocent return-value mutants as
    `:poisoned` (they never run) while leaving the real poison. So the inline-macro match is tried *first*;
    only its ids (the argument mutants inside the raising macro) are dropped. **Block-macro** mutants are
    excluded from this priority (`inline_macro_poison/3` subtracts `block_macro`-tagged ids) — they keep
    recovering through `escalate_block_poison/3`'s id-specific-then-wholesale second-strike path.
  * **First-strike, wholesale, per-`{module, name}`** — no second-strike (the frame names the *macro*, not a
    mutant, and the rejection is structural, so there is no one-off to distinguish) and no per-invocation
    scoping (the natural fix is `{Mod, :fun, :skip}` *everywhere*, which is exactly what the frame supports).
  * The frame carries the **module**, so the suggestion is a precise `{Module, :fun, :skip}`
    (`Hint.macro_skip_note/1`), unlike the block case's `{:*, :name, :skip}` wildcard. A loud `⚠`
    `{:macro_poison, …}` narration names it inline during recovery; `--check` and the end-of-run stderr note
    surface it durably (and the old `--check` "custom mutator, nothing to route" *misdiagnosis* of these
    drops is fixed). On the rare non-recovery (innermost frame is a library-internal macro the user never
    wrote, so nothing matches), we still abort — with `Hint.for_compile_failure/1`'s skip snippet as before.
  * **Consequence:** the `Size.megabytes(5)` "unrecoverable" class is now *recovered* — its literal mutant is
    dropped `:poisoned` and the run proceeds, where it used to abort the whole run.

**One manifest per round, one reader of the frames (2026-09-11).** Two duplications had grown
around this fallback. (1) `recover_compile_poison/5` called `Poison.ids/3` — which parsed the
metamutant and built its manifest, memoized within that one call — and then `macro_poison/3`,
whose `Manifest.ids_in_named_calls/2` took *source* and parsed + built again: the same file,
normally. `%Manifest{}` now retains its `ast`, `ids_in_named_calls/2` takes the manifest, and
`Poison.attribution/3` returns both halves (`%{line, macro}`) from one `%{file => manifest}` memo
threaded through both; `ids/3` and `macro_poison/3` remain as the single halves. Wall-clock this
was small next to the recompile a round costs — the point is one manifest with one lifetime.
(2) `Hint` and `Poison` each had an `expanding macro:` regex and a line-walking state machine over
the same output, under a stale rationale on `Hint`'s ("read only for human remediation, never to
form a verdict" — untrue from the moment `macro_poison` began reading it) and with a semantic gap:
`Hint` took the *innermost* frame per stacktrace, `Poison` the call-site file after *every*
marker, and `macro_poison` cross-producted all names × all files. `Output.macro_expansion_stacks/1`
is now the one reader — per stacktrace, innermost first, each frame carrying its own call site;
its `** (` header is deliberately wider than `diagnostic_severity/1`'s `…Error)` marker, since any
raised term heads a stacktrace — `Hint.culprits/1` pairs each stack's innermost frame with *its*
call site, and `macro_poison` looks that name up in exactly that file. The only test that noticed
the tighter pairing was a synthetic headerless two-frame fixture in `runtime_id_test` (two
`expanding macro:` frames with no `** (…)` between them read as one nested stack); it now carries
one header per failure, as the compiler prints them.

### Warn for ineffective `# mutare:ignore` directives `[done]`
`# mutare:ignore` filtering fails **safe** — a typo'd family (`[arithmatic]`), an empty
`[]`, a standalone directive on the wrong line, or a family that produced no mutant there
all simply match nothing, so the mutant still runs. Safe, but **silent**: the user thinks
they suppressed a mutant and didn't. `Mutare.Ignore.ineffective/2` closes that gap — it
returns every directive **no recorded site admits** (`Directive.applies_to?/3` false for
every occupied `{mutator, result}` on the directive's line). One rule covers every failure
mode; there's no need to special-case typo vs. wrong-line vs. wrong-family vs. wrong-result.

It takes `{line, mutator, variant}` triples, not `Mutare.Site` structs, so `Ignore` stays
unaware of the site representation (same discipline as `directive_for/4` taking the bare
`mutator` atom + the site's mutator-declared `variant` label).
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

### Standalone `# mutare:ignore` placement — comment-block read-through + pipe hint `[done]`
The Phoenix sweep hit the same self-inflicted miss three times: a standalone
directive covered *literally the next line*, so both natural placements silently failed with
only the ineffective warning to notice —

- **directive-first, reason continuing below**: the directive's target landed on the second
  comment line, not the code. Fixed *semantically*: a standalone directive now reads through
  the contiguous block of standalone comments below it to the next code line, so a directive
  works at either end of an explanatory block. Only *standalone* comment lines
  (`previous_eol_count > 0` — nothing else on the line) are read through: a trailing comment's
  line carries code and correctly stops the walk, and a blank line ends the block (a detached
  block reads as unrelated; fail-safe toward running the mutant, surfaced as ineffective).
  Emergent nicety: stacked directives each read through the other to the shared code line.
- **directive above a multi-line pipe's first line**, mutated tokens two `|>` steps down. *Not*
  fixed semantically on purpose — covering "the whole logical expression" would silently widen
  every existing directive's blast radius (the dangerous direction). Instead the ineffective
  warning now carries a **misplacement hint** (`Ignore.misplacement_hint/3`): if the directive
  would have matched mutants on a later line *within the expression that starts at its target
  line* (span via `Sourceror.get_range/1`, so the hint can't point into an unrelated statement),
  the warning names that line and says to move the directive directly above it. The moduledoc
  documents the one-line rule with the pipe example.

Directives now also carry `comment_line` (where the directive text is) separately from `line`
(what it suppresses): with the read-through the two can drift apart, and every message —
ineffective warnings, `SpecError`s, `--list-ignores` — points at the comment, where the user
must go to fix it. (`--list-ignores` matches schema entries by `{file, directive}` struct
equality across two parses of the same source; both sides stamp `comment_line` identically,
so the equality survives.)

### Per-variant `# mutare:ignore[family:label]` qualifier — mutator-declared labels `[done]`
The `[family]` filter was all-or-nothing per family — too blunt for the common "one of these
mutants is equivalent, the rest aren't" case. Motivating shape: `i < j` where `i`/`j` are symmetric
(rows/cols cutting the diagonal), so `i > j` is an *equivalent* reflection but `i <= j` (the
boundary) is a real, non-equivalent mutant. `[relational]` would lose both; `Relational`'s table is
`:< => [:<=, :>]`, and the only thing distinguishing the two mutants is *which* mutation it is.

The first cut derived the discriminator from the rendered AST (`Site.ignore_target/1`: the mutated
operator atom, else the one-lined `mutated_code`). That was rejected as the wrong factoring: it leaks
an implementation artifact (`>` works, but a call rewrite is the whole `Enum.filter(x, f)` string, a
list result is `[]` which the filter's `]` terminator can't even spell, a negative int collapses to
`-`), it can't be validated statically, and it makes every family half-support qualifiers whether or
not that's meaningful. The replacement: the **mutator declares its own vocabulary** and tags each
mutation. Two optional callbacks (discovered by export, the `macro_routes/0` pattern): `variants/0` → the
label set (a family's *public contract* — operator names `> <= ==`, or semantic kinds `empty
sentinel` / `zero succ pred`), and `variant(original, mutated)` → the label(s) for one produced
mutation (a member of `variants/0`, or `nil` = unlabeled/bare-only — **or a list** when the mutation
is several kinds at once). Classify from the
`{original, mutated}` **pair**, never the mutated node alone — a strip (`-(a+b)` → `a+b`) emits a
`{:+, …}` that would otherwise be mis-read as a `+` swap.

`Site` stores the (downcased) label **list** in a `variant` field (`[]` when unlabeled), set by
`Mutare.Mutator.Dispatch.variant/3` from the producing `Spec`'s module (`function_exported?` guard,
so a non-opting mutator yields `[]`; the callback's `nil`/single/list return is normalized through
`List.wrap`). A list because one deduped mutant can be several kinds — `integer`'s `1 - 1`/`0` is both
`pred` and `zero`, so `[integer:pred]` *and* `[integer:zero]` each suppress it. The matching is
otherwise unchanged — `Directive.applies_to?/3` against the site's label list, a qualifier matching
when its token is a **member**, `:any` a wildcard on either side. Opt-in falls straight
out of "did the module export `variants/0`?": a family that didn't (Collection, the call families,
most structural) is bare-only, and the call/structural half-broken tokens simply don't exist.

The big win is **static, strict validation where the mistake is certain** (composing with the
fail-loud grammar decision): because the vocabulary is finite and declared,
`Mutare.Mutators.vocabulary/1` harvests `family → :none | MapSet(labels)` (full registry +
active custom/renamed specs, keyed case-folded; an `:as`-renamed custom overrides
the shadowed built-in — validate names a known family's labels against *all* built-ins, not the
`--mutators`-active subset, so a directive on a *disabled built-in* isn't a false typo), and
`Ignore.validate!/3` rejects a **qualified** `[family:label]` whose family **is in the vocabulary**
but whose label is absent — a no-variants family, or an unknown label: a hard `Ignore.SpecError`
with file:line and a Jaro "did you mean", raised from `Transform`, rendered by the Mix task as a
clean abort. So a label typo on a known family is caught *up front without a site*. The boundary is
**certainty**: an *unknown* family (qualified *or* bare) is *not* a hard error — it is
indistinguishable from a `--mutators`-excluded or removed *custom* family (which the active
vocabulary can't enumerate), so it stays lenient, exactly like a bare typo → a soft `ineffective`
warning. (The earlier design hard-erred an unknown *qualified* family, which inconsistently aborted
a legitimate focused run that excluded a custom mutator while tolerating the same for a built-in;
the certainty rule removes that asymmetry.) The vocabulary is only built when a file actually
carries a **qualified** entry (`Ignore.any_qualified?/1`), so a no-directive or bare-only file skips
the registry-reflection pass. Labels are checked **wire-safe** at harvest (no whitespace/`,`/`()`/
`]`/`"`) so a declared label is always expressible as a filter token, and matched case-insensitively
(declared + filter both folded via `Mutare.Mutator.normalize_label/1`). The drift invariant
(recorded label ⊆ `variants/0`) is covered by a test exercising the opted-in families end-to-end, plus
a completeness test that every binary operator-swap mutant of an opted-in family carries a label
(catching a `mutate/1` result operator missing from the family's `@swap_ops`, which the shared
`Mutare.Mutator.op_swap_variant/3` single-sources with `variants/0`).

**Later: labels ride on `%Mutation{}`, opt-in is `variants/0` alone.** The first cut had `variant/2`
re-derive each label from the rendered `{original, mutated}` pair — fine for an *operator* family
(the swapped operator IS the label, one-lined via `op_swap_variant/3`), but the *value* families
(`Literal`/`Float`/`String*`/`Charlist`/`WordList`) then re-ran their own production logic just to
re-classify it (`numeric_variant_labels`, `empty_sentinel_variant`-as-classifier) — a produce-then-
re-derive duplication that could drift. So `Mutare.Mutator.Mutation` grew a `variant` field and a
`tagged/2` constructor: a value family attaches the label **where it builds the mutant**
(`Helpers.numeric_mutations` tags `succ`/`pred`/`zero`, merging both onto the dedup-collapsed `0`;
the empty/sentinel families tag each half), and the tag rides the same `note` channel
(`mutations/3`'s `{spec, node, note, variant}` quad → `Candidate.{InPlace,Lifted,CaseClause,CasePattern}`
→ `Site`). `Dispatch.variant/4` resolves a site's label as **carried-tag-wins, else `variant/2`,
else none**, so the two mechanisms coexist (each family uses the cleaner one) and `variant/2` is now
*optional*. This forced **decoupling opt-in from label-assignment**: `opted_in?/1` is now just
`variants/0` exported (declaring the vocabulary), not the old "*both* `variants/0` and `variant/2`" —
a value family that tags has no `variant/2` yet must still expose its vocabulary for validation. So
the gate is "has a vocabulary?", and *how* labels are assigned (tag vs derive) is orthogonal; a
`variant/2` without `variants/0` is inert (no vocabulary to validate against). Net: the value
families dropped their `variant/2` and the duplicated classifiers, and "the label lives where the
value is born" replaced "re-derive it later". See the `Mutare.Mutator` moduledoc.

Three edges the two-phase build + info-mode dispatch surfaced (all now closed): (1) validation is
shared by the **count *and* render** paths (`Transform.validate_ignore_qualifiers!/2`), not render
alone — a **zero-site** file (e.g. a relational-only file scanned with only `--mutators arithmetic`)
is counted but never rendered, so render-only validation would silently downgrade its bad qualifier
to an `ineffective` warning; the count path prefilters on the `mutare:ignore` substring to keep the
directive prewalk off directive-free files. (2) The Mix task's `SpecError`→clean-`Mix.raise` rescue
sits at `dispatch_with_options/2`, around **both** a mutation run and the scan-backed info modes
(`--dry-run`/`--list-ignores`), which build a schema *before* `run_mutation_testing/3`'s own
try/after — without it those modes leaked a raw stacktrace. (3) A custom **family name** with a `:`
(or other wire-unsafe char) is rejected at `vocabulary/1` build (`:unfilterable_family`): the `:` is
the qualifier separator, so `[ecto:query]` parses as family `ecto` + label `query` and could never
name a whole `ecto:query` family — better to fail loud than let the filter silently match nothing.

`RegexLiteral` adopted the mechanism after the Phoenix sweep caught its moduledoc promising a suppression its granularity couldn't deliver: one
line's regex produced 5 killable character-class mutants plus exactly 1 provably-equivalent
lazy-quantifier mutant, and the only available qualifier — the line-granular `[regex]` — would have
swallowed all six. It now declares eight production-tagged labels (`pattern`/`anchor`/`class`/
`dot`/`quantifier`/`laziness`/`alternation`/`modifier` — see the family moduledoc), so
`[regex:laziness]` suppresses exactly that mutant. One wrinkle unique to this family: two passes
can produce the *same* candidate (a leading-`^` pattern's anchor drop coincides with the
whole-pattern `""` replacement), so candidate dedup **unions** the labels — the shared mutant
answers to either qualifier — instead of keeping whichever pass ran first.

### The `mutare:` comment namespace is reserved — unknown verbs warn `[done]`
Forward-compat groundwork done *before* any second directive exists: a comment that claims the
namespace (anchored `# mutare:`, same "must be the comment's purpose" rule as the directive regex)
but spells no recognized verb is warned at scan time (originally `Ignore.unknown_directives_from_ast/1`
→ `Schema.detect_directive_diagnostics/1` → the Mix task's stderr warning; now the `unknown` field of the
`Directives` container the count pass reports, see "The count pass is the scan's only parse"), and `--strict-ignores`
counts it alongside ineffective directives. Without this, a typo'd verb (`# mutare:ingore`), a
colon-detached one (`# mutare: ignore`), or a directive from a *newer* Mutare run under an older
version is silently inert — the same fail-silent class the ineffective warning exists for, but one
regex earlier. Adding any future verb starts at `Ignore.@known_verbs` (plus its own parser).

Two consequences worth remembering:
- **The directive boundary tightened from `\b` to `(?![\w-])`.** Under `\b`,
  `# mutare:ignore-file` (then not yet a verb) parsed as ignore-*everything* with reason `-file`
  (the `-` is a word boundary) — precisely the silent over-suppression a future hyphenated verb
  must not trigger. A hyphen now extends the *verb*, so an unrecognized hyphenation
  (`# mutare:ignore-lines`) lands in the unknown-verb warning instead. Behavior change is
  fail-safe (stops suppressing, starts warning) and the glued-reason shape (`ignore-…` with no
  space) is implausible as intentional usage. This groundwork is what later let
  `ignore-file`/`ignore-start`/`ignore-end` (next entry) become real verbs without ambiguity —
  the suffix alternation carries the same lookahead, so `ignore-startx` is still an unknown verb,
  not `ignore-start` with reason `x`.
- **The diagnostics prefilter widened from `mutare:ignore` to `mutare:`** (in
  `Schema.detect_directive_diagnostics/1`, which now runs one parse per flagged file for both the
  ineffective and unknown scans). The count-path *qualifier validation* prefilter in
  `Transform.count_string/2` stays at `mutare:ignore` — it only feeds the hard validations, which
  only read real ignore directives (every scoped verb starts with `mutare:ignore`, so the substring
  admits those too).

The warning stays **soft** (lenient like a bare-family typo, not a hard `SpecError`): an anchored
`# mutare:` comment could in principle be prose, and — unlike a `[family:label]` on a known family
— we cannot prove a mistake. The Jaro near-miss hint (`; did you mean # mutare:ignore?`) reuses the
label-suggestion threshold via the shared `closest/2`.

### Scoped suppression — `# mutare:ignore-file` and `-start`/`-end` regions `[done]`
The line directive doesn't scale to a large low-value span — a literal lookup table
(`def enc(?A), do: ?B` × 200) breeds several mutants per head and would need one trailing comment
per line; a generated module would need hundreds. `--exclude` covers only spans that happen to be
whole files the user is willing to split out. So two scoped verbs, both reusing the line
directive's `[filter]`/reason grammar verbatim (`Ignore.parse_rest/1` is shared): `ignore-file`
suppresses everywhere in the file from wherever it sits, and an `ignore-start`…`ignore-end` pair
suppresses a region. Decisions worth remembering:

- **Region bounds are inclusive of both delimiter comment lines.** A trailing
  `x = 1 # mutare:ignore-start` covers line 1's own mutants; likewise `-end`. The alternative
  (exclusive) makes the trailing form a no-op on its own line — surprising, and useless for the
  one-line-table-row case. Text after `ignore-end` is prose, never parsed: the filter and reason
  belong to the `-start` (an `-end` filter would suggest per-family region closing, which doesn't
  exist — regions don't nest, see below).
- **Pairing mistakes are hard `SpecError`s** (`:unmatched_end`, `:nested_region`,
  `:unterminated_region`), not soft ineffective warnings — the one place the ignore grammar is
  strict beyond known-family labels. The mistake is provable from the delimiters alone, and both
  lenient readings fail the wrong way: reading an unterminated `-start` as "to end of file"
  silently over-suppresses (the dangerous direction `parse_rest`'s malformed-filter handling
  already refuses); reading it as nothing silently runs mutants the user asked to skip.
  `ignore-file` is the sanctioned way to say "to end of file". Parsing itself never raises —
  errors ride the `Directives` container (`scope_errors`) and `Ignore.validate_scopes!/2` raises
  once a file name is in hand, on both transform paths (render, and count — where a zero-site
  file's directives are only ever seen; same reasoning as qualifier validation, one entry up).
  Nested `-start`s error but the open region still closes at its `-end` — the partial container
  stays sound for any reader that proceeds past the error.
- **Precedence: filter specificity first, then scope narrowness, then source order**
  (`directive_for`'s `{match_specificity, scope_rank, -source_order}`). Specificity-first means a
  file-wide `[integer:zero]` beats a line-level bare `ignore` *for that one mutant* — the
  qualified directive is the more informative reason to record; the mutant is suppressed either
  way (the ranking only ever picks among directives that all match). Scope rank (line 2 > region
  1 > file 0) breaks the common tie so the most locally-written reason wins.
- **The container split (`Directives{by_line, scoped}`)** keeps the per-site lookup a key fetch
  and makes scoped coverage an explicit `Directive.covers?/2` scan of the (few) scoped
  directives; `covers?` also answers the nil-line site case (`:file` yes, region no — the one
  scope that needs no line to decide). Ineffectiveness holds scoped directives to the same bar
  (`ignore-file` in a file with no matching mutants warns, `--strict-ignores` aborts), but the
  misplacement *hint* is line-only — a scoped directive can't miss by one line.

### Scan is transform-bound, and the loop heap makes it worse `[resolved; was deferred]`

> **OUTDATED as a current-state claim (deferred-work audit, 2026-06-30):** the
> timings in the next two paragraphs describe the old sequential/eager pipeline.
> The loop-heap penalty, lifting blowup, count-pass `Site` cost, and eager diff
> rendering were all addressed by the completed steps in this section. The
> current `Schema.from_files/4` uses two parallel, heap-isolated passes and lazy
> site-code hydration where reporters allow it.

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
  the parent, off the render's heap) — **`[superseded by the parallel pass below]`**:
  the old `safe_transform/5` ran the per-file `Transform.transform_string` inside a
  `Task.async`/`await`, so its transient ASTs die with the worker instead of inflating
  the loop heap. Exact `start_id` threading was preserved (each file awaited before the
  next), and the `try/rescue` for unparseable sources moved *inside* the worker so a bad
  file still skips rather than crashing the scan. **Measured ~24 s** on this repo's
  `lib/` at the time (down from ~180 s — the loop-heap penalty gone; the scan ≈ the
  isolated per-file sum). But the `Task.async`/`await` was *purely* for heap isolation
  — one worker at a time, awaited immediately — which is why it read as awkward and was
  the natural place to grow into the parallel pass.
- per-clause lifting — **`[done]`**: with the lifting blowup fixed (below) the big
  file's metamutant shrank ~4.6× (1.8 MB → ~0.4 MB), so its transform/render dropped
  from ~20 s to ~2.7 s and the **whole sequential scan to ~7.6 s** (~5.7k mutants).
- **parallel** across files, two-phase (`Task.async_stream`, schedulers_online) —
  **`[done]`**. The blocker — mutant ids are baked into each metamutant's selector
  clauses, so concurrent files can't thread `next_id` sequentially — is dissolved by
  decoupling id assignment from rendering, exactly the IR's existing plan/emit split.
  `Mutare.Schema.from_files/4` now runs two parallel passes (`Mutare.Schema`'s "Two-phase
  build"): **(1) count** — `Transform.count_string/2` per file (the same analyze → plan
  → emit pipeline, skipping the dominant final render), so each file's mutant count is
  known *without* an id range; **(2) render** — prefix-sum the counts to hand each sited
  file its `:start_id`, then `transform_string/2` each file concurrently. The count is
  drift-proof: it comes from the *same* id-claiming path (`SelectorEmit.claim_item/4`)
  emission uses, so `count_string` ≡ a render's `next_id - start_id`; `render_one/5`
  re-checks this and crashes loudly on any drift (cross-file id stability depends on it).
  Both passes keep heap isolation (a worker's transient ASTs die with it) and the
  let-it-crash contract (an unparseable source is a skipped file; any other exception is
  captured + re-raised faithfully in the parent — the surfaced-error contract the old
  single-worker had). The cost is that analyze+plan+emit runs twice for a sited file
  (count, then render) — so the count/render agreement *rests on that pipeline being
  deterministic for one source*: a nondeterministic custom mutator or extension
  `expand_use/3` surfaces as a `render_one/5` drift crash, never a silent id overlap (this
  is why caching only `use`-expansion across the two passes wouldn't help — a mutator can
  drift too, and the full pipeline output *is* the render the design splits off). But
  render is ~60–85 % of per-file cost (measured), happens once, and both passes
  parallelize. **Measured ~11 s vs the old sequential-throwaway's ~54 s** on this repo's
  now-larger `lib/` (136 files, ~16k mutants, 16 cores) — ~4.8×. `on_scan` fires once per
  file, in input order, with the running mutant tally, **streamed as each count finishes**
  (folded into `count_files/3`'s `Enum.map_reduce` over the lazy worker stream — not
  batched after the phase, which would freeze live progress for the whole count). The
  count pass is where mutants are discovered, so the tally is known there; the render pass
  shows the spinner. Scan concurrency is `System.schedulers_online/0`, independent of the
  runner's `:workers` (which bounds the per-mutant `mix test` OS processes, a different
  resource). `from_files/4` dedups its input by relative path first, so a file passed
  twice is rendered once under one id range rather than minting overlapping ids.

#### The count pass skips per-mutant `Site` construction — the count sink `[done]`
The two-phase build runs analyze→plan→emit *twice* per sited file (count, then render).
The count pass originally still built a full `Mutare.Site` per claim — `Site.in_place`/
`return_value`/… each render `original_code`/`mutated_code` through `Sourceror.to_string`,
the very per-node render that dominates a *whole* metamutant render — and retained the
growing `[%Site{}]`, none of which a count needs (it wants only "how many ids").

So the claim state carries a **sink**. `Mutare.Transform.ClaimState` (the id/site
accumulator, see the `Ctx` split below) has two: `:render` builds and retains a `Site` per
claim (the full transform); `:count` advances the id and bumps a tally only — no `Site`
built (no `Sourceror.to_string`), none retained. **Both still emit the live artifact**, so
the emitted tree (hence the *set* of downstream claims) is byte-identical — the count stays
drift-proof by construction, just without the site cost. `count_string/2` flips the sink and
reads `ClaimState.total/1`; `Schema.verify_count!` still re-checks count ≡ `next_id -
start_id` on the render, so a sink mismatch can't hide. The win is heap *and* CPU: the count
pass no longer holds a `Site` list or renders any diff text.

This rides on splitting the per-pass threading context `Ctx` by **responsibility** into
`Mutare.Transform.{Config,Scope,ClaimState}` — immutable config + generated-name hygiene;
the mutable lexical/emission scope + the per-module behaviour-enriched mutator cache; and
id/site accumulation + the sink. The old single struct conflated five roles behind a comment
claiming two. The composite `Ctx` still threads as **one** value (the "thread one struct"
discipline is intact — `update_scope/2`/`update_claim/2` keep the nested updates terse); the
split just gives the count sink a clean home and keeps each stage reading only what it owns.

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
affected clause + index; `LiftedEmit.lifted_mutant/6`/`lifted_original/5` assemble
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

#### Defer the per-mutant diff render to report time `[done]`
With the count pass freed of `Site` construction and the metamutant volume tamed, the next
driver measured was the **per-`Site` diff render**: every `Site` constructor renders
`original_code`/`mutated_code` through `Sourceror.to_string`, and the render pass does this for
*every* mutant. Instrumented in-process on this repo's `lib/` (155 files, ~18.7k mutants, shared
atomic counters so the split is load-independent), the render CPU broke down as: per-`Site`
**~29 s** (`original_code` ~15.7 s over 18.7k, `mutated_code` ~13.5 s over 17.3k) vs the
whole-metamutant render **~13.5 s** over 146 files. So **per-`Site` rendering was ~2.2× the
whole-tree render** — the single biggest build cost — and nearly all of it is waste: the default
human report only diffs **survivors** (a handful), and killed/no-coverage mutants (the 90 %+) are
never shown. (`Sourceror.to_string` is also ~32× slower than `Macro.to_string` on these small
nodes, but the diff text is patched back into the report by `Sourceror.patch_string`, so the
faithful renderer stays.)

**Fix: render the diff lazily, only for the sites a reporter actually shows.** `Site`'s
constructors take a `render?` flag (default `true`, threaded `Config.render_site_code →
ClaimState.claim → Delivery.site/4 → Site`); a `mix mutare` scan passes `false`, leaving
`original_code`/`mutated_code` `nil`. The flag gates **only** those two fields — ids, the
`*_form` tags, `variant` (read for `# mutare:ignore`), and the emitted tree are all unchanged, so
deferral is provably id/tree/count-neutral (the same property the count sink rests on). The report
re-derives a displayed site's code on demand: `Mutare.Runner.Hydrate` re-renders that one file
(`Transform.render_sites/2`, `Mutare.Schema.render_opts/3` for the matching `:start_id`), memoised
once per file, and fills the code in **before the result reaches the reporter** — so the live
`leave_behind` lines (`:survived`/`:timeout`/`:atom_exhausted`/`:harness_error`, the only streamed
statuses that show a diff) and the final/SARIF reports are byte-identical to eager. Because the
re-render is the same deterministic pipeline at the same `:start_id`, the recovered ids and code
match the schema's exactly (verified: hydration reproduces eager code byte-for-byte).

Measured: scan **31.0 s → 18.7 s (~1.66×)** on this 16-core box; the win is larger on a
core-starved CI box, where the ~29 s of per-`Site` CPU serialises instead of fanning out (the same
asymmetry the `no_ssa_opt_alias` note calls out — CI is where it matters).

Three load-bearing choices (mirroring the dep-seed's "never produce a wrong result" discipline):
- **Eager stays the default and the safety net.** `transform_string/2` and the test helpers keep
  `render?: true`, so the public API and the ~390 test assertions reading `Site` code are
  untouched. Only the Mix task opts in (`defer_site_code?`), and only when every active reporter
  needs code for **survivors alone** — *not* `--verbose` (a diff per mutant, streamed) and *not*
  `:json`/`:html` (every mutant's replacement); those render eagerly up front. The library
  `Mutare.run/2` path never defers (a custom `:reporter` hook may read any result's code), and the
  `--dry-run`/`--list-ignores` info commands stay eager (they `describe` every site).
- **Hydrate in the worker, not after the run.** The live reporter consumes a survivor's diff *as
  it streams*, so deferral can't wait for a post-run batch; `Hydrate.result/2` runs in the
  per-mutant task, on the result the collector then reports and keeps, so the final report needs
  no second pass. Killed/no-coverage results (no `leave_behind`) are never
  hydrated — that's the whole win.
- **A miss is a warned no-op, not a crash.** If the deterministic re-render ever failed to cover
  an id, `Hydrate` emits a `Logger.warning` naming the mutant (the tripwire for a broken
  determinism/`:start_id` invariant) and leaves the site's code `nil` — the reporter degrades to
  an empty diff — rather than raising in a reporting path after the whole run's work is done.
  Poisoned sites keep `nil` code (never displayed, never read).
- **The file's `:start_id` is recorded by the scan, not reconstructed from the sites.** The
  first cut derived it in `Hydrate` as `min(site.id)` over `schema.sites` — sound for a full
  run, wrong for a narrowed one: `:only_lines` (`--line`) and `:max_mutants` filter `:sites`
  *after* ids are assigned, so a `--line` on anything but a file's first mutant left a min that
  wasn't the range's origin. The re-render then started from the visible min and assigned that
  id to the file's *first* mutant, so every hydrated survivor showed an unrelated diff (a
  `--line` on arithmetic site 5 reported site 1's `optional_suffix` clause) — and the miss
  tripwire above stayed silent, because the offset ids were all present. `Schema` now records
  each sited file's prefix-sum origin under `:start_ids` at render time, and `render_opts/3`
  documents that as the only valid `:start_id`. A re-render is deterministic only *given* the
  right start; the start itself must come from the pass that assigned it.

Not pursued: retaining the mutated/original AST nodes on the `Site` to render lazily without a
re-render — rejected for the same reason `Site`'s moduledoc gives for not keeping trees at all
(an operator-swap node shares the source operands, so retaining ~18.7k of them pins large source
subtrees — substantial heap for a handful of eventual reads). Re-rendering the few survivor files
is cheaper than the heap.

#### The count pass is the scan's only parse — diagnostics read its facts, never a source `[done]`
An audit (2026-09-11) found every source Sourceror-parsed two to four times per scan, and the
same metamutant parsed twice per poison round (that half is under "Macro-expansion poison
fallback"). Per source:

  * count and render each parse — the designed two-phase build above. Measured on this repo's
    biggest `lib/` files the parse is 4–13 % of the count pass and 1–5 % of render, and handing
    the AST across the worker boundary would copy a multi-MB term through the parent twice and
    hold it live between phases: the loop-heap penalty this section exists to avoid. That one
    stays. (What *does* run twice is resolve→analyze→plan→emit; the metamutant text is now
    `start_id`-independent — "Stable per-file runtime identities" — so the count pass serves only
    `:max_mutants` and the drift check. Folding count into render for uncapped builds would save
    on the order of 15–30 % of scan wall-clock at the price of the drift tripwire; weighed,
    left for a deliberate decision.)
  * `Schema.detect_directive_diagnostics` re-parsed every file containing `mutare:` to find
    ineffective directives, unknown verbs, and the misplacement hint's expression span — though
    the count worker had already parsed the file *and built its `Directives`*, then discarded
    them because `count_report/2` didn't return them (`Ignore.directives_from_ast/1`'s comment
    claimed a reuse that held inside `Transform` and not across the system).
  * `mix mutare --check` re-parsed **and re-annotated** (re-expanding every `use`) each
    `use`-bearing source to read the `:mutare_use_degraded` stamps the count pass's `Resolve`
    had already put on its tree. The comment's "computed only for `--check` so a normal run pays
    nothing" had the cost inverted: collecting the stamps is one prewalk; the re-expansion was
    the expensive half.

The fix follows the side channel the count pass already had (`skip_lifting_matches` /
`route_matches` / `mark_matches`): **return small facts from the worker, never the AST.**
`Transform.count_report/2` now also returns the file's `Directives` container — which
`Ignore.directives_from_ast/1` fills completely in its one walk: `by_line`/`scoped`, the
unknown-verb comments (`unknown`), and for each line directive the last line of the expression
starting on its line (`end_lines`: one `Sourceror.get_range/1` prewalk, ~20 ms on a 1200-line
file, paid only by directive-bearing files, in both passes — cheaper than gating it) — and
`degraded_uses` (`Uses.degraded_uses/1`, read off the annotated tree under the count sink only).
`Schema` keeps the per-file map as the `facts` element of each `:counted` tuple *(since folded
into `%Schema.Counted{}`'s `CountReport`; see "Data shapes: one struct per produced thing")*;
`detect_directive_diagnostics/2` and `record_degraded_uses/2` are pure over it,
`Ignore.misplacement_hint/3` takes the container instead of an AST, and the Mix task's
`scan_degraded_uses` is gone (`Info.print_check/2` reads `schema.degraded_uses`). The transform's
comment-walk gate widened from `"mutare:ignore"` to `"mutare:"` so unknown verbs are seen too.

**Rule going forward:** a new scan-time diagnostic adds a field to `count_report/2`; nothing
parses a source after the scan.

### Sandbox isolation & dependencies `[M4, done; isolation question settled]`
`Mutare.Sandbox` copies the whole project (excluding `_build`/`.git`, keeping
`deps`) to a temp dir. Consequences:
- **Path deps outside the copied root don't resolve in the copy.** The old claim
  that *any* local path dep breaks is **OUTDATED** (deferred-work audit,
  2026-06-30): an in-tree sibling (notably an umbrella app) is copied and keeps
  resolving. A target using `{:mutare, path: ...}` to a directory outside the
  copy root still breaks in `/tmp`. That's why the examples are driven via
  `mix mutare examples/<name>` (positional root) rather than depending on Mutare.
  Hex deps are fine (they're under the copied `deps/`).
- We deliberately don't run `mix deps.get` in the sandbox. The old "fine for
  the common case, revisit" diagnostic gap is **OUTDATED** (2026-06-30): the one
  sandbox compile already performs Mix's authoritative dependency validation,
  and `Sandbox.Command.Output.dependency_issue/1` now classifies its result as
  fetch/compile/diverged/unavailable/invalid. `Runner` returns the distinct
  `:dependency_failed` **before poison recovery** (dropping mutants cannot repair
  dependency state), and `Sandbox.DependencyDiagnostic` names the original
  project root, recommends `MIX_ENV=test mix deps.get` / `deps.compile` / `deps`
  as appropriate, explains the external-path-dep case, and preserves Mix's raw
  diagnostic. Fetching stays a user action: it can use network credentials,
  modify `mix.lock`, and would otherwise write into a disposable sandbox.
- The design's open question — one shared copy + `_build` for every worker (as
  now) vs per-worker isolation (N source copies, or one copy with a per-worker
  `MIX_BUILD_PATH`) — is **settled: not worth it**. Measured 2026-08-27; see
  "Per-worker `MIX_BUILD_PATH` vs the shared sandbox build" below.

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

**Fix (`Sandbox.Seed.dep_build/2`):** after materialising the copy, copy each
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
- **`@mix_env` ("test") must track `Mutare.Sandbox.Command.Invocation`,** which sets
  `MIX_ENV=test` on every sandbox `mix`; we seed `_build/test/lib`. We never seed
  across envs (a `dev` artifact is not valid under a test compile).

Not pursued (measured/considered, net-negative or low-value): disabling protocol
consolidation (one compile saved vs every one of N per-mutant runs paying slower
dispatch), and suppressing the mutant-induced compile warnings (`Mutare.Poison`
scans that output to map errors → ids). The remaining compile long-pole is a single
huge metamutant *module* compiling serially (Elixir parallelises across modules, not
within one) — not easily splittable; the volume drivers are already tamed by
per-clause lifting, `PipeEmit.hoist` (see "lifting blowup"), and the hoisted per-site
active-id read (see "Hoist the per-site active-id read", now done).

### Seed the mutated app's `_build` too, so a narrowed run compiles incrementally `[done]`
The dep seed above leaves the cold-compile-the-whole-app cost in place. That's the
**first-run experience** when someone aims Mutare at a single module (`--only`/`--line`/`--since`,
or a `.mutare.exs` `paths:` narrowing) on a large legacy app: only that file becomes a
metamutant — every other source is copied **byte-for-byte** from a project they already
compiled — yet the one `mix compile` rebuilds the *entire* app from scratch. The thing they
did to be cautious is the thing that's slow.

Why the dep seed deliberately never extended to the app, and why it can now: mix decides
**app-source** staleness from its compile manifest (`_build/<env>/lib/<app>/.mix/compile.elixir`),
which records per-source paths *relative* to the project (already portable) **plus an
absolute project-root reference**. Transplanted to the sandbox (a different dir) that bare
root no longer matches, so mix decides the build isn't its own and recompiles the lot — the
asymmetry with deps, which mix gates as a *unit* on the lock and never re-runs per-source.
The bigger reason to be wary is the inverse: seed an app's *original* beam and it can
**silently win** over the freshly-written metamutant, turning mutation testing into a no-op
that reports everything killed. (Verified both: a `cp -rp`'d build recompiled cold until the
manifest's root was rewritten; and a relocated-manifest seed *without* deleting the
metamutant's beam served the stale original beam — the injected code never compiled in.)

**Fix (`Sandbox.Seed.app_build/4`, scoped runs only):** after the copy, seed the mutated
app's own `_build/<env>/lib/<app>`, then make both contracts hold:

  - **Relocate the manifest** (`relocate_manifests/3` → `rewrite_paths/3`): rewrite the
    recorded project root to the sandbox — the bare root *and* any root-prefixed absolute
    path, but only as a whole token or `/`-delimited prefix (so a sibling `path:` dep sharing
    a name prefix, `/p/app` vs `/p/app2`, is untouched). The walk depends only on the
    **public** term format (`binary_to_term`) and "paths are binaries", never on the
    manifest's private field layout (version tag 29 today), so a manifest-version bump can at
    worst cause a spurious recompile, never a wrong result. `File.write!` also restamps the
    manifest to "now" (≥ the just-copied sources), which is what makes the unchanged files
    non-stale and thus reused.
  - **Delete the metamutant's beam** (`delete_metamutant_beams/2`): the *structural* no-op
    guard. The relocate restamps the manifest to "now", so by mtime alone mix would think the
    metamutant fresh and serve the stale beam — but a module with **no beam** *must* recompile,
    from the only source available (the metamutant). The beam is identified by its recorded
    `compile_info[:source]` read via **`:beam_lib`** (public, stable) — authoritative about
    what mix actually compiled, unlike guessing module names (nested modules / `defimpl`s /
    dynamic names would miss one and reopen the no-op).

**Fail-safe by construction** (the property that made this worth doing): the seed is kept
**only if every** metamutant's beam was positively found and deleted (`MapSet.subset?`); any
shortfall — a beam whose source we couldn't match, or *any* exception — tears the seed back
down (`teardown/1`) and the run proceeds exactly as before, a cold compile. So a bug here can
only ever lose the speed-up, never produce a wrong score.

**Gated on the outcome, not the flag** (`worth_seeding?/2`): seed when the metamutant files
are a small enough fraction of the app's compiled modules (default ≤ ½, `@seed_app_build_max_fraction`),
read from `metamutants` vs a cheap **beam-name listing** (a directory read, not a `:beam_lib`
parse). This deliberately replaced an earlier per-flag `scoped?` (`--line`/`--since` only):
that proxy *missed* `--only` and a `.mutare.exs` `paths:` narrowing — both scope the run via
`:paths` (no `:only_*` field to check) — and couldn't see a full run that's *effectively*
scoped because most files have no mutation sites. `metamutants` already reflects **every**
narrowing, so reading it can't forget a mechanism; and the ratio also *declines* a nominally
"scoped" run that still touches most of the app, where the copy + scan would outweigh the
saving. Idempotent like the dep seed (only fills an app the sandbox lacks), so a
`keep_sandbox` re-run's preserved `_build` is untouched. Beams are **not** rewritten (their
embedded source paths don't gate staleness; leaving them means a failing test's stacktrace
points at the user's real source, a freebie). End-to-end on a 3-module scratch app, `--only`
(or `--line`) at one module: the sandbox `mix compile` recompiles only the metamutant file +
the generated coverage helper, reusing the rest — 1 file instead of N. Mutations that change a
module's *compile-time* surface (macros, module attributes other modules read) still cascade
to compile-time dependents; correct, and usually tiny since metamutants preserve the public
function signatures. `--no-seed-app-build` (`:seed_app_build` false) opts out wholesale —
forcing a cold compile — as a diagnostic A/B for the no-op surface or for a paranoid CI.
Surfaced under `--verbose` (`[done]`): `Seed.app_build/6` returns a `t:summary/0`
(`:seeded` with reused/recompiled beam counts, `:partial`, a `:fallback` to a cold
compile, or `:skipped`), which `Sandbox.prepare/3` hands back and `Runner.Compile` relays on
the `:on_phase` hook as `{:seed_app_build, summary}`; `Report.Live.Lines.seed_line/1` renders a `✓`/`↺` line for the
first three (a `:skipped` seed — the broad-run default — stays silent even in verbose), so
both the speed-up and the otherwise-silent fallback are visible.

Per-app teardown (`[done]`): the completeness check is now **per app**, not global — a
partial miss tears down only the app that owns the unmatched beam (`seed_one/6` +
`aggregate/1`), so in an umbrella one app's miss no longer sinks its cleanly-seeded
siblings (the earlier code's `teardown/1` wiped every app's seed). Each metamutant is
attributed to its owning app by **source-file location** (`expected_by_app/4`: the
`Mutare.Project` app whose `dir` is a path-prefix of the source; the lone app for a single
project), which drives *keep-vs-teardown* only — deletion still scans the **global**
metamutant set in every app, so no stale metamutant beam can survive a kept app even under
mis-attribution (worst case an over-conservative teardown, never a no-op). An
unattributable shape (a metamutant under no app dir, or no umbrella project yet >1 seedable
app) collapses to `:skipped` rather than risk an unreasoned no-op. A mix of kept + fallen-
back apps reports `:partial`.

### Tuning the app-build-seed fraction gate `[done]`
`worth_seeding?/2` declines the app seed once the mutated files exceed
`@seed_app_build_max_fraction` of the app's compiled modules — the guard against "copy +
beam scan costs more than it saves." The threshold started at **0.5**, a guess. Measured it
and raised it to **0.9**.

Measurement (synthetic 120-module app + Mutare's own 197 modules). The gate trades two
terms, both measured directly (the end-to-end compile wall was too noise-dominated on cheap
modules to read a crossover from):
- **Overhead** — copy `_build/<env>/lib/<app>` + `:beam_lib`-scan every beam (what
  `app_build` does besides compile): **~0.1 ms/beam** (≈15-20 ms total; copy ~2× the scan),
  and *per-beam* so scale-invariant.
- **Saving** — the cold-compile wall of each reused (unmutated) original: **~8 ms** (cheap
  synthetic) to **~11 ms** (real Mutare modules) per module.

So the crossover `f* = 1 − overhead_per_beam / compile_wall_per_module ≈ 1 − 0.1/8 ≈ 0.98`.
Overhead is negligible; seeding is a clear win for narrow runs (the motivating "aim at one
module" case) and, thanks to `--verbose` timings, measured at e.g. 0.6 s seeded vs ~5 s cold
on a one-file scope. The end-to-end sweep (seed on vs `--no-seed-app-build`) confirmed the
*direction* — win at low `f`, a wash (never a real loss) at high `f`, because there the
metamutant compile dominates the wall and the reused originals compile "for free" behind it
in parallel. **0.5 was far too conservative** — it cold-compiled the whole app for any run
touching >½ of it, forgoing reuse of the untouched remainder (still +80-200 ms on these apps
at f=0.9; more on apps with pricier modules).

Chose **0.9**, not removal: keeps ~all the benefit (typical *full* runs land at f≈0.85-0.95,
since data/behaviour/`ignore-file` modules have no sites), while leaving margin for the
degenerate near-`f=1` case on a **very large** app, where the O(N) copy — the one cost that
grows unbounded with module count, ~1 s at a few-thousand beams — can exceed the vanishing
reuse. Never a correctness lever (seeding is always correct; per-app teardown makes a miss
cheap): purely how often we pay a tiny overhead for a often-large win.

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
for the one `mix compile` (`Mutare.Sandbox.CompilerOptions.compiler_env/0` owns it,
scoped to that single compile). Measured, deps pre-seeded, Mutare-on-Mutare
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
`:persistent_term.get(:mutare_active, 0)` — `SelectorEmit.selector_case/3` always spliced
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
nodes for the frontend/SSA passes to chew, and the "per-site runtime tax" of the
per-line lookups collapsed to one per function activation), with **no
tradeoff** (unlike the `no_ssa_opt*` options that buy compile time with per-run
runtime).

**Fix.** `Ctx.active_bound` records whether `mutare_active` is bound in the current emit
scope; `SelectorEmit.subject/1` returns the bare variable `{var, [], nil}` when it
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
(`Ctx.module_depth`, bumped on `defmodule`/`defimpl`/`defprotocol`), and `SelectorEmit.subject/1`
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
the source uses, so it can never equal a user scrutinee's name. `PipeEmit.hoist` recognises
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

### Skip redundant per-mutant `mix test` startup work `[done]`
PHILOSOPHY says "boot is cheap, amortized by running only the covering tests" — but for a
*fast* suite that premise breaks down. Measured on the `auth` example (warm `_build`): ExUnit
runs the 6 tests in **0.07 s** while the whole `mix test` wall is **~1.0 s** — so **~93% of a
per-mutant run is BEAM + Mix boot**, paid once per mutant, and test selection (running only the
covering subset) makes that fraction *larger*, not smaller. Boot is the dominant per-mutant
cost, not metamutant execution (that side is already lean — see "Hoist the per-site active-id
read" / "Compiler options for the one metamutant compile").

The isolation-preserving lever (PHILOSOPHY forbids trading isolation for speed, so a shared/warm
BEAM is off the table): keep the fresh OS process, just make its boot do less. `Command.test_argv/1`
now appends `--no-compile --no-deps-check --no-archives-check` to **per-mutant** runs only. All
three are pure overhead under the one-compile invariant — the lib is built once and sources never
change between runs (`@boot_skip_flags` documents each). `--no-compile` skips mix's compile-staleness
`stat` scan (which grows with source count, so the win scales with project size); the dep/archive
checks are redundant work the one compile already did. Neutral on a tiny depless project like
`auth`; the payoff is on large / deps-heavy targets, multiplied by N mutants.

Two correctness anchors:
- **Per-mutant path only.** The one-time baseline (the authoritative green check) and coverage
  probe keep a plain `mix test` — the saving there is one-off and a full check is the conservative
  choice. Only the N-times kill-detection argv changes.
- **`:suite_compile_error` detection survives.** `--no-compile` skips the *lib* recompile (which
  can't fail per-mutant anyway — it's built once), but `.exs` **test scripts** are still evaluated
  at `mix test` time, so a mutation that breaks a test file at load time still trips the test-file
  compile banner `outcome/2` reads as a kill.

Implication for tests: `--no-compile` makes `Command.timed_test/4` strictly a *post-compile* tool
(exactly its production contract). The `Mutare.HarnessTest` first-block tests that drove it directly
were relying on `mix test`'s on-the-fly compile; they now compile up front via `Mutare.Test.Project.compile/1`,
mirroring production. A non-compiling-lib fixture therefore exercises the compile step's failure
*plus* the per-mutant path failing safe (no `.app` ⇒ `:harness_error`, never a kill) — the same
verdict by a different route, since in production a non-compiling lib is caught at the compile step
(poison recovery) and never reaches per-mutant runs.

### Bypassing Mix's build lock per mutant `[dead end]`
Follow-on to the boot-skip flags above, attempted and abandoned 2026-07-02 (`7657e85`)
The observation was real:
`Mix.Tasks.Compile.All` enters `Mix.Project.with_build_lock/2` *before* honoring
`--no-compile`, so concurrent per-mutant runs serialize around a no-op compiler
branch and can print "Waiting for lock on the build directory". The fix was
`MIX_OS_CONCURRENCY_LOCK=false` on the per-mutant path — and each safety layer it
then needed propped up the one above:

1. The env leaks to nested `mix` calls from the target suite (a suite testing Mix
   tooling would inherit a disabled real lock) → restore it from an injected
   snippet in `config/runtime.exs`, which Mix loads after the outer no-op compile
   but before app start.
2. Placing that snippet needs `:config_path`, and its timing is only correct when
   no `test` alias runs work before the inner `test` task → statically parse the
   target's `mix.exs` (`Sandbox.MixProject`, ~250 lines).
3. The static parse can't evaluate `aliases: aliases()` — the *most common*
   real-world `mix.exs` shape — so it classified it "unsafe", which suppressed the
   bypass **and** dropped the long-standing boot-skip flags: a net regression vs
   the status quo for typical targets. Edge-case whack-a-mole followed
   (absolute `:config_path`, umbrella children, lock-override scoping).
4. Removing the lock removed its *accidental* start staggering, exposing a
   boot-stampede risk on shared services → a `LaunchStagger` compensator.

Two reasons to abandon rather than polish:
- **No demonstrated win.** A micro-benchmark (three batches of eight warmed
  two-scheduler `mix test` runs of `ast_test.exs`) showed no speedup from the
  bypass. Don't over-read the run: it was taken on a contended host with plenty
  happening in parallel, so it is *inconclusive* as evidence the bypass is
  slower — but the burden of proof sat on the bypass, and it wasn't met. Under
  `--no-compile` the lock's critical section is near-free anyway, and its
  serialization doubles as an accidental boot-stampede limiter. The case that
  motivated the work (false serialization on large targets) was never measured.
- **The "Waiting for lock" noise is invisible anyway** — it lands in captured
  per-mutant output that only surfaces on failure.

If a large-target measurement ever shows the lock actually costing throughput:
**don't parse `mix.exs` — ask Mix.** One `MIX_ENV=test mix eval` probe per run,
in the sandbox during materialization, reads `Mix.Project.config()[:config_path]`
and `[:aliases][:test]` as ground truth (`mix eval` evaluates the project without
compiling or starting apps; umbrellas iterate `Mix.Project.apps_paths` +
`Mix.Project.in_project`). Trust is a non-issue — we already execute the target's
whole test suite. That replaces the fragile parser with ~30 lines and lets the
rest of the abandoned design (marker file, restore snippet, conditional argv)
stand as written.

### Per-worker `MIX_BUILD_PATH` vs the shared sandbox build `[measured; not pursued]`
The design's oldest open question (M4): the `:workers` concurrent per-mutant
`mix test` processes all run in the one sandbox against its one `_build`, and
contend on Mix's build lock at boot ("Waiting for lock on the build directory").
The proposed fix was per-worker isolation — N full source copies, or one copy
with a per-worker `MIX_BUILD_PATH` — "to be measured on a large target".
Measured 2026-08-27 on phoenix_live_view (34 deps): **the contention costs
≤ 1 % of a mutant run. Not worth any of it.**

What the lock guards on the per-mutant path: `Mix.Tasks.Compile.All` takes
`Mix.Project.with_build_lock/2` *before* honouring `--no-compile`, and `mix test`
reaches it twice per boot (`compile`, then `app.start`). The critical section is
the app-cache staleness check plus loading every dependency's `.app` file —
**59 ms** uncontended for 34 deps (`MIX_DEBUG=1`, `<- Ran mix compile.all`),
against a ~2.5 s boot-dominated run. The lock key is `Mix.Project.build_path/0`,
so a per-worker `MIX_BUILD_PATH` would sidestep it without disabling anything —
but each worker then needs a complete `_build/<env>` of its own (Mix loads every
dep from `<build_path>/lib/<dep>`), refreshed after every compile, poison-recovery
rebuilds included.

The measurement: 4 workers × 5 rounds of `mix test --no-compile --no-deps-check
--no-archives-check` on a 3-test file (boot-dominated — the *worst* case for lock
cost), shared `_build` vs per-worker `MIX_BUILD_PATH` copies, interleaved twice,
with per-run attribution from `MIX_DEBUG=1` task timings:

- shared: 5–11 of 20 boots printed "Waiting for lock"; `compile.all` (both calls,
  wait included) mean 135–138 ms, max 280 ms, of a 2.9–3.1 s run.
- per-worker paths: no waits by construction; `compile.all` mean 105–131 ms,
  max 275 ms, of a 2.9–3.0 s run.

So the whole lock phase is ~4–5 % of a run, and the *contention* share of it —
the only part isolation could recover — is 0–33 ms per run, ≤ 1 %, inside the
noise. Wall-clock throughput differences were inside the noise too (the host was
heavily loaded by unrelated work throughout, load 40–90 on 16 cores — which is
why the per-run attribution is the load-bearing number, not the totals). Cost is
not the objection — a `_build/test` copy is 13 MB / 805 files here, 67 ms with
`cp -a`, 38 ms hard-linked — there is simply nothing to buy. The critical section
grows with dependency count, but so does such an app's boot (Ecto, Repo,
endpoint); the ratio holds. And the worker pathology this question was filed
against (false `:timeout`s, OOM `:sigkilled`s at 16 workers — "Parallel workers",
"Timeouts") was CPU oversubscription, not the lock, closed by the worker clamp
and `:confirm_timeouts`.

Why not build it anyway, for hygiene: `MIX_BUILD_PATH` leaks into nested `mix`
calls from the suite exactly as `MIX_OS_CONCURRENCY_LOCK=false` did (the
`[dead end]` above) — and worse, since it is a hard override "including the
environment": a suite that runs `mix` in a generated project (installer-style
tests) would have that child's build redirected into our lane's `_build`. The
same restore-from-config machinery the dead end drowned in would be needed, and
the lock's accidental boot stagger (the dead end had to add a `LaunchStagger` to
replace it) would go too. If a future target ever shows a real lock cost, the
lane identity already exists — `Mutare.Runner.Partitions` checks one token out
per concurrent run — so a per-lane build path is that token mapped to
`<sandbox>/_build/<env>_w<n>`, seeded from the master build after every compile
(`Runner.Compile`, poison loop included) and appended to the slot env as
`MIX_BUILD_PATH`; deps could be symlinked and only the mutated app's dir copied,
since a `--no-compile` run writes nothing beyond ExUnit's failures manifest (the
app cache is fresh after the one compile).

### Early stop: survivor cap and time budget `[done]`
`--max-survivors N` is for the iterate-and-fix loop: surface a handful of concrete test gaps, not a
full score. `--time-budget "10m"` (added later) is the sibling for a fixed wall-clock window: "see
what I can get in ten minutes." Both are *run-loop* early stops sharing one mechanism — every mutant
is still compiled in (only `--max-mutants`, a `Mutare.Schema` site cap, reduces *what is built*); the
**run** halts once its condition trips, whichever fires first. `collect_until_stop/4` ORs the two
conditions into the one drain trigger. Several decisions make it well-behaved:

- **Stop at the Nth survivor in *source order*, not the Nth-to-finish.** The per-mutant stream is
  consumed `ordered: true`, so the cap triggers on the Nth survivor by position — deterministic
  regardless of which worker finished first, and the reported set is exactly the first N. An
  early-stop run is then a clean *prefix* of a full run, which is why `finalize_run` skips the
  harness-error abort guard and the Mix task skips the `--min-score` gate (a partial prefix is not a
  verdict).

- **Drain in-flight runs on stop, don't kill them.** The obvious implementation — `Enum.reduce_while`
  halting the `Task.async_stream` — shuts the stream's in-flight tasks down, killing their `mix test`
  OS subprocesses mid-write. Those dying processes then race the sandbox/project teardown
  (`cleanup_sandbox`, and a test's `on_exit File.rm_rf`): an intermittent `File.rm_rf` `:eexist` that
  surfaces only under concurrent load (it passes serially and in isolation). Fix: an `:atomics`
  `capped` flag the collector sets when the cap is reached, making any task that *starts after* it
  skip its real run (returning `:capped`). The collector then **drains** the rest of the stream
  rather than halting — the already-in-flight stragglers (≤ one per worker, the same handful that ran
  before) finish cleanly and are discarded; every later site is a trivial skip. So no extra mutant is
  actually run, and no live subprocess outlives the run to race teardown. See
  `Mutare.Runner.Stream.collect_until_stop/4`.

- **Report from the collector, not the worker.** Calling `:reporter` in the `Task.async_stream` task
  that produced the result (as the loop originally did) leaked exactly those drained stragglers: a
  discarded result had already reached the reporter, so live/`--verbose` stderr showed KILLED /
  SURVIVED lines for mutants absent from `run.results`. It is not a race a post-run `capped` check in
  the worker could close, either — an ordered stream *buffers* the results that finished ahead of the
  trigger, and those are reported long before the collector reaches the trigger at all. So
  `collect_until_stop/4` reports each result as it **accepts** it. Two things fall out: the live line
  order becomes deterministic (source order — the order the final report prints, no longer "whichever
  worker finished first"), and a custom `:reporter` hook gets one calling process instead of
  `:workers` of them. `:on_start` still fires from every worker, so the live reporter stays a
  `GenServer`. The cost is bounded and lands where it doesn't show: the counter advances in ordered
  batches (≤ one per lane) rather than on each completion, while the spinner and the in-flight mutant
  line — both driven by `:on_start` — keep moving.

- **The budget clock is read per-landing, not on a timer.** `collect_until_stop/4` checks the
  deadline in the same reduce that receives each result. That looks like it could miss the deadline
  while all workers are mid-run — but under `Task.async_stream` a result landing is *exactly* when a
  worker slot frees and the next mutant would launch, so the check gates launches at precisely the
  moments that matter; nothing launches *between* landings, so an out-of-band `send_after` + atomics
  timer would gain nothing (and we drain rather than preempt in-flight runs anyway). The one
  consequence is that the stop lands up to one in-flight mutant's runtime past the budget — the same
  bounded overrun the survivor path already has.

- **The budget is a duration *string*, stored un-canonicalized; parsed to ms at use.** `--time-budget`
  takes `"10m"`/`"90s"`/`"1h30m"` (`Mutare.Duration`), never a bare number — `600` gives no unit and
  we won't guess seconds vs milliseconds. It is tempting to canonicalize to integer ms in the
  `Options` validator, but that reopens the bare-number footgun: `Options.new(%Options{})`
  re-validates the *stored* value, so accepting an integer for idempotency would also silently accept
  `time_budget: 600` from `.mutare.exs`. Keeping the string as the canonical form makes re-validation
  trivially idempotent and the rejection unconditional; the runner parses it once, when the phase
  begins. The clock therefore starts at the *mutant phase*, not process start — compile/baseline/probe
  are not charged against it (they have their own caps), so the budget means "time spent running
  mutants."

### Umbrella support `[M5, done; was in progress]`
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
running every app. The dependency graph is the **declared** inter-app graph, read
by asking Mix (`Mutare.Runner.AppGraph`: one `mix eval` printing
`Mix.Project.deps_tree/0`); it was first read off the compiled `.app` files'
`applications` lists, which under-report — see "Umbrella narrowing must follow the
declared graph" below. An unreadable graph degrades to no narrowing (whole
umbrella). A killer must execute the mutant's code, and a sibling only reaches it
through a declared dep, so owning-app + dependents is a safe superset — we never
narrow below it. Attributed coverage selections (step 3) are left untouched.

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

### Umbrella narrowing must follow the declared graph, not the `.app` files `[done]`
Step (4) of umbrella support first read the inter-app graph off each compiled
`.app`'s `applications` list, reasoning that Mix derives it from the deps and so
it can't under-report a sibling edge the way parsing `mix.exs` could. It can:
`Mix.Tasks.Compile.App` builds `applications` from the **runtime** deps only —
`runtime: false` is dropped, as are `app: false` and any dep whose
`only:`/`targets:` misses the env — while `Mix.Tasks.Compile.All.project_apps/1`
puts **all** declared deps on the code path ("include all deps by design"). So
with `{:core, in_umbrella: true, runtime: false}` in web, `web.app` shows no edge
to core, yet `WebTest` calls `Core.double/1` fine — and a broad run of a core
mutant (`:run_all`, `:full`, an unlabeled-coverage id) narrowed to core's own
suite alone: a false survivor. (Verified on Elixir 1.19.5; `Mutare.UmbrellaTest`
pins the case.)

The graph is now the **declared** one, read from Mix itself: `Mutare.Runner.AppGraph`
runs one `mix eval --no-compile --no-deps-check` in the sandbox that merges
`Mix.Project.deps_tree/0` from the umbrella root with sibling names in every
child's `application/0` (`:applications` and `:extra_applications`). Both callbacks
are evaluated under `MIX_ENV=test`, so `runtime:` is ignored, `only:` applies
exactly as the test run applies it, and application-only sibling relationships
that the compiled `.app` records are not lost. The output is sentinel lines
(`mutare-dep <app> <deps…>`, then `mutare-dep-end`) matched by *name* against the
discovered apps (never `String.to_atom/1` on subprocess output); a missing app or
end marker is `:error` → no narrowing, since a missing node would silently hide
its dependents. Cost: one Mix boot (~2s on a small umbrella), paid only when the
selection actually holds a broad run (`CoverageProbe.broad_runs?/1`) — under
`:tests`/`:coverage` with full attribution it never runs.

Discarded: parsing `apps/*/mix.exs` statically (a computed `deps/0` is invisible —
the same reason we never rewrite one, see the `mutare_support` note above);
`_build/…/.mix/compile.app_cache` (it *does* hold the apps loaded at compile
time, `runtime: false` included, but it is a versioned internal manifest);
dumping `Mix.Project.config()[:deps]` from the injected `test_helper.exs`
bootstrap (free, but an app with no tests never runs its helper, so an
intermediate node could go missing, and it would couple the graph to the
bootstrap contract).

Two Mix mechanics verified along the way, both load-bearing for the narrowing:
- From the umbrella root, `mix test` leaves **every** sibling's `ebin` on the
  code path, so a test can call a sibling with **no** declared dep at all (an
  undeclared cross-app call passes). Owning-app + declared dependents is a
  superset only for projects that declare the deps they use — the convention
  `mix xref` and releases rest on too — not a Mix-enforced boundary.
- A narrowed run may name an app's `test/` dir that holds no test files (only a
  `test_helper.exs`, or a dependent without tests). Under umbrella recursion Mix
  reports "Paths given to mix test did not match any directory/file" as an *info*
  line and exits 0 (`raise_or_error_at_exit` checks `Mix.Task.recursing?/0`), so
  it cannot manufacture a false kill; only a non-recursing single-app run treats
  it as an error, and that path never receives dir args (a single project's
  broad run is the bare whole suite).

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
`Runner.prepare_compiling/3` recurses to recover from compile-poisoning: drop the
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
cold every time. `--keep-sandbox` (`Options.keep_sandbox`; default `false` when
this landed, flipped to `true` — see the next entry) makes
the sandbox *survive* between runs so mix's incremental compiler does almost
nothing on a re-run. The precondition is already true: the metamutant is
deterministic for identical input (stable mutant ids), so an unchanged source
file produces a byte-identical metamutant.

`prepare/3` branches on the flag:
- `claim!/2` skips `reset!` on an owned dir (keeps `_build`/`deps`/sources).
- `default_sandbox/2` returns a **stable** per-project temp dir (a SHA-256 of the
  expanded root) instead of a random one, so `mix mutare --keep-sandbox` alone
  reuses the same path. CI usually pins `--sandbox <cache>` instead.
- `sync/3` re-materialises in place: `put_sandbox_file_if_changed/3` rewrites a
  file **only when its bytes differ** (size-check, then compare), so an unchanged file keeps
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
- The mirror copies each source's **shape**, not just its bytes: permission modes
  (a suite may invoke a project script or native helper, which needs its
  executable bit) and symlinks (recreated with the same raw target, never
  followed, so a link out of the tree is copied rather than chased). Fresh mode
  gets both free from `File.cp_r!`, so a content-only sync was a silent
  behavioural fork between the two modes — an executable arriving `0644`, a
  symlink simply absent. Two sharp edges it has to dodge:
  - `File.chmod/2` is `write_file_info` with only the mode filled in, which
    resets **mtime to now** (verified). A blind chmod pass would therefore hand
    mix a changed file on every sync and undo the byte-aware mirror it sits next
    to, so the mode is re-applied only when it actually differs, and the mtime
    restored afterwards.
  - Generated overrides are overlaid **after** the mirror, so a path Mutare owns
    always replaces a copied link (or a copied symlinked parent dir) instead of
    being written *through* it into the real project — the same guarantee
    `put_sandbox_file_if_changed/3` gives fresh mode, which needs the ordering
    because the mirror now recreates those links in the first place.

CI pattern: `--sandbox <cache-dir> --keep-sandbox`, and cache `<cache-dir>/_build`
and `<cache-dir>/deps` keyed on `mix.lock`. tar-based caches (e.g. GitHub
`actions/cache`) preserve mtimes, which is what makes the cross-run incremental
compile work. Still out of scope: `mix deps.get` in the sandbox (unchanged). (The
`MIX_BUILD_PATH` worker-isolation question is settled — not pursued; see
"Per-worker `MIX_BUILD_PATH` vs the shared sandbox build" above.)

### The kept sandbox is the default `[done]`
`keep_sandbox` shipped as `false`, framed as a CI cache ("pair with a stable
`:sandbox`"). That framing pointed it at the audience for whom the default matters
least: CI configs spell their flags out, and a fresh checkout has nothing to reuse
anyway. The default only bites the *interactive* loop — run, read survivors, write a
test, rerun — which is the workflow the tool exists for, and the one where the kept
sandbox pays best: editing `test/` leaves the metamutant byte-identical, so the one
`mix compile` does nothing. Fresh mode threw that away on every run, and in practice
the flag was passed every time and its omission regretted. "Compile once" was coined
against per-mutant recompilation; extending it from once-per-run to
once-per-source-change is the same bet, and the machinery (`sync/3`, the byte-aware
mirror, `prune/2`, the stable digest path, the live-owner `Lock`) already existed and
was tested. So the default is now `true`; `--no-keep-sandbox` is the opt-out.

What changes for a default run, and what was weighed:
- **Space.** One project copy plus its `_build` per project root ever mutated, at
  `System.tmp_dir!()/mutare_sandbox_<digest>`. On tmpfs `/tmp` (Fedora et al.) that
  is RAM; a reboot clears it, which doubles as the sweeper. macOS ages `$TMPDIR`;
  persistent-`/tmp` distros age it via tmpfiles. Bounded in practice, so no sweeper
  was written (the "No sweeper for leaked sandboxes" item above still applies to
  fresh-mode leftovers only).
- **Persisted corruption.** Fresh mode's wipe was a free reset; a kept sandbox
  carries a bad `_build` forward (the PropCheck DETS incident is the archetype:
  every later run fails with undifferentiated harness errors). So the two aborts
  that this looks like — `:too_many_harness_errors` and `:baseline_failed` — now
  name `--no-keep-sandbox` as the cold-rebuild escape hatch.
- **Concurrent runs on one project.** Fresh mode gave each its own pid-salted dir;
  kept mode shares the digest path, and `Lock.acquire/1` refuses the second live
  owner rather than letting them race. Two terminals on one project is now a
  refusal, not two runs — acceptable (they would each pay the compile anyway).
- **Dep bumps.** `Seed.dep_build/2` only fills deps the sandbox lacks, so after an
  upgrade mix recompiles that dep cold in the sandbox instead of seeding the
  already-built new version. Correct, slower for that one run; could reseed on a
  manifest mismatch if it ever matters.
- **How incremental is a `lib/` edit?** Ids are a prefix-sum across files in
  discovery order, so a new mutant in file *k* shifts the ids in every later file
  and those metamutants get rewritten and recompiled. Kept mode is still never
  slower than fresh (which recompiled everything), but "only what changed" is exact
  only for test-side edits.
- **`--sandbox <path>` alone** now reuses in place too (it used to wipe-and-recopy);
  fresh-at-a-pinned-path is `--sandbox <path> --no-keep-sandbox`. `Ownership`'s
  decision table needed no change — only the flag's default moved.
- **Tests.** The suite's fixtures pass `sandbox:` (a scratch dir the fixture
  removes), so nothing leaks into `/tmp`; the tests that exercise fresh-mode
  semantics (wipe on reuse, pid-salted path, cleanup on completion) say
  `keep_sandbox: false` explicitly.

**Empty directories (0.1.2).** The flip changed which materialiser a first run uses: the
throwaway path bulk-copies with `File.cp_r!`, which copies an empty directory; the kept
path `sync`s, which mirrored files and symlinks and treated directories as "implied by the
files under them" — so an empty directory was never created, and pruning ("any directory
left empty") would remove one anyway. Nothing in an ordinary Elixir project has an empty
directory, which is why the mirror was written that way and why nothing caught it — but a
shallow git checkout under `deps/` (`depth: 1`, as Phoenix 1.8 generates for `heroicons`
and `daisyui`) keeps `.git/refs/heads` and `.git/refs/tags` empty (packed-refs holds the
refs), and git does not recognise a repository without a `refs/` tree. The sandbox's git
deps then read as "lock mismatch" and the run died before the one compile. The v0.1.0
release smoke test found it. `walk/2` now emits an empty directory as its own `:directory`
entry, `mirror_source` creates it, and `prune_path` leaves a managed empty directory alone.
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
- **Guards:** function-clause guards are mutated via lifting (M2), since a `case`
  can't live in a guard. The analyzer
  returns the whole `when` untouched for *in-place*; this is position-independent,
  so a bare selector is never spliced into a guard. The former claim that
  `case`/`fn` clause guards are skipped is **OUTDATED** (deferred-work audit,
  2026-06-30): `case` guards now use `Candidate.CaseClause`, while `receive`/`fn`
  guards use the whole-construct `Candidate.CasePattern` path. (A function clause
  *head's* literals are not mutated in place either, but they **are** mutated by
  lifting — see "Head-pattern literals are lifted" below.)
- **Module-attribute expressions** (`@x 1 + 2`): **excluded** (context
  `:compile_time`). Such a value is frozen at compile time — `persistent_term`
  reads the default → original — so a selector there could never activate (an
  inert/equivalent mutant). The analyzer prunes the whole `@<name> <value>`
  definition. (A bare attribute *read*, `@x`, has no value list and is not
  skipped.) Pinned by a transform_test.
- **Macro bodies** (`defmacro`/`defmacrop`): **excluded** (also `:compile_time`).
  A macro body runs at expansion time, before `MUTARE_ACTIVE_MUTANT` is set at test
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
- **`quote` blocks**: **quoted data excluded; escaping runtime unquotes reached**.
  A `quote` *constructs
  AST* — its literals become part of the code the quote generates, which is out of
  scope (PHILOSOPHY: "macro-generated code is a different tool"), exactly like a
  `defmacro` body. And it is a *silent* poison if mutated: a selector `case`
  spliced into a quoted pattern/guard (e.g. `quote do: (case x do "" -> … end)`,
  as in `Selector.bootstrap_ast`) is valid *as a quote* — the metamutant compiles
  — but illegal where the AST is later expanded/`Code.eval_quoted`'d, so the
  pre-filter never sees it and it surfaces as a baseline failure. The analyzer
  therefore keeps quoted data raw. **Now done** (was deferred): in a runtime
  `quote`, an escaping `unquote(expr)` / `unquote_splicing(expr)` argument is a
  runtime sub-position (it runs when the quote is built), so it is routed back to
  `:runtime`, like the `\\` default. The walk is quote-level-aware: a single
  `unquote` inside an inner `quote` only escapes that inner quote and stays data
  to the outer one; even stacked unquotes under that inner quote remain quoted data
  from the surrounding runtime quote's perspective. `quote unquote: false`
  disables this escape and is left raw; `bind_quoted:`'s implicit unquote
  disabling is treated the same unless `unquote: true` is explicit. Quote option
  values themselves, such as the `bind_quoted:` value list, remain outside this
  reach.
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
  literals are lifted" below.) The former claim that every `=` LHS and
  `case`/`fn`/… clause pattern stays unmutated is **OUTDATED** (deferred-work audit,
  2026-06-30): value-discarded `=` patterns and `case`/`receive`/`fn` clause patterns
  now have dedicated delivery paths. The narrower exclusions are recorded under
  *Pattern-structure mutators* and *Clause-pattern mutation* below.
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
  now a **known macro** (`Mutare.MacroRouting.Registry`): arg 1 `:pattern`, arg 2 `:expression`.
  This generalises the old hard-coded clause (which matched the bare name only,
  leaving a qualified `Kernel.match?/2` to poison fallback): the registry resolves
  the call's module through the existing alias/import/displacement machinery, so
  the bare **and** qualified/aliased forms are both routed, and only when the call
  is genuinely `Kernel.match?` (a local `def match?/2` shadowing it is a compile
  error, so a compiling bare `match?` is unambiguous — the same soundness `Imports`
  rests on). See "Known-macro registry" below. Found running Mutare against `plug`
  — see "Real-world poisons (plug/router)" below.

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
can't decide it. But the *policy* belongs to the mutator: a context-free atom replacement
usually makes an ignored unknown option, while `ModeSwap` changes a known key to another
legal key and must keep firing. The candidate therefore carries its `Mutare.Mutator.Spec`,
and the transform asks the producing module's optional `mutate_call_option_keys?/1`
callback, passing `spec.opts`. `AtomLiteral` and `ConventionAtom` implement it; a module
without the callback is unaffected even if its opts happen to contain a
`call_option_keys` key. No Options field, CLI flag, or `Ctx`/`Schema` plumbing.

  * **Detect + tag in `Analyze`** (it alone knows the call context): `recurse_runtime/2`
    post-processes its result with `CallOptions.mark/1`, which — when the node is a
    real call (`call_form?/1`: a remote `{:., …}` or an atom form not in `@non_call_forms`,
    so a `%{}` map / `{}` tuple ending in a keyword-shaped list isn't mistaken for one) and
    its last arg is keyword-list-shaped — stamps each *key* candidate `call_option_key?: true`
    (a `Candidate.InPlace` field). Shallow: a nested map/list inside an option *value* keeps
    its own keys. Piped calls (`x |> foo(opt: 1)`) go through `recurse_runtime` too.
  * **Gate in `Transform`**: `emit`'s `gate_candidates/1` drops a `call_option_key?: true`
    candidate when its producing mutator's `mutate_call_option_keys?/1` callback returns false
    — *before* `SelectorEmit.claim_items/4`, so it consumes no id and records no site
    (unlike a poisoned id, which is recorded). Ids stay **contiguous** and stable: the mutator
    list (hence each spec's opts) is constant within a run, so poison rebuilds reproduce the
    same id sequence.
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
  except: [+: 2]` + a custom `+`) — Arithmetic/Relational/Logical don't read the stamp.
  Imports introduced by macro expansion that the `Uses` pre-pass cannot expand remain invisible.
  The old blanket claim that **`use`-injected imports are invisible is OUTDATED**
  (deferred-work audit, 2026-06-30): `Mutare.Transform.Uses` surfaces directives from
  successfully expanded `use`s, with `Mutare.UseExpansion` as the explicit override.
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
  even for guard macro_routes: the original source was already a call, so a call is guaranteed legal
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
extensible **registry** (`Mutare.MacroRouting.Registry` + `Mutare.Macro.Spec`): a spec declares, per argument,
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
  a declarative `:macro_routes` option, and an optional **`macro_routes/0` callback on `Mutare.Mutator`**.
  The last is the extensibility win: a library ships *one* module carrying both its custom
  mutator and the macro routing it relies on, and the user adds a single `:mutators` entry —
  Mutare core never knows about the library. The motivating case is Ecto: register
  `{Ecto.Query, :from, :any, :skip}` so core leaves the query DSL alone, while the same module's
  `mutate/1` rewrites the query (drop a `where`, flip `:asc`/`:desc`). `:skip` is also the
  mechanism behind "owned only by a custom mutator": core skips the args, but the **whole macro
  node is still offered to every mutator**, so the registering mutator fires on it.
- **Reflection-free config resolution.** `Mutare.MacroRouting.Registry.resolve/1` (and the `:macro_routes` validator
  in `Options`) never reflect on the module — module keys are purely syntactic (`Module.split`
  via `Macro.classify_atom` to tell an Elixir alias from an Erlang atom) — so a
  `{Ecto.Query, …}` entry validates even when `Ecto` is not a dependency of the Mutare process.
  Resolution at the *call site* still reflects (via `Imports`), where the target app's deps are
  loadable.

**Pipe-aware** (the query-builder shape `q |> where([p], p.x == 1) |> order_by(...)`, where each
stage is a piped macro and the piped value is effective arg 0). `Resolve.MacroStamp.stamp/7` matches on
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
`:macro_routes` registration. The fix: when reflection can't resolve the call, consult the **registry**
directly — among the *whole*-imported modules in scope, find one registering `fun/arity` as a known
macro. Sound by the same compile-unambiguity rule `Imports` rests on: the user's `:macro_routes` entry
asserts the module provides the macro, and a whole import of it makes the bare call unambiguously
its macro. Scoped to whole imports because a selective `import Mod, only: [m: 1]` resolves straight
from the source (no reflection), so it never reaches the fallback. This does **not** lift the
inherited `Imports` limit for *un*registered bare calls (the ordinary stdlib *function* families
still need reflection — but those modules are always loadable, and a real `mix mutare` run has the
target's deps loaded anyway). A known macro in a `:scaffold`/compile-time position isn't routed
(it's already non-mutating there, so `:skip` would be a no-op anyway). `test/support/macro_mutator.ex`
is the worked `macro_routes/0` example (with a piped `where/2` stage).

**Rebuilding a renamed/re-aritied bare macro must qualify when the import isn't proven sole**
(`Calls.macro_rebuild/5`). `resolved_macro_call/1` hands a `:routing`/`:hosted` mutator a `rebuild`
closure to re-emit a swap in the written form. For a *bare* macro the safety of leaving a **renamed**
(or re-aritied) sibling bare hinges on the import shape, and the three sources diverge: a `:bare`
import stamp is the `rebuild_kind`-guaranteed **sole whole import** with an unmanipulated `Kernel`, so
the sibling is unambiguously bare-callable (stay bare); a `:qualify` stamp already requalifies. But a
**`nil` import stamp** has *two* origins that look identical and are **both unsafe** to leave bare on a
rename: a `Kernel` macro (`match?`, auto-imported — the renamed sibling might be displaced by
`import Kernel, except: [destructure: 2]`, so a bare `destructure` is a compile error) and the
**registry-fallback** whole import above (Mutare never proved it the *sole* import, so an overlapping
provider could shadow a bare sibling). Neither carries the sole-whole-import guarantee `:bare` rests
on, so the old `_`-fallback's unconditional bare emit was a latent poison. The fix threads the resolved
**identity** module (the `@macro_call_key` stamp `resolved_macro_call/1` already reads) into the
rebuild and requalifies a renamed/re-aritied sibling with the alias-proof `Elixir.`-prefixed module —
the same `Calls.qualifier/1` the `:qualify` path uses (see "Absolute `Elixir.`-led aliases"). A
**value-only** swap (same name *and* arity) still stays bare in every case (it resolves as the
compiling original did), and a `nil` *identity* module (a name-only `{:*, name}` match never pinned to
a module) has nothing to qualify against, so it stays bare too — the name-only hatch's inherent limit.

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
user opts their own macro in via `:macro_routes` / `macro_routes/0` (e.g. `{MyDsl, :unpack, 2, [:binding_pattern,
:expression]}`). The treatment routes identically to `:pattern` for the in-place descent (still safe
everywhere); the *extra* structural mutants are delivered by the **`MacroPattern`** candidate — the
`MatchPattern` tuple re-export generalized from a `=` to running the macro itself inside each selector
branch (`{x, y} = case <sel> do <id> -> destructure(<mut>, v); {x, y} … end`). The shared discovery
(`pattern_export_context/1`: `PatternStructure.bound_var_names/1`, per-occurrence export tuple, forced-thin wildcard) is
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
custom mutator (`macro_routes/0`) can mutate the whole call — the Ecto-style use, where the library
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
avoid. The asymmetry is deliberate: the macro node is offered *on purpose* (the `macro_routes/0` feature),
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
injected aliases in scope. **Status: partial `__CALLER__` mirroring.** `:module`, `:requires`,
`:aliases`, implicit nested-module aliases, and the sandbox `Mix.env()` are mirrored; the remaining
fields (`__CALLER__.functions/macros/context_modules`) are still out of scope until a concrete
library needs them. Tested in `uses_test.exs` via `Mutare.Test.AliasAwareUsing` (a `__using__` that
picks its import off `__CALLER__.aliases`).

**Mirror the implicit alias a nested `defmodule`/`defprotocol` introduces.** Elixir auto-aliases a
nested module's name when a body *defines* it: inside `Outer`, `defprotocol P` introduces `alias P =>
Outer.P`, so a later sibling resolves the short name. The walk's alias env recorded only explicit
`alias`/`require …, as:`, so two faithfulness bugs followed when a later `use`/`defimpl` referred to a
sibling by short name: `defmodule Outer do defprotocol P …; defimpl P, for: Integer do use X end end`
computed the caller as `P.Integer` instead of **`Outer.P.Integer`** (so a `__using__` deriving
imports from `__CALLER__.module` harvested for the wrong module), and `defmodule U …; use U` left the
`use` **unstamped** (`U` resolved to the unloadable top-level `U`, not `Outer.U`). Fix:
`Mutare.Transform.ModuleScope`'s `register_defined_module/3` folds the implicit alias into the env for
following siblings (via `register_lexical/3`, the unified source-alias + implicit-alias fold used by
both the module-body walk and the top-level block). (The vocabulary was later extracted into that
shared `ModuleScope` and applied to `Resolve`/`Behaviours` too — see *Implicit nested-module alias*.) Subtlety verified against the compiler: the alias binds the **first**
written segment to the parent-prefixed first segment — `defmodule Foo.Bar` ⇒ `Foo => Outer.Foo`, *not*
`Bar => Outer.Foo.Bar` — so it is computed as `child_module/3` of just that first segment, stored as a
path so `resolve_path/2` extends it. Lexical (scopes only to following siblings, like an explicit
alias), and skipped for a dynamic/`Elixir.`-absolute/atom-named head. `defimpl` defines `P.T` but
introduces no short alias, so only `defmodule`/`defprotocol` are definers. Tested in `uses_test.exs`
(the `defimpl`-caller and short-name-`use` cases, plus the lexical-scope guard).

That implicit alias is in scope for **following siblings** *and inside the module's own body* — the
same `ModuleScope.register_defined_module/3` folds it into the env before the body walk, so in
`defmodule Outer do defmodule Foo.Bar do use Foo.Baz end end`, `Foo => Outer.Foo` resolves
`use Foo.Baz` to `Outer.Foo.Baz` (and an
alias-sensitive `__using__` sees it via `__CALLER__.aliases`). Passing only the parent env would
resolve the body's short-name `use`/calls through an outer/top-level `Foo` or not at all.

**Normalize a harvested directive before folding it into the body env.** Within an expanded
`__using__` body, the env for later statements is advanced from the directives each statement
*yields* (so `alias … as: T; use T` resolves the `use`). Those harvested directives are **raw
standard-quoted**, where an `unquote(mod)`/`bind_quoted` alias carries its target as a **bare module
atom** (`{:alias, _, [Mutare.Foo, [as: T]]}`) — a shape `Aliases.register/2` silently no-ops on. So
`alias unquote(target), as: T; use T` bound nothing, `use T` didn't resolve, and the directives from
that nested `use` were dropped. Fix: `register_harvested/2` runs the same Sourceror conversion (`to_sourceror/1`)
(atom → `{:__aliases__, …}`) that `Harvest` applies at the end *before* `Aliases.register`, so the
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

**Degrades, never errors** (all wrapped in `try`): a non-loadable module (an external target, or a `use`
target that can't be resolved to a loaded module — note `Uses` *does* alias-track the target, so an
aliased `use Web` resolves when its alias is in scope), non-literal args (`use Foo, var`),
a `__using__` that raises (e.g. reads caller-module attributes), or an import gated behind a runtime
`if`/`unless` in the body — all become *no stamp* = the old unresolved behaviour. The stamp is stripped
before render (`Render.@internal_meta_keys`) and `use` is already pruned from mutation in `Analyze`, so
the directives are doubly invisible to the metamutant. `:expand_uses` (default `true`, `--no-expand-uses`)
toggles it; the default-on **changes mutant counts** on existing projects (new mutants; Ecto files that
failed to compile now compile). Tested via `test/support/using_fixtures.ex` (`__using__` fixtures, the
only vehicle — `examples/*` have no deps and are external) in `test/mutare/uses_test.exs`, including the
Ecto `:skip`-now-fires case with/without expansion.

**Isolate failure per `use`, not per bundle.** The "degrades, never errors" `try` was originally only
on `run/4` — the *per-top-level-`use`* boundary. But a bundle is recursive: idiomatic Phoenix's
`use MyAppWeb, :live_view` expands to a **block** that itself contains `use Gettext, backend: …`, whose
`__using__` runs `Module.put_attribute` on the (already-compiled) caller and **raises `ArgumentError`**.
That raise originates one level down, inside the *nested* `expand_and_collect(Gettext, …)`, and with the
catch only at the top it propagated through the enclosing block's `flat_map_reduce` and collapsed the
whole bundle to `{[], []}` — silently dropping the good `import Phoenix.LiveView` / `@behaviour
Phoenix.LiveView` sitting right beside the bad `use`. Fix: move the isolation onto **`expand_and_collect/7`**
itself — the recursion unit *and* the only site that runs a `__using__` (the only thing that can raise).
Now each `use` (top-level *and* every nested one) self-isolates: a raising `__using__` drops only its own
contribution while its siblings, harvested in the enclosing block, survive. Partial harvest is strictly
better than empty: every directive we keep expanded cleanly, and we never emit a half-baked one from the
failed `use` (the only loss is env-advancement for *its* injected aliases — already unavoidable, since it
couldn't expand at all). `run/4`'s outer `try` stays as a backstop for `to_sourceror`. The
rescue is left **broad** (`rescue _` + `catch _, _`) on purpose: other `__using__`s raise other things
(`KeyError`, `RuntimeError`, …) for the same compiled-caller reason, so narrowing to `ArgumentError` would
be fragile. The bug was invisible precisely because the degradation is silent, so it's regression-guarded:
`Mutare.Test.BundleWithRaisingUsing` (a bundle mixing good directives with a nested `CallerMutatingUsing`
raiser that mirrors Gettext) in `uses_test.exs` asserts the siblings survive and only the raiser's own
directive is dropped.

### Extension `use`-expansion override (`Mutare.UseExpansion`) `[done]`

**Charter (the in/out rule, pinned).** An extension teaches Mutare a library's **compile-time vocabulary**
— how to *resolve and route* the constructs the built-in mutators encounter — and **never participates
in the run, verdict, or score**. The defining axis is **vocabulary vs. judgment**, *not* compile-vs-
runtime: in = macro routing, `use`-expansion, block-macro treatment, opaque-literal declarations (act
*at* mutant generation); out = coverage/test-selection, exonerating an equivalent survivor, scoring,
reporting (read a run or *weigh* a generated mutant). The subtlety that makes the axis load-bearing:
both sides change the mutant *set* (a `:skip` removes mutants), so "affects the score" is not the test;
and "compile-time" alone is too weak, since statically proving a mutant equivalent is compile-time yet
*judges* a generated mutant — so it's **out**. The doc leads with the capability, not "third-party"
(which is *incidental* — the built-in `Kernel.match?`/`destructure` routings are the same vocabulary,
first-party). **Naming:** kept top-level `Mutare.UseExpansion` rather than `Mutare.UseExpansion.Compile`. A
`.Compile`/`.Runtime` split would (a) encode the *wrong* axis (compile-vs-runtime, not vocabulary-vs-
judgment) and invite the exact misread the charter forbids, (b) name for an unknown sibling that may
never exist and may not even be cleanly "runtime" (a coverage strategy spans transform-time
instrumentation + runtime readout), and (c) break the established convention of capability-named *peers*
(`Mutare.Mutator` is top-level, not `Extension.Mutator`). If a judgment-side extension point ever lands, it
gets its own capability name as a peer (`Mutare.Reporter`/`Mutare.CoverageSource`/…), not a `Extension.*`
child. The charter — not the name — is what pins the boundary.

The "degrades, never errors" stance keeps the build alive when a `use` can't be expanded, but it leaves
a real hole that **Gettext** falls straight into, and the hole is structural — not a bug to patch but a
limit of in-process expansion. `use Gettext, backend: MyApp.Gettext` injects `import Gettext.Macros`
(the `gettext`/`ngettext`/… macros, as **bare** calls whose msgid arguments must be compile-time
literals). Two failures **compound**: (1) Gettext's `__using__` registers its backend by
`Module.put_attribute` on `__CALLER__.module`, which **raises** against the already-compiled caller the
pre-pass expands under (the `CallerMutatingUsing` story above), so in-process expansion harvests *nothing*
— `import Gettext.Macros` never becomes visible, the bare `gettext` calls never resolve; and (2) even with
the import visible, a registered `{Gettext.Macros, :gettext, :skip}` only fires once the call **resolves**
to that module, and at the time `# mutare:ignore` applied after render and could not stop the
selector splice that poisons (it now can; see "Ignored mutants reserve IDs but emit no code").
So the user *wants* to mark the macros `:skip` but **can't make the
registration take effect** — the resolution it keys on depends on the very expansion that failed. Deadlock.

**Why this is an extension, not a core special-case.** The fix has to (a) supply the `import` the failing
`__using__` would have, and (b) route each macro's literal positions `:skip` while *mutating* the runtime
ones (`ngettext`'s count, a bindings map — great signal we'd otherwise lose to a blanket skip). Both are
**library knowledge** (Gettext's macro table, its backend wiring), so they belong in a `mutare_gettext`
package, not in Mutare core. `Mutare.Extension` is the configuration boundary: a module listed under
`:extensions` contributes source-understanding capabilities without being a mutator (no `name/0`, no
mutation producer, never in a report — it only makes the built-in mutators land). Two independent
behaviours are recognized:
- **`Mutare.MacroRouting.macro_routes/0`** (a *registration*) — the same capability an enabled
  mutator may implement; collected by `Macros.from_extensions/1` and **merged** by `build/3`.
  Opts-independent (a static library fact).
- **`expand_use(used_module, args, context) -> Mutare.UseExpansion.Expansion.t() | :decline`** (a
  *decision*) — the `use`-expansion override, **first-non-`:decline`-wins**. `context` is a map
  carrying the caller `:module` + the extension's `:opts`; the return is a struct (`%Expansion{directives,
  behaviours}`, built by `Mutare.UseExpansion.expand/2`).

**API-surface decisions (locking the third-party boundary before there are external extensions).** The
callbacks divide by **kind**, and the kind fixes both combination and configuration: a *registration*
(`macro_routes/0`) **merges** across extensions and ignores opts (it declares library facts); a *decision*
(`expand_use`) is **first-win** and reads opts — exactly mirroring mutators (`opts` reach `mutate/2`,
never `macro_routes/0`). Three deliberate future-proofing choices fell out: (1) `expand_use` takes a
**`context` map** (`:module` + `:opts`) rather than more positional args — the map gains keys without
an arity bump, and `:module` is real parity (in-process expansion already threads the caller module/
aliases for a `__CALLER__`-dependent `__using__`; an extension replacing it deserves the same). (2) It
returns a **struct** (`Mutare.UseExpansion.Expansion`), not a `{:ok, …}` tuple — a new field is a default,
not a breaking widen. (3) `:extensions` entries accept **`{module, opts}`** (resolved to
`Mutare.Extension.Spec`, the extension twin of `Mutator.Spec`), so an extension is configurable like a mutator.
`macro_routes/0` deliberately **stayed arity-0**: the registry is built once, globally, before any file is
walked — there is no per-file "module it's registering for", and per-*call* routing variation is
already served by the `:routing` classifier (`macro_routing/1` sees the call node). A `context` there
would be a global-vs-per-call category error; YAGNI.

**Where the override hooks in (and why there).** `Harvest.run/4` is the one site that both resolves the
`use` *target* and decides expansion, so the dispatch lives there, not in the recursive `Uses` walk. The
old `standardize/2` coupled module-resolution with the **static-literal opts gate** — fatal here, since
Gettext's `backend:` is a module alias, *not* a literal, so the gate would `:error` before any extension
could be asked. Split it: `target/2` alias-resolves the module and returns the **raw** args (no gate);
extensions are consulted first via `UseExpansion.Dispatch.run/4`; only on `:decline` does `in_process/5` apply the
opts gate + `Code.ensure_loaded?` + expand. The extension path needs *neither* gate (it never invokes
`__using__`, so it asserts the directives rather than deriving them). Its returned directives are
standard-quoted (from `quote`), so they ride the **same** `to_sourceror/1`
(`Macro.to_string |> Sourceror.parse_string!`) as a harvested directive and arrive as the Sourceror form
`Resolve.register/2` folds — zero new register clauses. The nested-`use` recursion (`collect/7`, formerly
`/6`) is now **also** extension-aware: `handlers` thread through `in_process → expand_and_collect → collect`,
and `collect`'s `use` clause consults the extensions *first* (via `use_target/2` — the raw-args, no-gate
nested twin of `target/2`) before falling back to in-process (`nested_in_process/7`, which keeps the
gate + loadability check). This is the **positive fix for the Phoenix integration point**: `use MyAppWeb,
:html` expands to a body that itself does `use Gettext, …`, so the override has to reach a *nested* `use`,
not just a directly-written top-level one — the original "internal `use`s stay in-process" boundary
silently defeated the motivating case (the bare `gettext` calls never resolved, the msgids poisoned the
build). An extension override of a nested `use` returns `collect/7`-shape items (`extension_items/2`): directives
left standard-quoted for `in_process/5`'s final `to_sourceror`, behaviours as `{:mutare_behaviour, atom}`
tuples. (Cycle/depth caps still backstop a genuinely recursive in-process chain; an extension override is
terminal for its `use`, so it adds no recursion.)

**Dispatch + safety.** `Mutare.UseExpansion.Dispatch.run/4` is **first-non-`:decline`-wins** over the ordered `:extensions`,
each handler call wrapped (`safe_expand/4`). The boundary is **`:decline` is the only opt-out; every other
outcome is loud.** An extension *bug* — whether a return that is neither `%Expansion{}` nor `:decline` (a
non-list `Mutare.UseExpansion.expand/2` call lands here too), or a **raise/throw/exit** from `expand_use/3` — is a
*misconfiguration* (a broken installed extension, not a property of the target), so it surfaces as
`Mutare.UseExpansion.ContractError` **loudly** (like `validate!/1` on a non-extension module): a malformed return
raises it directly, a raise/throw is *wrapped* in it (original cause in the message, stacktrace preserved).
That single type rides *through* `Harvest`'s otherwise-catch-all rescue (via a dedicated
`e in ContractError -> reraise` clause at every layer) up to `Schema`, which re-raises it — while the
*target*'s own un-expandable `use` (a raising `__using__`, a non-static head) still degrades silently, the
behaviour that boundary exists to provide. **Why loud, not isolated** (the deliberate choice): an earlier
design swallowed a raising handler to `:decline`, but that is indistinguishable from a deliberate decline —
an extension silently doing nothing for every run, the worst failure mode for a tool whose job is to *not* miss
mutants. An extension author's only fall-through is an explicit `:decline`; `nil` (an `if` with no `else`), a
crash, or junk all fail the run with a message naming the culprit. (`Harvest`'s rescue still absorbs target
failures, so a missing/raising extension can't sink a scan — only an extension that is *present and broken* does.)
An **empty** `%Expansion{}` is *not* a failure — it is a deliberate "handle and inject nothing" that still
wins first-non-`:decline` (an extension wanting to fall through must return `:decline`). The dispatcher merges **each handler's own `:opts`** into the shared `context` before the call,
so a `{module, opts}` extension reads its config in `expand_use/3`. `handlers/1` `Code.ensure_loaded?`s
each module before `function_exported?` (false on a not-yet-loaded module — an order-dependent footgun
the standalone tests caught) and resolves each entry to an `Extension.Spec`.

**Threading + validation.** `:extensions` is an `Options` field (default `[]`) that resolves to
`Mutare.Extension.Spec`s (bare module → empty opts; `{module, opts}` → carried opts), validated by
`Extension.extension?/1` — **reflection-based** (loaded + exports a capability callback), unlike `:macro_routes`'s
syntactic validation, because an extension module genuinely *is* on the Mutare process path (it's a dep of the
target, like a custom mutator), whereas a `:macro_routes` entry only names a possibly-absent module. `Schema`
forwards the specs; `Transform` threads the extension **specs** into both `Macros.build/3` (which reads each
spec's `.module` — registration is opts-independent, so `Macros` ignores the opts) and `Uses.annotate/2`
(so `opts` reach `expand_use/3` via context). `Macros.from_extensions/1` accepts specs *or* bare modules
(extracting the module from each, mirroring `from_mutators/1`), and **rejects** an extension `macro_routes/0` that
declares a `:hosted`/`:routing` treatment — static routing cannot carry a host, so the entry must move
to an enabled mutator's `hosted_routes/0`. Extension behaviours are kept **atoms-only**
(`normalize_behaviours/1` filters to concrete module
atoms, dropping a stray quoted node / junk / the degenerate `nil`/`true`/`false`) per the
`Expansion` `behaviours: [module()]` contract — *not* alias-resolved against an empty env, which would
silently mis-resolve a single-segment or aliased node to the wrong module.
It's `.mutare.exs`-only (no CLI flag) — extensions are modules, and the UX is the **Igniter installer**
(`Mix.Tasks.Mutare.Install`), which on detecting `:gettext` adds the `mutare_gettext` dependency and
writes the one `:extensions` entry (`extensions: [Mutare.Gettext]`) into the generated `.mutare.exs` — the
extension counterpart of how a detected `:phoenix`/`:ecto` extends the `:mutators` list (the "without
editing config" goal). So a console string flag earns nothing.

**Scope decision — tied to `:expand_uses`.** When `--no-expand-uses` freezes the pre-pass, extension overrides
are frozen with it (the whole `Uses.annotate` is skipped). Defensible: `--no-expand-uses` means "no `use`
magic at all," and it's a debug/count-pinning flag. **Status: still deferred by design.** Making explicit
extension overrides independent of heuristic in-process expansion would need a new explicit mode (for
example "extensions only") rather than silently changing the meaning of `--no-expand-uses`.

**Merge precedence — explicit config is the final authority.** `build/3` folds **built-ins → mutator
`macro_routes/0` → extension `macro_routes/0` → declarative `:macro_routes`** (`Map.put`, later wins), so a `.mutare.exs`
`:macro_routes` entry overrides *both* a mutator's and an extension's registration for the same
`{module, name, arity}`; among the code extensions an extension wins a tie over a mutator. The earlier order
folded config *first* (weakest), which let an installed extension silently override a user's explicit
routing — a footgun. Folding config last fixes it under the rule "the user's explicit config is always
the final say." The accepted cost: config now also outranks a *mutator's* macro registration, so a user
who explicitly writes `{Ecto.Query, :from, :expression}` can un-skip a DSL its mutator needs left raw —
but that's a deliberate, explicit opt-in, and the poison backstop still catches a bad override at compile
time. (The alternative — let code extensions outrank config — was rejected: explicit user intent losing
to an *installed dependency* is the more surprising failure.)

**Three robustness guards on the override path** (small, each closing a gap a review surfaced):
`target/2` guards `not is_nil(mod)` — `Aliases.resolve_node/2` returns `nil` (itself an atom) for an
unresolvable target, so a bare `is_atom` would hand a `nil` module to every extension's `expand_use/3`
(harmless on the in-process path, but an extension with an unguarded catch-all clause would fire on a `use`
it can't see). `from_extension/2` runs extension-injected behaviours through `normalize_behaviours/1`
(`Aliases.resolve_node` each, drop the un-resolvable) so only concrete module atoms reach the behaviour
set — matching the in-process harvest, where a non-atom would silently match no `@behaviour`.
`flatten_directive/1` **recurses** through nested `__block__`s, so a block-in-a-block (a legal if unusual
`Macro.t()` an extension might `quote`) flattens to its leaf directives rather than surfacing an inner
`__block__` that `register/2` would drop.

**Superseded alternative.** An earlier idea was to match a registered `:skip` macro by **bare name** on an
*unresolved* call (sound because `:skip` only ever *removes* mutation, never poisons). The override is
strictly better: it produces *real* resolution, which enables **per-position** routing (mutate the count,
skip only the msgid) that a name-only skip can't do safely — so we built the override and dropped the
bare-name path. Tested in `extension_test.exs` (dispatch, macro merge, the config-over-mutator precedence,
the `Uses` override surfacing the directive a raising `__using__` can't, a 3-tuple `@behaviour` injection
normalized to module atoms, and end-to-end per-position routing through `transform_string`) with
`test/support/extension_fixtures.ex` (`GettextLike` + its raising caller-mutating `__using__`,
`GettextLikeMacros`, `GettextLikeExtension`, `BlockDirectiveExtension`, `BehaviourExtension`).

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
`use`-injected set. The injected half piggybacks on the **existing** `Uses` expansion: a new `collect/7`
clause harvests `{:@, _, [{:behaviour, _, [mod]}]}` from the expanded `__using__` body (it appears as a
top-level statement there, reached by the same block/nested-`use` recursion that harvests
imports/aliases), tagged `{:mutare_behaviour, mod}` so `run/4` can split it from the
name-resolution directives and stamp `meta[:mutare_use_behaviours]` (read by `Uses.injected_behaviours/1`).
Only canonical `@behaviour` is recognised — Elixir **rejects** `@behavior` outright, so matching the
American spelling would be wrong, not lenient.

**Thread with zero new plumbing — the spec is already the universal carrier.** Behaviours are a
per-module fact, but the value threaded to *every* leaf where a mutator runs (`Mutator.mutations/3`,
the structural callbacks, `Tag`, `FunctionPlan`) is the `Spec` list. So we add a `behaviours` field
to `Spec` (empty default) and **re-bind it per module** at the few analyze/plan entry points
(`enrich_mutators/2` = `Enum.map(ctx.mutators, &%{&1 | behaviours: ctx.behaviours})`, cached as `ctx.analysis_mutators`,
`ctx.behaviours` set save/restore per `defmodule`). The deep `analyze/3` recursion is untouched — it
already forwards the spec list opaquely; only `enrich_mutators/2` and `Mutator.mutations/3` (which
injects `spec.behaviours` into the `mutate/2` context, beside `:opts`) change. The alternative — a
threaded env bundling specs+behaviours — would have changed the *type* of the value passed through
~400 `mutators` references; the spec-field re-bind keeps the value a plain `[%Spec{}]` list, so every
existing `Enum`/`Spec.find` over it works unchanged. (It's a per-module fact on a per-mutator struct,
yes — but it rides the spec→context path *exactly* as `opts` does, so the framing holds.) Id stability:
behaviours are a deterministic function of the static source, so the same module re-binds the same set
across poison rebuilds — ids stay put.

**Structural callbacks get context-aware arities.** `mutate/2` reads `context.behaviours` directly;
the structural hooks (`return_replacements`/`condition_replacements`/`pattern_mutations`) take only a
node, so each gains a `+1`-arity variant taking a context map. `Mutator` centralises
the dispatch (`return_replacements/2` etc. call the context arity when exported, else the base) and the
discovery (`implementing_any(specs, fun, [base, base+1])`), so a mutator implements *either* arity and
the four call sites stay one-liners.

**Now also configurable.** The same context-taking structural arities now receive `%{opts: spec.opts,
behaviours: spec.behaviours}`. The base arities remain context-free, but a configured structural
mutator can implement `return_replacements/2`, `condition_replacements/2`, or `pattern_mutations/3`
and read its `{Module, opts}` configuration through `context.opts`, matching the node-level
`mutate/2` channel.

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

### Implicit nested-module alias — shared `ModuleScope`, folded by `Resolve`/`Behaviours` too `[done]`
Elixir auto-aliases a nested module's short name for its body and following siblings — inside
`Outer`, `defmodule Foo …` puts `Foo => Outer.Foo` in scope, so `Foo.bar()` and `@behaviour Foo`
resolve there with **no explicit `alias`**. Only `Uses` folded this alias (for `__CALLER__` fidelity —
see the `use` expansion entry's *Mirror the implicit alias* passage). `Resolve` (stamps every call)
and `Behaviours` (gathers `@behaviour`) folded **explicit** aliases only, so a sibling nested module
referenced by short name resolved to the wrong module: in `Resolve`, `Foo.bar()` keyed on the bare
`[:Foo]` instead of `[:Outer, :Foo]`, so a `:macro_routes` entry keyed on the real module never
matched (the built-in call families key on the *literal* path, so they were unaffected — this only bit
custom routing); in `Behaviours`, a nested `@behaviour MyBehaviour` was gathered as the top-level
`MyBehaviour`, so a behaviour-gated mutator missed it. Separately, `Behaviours.walk/2` lacked the
`:quote` boundary its two sibling walks have, so a `defmodule` written inside a `quote` block (quoted
*data*, realised only when some caller expands it) got a **spurious** behaviour stamp.

Fix: extracted the implicit-alias vocabulary out of `Uses` into `Mutare.Transform.ModuleScope`
(`child_module/3`, `register_defined_module/3`, the combined `register_lexical/3`, and the
`@unresolved` sentinel — `Uses` now sources its own `@unresolved` from it so the two can't drift), and
taught `Resolve` and `Behaviours` to thread the enclosing module and fold the implicit alias through
`ModuleScope`. Added the missing `:quote` clause to `Behaviours`. `Uses` delegates — a pure,
behaviour-preserving move (its suite is unchanged). This **reverses** the old "`Resolve` deliberately
doesn't track module scopes" note: `Resolve` now tracks exactly one thing, `env.module` (the enclosing
module, `nil` at the top level), and nothing else.

**Getting `env.module` right when *entering* a scope.** Folding the implicit alias against
`env.module` only works if every scope sets the *correct* enclosing module before its body/siblings
are folded — otherwise a nested module is parent-prefixed to the wrong module (and can then match or
miss a `:macro_routes` entry for a module that needn't even exist). Three cases beyond a plain static
`defmodule` need care, all handled in `Resolve`:

  * **Non-static head** (`defmodule __MODULE__.Foo`, `Module.concat(…)`) — can't be named, so the
    body enters under the `@unresolved` sentinel and a nested `defmodule Bar` stays its literal
    `[:Bar]` rather than resolving to the enclosing `Outer.Bar` (the compiler defines `Outer.Foo.Bar`,
    which no static answer produces). The `defmodule` clause was **broadened to match any head** so it
    sets this scope, instead of a dynamic head falling through to the generic bare-call clause and
    inheriting the *enclosing* module.
  * **`defimpl P, for: T`** — opens the absolute scope `P.T`, so `Resolve` gained a `defimpl` clause
    that walks the body under `impl_module(P, T)`; a nested module inside resolves as `P.T.Sub`, not
    `Outer.Sub`. `impl_module/3`/`for_type/1` moved to `ModuleScope`; a `for:`-less or non-static
    impl degrades to `@unresolved`. The clause scopes only the **last** argument (which always holds
    the `do` block) to `P.T`, so it covers all three surface forms uniformly — `defimpl P, for: T do
    … end` (`[proto, opts, do-block]`), the inline `defimpl P, for: T, do: …` (a *single* arg
    `[for: …, do: …]`, a distinct two-element-keyword shape the earlier two-clause split missed), and
    the `for:`-inferred `defimpl P do … end`. It is **gated on `Kernel.defimpl`** just like the
    `defmodule` gate below: a displaced `defimpl` (`import Kernel, except: [defimpl: 3]` + a DSL's
    own) builds no `P.T`, so it falls back to ordinary traversal in the enclosing scope rather than
    scoping the DSL block to a nonexistent impl module.
  * **Displaced `defmodule`** (a DSL macro over Kernel's — `import Kernel, except: [defmodule: 2]`;
    `import MyDSL, only: [defmodule: 2]`) defines no module named after its head, so opening a scope
    and installing `Foo => Outer.Foo` would resolve/route interior and sibling calls against a
    nonexistent module. Both the body scope (the `defmodule` clause) and the sibling alias
    (`register/2`) are gated on the call still resolving to `Kernel.defmodule`
    (`kernel_module_definer?/4`, via the existing `bare_module_key/4`); a displaced definer falls back
    to ordinary traversal.

The displaced-definer gate is **`Resolve`-only**: `Behaviours` threads only the alias env, not the
import env, so it can't distinguish a displaced `defmodule` from a real one without adding import
tracking — disproportionate for the near-impossible case of gathering `@behaviour` off a DSL block
that displaces `defmodule` *and* cross-references its name as a behaviour. `Behaviours`'s
non-static-head and `defimpl` handling is already safe (both degrade to `@unresolved` via
`child_module/3`).

Tested in `aliases_test.exs` (sibling + multi-level resolution; the non-static-head, `defimpl`-body,
and displaced-`defmodule` cases) and `behaviours_test.exs` (sibling `@behaviour`, quote boundary).

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

**Scope: remote + imported bare refs.** `&Mod.fun/N` (Elixir, alias-resolved through the synth
call's own node — `&E.first/1` for `alias String, as: E` keeps the `E.` in the diff) and
`&:mod.fun/N` (Erlang atom module) both route. A **bare imported** capture
(`import Enum; &filter/2`) now routes too: the resolve pass recognises the `&fun/N` ref shape,
stamps the ref with the same `:mutare_import` metadata a written `fun(args…)` call would carry,
and copies the import-witness payload to the outer `&` node because capture candidates are
attached there. The synthetic bare call then goes through `Calls.resolved_call/1` unchanged:
whole imports can recapture a clean bare sibling (`&filter/2 → &reject/2`), while selective or
overlapping imports recapture an alias-proof qualified sibling
(`&filter/2 → &Elixir.Enum.reject/2`). A truly local capture (`&local/1`) still has no import
stamp, so `synth_call/2` returns `:error` and the node is left pruned. Nested captures (a capture
inside another `&`) are illegal source, so they never reach the clause; `& &1 / 2` (the
shorthand, not a reference) still recurses and mutates its body unchanged.

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

### Macro registry wildcards — whole-module and name-only escape hatch `[done]`
Two flexibility asks on `:macro_routes`: (1) mark a **whole module**'s macros with one treatment (a
whole DSL `:skip`), overridable per-macro on a separate line; (2) configure a treatment **by name
only**, applying to any module exporting that name — the escape hatch for when the module-resolution
machinery can't see the macro (a `use`-injected import Mutare can't expand, an alias it can't follow).

The whole thing is **two wildcards in the existing positional grammar** — no new tuple shapes, almost
no new code. The glob atom **`:*`** (`Spec.wildcard/0`) means "match anything" in any slot:
`{Mod, :*, t}` is whole-module (name wildcard), `{:*, name, t}` is name-only (module wildcard), and in
the *arity* slot `:*` is a synonym for the canonical `:any`. Why `:*` and not `:any`: `any` is a
perfectly ordinary macro name (a real collision — is `{Mod, :any, …}` the macro `any` or the wildcard?),
whereas `*` is a *vanishingly unlikely* one. Note `*` is **not** an impossible name — it's the
multiplication operator `Kernel.*/2`, `defmodule :*` compiles, and a metaprogrammed `def unquote(:*)`
works — but nothing registers the `*` operator as a known macro (operator handling is out of scope), so
in practice `:*` never collides: a near-impossible, escaping-free sentinel rather than a strictly
impossible one. (We asked; `:*` was chosen over `:_` for glob-obviousness.)

Where the code actually changed:

- **`Spec`** — `normalize_module(:*) → :*`, `validate_arity(:*) → :any`, and `validate_wildcards!/3`
  rejecting the two nonsensical combos: *both* module and name `:*` (route everything everywhere), and
  a name-`:*` entry pinned to a real arity (the lookup cascade only ever consults `{module, :*, :any}`
  for a whole module, so an arity there would be dead config — fail loud, don't silently drop). The
  existing `resolve!/1` 3-/4-tuple clauses already build these — `:*` just flows through the slots.
- **`Macros.lookup/4`** — the one behavioural change: a **most-specific-wins cascade**
  `{m,n,a}` → `{m,n,:any}` → `{m,:*,:any}` → `{:*,n,a}` → `{:*,n,:any}`. So a specific entry overrides a
  whole-module one (the per-macro override falls out for free), the name-only hatch is **last** (never
  shadows a module-matched or built-in treatment like `Kernel.match?`), and a name-only entry fires even
  when the resolved `module_key` is `nil` (the unresolvable bare call — exactly its purpose).

**No `Resolve` change.** `MacroStamp.stamp/7` already calls `lookup` with the resolved (or `nil`) module and
acts on whatever spec comes back; the cascade does the rest. `registered_macro_module/3` (which recovers
a module for a bare call under a whole import of an unloadable DSL) now matches more eagerly when a
name-only entry exists, but harmlessly: its returned `module_key` is used *only* to re-feed `MacroStamp.stamp/7`,
which produces the same name-only routing whether the module is the recovered one or `nil`.

The name-only hatch is documented as deliberately non-standard and broad (it skips/routes *every* call of
that name, function or macro, in any module) — that's the user's explicit opt-in for the case where
proper module resolution isn't available.

### A name-keyed catalog and somebody else's macro `[documented; built-ins unguarded]`
A registered macro's route describes its **arguments**. The call node itself is still offered —
NOTES "Whole-call mutants on a binding macro" records why, since the whole `macro_routes/0` feature
depends on it. So a `:skip` registration hides a DSL's interior and leaves its *name* exposed to
every enabled mutator, which is the intended asymmetry and also a trap.

It is harmless for a catalog keyed on `{module, function}` through `Calls.resolved_call/1`, which
returns `nil` for anything it cannot resolve. It is not harmless for a catalog keyed on a **bare
name** — what a DSL forces when its API functions are never imported and the library's own builder
interprets the name, so there is no module to resolve and the name is the only key. Rewrite somebody
else's `max(a, b)` to `min(a, b)` and you emit a call the DSL doesn't define; the library rejects it
while expanding, and the single metamutant build takes the whole thing as poison.

The test is `macro_treatment(node) != nil` — having a treatment is exactly what being registered
means — documented on `Mutare.Calls.macro_treatment/1` for adapter authors. Two properties to keep
straight: `[]` is a *registered* macro with no visible arguments (truthy, and pinned as distinct from
`nil` by the reader's own tests), so the check is against `nil` and never against emptiness; and the
name-only `{:*, name, …}` route (previous entry) is what makes the test fire at all in the
unresolvable-module case it exists to serve. An *unregistered* macro is invisible to it.

**The built-ins do not apply it, deliberately-for-now.** `Helpers.swap_bare_kernel/3` and
`remove_bare_kernel/3` gate only on effective arity and `Imports.kernel_displaced?/1` (the
`import Kernel, except:/only:` stamp); no mutator family consults macro routing at all. A
third-party macro registered as `max/2` would be offered and swapped to `min`. Nothing collides
today only because the bare tables are small and arity-pinned — `Numeric`'s `{min,2}`/`{max,2}`/
rounding, `Arithmetic`'s `{div,2}`/`{rem,2}`, `CallRemoval`'s `{abs,1}`/`binary_slice`/`binary_part`
— and the DSL names that would plausibly wear those spellings are registered at other arities. Left
unguarded rather than fixed speculatively: the fix is one `macro_treatment/1` check in each
bare-`Kernel` helper, and it should land with a test that registers a genuinely colliding macro
rather than on the strength of this note.

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

**#1 — mutator-supplied selector host (the delivery seam, `c:Mutare.Mutator.MacroHost.host/2`).** You can't
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
seam (now owned by `BindingEscapeEmit`, shared by the `=`-match/binding-macro tuple-export rewrites)
to a mutator:
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
separate path). Lands as `Transform.Candidate.Hosted` + `Transform.HostedEmit.emit/5` (the `:mutare_hosted`
meta key — a third emit alongside `:mutare`/`:mutare_case`) + `Mutator.host_targets/3` (the validate/
default-`wrap` normalizer). Multiple targets fold over the node (each `splice` replaces its own
position); a whole-node `:mutare` mutation on the *same* node still rides an ordinary selector wrapping
the spliced result (`emit_site/3`) — a no-op when there is none, the common case.

**#2 — a `:hosted` macro-arg treatment + shape-aware routing (`c:Mutare.Mutator.MacroHost.macro_routing/1`).**
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
A declarative `:macro_routes` entry can't use `:hosted`/`:routing` (no host to deliver/answer) — `Macros.build/2`
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
    fragment, `HostedEmit.emit/5` dispatches the leftover `:mutare` candidates exactly as the
    un-hosted path does: a `MacroPattern` head routes to the tuple-export
    rewrite (`BindingEscapeEmit.macro_pattern_site/3`), whose **baseline branch is the spliced macro** — so the
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
    vanish without a trace. `Resolve.MacroStamp`'s undeliverable-host check (the classifier-path analogue of
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
    it unblocks `mutare_ecto`'s shorthand-split + `nil`-pair exclusion without the extension re-implementing
    core's literal families. Tested via the `set/2` fixture macro (`Mutare.Test.HostDSL`/`HostMutator`).
    A keyword *value* is `t:Mutare.Mutator.MacroHost.keyword_value_treatment/0`, which **includes `:hosted`**:
    a value inside a keyword shorthand can be a foreign-DSL fragment too (e.g. an `mutare_ecto`
    `where(q, x: u.a == u.b)`-shaped value), so it routes to the registering mutator's `host/2` like a
    top-level `:hosted` argument. Hosting still delivers through `host/2`, which weaves into the **whole
    macro node** (#1) — there is no *per-keyword-value* delivery — but that's never needed: core only has
    to (a) leave the value **raw** during descent and (b) find the host. Both fall out of making the three
    routing walks recurse through `{:keyword, …}`: `route_macro_arg/3` already left a `{:hosted, host}`
    value raw, `MacroStamp.inject_host/2` now rewrites a nested bare `:hosted` → `{:hosted, host}` at any
    depth, and `hosted_host/1` (analyzer detection) / `reject_undeliverable_hosted!`'s `hosted?/1` (stamp
    check) now descend keyword treatments to find it. The host's `splice` navigates a *path* into the
    keyword tree to the target value, so whole-node delivery reaches an arbitrarily-nested leaf, and
    `HostedEmit.emit/5` threads the node across targets so several keyword leaves on one call weave
    independently. This **replaces** the earlier narrowing (which excluded `:hosted` from a keyword value
    and rejected a nested one at stamp time, on the now-wrong premise that injection/detection couldn't
    recurse): with all three walks recursive, the silent-miss / poison risk that justified the rejection
    is gone, so there is nothing to reject. A deeper `{:keyword, [{:keyword, [:hosted]}]}` routes too
    (every walk recurses). Tested via `Mutare.Test.KeywordHostedMutator` (`hosted_test`) — a direct
    keyword value and a nested one, each round-tripped through `Code.compile_string`.

  * *Classifier output is validated in `Resolve.MacroStamp`.* A `:routing` classifier's return
    is **untrusted input**, but only its hosted corners were originally checked. An unrecognised or
    mis-shaped treatment (`:expresion` typo, `{:keyword, non_list}`, or a non-list return) would
    otherwise fall through `route_macro_arg/3`'s `:expression` catch-all and *silently mutate* a position
    core was asked to skip/host/pin — a wrong-position mutation or a poison. MacroStamp's validator (the
    classifier analogue of `Macro.Spec.validate_args/1`'s build-time check for static `args`) recurses the
    **raw** output (pre-`inject_host`) and raises with the offending value; `:hosted` is valid in **any**
    position (a whole argument *or* a keyword value — see the keyword-hosted case above), and a
    `{:keyword, …}` recurses into its values. The recognised atom set is derived from `Spec.treatments/0`
    (+ `:pinned`) so it can't drift. Tested via `Mutare.Test.UnknownTreatmentMutator` and a
    non-list-returning classifier (`hosted_test`).

  * *`:pinned` — `^`-pinned in-place mutation.* Per-pair routing alone isn't enough for the shorthand
    split: a shorthand value sits **inside** Ecto's query macro, which rejects a bare selector `case`
    (`where(q, category: case … end)` → "unbound/`case` not supported") but accepts the interpolated
    `where(q, category: ^(case … end))`. So core can't mutate a shorthand value with its ordinary
    in-place selector — the same wall the host (#1) climbs for *conditions*, but here the mutants are
    core's literal families, not the extension's catalog. New value treatment `:pinned`
    (`route_macro_arg/3`): analyze the value as ordinary runtime so the configured families attach
    their `Candidate.InPlace`s (their **own** family name reaches the Site — `:string`/`:integer`, not
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
    fine — nothing to pin. This is why "shorthand values are plain interpolated Elixir,
    *not* hosted" was half-right: the value *mutation* is core's (not the SQL catalog), but the
    *delivery* must be pinned, not a bare selector. Tested via `Mutare.Test.CompoundInterpolatedMutator` (né `CompoundPinnedMutator`).

  * *Per-mutant report note — `Site.note`.* A hosting mutator may want to flag a *live, scored* mutant
    with advisory text the report shows on a survivor — `mutare_ecto` tags its equivalence-sensitive
    families (`:comparison`/`:connective`/`:null_predicate`) "kill may require NULL/boundary data", so a
    survivor reads as honest SQL-three-valued-logic signal, not a plain test gap. Distinct from
    `ignore_reason` (which *suppresses* a mutant). New optional `Site.note` (default `nil`), set via
    `Site.in_place/7`. The channel is per-mutant on the **host target**: a target's `mutants` entry is
    now a bare node *or* a `%Mutare.Mutator.Mutation{}` (`Mutator.normalize_target/1` → `{node, note}`
    pairs on `Candidate.Hosted.mutants`; `HostedEmit` threads the note to the Site).
    The **struct** form is used (not a bare `%{node:, note:}` map, nor a `{node, note}` tuple) because a
    quoted 2-tuple AST (`{a, "str"}`) collides with a `{node, note}` pair, and a quoted *map* literal
    (`%{a: 1}`) is itself a valid mutation node — only the struct is unambiguous (see "the note channel,
    generalized" below). `Mutare.Report.header/1` appends `  — <note>` to the `SURVIVED` line (mirroring
    `ignored/1`'s reason suffix) and the JSON report emits it as `description`. Fourth foreign-DSL
    extension; contained — `note` defaults `nil`, the non-host `in_place/6` callers are unchanged, and a
    bare-node host mutant still works. Tested via the `filter` fixture noting its boundary flip but not
    its reversal (`hosted_test`).

  * *Reading how a **nested** macro is registered — `Calls.macro_treatment/1`.*
    A `:hosted` argument is left **raw** and core does **not** descend, so it never routes the macros
    *inside* the fragment — they're the host's to own (the `host/2` walk decides what's mutable). That
    means a nested `:skip`-registered macro (`from(t in U, where: custom_fn(t.x) and t.age > 18)`, with
    `custom_fn` marked `:skip`) is *not* auto-respected: core isn't looking in there. But it isn't lost
    either — the `Resolve` pre-pass walks **uniformly** (`descend(args, env)` doesn't prune at a
    `:skip`/`:hosted` boundary), so every nested known-macro call in the raw node handed to `host/2`
    already carries its `:mutare_macro_call` identity + `:mutare_macro` routing stamp, from the *merged*
    registry (built-ins + mutators'/extensions' `macro_routes/0` + the declarative `:macro_routes`) and the same
    alias/import/`use` resolution. So the reader is pure stamp-reading — no new plumbing, no registry in
    `host/2`'s context: `macro_treatment(node)` returns the resolved **per-visible-arg** routing (or
    `nil`). It is deliberately per-argument with *no* all-`:skip` convenience predicate: a macro is
    registered per position (`[:skip, :expression]`), so collapsing that to one boolean would hide the
    very distinction a host needs. The one normalization: `Resolve` rewrote each `:hosted` → the internal
    `{:hosted, host_module}` (and recurses through `{:keyword, …}`), so `author_treatment/1` maps it back
    to the `:hosted`/`:keyword` vocabulary the author wrote. Resolution is whatever `Resolve` could see —
    a qualified/imported macro resolves cleanly, a *bare* call to a locally-defined, un-imported macro
    only via the name-only `{:*, name, …}` hatch. Tested in `calls_test`.

**Explicitly not needed.** `context.uses` — every Ecto target self-identifies *node-locally* (a resolved
call or a known macro), unlike a GenServer return tuple (shape-ambiguous, *does* need module context); the
node never has to ask the module who it is. `opts` for `macro_routes/0` — Ecto's macro set is fixed. Caveat
inherited from `Uses`: an external-path target whose deps aren't on the task's code path won't expand
`use Ecto.Schema`, so schema-skip silently degrades and the body poisons — run mutare **as a dep of the
app under test**, the supported deployment.

### The note channel, generalized to the standard `mutate` API
The per-mutant advisory `Site.note` (above) was born private to the selector host: only a `host/2` target's
`:mutants` could carry one. But the note is not a *hosting* concern — it is "this mutant deserves a word on
the survivor line", which any mutator may want (an off-by-one literal swap, an equivalence-sensitive
operator). So the channel is now open to the **ordinary `mutate/1`/`mutate/2`** path, with **no new
delivery mechanics** — the note is a pure carry-along that never touches the AST used for suppression,
`Overlap` footprinting, or lifting.

  * **One shape, a struct — `Mutare.Mutator.Mutation`.** A `mutate` return-list element (and a host
    target's `:mutants` entry) is now `t:Mutare.Mutator.mutation/0`: a **bare node** (no note; except a
    top-level bare `nil`, which is rejected so it cannot masquerade as “drop this slot”), or a
    `%Mutare.Mutator.Mutation{node:, note:}`. The struct is **required for the noted form** — *not* a bare
    `%{node:, note:}` map — because a quoted **map literal** (`%{a: 1}`) is itself a perfectly valid
    mutation node, so a bare map can't unambiguously mean "noted mutant"; a struct never collides with
    quoted AST. (This supersedes the host path's earlier bare-map form; `mutare_ecto` moves to the struct.)
    `normalize_mutant/1` is the **one** home for the contract — struct → `{node, note}`, bare node →
    `{node, nil}`; a bare `nil` (filter inapplicable entries before returning the list, or use
    `Mutare.AST.literal(nil)` for a literal-nil replacement), a bare map, **any non-`Mutation` struct**
    (no AST node is a struct, so it would otherwise pass through as `mutated` and crash Sourceror), or a
    non-string note **raises** (fail loud over a vanishing/garbled mutant); an **empty-string note collapses
    to `nil`** (a blank note carries no signal,
    and `nil` keeps the report from rendering a dangling `— ` suffix / an empty JSON `description`). The
    per-mutant normalize is itself single-homed in `normalize_mutants/1`, shared by both `tag/2` (the
    `mutate` path) and `normalize_target/1` (the host path), so bare-`nil` items fail loud in both paths.

  * **Threaded as the third tuple element.** `Mutator.mutations/3` now returns `{spec, mutated, note}`
    triples (was a pair). Everything that consumes the pair widened to `{spec, mutated, _note}` — the
    `Tag` suppression/literal filters, `Tag.expand_targets/2`'s build closure (`… mutator, mutated, note,
    range`), `Analyze.build_candidates/2`, `Captures.capture_mutations/4`, `Mutare.Test.node_mutations/3`.
    A note-bearing candidate gains a `note` field: `Candidate.{InPlace,Lifted,CaseClause,CasePattern}` —
    the four kinds a `mutate` result lands in *directly* (in-place body, lifted `def`-head guard/literal,
    `case` clause, `receive`/`fn` clause) — **plus `MacroPattern`**, the one kind a `mutate` result reaches
    *indirectly*: a whole-call mutation on a binding-escaping macro is **re-homed** from its `InPlace` into a
    `MacroPattern` (`Analyze.MatchPatterns.call_mutation_candidate/3`), which now copies the `InPlace`'s note
    through (it was silently dropped while `MacroPattern` had no `note` field). The **structural** tuples stay
    pairs and never carry a note: `PatternStructure.node_mutations/3` (swap/wildcard) and the
    `condition_replacements`/`return_replacements` locals — see the scope note below.

  * **All positions, no silent drop.** A `mutate` result doesn't know *where* it will land (the same node
    is offered in-place, lifted, in clauses, and re-homed), so threading the note only into `InPlace` would
    silently drop it whenever the node lifted/re-homed. Hence the note rides into every note-bearing candidate;
    emission reads it through `Transform.site_note/1` and passes it to `Site.in_place/7` / the new
    `Site.lifted_replace/7` (default `nil`, so every existing call is byte-identical). `site_note/1` matches on
    the **field** (`%{note: note}`), not on each struct: any kind carrying a `note` field yields it, and a kind
    without one (`PatternStructure`/`MatchPattern`/`GuardDrop`/`Return`/`RescueDrop`/`Drop`) never matches and
    reads `nil` — keeping the typed-struct discipline (no perpetually-nil field on a kind that can't carry one)
    *and* covering a new note-bearing kind the moment it gains the field (no clause to forget — the gap that
    dropped the re-homed `MacroPattern` note when `site_note` enumerated structs).

  * **Scope — `mutate` only, not the structural callbacks (yet).** **Status: still deferred.**
    `return_replacements`/`condition_replacements`/`pattern_mutations` build their own
    `{spec, mutated}` pairs and don't accept the struct, so a *structural*
    mutator can't note a mutant. Deliberate: the ask was the standard node-level API, and the structural
    callbacks return bare nodes by contract. The hook is there if needed (give those callbacks the
    `t:mutation/0` shape and route through `normalize_mutant/1`) — named here so the limitation is a
    decision, not a hidden gap. Tested via `Mutare.Test.NotedMutator` (`note_test`), which returns a noted
    `0`, a literal-`nil` replacement, and a bare `1` for `42`, proving the note across
    in-place/lifted/case positions and that nil replacements do not disappear; the **re-homed `MacroPattern`**
    note is proven via `Mutare.Test.UnpackMutator` on both the
    direct and piped binding-escaping-macro forms (`macro_pattern_test`); the bare-map rejection, the
    foreign-struct rejection, and the empty-note coercion on both paths (`note_test`, `hosted_test`).

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

A `defimpl` body is a **module body**, not just runtime code — and for a long time only
the latter was true of it. `Transform.transform_node/2` had a `defmodule` clause (plan the
statements → lift clause groups → emit) but none for `defimpl`, so a module-level `defimpl`
fell through to the expression path (`Analyze`'s clause above), whose defs are analyzed *in
place*: body selectors only. Identical two-clause guarded functions gave 8 lifted mutants in
a `defmodule` and **0** in a `defimpl` — no guard, head-literal, clause-drop or lifted mutant
inside any protocol implementation. Now `Resolve` stamps a genuine `Kernel.defimpl` with the
impl module it opens (`:mutare_impl_module`, `P.T` or the unresolved sentinel), and
`Transform` plans the stamped node's `do` block exactly like a `defmodule` body under that
module (so `:skip_lifting` names `P.T`; the dispatcher lands inside the impl module and
protocol dispatch reaches it). The stamp's *presence* is the Kernel gate: a displaced
`defimpl` (a DSL macro) carries none and keeps the expression path, as does a `defimpl`
nested in a scaffold (`for type <- … do defimpl … end`), which is analyzed whole with the
scaffold. `Behaviours` still leaves a `defimpl` unstamped (empty behaviour set), so an impl's
`:ok` tails are unit-returning like any non-callback's. `test/mutare/lift_test.exs`
(`Mutare.LiftDefimplTest`).

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
`tag_walk/3` (the lifted-guard path) used to be a blind descent that ran
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
group-wide), and each `Candidate.Lifted` materializes a mutant clause with that one
literal swapped — `def f(2)`, etc. The `Site` is a `:lifted` replace, identical in
shape to a guard's (`Site.lifted_replace/7`), with the literal mutator's name.

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
LHS pattern before/after), so only **emission** is new (`BindingEscapeEmit.match_site/3`): the
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
* **An outer pin cannot overlap a chained RHS binding.** In
  `{^x, y, q} = {x, z, q} = point`, the source snapshots the pre-match `x` for the pin before
  evaluating the right-associative chain. The tuple-export rewrite would evaluate `{x, z, q} =
  point` as its inner-case scrutinee first, so `^x` would incorrectly see the rebound value.
  `MatchPatterns` rejects structural candidates when an outer pinned name intersects the exact
  binding set of any RHS-chain pattern; the original statement remains untouched. Snapshotting
  pinned values through fresh temporaries and every selector branch would recover these rare
  candidates, but is not justified by their value.
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
  reachable. `Candidate.Delivery.selector_branch/1` picks `replacement` for a `CasePattern`,
  `mutated` for every other ordinary in-place candidate.

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
**Update (2026-09):** `fn` and `receive` now use per-clause delivery where the selector is
already bound; see *Anonymous functions: per-clause delivery* and *Receives: per-clause
delivery* below. The historical whole-construct account still describes their unbound-scope
fallbacks.

`case`/`receive`/`fn` clause patterns used to get *only* the structural families (swap/wildcard)
via the whole-construct selector. They now also get **literals** and **guards**, so a clause
pattern is mutated as fully as a function head. Two deliveries, picked by whether the construct
has a scrutinee to tuple:

- **`case` → tuple-the-scrutinee** (`Candidate.CaseClause`, `Transform.CaseClauseEmit.emit/3`).
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
mutare_unmatched)` clause (`unmatched_clause/2`) restores both — it attributes the ids and
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
The whole-construct selector records in its catch-all (`SelectorEmit.selector_case/3` /
`SelectorEmit.catch_all_clause/3`):
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

**Exact string patterns keep one retarget; binary-composing patterns keep both.** `StringLiteral`'s
runtime `""` / `"mutare"` pair probes a real empty-vs-non-empty property, but an ordinary exact
pattern (`def f("foo")`, `%{"foo" => value}`, a tuple/list element, or a clause pattern) usually
turns both into the same signal: exercising the original `"foo"` makes either replacement stop
matching. They are not semantically identical — another clause or a map containing one replacement
can distinguish them — so this is deliberate redundancy suppression, not an equivalence claim.
`Tag.tag_pattern_targets/4` now threads an `:exact | :binary_composition` context. Exact positions
keep the sentinel as the canonical low-collision retarget and fall back to empty when the sentinel
is the source or map-key collision filtering removed it. Descendants of written `<>` / `<<>>`
pattern syntax keep both: emptying a prefix/segment may remove a structural constraint, whereas the
sentinel keeps a non-empty constraint and changes its content. The boundary is intentionally
conservative — even singleton `<<"foo">>` keeps both — and lives in the positional tagger rather
than `StringLiteral`, preserving the rule that a mutator produces candidates without choosing its
delivery context. Runtime and guard offers are unchanged.

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
  `Candidate.Lifted`, `Candidate.Drop`), shared by in-place and lifted alike.
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
  building the selector `case` and dispatcher) mostly stays in `Transform`, with the shared
  selector mechanics factored into `SelectorEmit` (`claim_items/4` owns the id/site claim).

### Transform IR — typed candidate variants + plan structs `[refactor, done]`
The earlier `%Candidate{}` was one struct that stored `context` *and* its two
consequences (`kind`, `operation`) as separate fields, so the type admitted
illegal combinations (a `:clause_drop` claiming to be `:in_place`/`:replace`)
that only discipline kept out — and every **guard** candidate carried a full
copy of the clause group with its one guard pre-swapped (`mutated_clauses`), N
near-identical copies for N guard mutants. Both are fixed:
- **One struct per legal kind.** `Candidate.{InPlace,Lifted,Drop}` (and the other
  variants) — the
  `context`/`kind`/`operation` triple is gone; the variant *is* the kind, and the
  matching `Site` constructor is chosen by pattern-matching the struct in
  `Candidate.Delivery.site/3`, alongside the selector-branch axis. The delivery
  classifier is deliberately narrower: `classify_node_candidates/1` covers only
  candidates attached to AST-node metadata and the four routes the main node
  dispatcher handles. Lifted candidates come from `FunctionPlan`; hosted candidates
  come from their separate metadata key and `HostedEmit`. Neither is advertised as a
  node-local route, and crossing that boundary raises. Illegal states can't be built.
- **The clause group is stored once.** `FunctionPlan` holds a single *tagged*
  clause group (every mutatable guard operator marked with a unique
  `meta[:mutare_tag]`, the tag counter threaded across clauses so tags are
  group-unique); each `Candidate.Lifted` carries only its `tag` + replacement.
  `FunctionPlan.mutated_clause/2` reconstructs the single affected clause on
  demand (`replace_tag/3` for a guard; a `Candidate.Drop` yields a `:drop`
  sentinel, the original gated off rather than deleted). Leftover tags on
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

### Analyze handlers call the descent statically `[done]`
The handler submodules that re-enter the walk (`ClausePatterns`, `Conditions`, `DefClause`,
`MatchPatterns`, `QuoteEscape`, `Routed`) used to take the descent as an injected first argument —
`Analyze` passed itself as `__MODULE__`, and the handlers called `descent.annotate/2` and so on —
so that the module graph stayed acyclic. That bought nothing: a runtime call cycle between
modules costs Elixir nothing (only a macro or struct use creates a compile-time edge, and none
exists here), and no check enforced acyclicity. It did cost: every re-entry was a variable-module
call on the transform's hot path (no static dispatch, invisible to Dialyzer), threaded through ~26
handler clauses. The handlers now alias `Mutare.Transform.Analyze` and call `annotate/2` /
`pattern/2` / `descend/3` / `recurse/3` directly; the Analyze ↔ handler cycle is the thin
child→parent call the split entry above already accepted for `ClausePatterns`.

### Function lifting (M2): sharp edges `[various]`
- **Recursion bounces through the dispatcher.** A self-call inside a lifted copy
  hits the public dispatcher and re-dispatches — correct, LCO survives, but ~2×
  the calls. Self-call redirection (point self-calls at the active copy) is
  deferred (open question / v2).
- **Error provenance shifts.** `FunctionClauseError` now raises from the lifted
  private fn (`__mutare_f_1_g3`), so its message names that, not `f`.
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
  `non_consecutive_only/3` drops those names from the non-consecutive warning set
  and `metaprogrammed_signatures/3` warns them instead — exactly one accurate
  warning, never both (a `defdelegate` sibling outranks both as the diagnosis —
  see the defdelegate note below). **Deferred:** the cases we *can* lift
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

  `metaprogrammed_heads/1` (via the shared `collect_heads/3` walk) collects every
  head `def`/`defp`'d *inside* a non-clause statement, and `plan_clause_group/5`
  refuses to lift any clause group it blocks — falling back to in-place exactly
  like the non-consecutive case. Not silent — `warn_metaprogrammed/2` logs once
  per blocked signature (it is not user-fixable; the generated clauses are
  intentional). Note the sibling functions `reason_atom/1` / `reason_phrase/1` in
  the same file were *already* safe via the non-consecutive path (their two
  literal clauses straddle the `for`), so this closes the remaining hole where
  the literal clauses happen to be consecutive.

  **Precision (originally name-only, now `{name, arity}` + macro-body pruning).**
  The first version keyed the set by bare *name* and walked into everything,
  which the Phoenix sweep showed over-blocks badly: `Phoenix.Presence`'s
  `defmacro __using__` quotes `def list(topic)` boilerplate destined for
  *other* modules, and the name-only match cost the module's own,
  metaprogramming-free `list/2`/`get_by_key/3`
  their lifting — a pattern endemic to `use`-heavy libraries (injected
  convenience wrappers deliberately reuse short names at a shifted arity,
  prepending `__MODULE__`). Two refinements, each argued against the
  false-negative direction (an under-block is a *baseline crash*, an over-block
  only costs mutants):

  - **Exact `{name, arity}` keying.** An in-argument `unquote` doesn't obscure
    arity (`def code(unquote(atom))` is arity 1 whatever `atom` is), so most
    generated heads block only their own arity. `unquote_splicing` is the
    exception — arity unknowable — and degrades that head to a bare-name
    wildcard (blocked at every arity). A fully dynamic name
    (`def unquote(name)(…)`) stays statically invisible and contributes
    nothing — the accepted residual hole (unchanged from the name-only version,
    which also saw `:error` there; the only static alternative is blocking the
    whole module). Defaults contribute only the full arity (an explicit def at
    an implied lower arity is a compile error beside the defaults).

    The **whole-head** spelling `def unquote(head)` belongs in that hole too, and
    used not to: `name_arity/1` read the head as a function called `unquote/1`,
    so two such clauses grouped and were *lifted* — splicing a variable into the
    dispatcher head and the head expression (`Enum.at(heads, 0)`) into a lifted
    clause's pattern, which does not compile. It now returns `:error`, which also
    keeps `Mutare.Transform.UnitReturns` from reading a generated data-returning
    sibling as absent. Cost: such a body no longer draws return-tail mutants
    (it is an `{:other}` statement now, not a clause) — the conservative side.

    A **qualified** definition (`Kernel.def f(:c)`, or an aliased `K.def` — a
    definition macro may be invoked qualified) was invisible for a duller
    reason: `collect_heads/3` matched the form *atom*, and a qualified call's
    form is a `{:., …}` tuple. The run of bare clauses beside it therefore
    looked complete and was lifted, and the dispatcher shadowed the qualified
    clause — `f(:c)` raised `FunctionClauseError` at **baseline**, no mutant
    active. `definition_form/1` now reads the head through the qualifier (via
    the resolver, so an alias works too). Only the *definition* forms are read
    that way: missing a qualified `Kernel.defmacro` boundary merely over-blocks,
    and this file's standing rule is that over-blocking costs mutants where
    under-blocking crashes.
  - **`defmacro`/`defmacrop` bodies are pruned as scope boundaries** (alongside
    `defmodule`/`defimpl`/`defprotocol`). A macro's body runs — with the one
    exception recorded below — only where the macro is *invoked*, and no
    invocation can target the
    defining module's own top level: a local macro call in the module body does
    not compile ("undefined function" — the module's own macros don't exist
    until it is compiled, the same principle that forbids `use __MODULE__` and
    `@before_compile __MODULE__`, whose docs require the callback to live in a
    separate module), and a generated `def` inside a function body is illegal
    ("cannot invoke def inside function"). All three routes verified
    empirically before widening — the initial design was a timid
    `__using__`/`__before_compile__`-only whitelist until the "local
    def-generating macro invoked later in the same module body" counterexample
    turned out not to compile at all.

    The exception, found by a codex review and **left open** here: a
    *definition-time* `unquote`. `defmacro g, do: unquote((def f(:bad), do:
    :pending; :ok))` — and the same shape in a plain `def` body — is evaluated
    while *this* module compiles, not where the macro is invoked, so it really
    does add a clause. The walk cannot see it (a clause chunk's interior is never
    scanned, and a macro body is pruned), so a literal run beside it still looks
    complete, gets lifted, and the dispatcher shadows it: a baseline
    `FunctionClauseError`. Closing it needs `collect_heads/3` to carry a quote
    depth so it can scan the live parts of a macro body while still pruning the
    quoted ones — a real change to the lifting path, for a shape no ordinary code
    writes. `Mutare.Transform.UnitReturns` *does* account for it
    (`nesting_kind/2`), because a miss there costs mutants rather than crashing.

    Bare module-level `quote`s (outside any
    macro definition) are **not** pruned: `Module.eval_quoted(__MODULE__, …)`
    really does inject their defs into the module (verified), and scanning them
    is what keeps that shape safe.

  The same walk feeds the defdelegate sibling set (next note), so both nets got
  both refinements at once. Regression pins in lift_test: arity-scoped recovery,
  `__using__`/`__before_compile__`/plain-macro recovery (with compiled-baseline
  checks), the splicing wildcard, and the `for`-generated def staying blocked.

  **Accepted limitation — the scan sees only literal def nodes in *this*
  module's source.** A def manufactured by an opaque module-level macro call is
  invisible by construction: `use SomeLib`, an imported or remote def-generating
  macro (`defmemo f(x) do … end`, a decorator, `SomeLib.defroutes(...)`) is just
  a call node with no `def` AST inside it, and the code that generates the defs
  lives in another module entirely. If such a macro adds clauses to a signature
  the module *also* defines literally, lifting shadows them — the same
  baseline-crash class every note above guards against — and no static scan of
  this file can know. Peering in would mean expanding arbitrary third-party
  macros at scan time, which is exactly what the transform architecture refuses
  to do generally (the `Uses` pre-pass expands the one `use` idiom, best-effort,
  for *name resolution* — not as a general expansion engine). Two things keep
  this acceptable: the failure mode is loud (a baseline crash before any mutant
  runs, never a silently wrong verdict), and it has not been observed on a real
  target (Phoenix's sweep hit the visible-`for` and `defdelegate` shapes, both
  now handled).

  Why the common injection patterns don't produce the hazard: shadowing needs
  the invisible clause to sit *after* the lifted run (the defdelegate crash was
  a delegate *below* the lifted clause, shadowed by the wrapper left in that
  clause's position). `use`-injected clauses land at the top of the module —
  *before* any literal siblings — so they keep matching first and the wrapper
  only catches what already fell through to the user's clauses, which the
  dispatcher replicates faithfully. And `defoverridable` injections are
  *replaced* by a user def, not merged as clauses (the `super` path is handled —
  see "`super` in a lifted body"). The residually hazardous direction is
  clauses injected after everything — `@before_compile` hooks — which no
  expansion Mutare owns can see. That is also why the once-considered
  mitigation of feeding the `Uses` pre-pass expansion through this head scan
  buys little: it could only see `__using__` injections (which are lift-safe by
  position, and which good practice keeps to imports/delegation anyway), not
  the `@before_compile` direction that could actually bite. Not pursued.
- **A `defdelegate` sibling blocks lifting for its exact name/arity** `[done]`.
  Same shadowing hazard, third source — and the most idiomatic one: "handle one
  special case explicitly, delegate the rest." A `defdelegate` expands to a plain
  `def` clause of its head's name/arity, but its AST form is `:defdelegate`,
  invisible to `clause_signature/1`'s grouping, so a literal sibling run looks
  complete and would lift — leaving an *unconditional* public wrapper that
  shadows the delegate clause and crashes the delegate's inputs at **baseline**,
  no mutant active. The real break, `Phoenix.Controller`:

  ```elixir
  def assign(conn, fun) when is_function(fun, 1), do: assign(conn, fun.(conn.assigns))
  defdelegate assign(conn, assigns), to: Plug.Conn, as: :merge_assigns
  # lifted, the wrapper matched every call — assign(conn, %{...}) raised
  # FunctionClauseError on the unmutated baseline, aborting the whole run
  ```

  `delegated_heads/1` collects `defdelegate` heads via the same shared
  `collect_heads/3` walk the metaprogrammed set uses (same scope-boundary
  pruning, same exact-`{name, arity}`-with-splicing-wildcard keying — see the
  precision passage in the previous note), and `plan_clause_group/5` refuses to
  lift a matching group; a same-named function at another arity keeps its
  lifted mutants, and a delegate quoted inside `__using__` boilerplate blocks
  nothing (it targets the using module). Defaults contribute only the full
  arity (an explicit def at an implied lower arity is a compile error anyway —
  "def f/1 conflicts with defaults from f/2"). Warned by `warn_delegated/2`;
  delegation outranks the other two diagnoses when several apply (it's the
  most specific message, and no remedy restores lifting while the delegate
  exists). **Deferred:** recognizing the delegate as a *real* sibling clause —
  grouping it into the run so the function lifts with the delegate as an extra
  dispatched clause — would recover the forfeited guard/clause-drop mutants for
  the explicit clauses (the safety net only degrades the crash to in-place).
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
  falls back to in-place via `metaprogrammed_heads` and the `for` heads route
  through `:scaffold` — both bodies mutate in place, independently (no dispatcher, so
  no shadowing). Still **out of scope**: mutating inside `unquote(expr)` here
  (a compile-time scaffold splice, unlike a runtime `quote` unquote), and lifting any of these
  (head-pattern/guard/clause-drop mutants).
- **Private names** are `<prefix><name>_<arity>_g<group>`. The
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
watcher (a quoted AST owned by `Mutare.Sandbox.Command.Invocation.watcher_ast/0`, rendered
into the bootstrap by `Mutare.Sandbox`) spawns a process that `System.halt(124)`s
after the deadline. The BEAM preempts a looping process, so the watcher always runs (even
on a tight infinite loop — confirmed); if the suite finishes first the watcher
dies with the VM; exit 124 ⇒ timed out. This replaced an earlier Port + `kill`/
`ps` process-group approach (Unix-only, and `Port.close` alone did *not* kill a
hung beam — SIGTERM is trapped). Caveat: a hang that wedges *every* scheduler in
a non-yielding NIF could starve the watcher — not reachable from mutating Elixir
source, so not handled.

False-timeout guard, round one: the cap floor is 10 s. The baseline is measured
uncontended but mutants run under parallel-worker contention, so a tight cap was
false-timing-out slow-but-finite mutants (a non-deterministic false kill, seen in
testing). A true infinite loop overruns any floor, so the generous floor keeps
correctness without missing real hangs.

Round two — the floor wasn't enough at scale: on phoenix_live_view (16 workers,
16.5 s baseline → 49.5 s cap) mutants in `phoenix_component.ex` recorded
`:timeout` that ran 11.9 s and **survived** uncontended. Two compounding effects:
16 concurrent `mix test` BEAMs each wanting every scheduler blow well past the
3.0 multiplier, and the false kills concentrate on *survivors* — a kill exits at
its first failing test (`--max-failures 1`), while a survivor must run its whole
selected set, so the slowest honest runs are exactly the broadly-covered
survivors, the product's entire output. Hence `:confirm_timeouts` (default on): a
streamed `:timeout` is provisional and re-run sequentially after the stream
drains; only a repeat overrun records `:timeout` (mechanics in the
`Mutare.Runner` moduledoc). The asymmetry that decides it: an over-generous
verdict path costs one extra cap per *genuine* hang (rare); a tight one silently
corrupts the score. Two companions attack the cause so few honest runs reach the
confirmation pass at all: the derived cap scales by half the concurrent lanes
(`min(workers, sites)`), and the default `:workers` dropped to half the
schedulers, later clamped at 4 (see "Parallel workers"). Per-covering-file caps
would be tighter and more precise — still a refinement.

### Parallel workers (M4 done) `[refine]`
The per-mutant phase runs `:workers` mutants concurrently (default: **half**
`System.schedulers_online/0`, **clamped to 1..4**) via `Task.async_stream` in the
shared sandbox. Concurrent `mix test` in one sandbox contends on mix's build lock
("Waiting for lock…") and, since each spawns a full BEAM, oversubscribes CPU — a
real overhead (4 workers gave ~2.4× in a spike; >4× observed at 16). The default
was schedulers_online originally; it was halved after the oversubscription
manufactured false `:timeout` kills on phoenix_live_view (see "Timeouts" round
two) — each worker's BEAM already uses every scheduler, so a worker per scheduler
ran ~N× oversubscribed for no throughput gain. Round three recognized the halving
had the wrong *shape*: a parallel suite already scales with the machine on its
own, so extra workers only pay while they fill the utilization gaps one run
leaves open — BEAM boot/app start (serial, and a big fraction of a kill's runtime
given `--max-failures 1` early exit), IO/DB waits, and the reduced intra-run
parallelism of small selected-test sets. The workers needed for that is a small
*constant*, not a fraction of the cores — so `schedulers/2` was fine on a laptop
(4–8 cores → 2–4 workers) yet still delivered all the observed pathology on big
machines (16 cores → 8, 32 → 16: the false-timeout epidemic, ~1 GB per mutant
BEAM compounding into OOM `:sigkilled`s, and each false `:timeout` now costing a
full sequential cap-length confirmation re-run). Hence the clamp at 4 — the
evidence-backed knee (~2.4× at 4, diminishing hard after) — which changes nothing
for ≤ 8 schedulers and only reins in many-core boxes. Suites with poor
parallelism genuinely benefit from more; that's what `--workers` is for, and
too-low-default (slower) is a far kinder failure than too-high (false timeouts,
OOM kills, confirmation tails). A future root fix — trimming each worker BEAM to
`schedulers/workers` via `+S` — would remove the oversubscription itself, but it
changes the target suite's own async concurrency semantics, too invasive for a
default. The lock contention itself is measured and negligible — per-worker
isolation (`MIX_BUILD_PATH` or full source copies) was not pursued; see
"Per-worker `MIX_BUILD_PATH` vs the shared sandbox build" above. (Disabling the
lock outright was tried and abandoned — see "Bypassing Mix's build lock per
mutant" above.)

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
entry into the compile `Invocation.mix` (concatenated with `CompilerOptions.compiler_env/0`) closes
that gap; it also overrides any *stale ambient* `MIX_TEST_PARTITION` the harness
happened to inherit.

**Delivery is just the existing `:env` plumbing.** `Mutare.Sandbox.Command.Invocation.mix/4`
already appends an `:env` list onto every sandbox `mix`; the partition entry rides
that, threaded through `timed_mix`/`timed_test` (new trailing `env` params,
defaulted `[]` for back-compat) and through `Baseline.run/3`/`CoverageProbe.run/4`.
`Command` stays partition-agnostic — the env is opaque extra to it; the runner owns
all "partition" semantics. Inert by default: `partition_env` `nil` → `Partitions`
`:disabled` → `[]` everywhere → byte-identical to the old behaviour.

Because the partition entry is *appended* to that base env, a `:partition_env`
naming a key Mutare itself sets (`MIX_ENV`, `MUTARE_ACTIVE_MUTANT`, the coverage
vars…) would land a duplicate key in the `System.cmd` env list, where Erlang's
resolution is unspecified — silently clobbering, say, `MIX_ENV`. So `Options`
rejects such a name up front, validated against the authoritative
`Invocation.reserved_env_names/0` (originally a hand-kept list sourced from the env
accessors; it drifted once regardless — see "The reserved env set is derived from the
one env builder" — and is now derived from the builder itself). The same validator also requires portable-POSIX env-name syntax,
for the same "fail at config time" reason: `System.cmd(env: ...)` *raises* on a `=` or
a NUL byte in a key, so a name like `"A=B"` used to pass `Options.new/1` and then blow
up deep inside the first sandbox `mix`. The pool-size↔`max_concurrency` coupling the non-blocking
checkout depends on is the other thing a future refactor could break silently —
flagged with an `INVARIANT:` comment at the `Task.async_stream` call.

**Distinct from the parked "shard mutants across machines" idea** (the early-exit
note below): that wanted to *split mutants* across runners and rejected
`--partitions` as the wrong axis (it filters *test files*). This is the opposite —
we run the *whole* selected suite per mutant and only want each concurrent worker
on its own DB. Reusing `MIX_TEST_PARTITION` here is purely to name a slot the user's
config already understands, not to filter tests.

### The reserved env set is derived from the one env builder `[done]`

The partition validator above depends on `Invocation.reserved_env_names/0` being complete,
and its first version was a list kept *next to* the code that set the variables — sourced
from the same accessors, which felt drift-proof. It wasn't: the compile invocation set
`ERL_COMPILER_OPTIONS` through `CompilerOptions.compiler_env/0` and nobody had added that
key to the list, so a `:partition_env` of `"ERL_COMPILER_OPTIONS"` passed validation and
produced the duplicate-key clobber the validator exists to prevent. The fix at the time
was to add the entry; the structural fix is that there is no longer a list to add to.

Every variable Mutare sets on a sandbox `mix` is now emitted by one builder,
`Invocation.environment/2`, from **named run options** (`:cap`, `:compile_cap`, `:compile`,
`:coverage`, `:max_heap_mb`, `:partition`); the raw `env:` passthrough on `Invocation.mix/4`
is gone, so a caller cannot set a variable the builder doesn't know about.
`reserved_env_names/0` is then the builder's key set with every option armed — a new run
option is reserved the moment it exists. The `:partition` entry is the one key outside the
set, by design: its name *is* the user's `:partition_env`, appended last, and the set is
what that name is checked against. The five `++` sites that used to assemble per-run-kind
env lists (compile, baseline, probe, per-mutant, and the base) collapsed into the callers
naming their options, and `RunCtx` carries `max_heap_mb` rather than a precomputed env
fragment.

Same commit, same seam: the exit codes moved out of `Command` into the leaf
`Command.Exit`. `Command.outcome/1` was documented as the single decoder, yet the compile
and the coverage probe compared `status == Command.timeout_exit()` by hand — not wrongly,
since they aren't mutant runs and the mutant-verdict vocabulary doesn't fit them, but the
"single decoder" claim was false. `Exit` now offers the two readings those runs actually
need (`success?/1`, `timed_out?/1`) beside `decode/1`, all over the same constants. It also
removes the `Command` ↔ `Invocation` cycle: the watcher ASTs embedded the codes by calling
back into `Command`, while `Command.timed_test` called `Invocation.timed_mix`. Both now
read the leaf.

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

### Early stop after N survivors (`--max-survivors`) `[done]`
`--max-mutants` caps the *candidate sites* the schema keeps (the first N in source
order) — a "test the first N mutants" smoke run, but rarely what you want, since the
product is **survivors** and you can't predict how many sites you must grind through to
surface a few. `--max-survivors N` (`:max_survivors`, `Mutare.Options`) instead stops
the per-mutant run once N **survivors** (`:survived`) have been found — the
iterate-and-fix workflow: get a handful of concrete test gaps, go fix them, re-run.

It is a **runner-loop** cap, deliberately *not* a `Mutare.Schema` one like
`--max-mutants`: every mutant is still discovered and compiled into the one metamutant
(ids stay stable; a poison rebuild is unaffected); only the *run* halts early. So the
two compose — `--max-mutants` narrows what's built, `--max-survivors` shortens what's
run — and a future re-run with `--line`/`--since` still sees the same id space.

**Survivors only**, by design: `:no_coverage` is "not killed" but it's a coverage gap
found *without running anything* (it would flood the count and stop the run almost
immediately, defeating the point); `:timeout`/`:atom_exhausted` are kills;
`:ignored`/`:poisoned`/`:harness_error` reached no verdict. The lone "unkilled,
actionable, cost-a-run-to-find" status is `:survived` (`Runner.survivor_count/1`).

**Deterministic stop.** The per-mutant stream is already consumed `ordered: true`
(`Task.async_stream`), so `Runner.collect_until_survivors/2` threads a survivor counter
through an `Enum.reduce_while` and halts at the **Nth survivor in source order** —
independent of which worker finished first. The reported survivors are therefore exactly
the first N, reproducibly, not "whatever N happened to land first". A `nil` cap drains
the whole stream as before (the function's first clause), so the common path is
unchanged.

**The cost of halting a `Task.async_stream`:** it shuts down its in-flight tasks. A
handful of mutants *past* the trigger (the concurrent lanes ahead of the ordered
consumer) may have already run — their results are discarded (so the count stays exactly
N), and their `mix test` OS processes are orphaned. Accepted as cheap: the orphans are
bounded by the per-mutant timeout watcher, and the default sandbox is a throwaway dir
(cleanup is best-effort `rm_rf` anyway). The live reporter's running "survived" tally may
likewise flash a couple above N before the halt — cosmetic; the final report is exactly N.

*Both costs were later paid off* — see "Early stop: survivor cap and time budget", where the
halt becomes a **drain** (nothing is killed, nothing orphaned) and reporting moves to the ordered
collector (a discarded straggler is never reported, so the live tally can no longer overshoot).

**Early stop is exploratory, not CI.** A stopped run tested only a *prefix* of the
mutants, so its score is over a partial denominator (and artificially low — we stopped
*because* survivors piled up). The run is flagged `stopped_early`; on that flag the runner
**skips the harness-error abort guard** (aborting would throw away the very survivors the
user asked for), and `Mix.Tasks.Mutare` **skips the CI gates** (`--min-score`,
`--max-no-coverage`, `--fail-on-poisoned`, `--fail-on-harness-error`), printing a note
to **stderr** (so a machine report on stdout stays clean, like the ineffective-ignore
warnings) naming the survivor count, `M of T` evaluated, and that the gates were skipped.

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

> **OUTDATED defer label (deferred-work audit, 2026-06-30):** the same shape exists
> for *any* compile-time-executed code in a test script (compile-time `@attr`
> expressions, `EEx`/`use`-time calls, custom route DSLs), but the implemented
> discriminator is already general: any test-script compile error is covered.
> There is no remaining work for those cases under the compile-once invariant.
> If a target compiled lib modules *lazily* per-run (it doesn't today; the
> metamutant is built once), a lib compile error here could be a real kill we
> conservatively keep as a harness error. Acceptable while "lib compiles once"
> holds.

### A self-erasing boot crash is a *named*, harder-retried harness error `[done]`
Surfaced on a full-stack Phoenix/LiveView/Ecto target at `--workers 16`: 6–13 of 39
covered mutants landed as `:harness_error` *non-deterministically* (the score wobbled
run-to-run), every one with an identical, unactionable cause. `--workers 1` → **0**;
`--workers 16 --harness-retries 4` → **0** (three consecutive runs). So it is pure
worker contention, not the mutations — but the engine surfaced it badly, and *that*
was the bug.

Root cause: under contention a supervised child (a `Repo`/Postgrex or `Redix`
connection — `econnrefused`) fails to start and takes down the node *during boot*.
Elixir's CLI exit-reporter then tries to print the dying task's error to
`:standard_error`, but the node is already tearing down so that IO device is gone →
`(ArgumentError) the device does not exist`; the reporter tries to print *that* to
`:standard_error` → same failure → the emulator terminates with
`{badarg,[{io,put_chars,[standard_error,…]}]}`, **replacing** the original reason. The
exit code is off-contract (`:harness_error`, correct), but the *cause is erased*: the
slogan binary is truncated and the captured output carries only the secondary
"terminating during boot … standard_error … device does not exist" banner. So the old
warning's "see the mutant's output to diagnose the sandbox" led nowhere.

Two engine-side fixes, both confined to the modules that already own these contracts:

- **Recognise + name it** (`Output.boot_failure?/1` → the `:boot_failure` outcome). A
  third `outcome/2` output-refinement of the otherwise-`:harness_error` bucket, but —
  unlike `:suite_compile_error`/`:atom_exhausted`, which flip to *kills* — this one
  keeps the **harness-error verdict** (`Runner.status_for(:boot_failure)` →
  `:harness_error`, out of the score). It is purely an internal label that never
  reaches `Result.status`/the reporters; its only jobs are messaging and retries. The
  signature requires *both* markers (`terminating during boot` **and** `standard_error`),
  because the `standard_error` recursion is exactly what makes the cause unrecoverable —
  a boot crash that left a real error wouldn't have recursed on a torn-down device.
  Kills take precedence in the `cond` (fail-safe: a detected mutation is never masked),
  though the cases don't co-occur (a node dead at boot never compiled a test script nor
  filled the atom table).
- **Retry it harder, independently** (`Runner.@boot_failure_retries`, 4 extra attempts,
  on top of and *separate from* `:harness_retries`, with a short jittered backoff so the
  retry doesn't re-collide with the same boot stampede). The two budgets are threaded as
  separate counters decremented by the *current* run's outcome, so a boot failure that
  later degrades to a plain harness error still draws its general retries, and vice
  versa. Sized to the field-proven figure (1 initial + 4 = 5 attempts cleared it). The
  warning is replaced with a *specific, actionable* one: it names the cause, says the
  output can't help, and names the real *contention* levers (`--workers`,
  `--partition-db`). It deliberately does **not** name `--harness-retries`: a
  `:boot_failure` is retried only from `@boot_failure_retries`, so raising that knob
  would not retry it more — naming it would send the user to a lever that does nothing
  for this outcome.

Also bumped the default `:harness_retries` 1 → 2 — a gentle, broadly-justified hedge for
*other* transient harness errors (the boot case has its own larger budget). Inert on a
healthy run: only an actual `:harness_error`/`:boot_failure` outcome ever retries, so
normal-run timing is unchanged.

Not done (the issue's optional fourth direction): persisting the sandbox
`erl_crash.dump` next to the result. The dump's slogan is itself the same truncated,
self-erased binary (5/5 inspected dumps were identical), so it adds nothing over the
specific warning; skipped to keep the change focused. The launch-stagger idea (offset
worker starts so N nodes don't boot in lockstep) is also deferred — the boot-retry
jitter addresses re-collision on retry, and `--workers`/`--partition-db` remain the
documented fixes for the initial stampede.

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
- **attribution** `{{label, id}}` — `label` is resolved per process by `label_of/1`
  (the running process, then each in its caller chain) → maps to the test *file* →
  per-file selection. Two signals back it:
  1. the process's own `$process_label` — `Process.set_label({case, name})`, which
     **ExUnit's runner only sets on Elixir 1.19+**. Read OTP-tolerantly:
     `:proc_lib.get_label/1` on OTP 27+, the proc-dict `:"$process_label"` via
     `Process.info(:dictionary)` on OTP 26 and earlier. A `Task` records its
     `$callers` chain, so a task started from a test resolves to the test's label
     this way too. (`get_label/1` reads the same dictionary key cross-process, so the
     OTP split is only about *how* the dict is read.)
  2. an ExUnit frame on the process's `current_stacktrace` (`stacktrace_label/1`) —
     the fallback when (1) yields nothing. This is **the only signal on Elixir 1.18**,
     whose runner leaves the test process unlabeled: a direct test then has no label
     and no caller chain, but its own `:"test …"`/`:"property …"` function is on the
     stack (`test_label/2`); a `setup_all` carries the `{module, __ex_unit__, 2}`
     frame on *every* version (it runs unlabeled, but synchronously inside the test
     module's generated `__ex_unit__/2` dispatch). `Process.info/2` reads the stack
     cross-process, so an awaiting `Task`'s caller is recovered the same way — which
     is what keeps Task/`setup_all` attribution working on 1.18. Module granularity ==
     file granularity, all selection needs. *Soundness* (setup_all): this attributes
     a `setup_all`-covered id to its **own** module's file — capturing every test that
     observes the mutation through the `setup_all` **context** (module-scoped — the
     common case), but NOT a different module's test that fails only because the
     `setup_all` had a cross-module global side effect (a seeded DB, a
     `:persistent_term`) — that id, run only against its own file, could survive. That
     is the same cross-file-dependency limitation `:coverage` already has for ordinary
     attribution (`:full` is the escape hatch); the change is that `setup_all` no
     longer gets the *extra* whole-suite conservatism the unlabeled bucket used to
     give it. See "setup_all stacktrace recovery" below.
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
missing capture tables. A valid empty dump means no emitted mutant ran; see
"Empty coverage is a valid focused-run result" below. The rule
throughout: never skip on doubt — run everything rather than silently drop a mutant
from the score's denominator.

**Per-test-case selection — `:tests`, the default (done).** The `{module, name}`
process label the attribution already resolves carries *two* keys, and file-granular
selection only ever used the `module` half (→ file). The `name` half — the runnable
ExUnit test name — is now kept too, so a mutant can run `mix test <file> --only
test:<name>` and execute just the covering test cases instead of the whole covering
file. `:test_selection` became a three-rung ladder, `:full` ⊃ `:coverage` ⊃ `:tests`,
with `:tests` the default (`--per-file` selects `:coverage`, the opt-out; `--full`
stays the whole-suite escape hatch).

Mechanism. The recorder writes the name key to `@test_table` (`{{mod, name, id}}`)
**only when the name is runnable** — a `test `/`doctest `/`property ` prefix
(`filterable_name?/1`, the exact space-bearing rule `test_label/2` already keys on).
A labeled-but-not-runnable hit (`setup_all` → `:setup_all`; an `on_exit` closure →
`-test …`) instead records its id to `@wholefile_table`. The dump gains `by_test`
(`%{id => [name]}`) and `wholefile` (`[id]`); both default empty in `Coverage`, so an
old dump degrades `:tests` to `:coverage`. `CoverageProbe` computes `:tests` by
*refining* the `:coverage` outcome: a non-empty file selection narrows to
`files ++ --only test:<name>…` **iff** the id is not in `wholefile` and has ≥1
runnable name; everything else (`:no_coverage`, the unlabeled/degraded whole-suite
`{:run, []}`, an id with any non-runnable attribution, or an empty name set) keeps the
`:coverage` decision verbatim. So all of `:coverage`'s conservatism is inherited; the
narrowing only *subtracts* sibling tests where every covering attribution is a
concrete test.

Two safety properties, both load-bearing:
- **No false kill.** `mix test --only test:<name>` with zero matches exits `1`, which
  our exit-code contract decodes as a *harness error* (not the `--exit-status 101`
  kill code) — so a bad narrowing could only drop a mutant from the score, never
  invent a kill. And it can't even do that: every emitted name ran in one of the
  included files during the probe, so at least one test always matches and the
  "no test executed" path is never hit. Names travel as argv list elements
  (`["--only", "test:test foo bar"]`), so spaces need no quoting; `ExUnit.Filters`
  splits `test:<name>` on the first `:`, so a name with a colon survives; matching is
  exact string equality on the `:test` tag (which *is* `test.name`, the label's second
  element — set by ExUnit's runner via `Process.set_label({case, name})`), so no
  over-matching.
- **The false-*survivor* it trades for (why it's opt-out-able, not forced).**
  File-granularity ran a whole file, so a **sibling test that kills indirectly** — one
  that fails because a covering test in the same `async: false` module ran the mutated
  line and left corrupt shared state, without the sibling touching the line itself —
  still ran. `:tests` drops that sibling. On a stateful, cross-test-dependent suite
  this can turn a kill into a false survivor. It's the default on the assumption that
  suites are predominantly `async: true` with per-test-isolated state (where a sibling
  that never runs the line cannot observe the mutation, so nothing is lost); the
  `setup_all`/`on_exit` → `wholefile` carve-out already keeps the module-scoped-context
  cases whole-file, so the residual exposure is specifically test-body-to-test-body
  shared state. `--per-file` (`:coverage`) is the documented opt-out for those suites,
  `--full` the fully conservative one. Considered gating narrowing to `async: true`
  modules only (the `:async` tag isn't in the process label, so the dependency-free
  recorder can't see it without more machinery) — deferred; the opt-out covers it.

**setup_all stacktrace recovery (done).** Originally `setup_all` coverage went
straight to the unlabeled bucket → whole suite, on the premise that an unlabeled,
caller-less process carries *no* recoverable owner. That premise is too strong:
`setup_all` is dispatched **synchronously inside the test module's generated
`__ex_unit__(:setup_all, _)`**, so a `{module, __ex_unit__, 2}` frame is on the
recording process's own `current_stacktrace`. The stacktrace fallback of `label_of/1`
(`stacktrace_label/1`) reads it and attributes the id to that module's file — and
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
(it runs in the labeled test process, or — on Elixir 1.18 — carries its own
`__ex_unit__/2` frame); a `setup_all` whose work runs in a `Task` it **awaits** is now
recovered too (the cross-process stack read finds the `__ex_unit__/2` frame on the
blocked-in-`await` caller — consistent with a synchronous `setup_all`), while a
**fire-and-forget** `Task` whose caller has already returned/exited still falls to
unlabeled → whole suite. Cost is only paid when the label is absent (i.e. exactly the
`setup_all`/`on_exit`/spawn cases, plus every test on Elixir 1.18), never on the
labeled-test hot path. Found while investigating why `setup_all`-heavy suites ran the
whole suite for so many ids; considered (and rejected) rewriting test files to label
these processes — too much blast radius for the trust anchor, and stacktrace recovery
gets `setup_all` for free without touching tests. `on_exit` stays unrecoverable
(detached runner-loop process, TCO erases the callback frame).

**Elixir 1.18 has no test-process label (done).** ExUnit's runner only began calling
`Process.set_label({case, name})` in **Elixir 1.19**; on 1.18 the test process is
unlabeled, so tier 1 misses for *every* hit — a direct test then has no label, no
caller chain, and (unlike `setup_all`) no `__ex_unit__/2` frame, so **all** coverage
fell to the unlabeled bucket → every mutant ran the whole suite (per-file selection
silently disabled). The fix reuses the same stacktrace mechanism: `stacktrace_label/1`
also recognises a `{module, :"test …"/:"property …", _, _}` test-body frame
(`test_label/2`, keyed on the space-bearing ExUnit naming convention), and `label_of/1`
runs it for the caller chain too (`Process.info/2` reads a stack cross-process), so an
awaited `Task`'s caller is recovered as well. Only surfaces when the **sandbox** runs
1.18 (so the bug hid on a 1.19+ dev machine and only reddened CI's 1.18 lane); the
regression tests drive `:mutare_cov.hit/1` from a raw-spawned (label-less) process
directly, catching it on any host Elixir.

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

### Empty coverage is a valid focused-run result `[fixed]`

Selective emission means a `--line` / `--since` run can emit mutants only in code
the suite never reaches. The probe then succeeds with an empty aggregate. Treating
that as capture failure forced `:run_all`, ran every uncovered mutant, and reported
false survivors that entered the score denominator. Adding one covered mutant to
the selection made the problem disappear, because the aggregate was no longer empty.

Probe health now comes from its exit status and a successfully read dump, independently
of hit count. The helper must read all five capture tables before writing coverage;
if any table is missing, it writes `{:error, {:missing_coverage_table, table}}`.
Previously it substituted an empty list for a missing table, making failed capture
indistinguishable from zero hits. The error overwrites any earlier dump (essential
when umbrella callbacks share a dump path), and the reader logs it and retains the
run-all fallback. A valid empty dump yields `:no_coverage` for every selected mutant
in all three selection modes, with no mutant subprocesses and no score denominator.

The regression fixture tests the same uncovered function alone, in a full run, and
alongside a covered function. Separate tests remove each capture table, verify an
earlier valid dump is invalidated, and exercise the real runner's failure fallback.

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
  reused the one channel that was already threaded. **Follow-up now done:** the context-taking
  structural callbacks receive the same `:opts` value (`return_replacements/2`,
  `condition_replacements/2`, `pattern_mutations/3`). The context-free base arities remain
  unchanged; a structural mutator that needs configuration implements the context arity. The
  change is backward-compatible: existing `mutate/2` clauses match `%{pipe_mode: m}`, which
  still matches a map that *also* has `:opts`; existing structural callbacks that match
  `%{behaviours: b}` also match the widened context map.

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
discovery via `Mutator.Dispatch.implementing/3` (`return_replacements`/`condition_replacements`) and
`RescueType` enablement via `Spec.find/2`, `PatternStructure`, `FunctionPlan`,
`Site.replace`) reads `spec.module`/`spec.name`/`spec.opts`. The CLI's `--mutators` CSV can't
express opts (strings only) — configured mutators are a `.mutare.exs`/`Mutare.run/2` feature.

Dispatch precedence: `mutate/2` is an override, not an additive second producer. If a module
exports `mutate/2`, `Mutator.Dispatch.mutations/3` calls it and does **not** also call
`mutate/1`; otherwise it falls back to `mutate/1`. A mutator that wants composition calls its
own one-arity helper from `mutate/2` and combines the results explicitly. This removes the
non-obvious duplicate-production footgun from the public contract while preserving the few
built-ins that need mixed context-free/context-aware production (`Arithmetic`, `Numeric`,
`OperandSwap`) as local, visible composition.

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
DFS-counter prewalk (`Resolve.NodeIds.stamp/1`) run at the end of its `annotate/2` pre-pass — *before*
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
deliberate exception is `Mutare.Sandbox.Command.Invocation`'s own `… |> Kernel.++(env)` — that is *first-party
harness* code in a module whose scope Mutare controls, not generated-into-the-target code, so a
plain qualifier (or even a bare one) is collision-free there.

Side effect on overlap: emitting `Elixir.Kernel.==` (vs bare `a == b`) changes *both* the callee's
module and fun, so the `equivalent?` footprint is now a nid-less `[mod, fun]` **list** —
*non-covering* rather than the old *covering-but-inert* `.`-dot-node. No behavioural change (it
pruned nothing before and prunes nothing now), but it makes `ModeSwap→AtomLiteral` the **sole**
covering footprint. See "Overlap resolution" above.

### Argument marks — a mutator asks the transform to mark positions `[done]`
*(The user-facing `:skip_arguments` option and the `SkipArguments` mixin this section mentions were
retired in favour of `call_routes` + `argument_marks` — see "Call routing: `:skip`, `:raw`,
`:interior`, keyed refinements" below. The facility itself is unchanged.)*

A general facility: a mutator declares argument positions it wants *marked* (`argument_marks/1`), the
transform stamps those positions during resolution, and the mutator reads the marks back at
`mutate/2` and decides. The transform stays domain-agnostic — it knows only "position P of call C
carries label L" — while the *meaning* lives in the mutator. `Mutare.Transform.Resolve.ArgumentMarks`
is the facility; `Mutare.Mutators.IntegerLiteral` is its flagship user (the timeout table); the mechanism is
timeout-agnostic (a custom mutator marking any function is exercised in `transform_duration_test.exs`).

**The motivating use — timeout literals.** `IntegerLiteral`/`AtomLiteral` mark the duration args of
`Process.sleep`, `send_after`, `GenServer.call`/`stop`, `Task.await`/`async_stream`/`yield_many`, …
with the `:timeout` label and decline there. A duration literal is left unmutated for two reasons,
the second the non-obvious one:

- **Survivor noise.** No test pins an exact millisecond count, so `sleep(100) → 101` just survives.
- **It can mint *false kills*.** A *shrunk* timeout (`… → 0`, the `zero` variant; or `n − 1`) can
  trip a real `:timeout` or a timing-dependent failure — which Mutare scores as a **kill**. So
  leaving these in doesn't only pad the denominator with unkillable survivors; it can inflate the
  *numerator* with kills that measure scheduler timing, not a test assertion. That numerator
  argument is what tips this from "nice-to-have" to "worth building".

**Why a facility, not a transform table.** The first cut hard-coded a timeout table *in the transform*
(an `Analyze.Durations` module) and held the literal back in the descent. That baked a very specific
piece of domain knowledge into the core. The rewrite inverts it: the transform provides generic
*marking* and the knowledge lives in the mutator that owns it. Same behaviour, right home — and any
mutator can now say "don't perturb the literal here."

Mechanism:

- **Where it stamps.** In the **resolve pre-pass** (`Resolve`), not Analyze — because that pass
  already resolves each call's `{module, fun, arity}` (through the same alias/import machinery as call
  matching — aliased / imported / `:timer`-atom forms for free, a shadowing `alias MyApp.Task`
  correctly not matched) and stamps `meta`. `ArgumentMarks.stamp/5` puts `meta[:mutare_marks]` (a
  label set) on the marked argument *value* node; the offer paths read it back into `context.marks`;
  `Mutator.marked?/2` is the reader. Analyze stays generic — it lost all the duration-specific code
  the first cut carried.
- **Both offer paths surface the marks.** A node meets the mutators via *two* paths, and each must
  enrich the context the same way or the contract goes inconsistent: the in-place body offer
  (`Attach.offer/4`) and the **tag-based guard/pattern dispatch** (`Mutare.Transform.Tag`, which offers
  guard/pattern nodes separately, without an in-place `case`). A guard-safe marked call
  (`is_integer(t)` with a `:skip_arguments`/`argument_marks` mark on arg 0) is stamped by `stamp/5` in
  the resolve pass regardless of where it sits, so a `when` guard's marked literal must be declined
  just like a body call's. Both paths run the node's marks through the one `Meta.context_with_marks/2`
  (empty-set short-circuit so unmarked nodes — the vast majority — pay nothing), so there is a single
  definition of "surface a node's marks" and the guard path can't silently drift from the body path.
  (The tag path's synthesized negative-literal value node carries no marks — `stamp/5` only marks call
  arguments, never head/clause patterns — so its enrichment is a harmless no-op, kept uniform anyway.)
- **Arity-keyed.** Positions are keyed by *effective* arity (a piped receiver is arg 0). Load-bearing
  for the keyword case: `Task.async_stream/3` (fun form) and `/5` (MFA form) end in an options list,
  but `/4` — `(enum, module, function, args)` — ends in the callback `args` *list*, so a literal
  `[timeout: 5_000]` there is ordinary data and must still mutate. And `Task.yield_many/2`, whose 2nd
  arg is *either* a bare `timeout()` *or* options, is marked in both forms (a bare literal via the
  positional index, `:timeout` via the option key) without colliding.
- **Mark the value node, nothing else.** Only the specific value node is stamped, never an enclosing
  container. So a keyword option's *list* still gets its own mutations (`List` collapsing an explicit
  `[opts] → []`) exactly as on an off-table call — the mark held back only the value. And a *computed*
  duration (`base * 2`, `@default_timeout`) is safe for free: the mark lands on the whole arg node,
  which `IntegerLiteral` doesn't fire on, while the unmarked sub-literal `2` mutates normally. No
  "which nested literal is the duration" ambiguity to resolve.
- **Value-aware reaction.** The mark says "timeout position"; the *mutator* decides what that means.
  `IntegerLiteral` skips (every integer there is a duration). `AtomLiteral` skips **only `:infinity`** — a
  *sibling* atom at the same position is not a duration, so `GenServer.stop(s, :normal, :infinity)`
  still mutates `:normal` and `Task.shutdown(t, :brutal_kill)` still mutates `:brutal_kill`. Reading
  the value, not just the mark, is why.
- **Opt-in per label.** A mark is a label a mutator *chose* to react to, not a blanket suppression: a
  mutator that didn't request the label still fires at the position. Both value families declare the
  `:timeout` table (via `IntegerLiteral.timeout_marks/0`, which `AtomLiteral` reuses) so the marks survive
  either family being disabled.

**Configurable marks.** `argument_marks/1` receives the mutator instance's config, so a mutator can
fold options-driven positions into its declarations. **Every value-literal family** exposes a
`:skip_arguments` option (`[{module, function, arity, positions}]`) via
`Mutator.skip_arguments_marks/1`, read back with `Mutator.self_marked?/1`. Because the wiring is
identical boilerplate, `use Mutare.Mutator.SkipArguments` injects the `argument_marks/1` +
`mutate/2`-gate pair — one line for `BitstringLiteral`/`TupleLiteral`/`List`/… (and any custom
value family). `IntegerLiteral`/`AtomLiteral` don't use it: their `mutate/2` also gates on the
built-in `:timeout`/`:infinity` marks, so they wire the two calls by hand. `ConventionAtom` is
deliberately *excluded* — its `:ok`↔`:error` swaps are high-signal, the opposite of the opaque
literals the option is for. Four properties worth calling out, each a fix from review:

- **Per-instance, and namespaced against the public label space.** The marks are labeled with an
  internal self-mark that `ArgumentMarks.build/1` *relabels to a reserved, per-instance
  `Mutator.self_label/1`* — the `__mutare_self__` prefix plus the spec's (`:as`-resolved) name — and
  `self_marked?/1` reads `context.name` (added by dispatch) back through the same `self_label/1`. Two
  properties fall out of that one label. **Per-instance:** two `:as` copies with different
  `:skip_arguments` don't collide, because their names differ (a shared module-name label would have
  made both skip every configured position). **Reserved:** relabeling to the *bare* name would put
  the self-mark in the same flat atom space as public labels, so a shared/custom mark whose label
  happened to equal a family's report name (a custom `:integer`, or an `:as` rename to `:timeout`
  while `IntegerLiteral`/`AtomLiteral` emit `:timeout` marks) would be misread as *that family's own* skip
  request and suppress it at a position it never configured — the namespaced label keeps the two
  spaces disjoint. (Marking with a *shared* label — e.g. `:timeout` — is still available via
  `argument_marks_from/2` for the cross-family built-ins; those deliberately share a label, which is
  exactly why the *self* mark must not.)
- **Effective-index-0 works piped — including the parenless RHS.** A configured
  `{Kernel, :to_string, 1, [0]}` suppresses `to_string(123)` *and* `123 |> to_string()`. The
  piped-receiver path resolves the RHS through `Resolve`'s own import/`Kernel` resolution
  (`bare_module_key`), not just `resolved_call/1` (which doesn't recover a bare `Kernel` call) — so the
  effective-index-0 contract holds for piped receivers the same as written calls. The *parenless*
  spelling `123 |> to_string` (or `1000 |> sleep`) is covered too, and it's a genuinely different AST
  shape: Sourceror gives a parenless bare-name RHS `nil` args — `{fun, meta, nil}`, the same shape a
  bare *variable* has — where a parenthesized `to_string()` gets `[]`. The generic resolve `walk/2`
  deliberately leaves `{fun, meta, nil}` untouched (it can't tell a call from a variable outside pipe
  position), so both the `receiver_funs` pre-filter (`ArgumentMarks.rhs_fun/1`) and `Resolve.pipe_target/2`
  handle the `nil` shape specifically *as a pipe RHS* — where it is unambiguously a 0-visible-arg call —
  and `pipe_target/2` stamps the RHS import itself before keying, so an imported bare name resolves there
  too. (A *remote* parenless RHS `1000 |> Process.sleep` already carries `[]`, so only the bare-local
  form needed the `nil` case.)
- **Keyword marks reach a piped options list.** An arity-1 API whose only argument is options can be
  spelled with the list as the pipe receiver — `[timeout: 500] |> MyApp.configure()`. The receiver
  path originally handled only *positional index-0* labels (and the `receiver_funs` pre-filter
  admitted only functions with an index-0 mark), so a configured `{:keyword, :timeout}` covered the
  written `MyApp.configure(timeout: 500)` but left the piped spelling mutating — a silently
  ineffective `:skip_arguments`. The observation that closed it: the piped receiver is *also* the
  call's trailing argument exactly when the effective arity is 1, so `stamp_receiver/5` applies the
  entry's keyword marks to the receiver in that one case (option-value stamping via the same
  `stamp_options` the written form uses — container-preserving as always), and the pre-filter admits
  arity-1 keyword-marked functions. Higher arities are deliberately untouched: there the receiver is
  a leading argument, never the options list.
- **A whole import of a project module resolves via the declaration itself.** `Imports.stamp`
  resolves a whole `import Mod` by *reflection*, so a mark naming a target-project module
  (`skip_arguments: [{MyApp.Cache, :put, 3, [2]}]` under `import MyApp.Cache; put(c, :k, 300)`)
  used to fall through: the module isn't loadable in the Mutare process, `bare_module_key`
  returned `nil`, and the configured argument mutated — while the remote and selective-import
  forms worked (a selective `only:` resolves straight from the source). The fix mirrors the
  known-macro registry fallback (`Resolve.registered_macro_module/3`): when reflection can't
  resolve a bare call, `marked_import_module/3` probes the marks registry
  (`ArgumentMarks.declares?/4`) among the *whole*-imported modules in scope — the declaration
  asserts the module provides `fun/arity`, and the compile-unambiguity rule makes the bare call
  unambiguously it. A wrong declaration errs only in the safe direction (a mark can at most
  suppress a mutant, never mis-resolve a mutation), and the piped forms come along for free
  (`pipe_target/2` keys through the same `bare_module_key`).
- **Fails loud on a bad index.** A one-based typo like `[3]` for an arity-3 call (valid effective
  indices `0..2`) raises at startup rather than silently marking nothing.

Adding a stdlib timeout is still a pure data edit to the built-in table; giving a new value family
the option is a single `use Mutare.Mutator.SkipArguments`.

Where the timeout use sits relative to the other positive exclusions: it is the **first
signal-quality** one — every prior exclusion (struct fields, `for` options, `:uniq`, quoted data) is a
*compile-safety* exclusion, and the equivalent-sibling drops are *provable* equivalences. This is
neither: `sleep(100) → 0` is not equivalent, it is a *judgment* that the mutant is near-unkillable and
score-corrupting. Deliberately **not configurable** (`# mutare:ignore` only *adds* suppressions, and
the site never exists to re-enable); the table is curated, not exhaustive — trivially extended by a
row. `receive … after N ->` needs no entry (the timeout sits in the `->` clause's *pattern* position,
which the walk never offers). A duration piped as the *receiver* (`1000 |> Process.sleep()`, effective
index 0, not a visible arg) is covered too: `ArgumentMarks.stamp_receiver/3` marks the pipe's left
side from the `|>` clause when the RHS marks index 0, behind a `receiver_funs` pre-filter so ordinary
pipes pay nothing. (This was a documented gap under the first cut and became cheap to close once
marking was a general facility — a mutator marks a position and the pipe LHS is just another node that
can carry the stamp.)

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
  `Candidate.InPlace` — so the existing selector + `PipeEmit.hoist` machinery delivers
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
- **`Site.original_form`/`mutated_form` are `:__block__` for literal sites** (they
  come from `elem(node, 0)`, the AST node's head tag), which is fine — reports use
  the rendered `original_code`/`mutated_code` (`1 → 2`), not the form tag; the form
  fields are only used by tests/lookups that key on a real operator.

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
- **`integer_call`** (`Mutare.Mutators.IntegerCall`) — `mod`↔`floor_div` (the two halves of
  floored division) and `is_even`↔`is_odd`; a Collection-style arity-blind remote
  rename keyed on `{[:Integer], fun}`. Named `integer_call` (beside `Mutare.Mutators.IntegerLiteral`,
  the `integer` value family) the way `string_call` sits beside `string`.

**The non-obvious part: a guard-legal *qualified* macro broke the old "guard-safety
is free" assumption.** The expanded-set note above argued no built-in can poison a
guard because each is either guard-legal (constants, `and`/`or`) *or* parser-
forbidden in guards (`Enum`/`List` calls, `++`). `Integer.is_even`/`is_odd` are the
first family members that are **guard-legal qualified remote macros** — they *do*
appear in `when` clauses (the source's existing `require Integer` carries to the
lifted copy, so `is_odd` compiles). That exposed a latent bug in the guard lift
path: the guard tagger used a context-free `Macro.postwalk`, which visits
the `{:__aliases__, _, [:Integer]}` node sitting in the call's *form* position and
offered it to `AliasLiteral` — minting a `when Mutare.Mutant.is_even(n)` mutant that
is **illegal in a guard** ("cannot invoke remote function … inside a guard") and
poisons the single build. The in-place analyzer never hit this because its `recurse`
descends a node's *args* only, never its *form*, keeping a remote call's module
opaque (the same reason `:erlang.foo()`'s module is untouched). The fix makes the
guard tagger mirror that: `Mutare.Transform.Tag.tag_walk` is now an explicit post-order walk
(args only, never form), so the whole call node and its arguments are still offered
(the `is_even`→`is_odd` swap, a literal argument) but the module alias is not. This
is *positive* compile-safety — fixing it at the classifier rather than leaning on
poison recovery, per the project's standing preference. (`:math`'s atom module never
reaches a guard — `:math` calls aren't guard-legal — so only the `Integer` path
needed the fix, but the fix is general: any guard-safe qualified macro is now safe.)

### DefaultDrop generalized — drop a trailing arg back to *any* implicit default `[done]`
`default_drop` began as a nil-only family: drop the trailing fallback of a lookup
(`Map.get/3`→`/2`, …) and skip a literal-`nil` default as equivalent. The mechanic —
pop the trailing arg, keep the rest — is identical for *any* call whose trailing
argument is optional with a known implicit default, so the family now covers a second
vein of **refinement defaults**: `Float.round`/`ceil`/`floor` precision (implicit `0`),
`Integer.to_string`/`to_charlist`/`parse`/`digits`/`undigits` base (`10`), `Enum.join`
separator (`""`), `String.pad_leading`/`pad_trailing` fill (`" "`), and
`String.trim`/`trim_leading`/`trim_trailing` to-trim string (no value form). Each asks
the same "is this refinement tested?" question the nil-lookups ask of the not-found
path. No new plumbing — it stays one `mutate/2` over the pipe-aware
`Helpers.lookup_resolved_arity` path; only the `@rules` value and the skip guard changed.

The non-obvious parts:

- **The equivalence guard generalized from `nil_literal?/1` to a per-rule list.** Each
  rule value is now `{base_fun, equivalent_defaults}` where `equivalent_defaults` lists
  the literal value(s) that *equal* the implicit default — dropping one is a no-op, so it
  is skipped (`Map.get(m, k, nil)`, `Float.round(x, 0)`, `Integer.to_string(n, 10)`,
  `Enum.join(xs, "")`, `String.pad_leading(s, n, " ")`). The check is `AST.literal_value/1`
  (the inverse of `AST.literal/1`) `in` that list, which subsumes the old `nil` case
  (`nil` is an atom literal) and reduces to "never skip" for an **empty** list. Two cases
  use the empty list deliberately: a `_lazy` fallback (a fun is never a literal — already
  always-drop) and `String.trim`'s to-trim string, because `String.trim(s, " ")` trims
  *only* spaces, not all whitespace, so it is genuinely **not** equivalent to
  `String.trim(s)` (the pad fill `" "` *is* equivalent — the asymmetry is real, not an
  oversight).
- **Escaped-string defaults are a documented false-keep.** The comparison reads a
  string literal's value, but Sourceror keeps escapes un-decoded, so an exotic spelling of
  a whitespace default — `String.pad_leading(s, n, "\s")`, where `"\s"` *is* a space and so
  equals the implicit `" "` — isn't recognised as equivalent and yields a phantom mutant.
  This errs toward *emitting* an equivalent mutant (a false survivor), never toward
  silently dropping a real one — the safe direction, consistent with BitstringSpec's
  literal-equivalence handling, and not worth a re-parse for the rare escaped whitespace.
- **Two deliberate overlaps with sibling families, producing distinct mutants on one
  call.** `call_removal` removes `String.trim`/`pad_leading`/`pad_trailing` outright (→ the
  raw input) where this drops only the refining arg (→ default behaviour); `numeric`
  renames `Float.ceil ↔ Float.floor` (keeping precision) orthogonal to this precision drop.
  These are different code, so neither is a redundant sibling for `Overlap` to prune.
- **`Enum.map_join` is excluded on purpose.** Its joiner is the *middle* argument
  (`map_join(enum, joiner \\ "", mapper)`), so dropping it is a non-trailing drop the
  pop-the-last mechanic can't express cleanly — left out the way `reverse/2` is.

### PeriodBoundary — calendar start/end direction swap `[done]`
A Collection/StringCall-style directional rename for the date/time **period boundaries**:
`Date.beginning_of_month ↔ end_of_month`, `Date.beginning_of_week ↔ end_of_week`,
`NaiveDateTime.beginning_of_day ↔ end_of_day` — the calendar twin of `List.first ↔ last`
and `String.starts_with? ↔ ends_with?`. Both ends return the same type and a different
boundary, so it is a plain arity-blind `Helpers.swap_call/2` family (`mutate/1`), one new
`@registry` entry; "does the code use the *start* or the *end* of the period?" is the
off-by-a-boundary bug at a reporting-window / billing-cycle edge.

Settled here:

- **The actual stdlib inventory ≠ the obvious guess — verified, not remembered.** The
  initial sketch listed `Date.beginning_of_year`/`end_of_year` and `DateTime.beginning_of_day`,
  *neither of which exists*; reflecting `__info__(:functions)` on `Date`/`DateTime`/
  `NaiveDateTime`/`Time` showed the real set is the three pairs above (and only `Date`'s
  week pair carries the optional `/2` `starting_on`). A wrong rename would have poisoned the
  single build, so the table is grounded in reflection.
- **Arity-blind is safe because the pair's arities match.** `beginning_of_week`/`end_of_week`
  both have `/1` and `/2`, and the `/2` `starting_on` is symmetric, so the rename carries it
  along unchanged (`beginning_of_week(d, :sunday)` → `end_of_week(d, :sunday)`). Mutating the
  weekday itself is `ModeSwap`'s orthogonal axis; mutating the day amount, `Literal`'s.
- **Deliberate triple overlap on one call, all distinct mutants.** `CallRemoval` already
  *removes* these same boundary normalizers (→ the original timestamp) and `ModeSwap` swaps
  the `starting_on` weekday; this flips the boundary direction. Three families, three
  independent axes (remove / which-weekday / which-end) — different code, so none is a
  redundant sibling for `Overlap` to prune, the same way `CollectionArity` and `CallRemoval`
  both fire on `Enum.sort(xs)`.

### CallRemoval — Map/Keyword/List key & element strippers `[done]`
Extended `call_removal`'s arity-agnostic `@removable` set with the collection strippers it
was missing: `Map.delete`/`drop`/`take`, `Keyword.delete`/`drop`/`take`, and
`List.delete`/`delete_at`/`keydelete`. Each takes the collection as its first argument and
returns the same kind of collection, so the existing first-arg-return mechanic (or
`Function.identity()` in a pipe) drops them with no new code — just table rows.

Two judgment calls worth recording:

- **Why these count as "strips," not the excluded `map`/`filter`/`reduce`.** The family's
  charter excludes calls that "change *which* data is present" as too coarse/noisy. A
  named-key `delete`/`drop` *does* change which data is present — but precisely and
  type-preservingly (one or a few named keys, map→map), which is the `Enum.uniq`/`dedup`
  side of the line (included), not the predicate-driven `filter` side (a comparator could
  drop nearly everything — excluded). The signal is sharp: "does removing *this* key matter
  to any test?" with a one-key diff, not a wholesale data change.
- **`take` is a projection, handled like `String.slice`.** `Map.take(m, ks)`/`Keyword.take`
  return a *subset*, so removal returns the *superset* (the whole collection) — exactly the
  inversion `String.slice` already does (return a part; removal returns the whole). Same
  type, plausibly interchangeable for code that only reads the projected keys, so it earns
  the same "is the projection exercised?" probe.

`Keyword.delete` has a deprecated `/3` (key+value) form alongside `/2`; arity-agnostic
removal covers both (the keyword list is the first arg either way), so no arity gate is
needed. No new family/registry entry — `CallRemoval`'s moduledoc is the source of truth.

### KeywordDelete — duplicate-key deletion breadth `[done]`
A Keyword-only complementary swap `Keyword.delete ↔ delete_first` — "does any test depend
on whether *all* matching entries are removed or only the *first*?", the untested edge of a
keyword list with a repeated key (accumulated/merged options). The Keyword-only sibling of
`MapKeyword`: a `Map` key is unique, so there is no breadth distinction and no
`Map.delete_first`. A new one-pair family (the codebase already has single-rule families —
`StringByte`, `MapSet`).

The non-obvious bit — **it can't use the arity-blind `swap_call/2` the other rename
families use.** `Keyword.delete` has both `/2` and the deprecated `/3` (key+value) form, but
`Keyword.delete_first` exists *only at `/2`*; an arity-blind rename would rewrite a
`delete/3` to a nonexistent `delete_first/3` and poison the single build. So it is keyed on
**effective arity** via the pipe-aware `Helpers.lookup_resolved_arity` (`mutate/2`, like
`CollectionArity`), gated to `/2` — which also makes the piped `kw |> Keyword.delete(k)`
swap correctly (effective arity 2) while leaving `kw |> Keyword.delete(k, v)` (effective 3)
alone. Verified `delete_first/2` is the only arity by reflection, the same discipline #2/#3
used.

Deliberately co-fires with the `Keyword.delete` *removal* just added to `CallRemoval` (#3):
`Keyword.delete(kw, k)` gets both a removal (→ `kw`) and a breadth swap (→ `delete_first`),
two distinct mutants; the `/3` form gets only the (arity-agnostic) removal, never a swap.

### OperandSwap — operand-order swap for non-commutative operators `[done]`
The operand-order sibling of the operator-swap families (`Arithmetic`/`List`): it
**keeps the operator and transposes the operands** of a non-commutative binary
operator — `a - b`→`b - a`, plus `/`, `**`, `<>`, `++`, `--`, and the `div`/`rem`
call forms. It catches the symmetric bug class the operator swaps miss: right
operator, wrong argument order (`elapsed = finish - start` written `start - finish`).
On by default; a plain node→node in-place mutation, so it needs no new `Site`
constructor and no `Transform` change — `mutate/1` returns the transposed node and
the existing in-place/lift routing delivers it.

The infix operators (`-`/`/`/`**`/`<>`/`++`/`--`) are always arity 2 written infix, so the
context-free helper handles them arity-blind. `div`/`rem` are bare `Kernel` *calls*, so they
go through the pipe-aware `mutate/2` gated on **effective arity 2** — the same bare-`Kernel`
safeguard `Numeric` uses (confirms the builtin over a same-named user `div/3`), which also
guarantees the node holds *both* operands.

**Piped stages transpose via a capture** (was: skipped). A pipe supplies the effective first
operand from *outside* the stage node, so a plain rebuild can't reach it — and a pipe expresses
an operator as its `Kernel` call form (`foo |> Kernel.++(bar)`). Both are handled by wrapping
the swapped call in a one-argument capture invoked on the piped value —
`foo |> (&Kernel.++(bar, &1)).()`, where the `.()` receives the piped value and binds it to
`&1`, so the operands end up transposed (`Kernel.++(bar, foo)`). Everything resolvable through
`Calls` is covered — the operator `Kernel.op` forms, `Kernel.div`/`rem`, and the remote calls —
keyed by `{module, fun}` in a `@piped_swaps` table (the `@remote_swaps` set plus the `[:Kernel]`
operator/`div`/`rem` forms). Three sharp edges: (1) a *bare* `Kernel` call (`x |> div(b)`) carries
no import stamp, so `Calls` leaves it unresolved and it stays skipped — only the explicit
`Kernel.div` form transposes (this differs from `Arithmetic`'s `div`↔`rem` *rename*, which keeps
the arg list and needs no capture); (2) the `same?` no-op guard can't run — the piped operand
isn't in the node — so an identical-operand pipe yields a harmless equivalent transpose rather
than being pruned; (3) `:piped` offers are runtime-only (set by `Analyze`'s `:|>` clause), so the
capture — an expression, not guard-legal — is never lifted into a `when`.

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
`# mutare:ignore[return_value]`. `clause_drop`, the *other* structural built-in,
is registered on the same terms — see "clause_drop was always-on and unregistered"
below for why it stopped being the exception.

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
targeted (`Transform.annotate_returns/3` → `annotate_block_returns/4`): the `:do`
tail via `attach_return/3`, and each clause body tail via `map_clauses/3` (the same
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
    lifting change. The walker navigated the analyzed (operator candidates already
    attached) and raw (clean, for the diff `original`) trees in lockstep, bailing to
    the leaf clause on any structural surprise — *superseded*: the surprise was real
    (the `if`-condition hoist), and the walk now reads the raw tree alone and delivers
    by node identity; see "Return tails are delivered by node identity". The condition
    of an `if`/`unless` is left untouched (wrapping it is the binding-escape
    machinery's job, not the return walk's).

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
`condition_replacements/1`, discovered by `Mutare.Mutator.Dispatch.implementing/3` (the shared "enabled
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
clause, for bodies) and `Transform.Tag.tag_walk` (the matching guard clause) —
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
so ids stay contiguous (the same property as `Overlap`/`gate_candidates`). Four new cases
span the two descents — `Transform.Analyze` for bodies and `Transform.Tag` for `when`
guards (`!`/`&&`/`||` are guard-illegal, so the guard side handles only `not` and
`and`/`or`). Cases 1, 2, and 4 offer a node and drop one specific mutation; case 3 and
the `not in` precedent do not offer the redundant inner node:

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

2. **A guard `x in <collection literal>`** — a mutation that *empties* the RHS
   collection makes the guard fail, which is the same result as `Conditional` replacing
   the whole `in` node with `false`. This covers the guard-legal standard shapes — `List`
   (`→ []`), `WordListLiteral` (`→ ~w()`), and `CharlistLiteral` (`→ ~c""`) — through
   `AST.empty_collection_literal?/1` in `Transform.Tag`. The drop is per mutation, so a
   word/charlist sigil keeps its non-empty sentinel and loses only its empty sibling.

   **Correction: body suppression was unsound.** The first implementation applied the
   same rule in `Transform.Analyze` and exposed `Mutator.empty_collection?/1` so custom
   builders such as `MapSet.new([])` could participate. But `effectful() in []` still
   evaluates `effectful()`, whereas replacing the whole expression with `false` does not.
   That is exactly the purity-dependent equivalence this section otherwise refuses to
   assume. Bodies now keep every empty-RHS mutation (including standard lists, maps, and
   sigils); only guards suppress standard empty literals. Guards admit no observable side
   effects, and a guard error is a failed guard, so the equivalence is sound there. The
   custom callback was removed rather than generalized: non-standard builder calls are not
   guard-legal, and a general mutator-supplied equivalence hook would put parent-context
   reasoning on the wrong side of the transform boundary.

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
   in `Analyze`, `offer_without_constant/4` in `Tag`) — the same per-mutation filtering
   shape as the guard-only empty-collection drop. `&&`/`||` are body-only; the guard twin
   handles `and`/`or`. It composes down a chain:
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
(there is no `mutate/1` path, like `ModeSwap`): `mutations/3` runs `mutate/2` when
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
Per the "don't emit obviously-equivalent mutations" mitigation, the
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

### Regex anchor swaps and *positional* flag tracking

The regex **anchor-swap** family (`^`↔`\A`, `$`↔`\z`/`\Z`) is the first mutation
whose *equivalence* turns on a regex **option flag** — specifically `m`
(multiline). Without `/m`, `^`≡`\A` and `$`≡`\Z` for **every** input (both anchor
the subject ends), so emitting the swap there would be a *guaranteed*-equivalent
mutant — strictly worse than the `+`/`*` / `/u` cases above (those are
*context*-dependent killable; this one no input can ever kill). So the swap **must**
be gated on the flag, which makes "is `m` active?" a precondition we have to answer
correctly — not a nicety. (`$`↔`\z` is the exception: `\z` is the strict end, so it
differs from `$` regardless of `/m` — always emitted, a suspected-equivalent without
`/m` like `+`/`*`.)

The catch: `m` is not one value for the whole pattern. An **inline modifier** sets
it *positionally* — `(?m)` turns it on for the rest of its enclosing group, `(?m:…)`
for one group, `(?-m)` off — so `^a(?m)$` has a non-multiline `^` and a multiline
`$`. A single `?m in modifiers` boolean is therefore **wrong**, and — worse — a naive
"pattern contains `(?m`" heuristic would flip the global flag and emit the very
guaranteed-equivalent mutants the gate exists to prevent (at every anchor *outside*
the `(?m)`'s scope). The only safe answer is a *correct* positional one; a partial
one is a regression, not a partial win. (Under-detecting — treating an inline `(?m)`
as absent — fails **safe**: a missed killable swap, never a wrong emission. That's
why the flag-only first cut was already sound; this is the principled completion.)

`Mutare.Mutators.RegexLiteral.Flags` is that answer, built as a **reusable, flag-
agnostic** primitive — and the payoff is already concrete: the **dotall dot** mutation
(`.` → `(?s:.)` where `s` is off, `(?-s:.)` where it's on — flip the dot's
newline-matching the non-equivalent way) is the *second* consumer, reading `?s` from
the **same** `Flags.active?/2` with no new infrastructure (it shares the one flag-aware
`mode_walk/6`, since anchors and the dot have identical walk state — `acc` + the flag
stack — so they are one walk, not the fourth). A caseless mutation reading `i`, a flag
*add* gated on relevance, … all plug into the same resolver. The model is a **stack of
flag sets**, baseline (the sigil modifiers) at the bottom, threaded through a
left-to-right walk by `open/2`/`close/1`:

- **scoped** `(?flags:…)` → **push** a frame (current ∪ adds ∖ removes); the matching
  `)` pops it (the change is confined to the group).
- **bare** `(?flags)` → **mutate the top frame in place**, push nothing. Because that
  frame is popped at the enclosing group's `)`, the change automatically applies to
  "the rest of the enclosing group" (PCRE's exact rule) and is inherited by nested
  groups (each pushes a copy of the *mutated* frame). At the top level there's no
  enclosing `)`, so it runs to the pattern's end.
- **ordinary** group / lookaround / named capture / `(?:` → push a copy, no flag
  change. Recursion/backref atoms (`(?R)`, `(?P=n)`) self-balance through the same
  push/pop, harmless. **Comments** `(?#…)` are swallowed whole (body isn't regex, so a
  `^` inside it is *not* an anchor — a real correctness point, not just flags).

Why a **separate** primitive and not a 7th param threaded through `scan/6`: the flag
state is genuinely cross-cutting (every future positional mutator needs it), and
`open/2`/`close/1` are pure and **independently unit-tested** (`regex_flags_test.exs`
feeds opener strings and asserts the stack) — the kind of fragile, subtle logic the
project keeps in one tested home. The flag-aware `mode_walk/6` threads the stack in
place of the old `multiline?` boolean and reads `Flags.active?(stack, ?m)` at each
anchor (and `?s` at each dot). The
classifier whitelists *exactly* the inline-flag letters the engine accepts both scoped
(`(?L:…)`) and unset (`(?-L)`) — `i m s x` plus uppercase `J U X` — so a *named* group
`(?P<n>…)` is never misread as a flag set (the `P` collision that would corrupt scoping),
while a real flag like `X` is still parsed (else `(?-Xm)` mis-splits and leaves `m`
wrongly active). Sigil-only/unsupported-inline letters (`u`, `n`) are deliberately *out*:
a `(?u…)` doesn't compile here anyway, so treating it as an ordinary group only ever
affects a non-compiling original.

**`x`-mode comments and `\Q…\E` — two inert spans the walk must respect.** Both are
regions where regex syntax does *not* apply, and an early version that ignored them was
unsound in the same way: it processed their bytes as syntax. Under `x` (extended), an
unescaped `#` starts a comment to end-of-line; a `\Q…\E` quotes a literal span. In
*both*, a `^`/`$`/`.` is inert (mutating it yields a guaranteed-equivalent) **and** — the
sharper bug — a `(`/`(?…)` would push a phantom frame onto the flag stack, leaking the
mode past the real `)` and mis-gating a *real* later anchor (e.g. `(?m:\Q(\E^a)^b`
emitting a bogus `\A` on the non-multiline `^b`). So the earlier "x-mode can only *miss*
a flag context, never invent one — fails safe" claim was **wrong**: a quoted/commented
`(` actively invents one.

**The shared `x`-aware reader closes this for *every* pass.** `inert_spans/2` is a single
positional walk (escape/class tracking + the `Flags` scope stack, so `x` is read
positionally) that records every inert byte range — each `\Q…\E` span and each `x`-mode
`#` comment — as `[{start, len}]`. The flag-unaware passes then consult it by byte offset
and never touch inert content: `scan/6` and `alt_walk/6` dispatch through it (an inert
span at the current offset — `byte_size(prefix)` or the tracked `i` — is swallowed whole
as an opaque atom, even inside a class so a quoted `]` can't close it), and
`trailing_anchors` declines a trailing anchor whose last byte is `in_inert?/2` (the
commented-`$` drop). `mode_walk/6` is itself flag-aware and keeps skipping these spans
inline. So the *correctness* residual — a guaranteed-equivalent mutant from a
commented/quoted construct in *any* pass — is gone. (This `inert_spans` pre-pass was the
intermediate step: it closed the correctness residual but re-derived the escape/class/flag
skeleton a fourth time. It has since been **subsumed** by the one-token-reader
consolidation — `inert_spans` is gone, the inert spans are now `:inert` tokens in the
shared `tokens/2` stream — see "collapsed onto one token reader" below.)
Verified two ways: a **differential fuzz** of 85k inert-free patterns (no `\Q`, no `#`)
confirms the new passes are **byte-identical** to the pre-reader output (the refactor
changed nothing where there is nothing inert), and a 200k-pattern fuzz seeded with
`\Q`/`\E`/`#`/`\n`/inline modifiers under `/x`/`/s` confirms every mutant of every
compiling original still compiles.

**The other equivalence the flag-positions expose — a *force-flag-off* swap vs. that
flag's modifier-drop.** Forcing one construct to behave as if a flag were off — the dot's
`(?-s:.)` (s off), `^`→`\A` and `$`→`\Z` (m off) — is the *same* matcher as dropping that
sigil flag **when they touch the same construct set**: the sigil flag on, no inline
modifier group (so the construct's behaviour comes solely from the sigil), and exactly one
such swap (one construct). So each mode swap is tagged `{:force_off, flag}` (or `:keep`) by
`mode_walk`, and `dedup_force_off/3` drops the lone force-off swap for any sigil flag —
**uniformly** for `s` (the dot) and `m` (anchors), no per-flag special-casing. `$`→`\z`
stays (`\z` is the strict end, *not* the m-off behaviour). The guard is the *sound* shape:
it fires only when the pattern has **no** `(?…` at all (so the behaviour is purely the
sigil's) and exactly one force-off swap for that flag exists; any inline modifier that
could break the equivalence leaves the pair un-deduped (a kept redundancy, never a wrong
drop), and two same-flag anchors (`^a$/m` → `\A` *and* `\Z`) likewise — a single swap no
longer equals the all-anchors drop. (The deeper *relevance-gated modifier-drop* — never
*emit* a flag-drop the pattern can't respond to — is still future work; this closes only
the swap-vs-drop *duplication*, not an inert flag-drop.)

`# mutare:ignore` (done) is the manual escape hatch: a trailing comment ignores
its line, a standalone comment the next line; matching mutants are recorded
`:ignored` — not run, kept out of the score's denominator (`killed / (total −
no_coverage − ignored)`), surfaced in the summary. Parsed from Sourceror's
comment metadata (`Mutare.Ignore`), not a raw-text scan — each comment's
`previous_eol_count` (`0` ⇒ trailing, `≥ 1` ⇒ standalone) drives the
classification, and a literal `"# mutare:ignore"` *string* is never mistaken for
a directive (the old text scan accepted it). Originally it still generated the unused
selector and could not rescue a compile-poisoning mutant. That limitation is resolved;
see "Ignored mutants reserve IDs but emit no code" below.

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
  hidden. The old "if we ever want typo-warnings" follow-up is **OUTDATED**
  (deferred-work audit, 2026-06-30): `Transform` now validates qualified labels
  against the known vocabulary, and `Schema` records directives that suppress no
  site so the task warns (or fails under `--strict-ignores`). Unknown *family*
  names remain deliberately lenient because they are indistinguishable from
  disabled/custom families at parse time.

Suspected-equivalent auto-reporting is still future work.

### OTP 28 regex `re_pattern` is a per-compile reference `[fixed — probe normalises regexes]`
The runtime property tests (`transform_baseline_property_test`,
`transform_activation_property_test`) compare two probed outcomes for equality via
`Mutare.PropertyProbe.probe/1`. On **Erlang/OTP 28** this started spuriously failing
the **baseline** property — and only it — whenever the generator happened to emit a
runtime `~r/…/` (one of nine `sigil_gen/0` choices, so seed-gated: red on some CI
seeds, green on others — it *looked* flaky but is fully deterministic per regex).

OTP 28 swapped the `re` engine to PCRE2, which compiles a pattern to a **NIF
resource** — an `#Reference` — carried in the `Regex` struct's `re_pattern`. A
reference is unique per compilation unit, so two **separately compiled** but textually
identical regexes (`~r/ab/` in the original *and* in the metamutant — distinct
`Code.compile_string` calls) hold different references and are never `==`, even though
`source`/`opts` match. On OTP 27- `re_pattern` was a plain, value-equal binary, so the
same comparison passed; that is why it surfaced only on the OTP 28 CI cell. Proven in
a container: 50/50 trials of two independently compiled `~r/ab/` compared **unequal**
(`#Reference<…992>` vs `#Reference<…993>`), `source/opts` identical `{"ab", []}`.

The **activation** property is immune by construction: it compares one metamutant
compile under two selector states, so a regex that no mutant touches is the *same*
compiled literal (same reference) on both sides. Only the baseline property, comparing
the original against a *separate* metamutant compile, sees two references.

**The fix (normalise in the shared probe).** `probe/1` now passes every captured value
through `PropertyProbe.normalize/1`, which reduces each `Regex` to its stable
`{:"$regex", source, opts}` identity (deep-walked through lists / tuples / plain maps;
other structs and scalars pass through). The comparison is now OTP-version-independent
and the change is the *correct* normalisation regardless of engine — `re_pattern` is an
opaque compiled artifact that was never a sound equality key. Regression coverage in
`test/mutare/property_probe_test.exs` pins it on **every** OTP (it asserts the
normalised shape directly, not the OTP-28-only symptom). The other generated sigils
(`~D`/`~T`/`~N`/`~U` structs) compare by value and need no normalisation.

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
names another. `Mutare.Sandbox.Command.Invocation` sets that var (to `Selector.suite_key/0`,
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

Verified end-to-end: a clean (`workers: 1`, generous cap) run on `baseline.ex`
flipped its in-process `classify/1` victims (`Enum.max→Enum.min`, `== []` polarity,
`true→false`, `take(-20)→drop(-20)`, `20→19`) from **false survivors → clean
kills** (8 killed/12 survived → 11/9). The unit guard is `selector_test`'s "under a
suite-key override, `put/1` leaves the harness key untouched".

What else is in place (unchanged):
- **Sandbox skips `:runner` tests.** `test/test_helper.exs` calls
  `ExUnit.configure(exclude: [:runner])` iff `MUTARE_ACTIVE_MUTANT` is set — true on
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
- **`Selector.bootstrap_ast` / `Invocation.watcher_ast` no longer break the
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
(`:mutare_cov__suite_fixture`). `Mutare.Sandbox.Command.Invocation` sets that env var on every
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

### Self-hosting: a leaked tracking flag + a vanished table crashed the baseline `[fixed — `hit/1` skips a missing table]`
The two coverage self-hosting fixes above isolate the helper *module name*; this is the
twin for the helper's *runtime state*. Once the `reduce:`-comprehension poison (above)
was fixed and the metamutant of Mutare finally compiled, the **baseline** run of a full
self-host (`mix mutare` on Mutare) collapsed with ~300 failures, almost all the same
`** (ArgumentError) the table identifier does not refer to an existing ETS table` from
`:ets.insert(:mutare_cov_agg, …)` — fired by the metamutant's own coverage records
inside ordinary lib functions (`Mutare.Transform.transform_string/2`,
`Mutare.Ignore.directives/1`, …) that almost every test calls.

Root cause is a single leak that cascades. `Mutare.CoverageTest`'s `setup_ast/0` test
sets `MUTARE_COVERAGE`, evals `Recorder.setup_ast/0` (which flips `:mutare_track` true
and `:ets.new`s the tables **in the test process**), then ends — and a process-owned
ETS table dies with its process. `on_exit` runs in a *separate* process, and its very
first line calls `Recorder.env_var/0` — a **metamutant** function whose coverage record
fires (`mutare_active == 0` at baseline, `:mutare_track` still true) and `:ets.insert`s
into the now-gone `:mutare_cov_agg`. That raise aborts `on_exit` **before**
`restore_track/1` runs, so `:mutare_track` leaks true for the rest of the BEAM and every
later instrumented line crashes the same way. (In a normal run these functions aren't
instrumented, so `on_exit` never records and the leak never happens — a pure
self-hosting artifact.)

**The fix (best-effort `hit/1` *and* `dump/1`).** The generated helper
(`Mutare.Coverage.HelperTemplate`) now treats a missing table as "nothing to record":
`hit/1` returns `true` without recording when its aggregate table is absent, and `dump/1`
reads each table through a `tab_list/1` that yields `[]` for a vanished one — the same
"never crash, a missing signal just means nothing to record" discipline as the dead-pid
label guards. So the metamutant's records can no longer crash an unrelated line: the
`setup_ast/0` `on_exit` completes, `restore_track/1` runs, and the leak is gone (302 → 0
ETS failures). A real probe run never reaches the `hit/1` guard — the bootstrap creates
the tables in the test-helper process, which outlives the whole suite. Guard is
`coverage_test`'s "a record is a no-op … when the aggregate table is absent".

**Two follow-ons surfaced once the baseline went green** (the abort had masked them):

1. **The `:case`-anchor `Mutare.ManifestTest` failure** — *not* ETS, the selector-key
   twin of the `:mutare_active` story. The fixture hand-built a metamutant string with a
   literal `:persistent_term.get(:mutare_active, 0)`, but the subject recogniser
   (`Mutare.Metamutant.subject?/2`) matches the key against `Selector.key/0` *at runtime*
   — `:mutare_active__suite` under the sandbox — so the subject went unrecognised and the
   id mapped to `[]`. Fixed in the test: fixtures build the read with `Selector.key/0`
   (the dispatch *variable* stays the un-overridden `Recorder.var_name/0`), so the key
   tracks whatever the recogniser expects in either context. (`manifest_test`'s `pt_key/0`.)

2. **The coverage *probe* recorded nothing → run-all** `[fixed — exclude the table-owning test]`.
   The probe sets `MUTARE_COVERAGE`, so the bootstrap creates the shared `:mutare_cov_*`
   tables in the test-helper process (alive for the whole suite). But one module destroyed
   them: `helper_template_test`'s `setup_all` unconditionally `:ets.delete`s and recreates
   them — its copy owned by the (module-lifetime) `setup_all` process, so it dies when the
   module finishes, *before* `after_suite`. Everything recorded into the bootstrap's table
   before it ran was lost with the delete; everything after fell to the `hit/1` missing-table
   guard. The dump came back empty and `CoverageProbe` ran every mutant against the whole
   suite. (The *other* coverage tests are already safe — `coverage_test` saves/restores and
   `drop_table_unless`-es, and uses probe-impossible `999_999_*` ids — so only this one
   module had to change.)

   **The fix is the *other* self-hosting tool, not a dynamic table name.** A runtime-resolved
   name can't separate the two the way the selector key does: the selector key works because
   the metamutant's read-*sites* bake the key as a literal (transform-time) while only the
   suite's `Selector.key/0` *calls* resolve at runtime — two non-interacting uses. Coverage
   has no such split: the real `:mutare_cov` helper and the metamutant of `HelperTemplate`
   are byte-identical recording logic in one sandbox BEAM sharing one env, so a runtime name
   resolves identically for both (and a test-local override still diverts the *real* records
   firing during that test's window). So `helper_template_test` is tagged `:coverage_tables`
   and excluded under `MUTARE_ACTIVE_MUTANT` alongside `:runner`/`:property` (see
   `test/test_helper.exs`). The probe's tables then survive the whole suite → a non-empty
   dump → real per-file selection. Cost (same as `:runner`): `HelperTemplate`'s own
   recording/attribution mutants, killed only by that module, go uncovered under dogfood and
   surface as survivors rather than `:no_coverage`. The `dump/1` missing-table guard above
   stays as the backstop for any other transient absence.

### Report diff fidelity for call-final keyword args `[fixed]`
A `mix mutare --only lib/mutare/ignore.ex` surfaced two *corrupt survivor diffs* on
`|> String.split(re, trim: true)` — both in `Mutare.Report`, **not** the metamutant
(which is built from the AST, compiles, and runs fine; only the diff a human reads
was wrong):

1. **`boolean` `true → false` ate the closing paren** — `…, trim: false` (no `)`).
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

### Report diff fidelity for long single-line originals — render unbounded `[fixed]`
A `logical` `and → or` on a 116-column boolean chain diffed as one `-` line against *two* `+`
lines: `Sourceror.to_string/1` re-flows at the formatter's default `line_length: 98` (nothing in
Mutare chose that; it fell out of calling the renderer with no options), and it measures from
column 0 — it can't see the column `Report.patch/2` will splice the fragment at. So the wrap was
also inconsistent: a 95-char fragment at column 40 stayed one (135-column) line, a 99-char one at
column 5 broke. Same family as the fidelity fixes above — the `-` side is source bytes, the `+`
side a re-format of the fragment, and the reader hunts for the flipped token across a re-flow.

Fixed in `Site.code_renderer/1`: a site whose range is one line renders through
`AST.to_string(node, line_length: :infinity)`. `Inspect.Algebra.format/2` takes `:infinity`, and
it drops only *fits*-based breaks (operator chains, call arguments); forced breaks (`do`/`end`,
`case` clauses) still render multi-line, so a one-line `case … end` original keeps its structural
shape. A multi-line range keeps the default 98 — the mirror case (an `and` chain the formatter
already broke over two lines would come back as *one* `+` line at `:infinity`) has no right width,
because Sourceror can't reproduce the original's operator-chain breaks from the AST, and the
default at least matches how the source was formatted. Hydration (`Runner.Hydrate`) goes through
the same constructors, so eager and deferred renders agree.

Not pursued: patching only the narrowest differing subtree (the operator token) so the `+` side is
byte-identical except the change. That would make every diff minimal, but a site's `range` is also
its `--line`/`# mutare:ignore`/SARIF location, and a whole-node rewrite (an `:attribution` clause,
a `:hosted` fragment) has no single differing leaf — a second, per-site "changed span" would be
needed. The one-line rule fixes the case that actually reads badly for a few lines of code.

### Surface skipped files more loudly `[deferred; corrected scope]`
The old claim that `Schema`/`safe_transform` skips **any transform failure** is
**OUTDATED** (deferred-work audit, 2026-06-30). `safe_transform` is gone:
`Schema.count_one/3` skips only parser failures (`SyntaxError`,
`TokenMissingError`, `MismatchedDelimiterError`), while every post-parse transform
or mutator failure is re-raised as a tool/configuration error. The task still only
prints `skipped <file>: <reason>` for those unparseable files, which can be easy to
miss. A strict mode that fails on any parse skip remains deferred.

### Live human progress (`Mutare.Report.Live`) `[done]`
The human run used to print a test-runner stream of symbols (`.`/`S`/`T`/…) via a
bare `IO.write` in the Mix task. It's now a cargo-mutants-style live display: phase
notes as the run advances, a permanent line left behind for each survivor (the
product) plus timeouts and harness errors (problems worth surfacing live), and — on
a tty — a bottom status block (spinner + the in-flight mutant + a counter with an
ETA) that animates via an internal tick timer. Design decisions worth remembering:

- **It's a `GenServer`, because the hooks fire concurrently.** `:on_start` is called
  from many `Task.async_stream` workers at once (as `:reporter` was too, until it moved
  to the ordered collector — see "Early stop: survivor cap and time budget"), so every
  terminal write must funnel through one owner. Reports/starts/phases are `cast`s (workers never
  block on rendering); `finish/1` is a `call`, and since all casts were *sent* (mailbox
  delivery complete) before the stream returned, FIFO guarantees `finish` sees the
  final state and clears the block before the after-the-fact `Mutare.Report` prints.
- **stderr, always; animation, conditionally.** Output goes to stderr so a machine
  report piped to stdout (`--report json > f`, or the default human report via
  `mix mutare > report.txt`) is never corrupted. Animation is gated on a real
  **stderr** tty (`:io.columns/1` succeeds), not `IO.ANSI.enabled?/0`: Elixir
  initializes that flag from stdout, so using it here incorrectly disables the live
  block when only stdout is redirected. Plain mode = phase notes + leave-behind
  lines as ordinary scrollback, no cursor codes, no spinner — exactly what CI logs
  want when stderr is not a tty.
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
  one activity line). The once-deferred "baseline green in Ns" timing note is now
  delivered by `--verbose` (below) — `baseline_ms` (and the compile time, coverage
  breakdown, cap, worker count) ride structured detail events on `:on_phase`.

### `--verbose` — narrate each step behind the scenes `[done]`

`mix mutare --verbose` (`verbose: true` in `.mutare.exs`) turns the compact live
display into a full narrative: a permanent scrollback line for **every** mutant as
it finishes (kills included, each with its duration), plus a `✓` detail note after
each phase — the one compile's time, the baseline timing, the coverage breakdown +
derived per-mutant timeout cap, and the worker count on the testing line. The
inverse UI knob to `--quiet`; `--quiet` wins when both are set (a quiet run starts
no reporter at all). Design choices, and why:

- **Purely a `Mutare.Report.Live` concern — the runner stays display-agnostic.**
  `--verbose` is Mix-task wiring (like `--quiet`): it threads `verbose:` only into
  `Live.start_link/1`. It does **not** plumb into `Mutare.Runner`/`Schema`/`Sandbox`.
  Instead the runner *always* fires richer structured `:on_phase` **detail events** —
  `{:compiled, ms}`, `{:baseline_done, ms}`, `{:coverage_done, summary}`,
  `{:run_config, cfg}` — carrying plain numbers; `Live` renders them only when
  `verbose` is set, ignores them otherwise. So the runner never learns whether anyone
  is listening (it composes no display text — `Live` owns the wording via the pure
  `detail_line/1`), and the events cost nothing on a normal run.
- **`:on_phase` was the right channel — overloaded, not a 5th hook.** `{:running,
  total}` already proved phases carry data, so the four completion events join the
  same hook rather than adding a `Run.Context` field. `Live` gets a catch-all
  `handle_cast({:phase, _})` so an unknown future event can never crash the reporter
  (it owns every terminal write); the `Run.Context`/`Runner` docs note a custom hook
  should tolerate unknown events.
- **Per-status verbose labels live in the one registry.** `Live` only had
  leave-behind labels for the 4 survivors/problems; verbose needs one for all 8
  statuses. Rather than a second list in `Live`, a required `verbose_label` field
  joined the `Mutare.Result.Status` descriptor (the "every per-status fact lives once"
  home) — `Live` derives `@verbose_labels` from it, and `Mutare.Result.StatusTest`
  pins that every status carries one.
- **Pre-mutant phases are clean scrollback; the counter block stays for `:running`.**
  In verbose mode the compile/baseline/coverage phase notes + `✓` details print as
  plain scrollback (no animated block — the detail line follows right behind), while
  the `:running` phase keeps the live counter block at the bottom with per-mutant
  lines scrolling above it (`put_line/2` re-anchors it; `verbose_note/2` leaves none).
  In a plain (non-tty/CI) run it's all scrollback, no cursor codes.
- **Rendering stays pure + unit-tested.** `humanize_ms/1`, `detail_line/1`,
  `verbose_leave/1`, `format_verbose/3`, and `CoverageProbe.summarize/1` (the pure
  selection-breakdown helper) are tested without a terminal, a clock, or a subprocess;
  a real `mix mutare --verbose` run proves the runner fires the events end to end.

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
  `MUTARE_ACTIVE_MUTANT` id (which isn't user-visible and *shifts* when discovery is
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
  the selector (`PipeEmit.hoist/2`): each branch becomes `lhs |> <branch>`, leaving a
  standalone `case` that is itself a valid pipe LHS, so chained pipes nest. Two
  spots needed it: the parent `|>` in the emit postwalk (a plain pipe stage), and
  `emit_site`'s catch-all default (a tail pipe that *also* carries a ReturnValue
  candidate, so the `|>` node goes through `emit_site` rather than the postwalk's
  pipe branch). The bare stage stays the Site's recorded node, so diffs are clean.

  - **Follow-up — that first form was exponential (`PipeEmit.hoist/1` → `/2`).**
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
  symmetric second half: `Mutare.Sandbox.Command.Invocation.watcher_ast/0` is its canonical
  quoted AST, owned next to the timeout env var it reads, and the sandbox
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
- **`--since <ref>` (done, now line-scoped).** `Mutare.Changes.since/2` runs
  `git diff -U0 --relative <ref>` with `root` as cwd and parses the hunk headers
  into a set of root-relative `{file, line}` pairs — the *new*-side added lines
  (committed + uncommitted). It feeds `:only_lines`, the **same** site filter
  `--line` uses, so a `--since` run and a `--line` run share all downstream
  machinery (discovery pruning + per-site line filter in `Schema`) and it still
  composes with `--only`/paths. This deliberately replaced the original
  file-scope (`--name-only` → `:only_files`): a one-line edit to a large module
  now mutates only that line, not the whole file — the CI behaviour people
  actually expect. The `-U0` parse is robust by construction: it consumes each
  hunk's declared body-line count (`\ No newline` markers excepted) rather than
  pattern-matching text, so content that *looks* like a `+++ `/`@@` header can't
  be misread as one. Limits (unchanged): untracked new files aren't reported by
  `git diff` (stage/commit them); pure deletions contribute no new-side line, so
  a delete-only change drops that file out of scope entirely; only the changed
  lines themselves are mutated, not code that transitively depends on them;
  `--since` assumes `root` is inside the repo.
- **Custom mutators (done).** `Mutare.Mutator` is the public extension point:
  `mutate/1` + `name/0`. `:mutators` in `.mutare.exs` accepts built-in family
  atoms *and* any module implementing the behaviour (validated, with a helpful
  error otherwise). Dropped the old `kind/0` callback — it was vestigial and
  misleading: placement (in-place selector vs lifting into a guard) is decided
  by the node's *position*, not declared by the mutator. The old blanket limit
  that custom mutators cannot express structural mutations is **OUTDATED**
  (deferred-work audit, 2026-06-30): `Mutare.Mutator.Structural` now exposes
  return-tail, condition, and head-pattern callbacks. Transform-managed structural
  families such as clause/guard/rescue drop still have no custom callback. CLI
  `--mutators` CSV is for built-in
  families (short names); custom modules go in `.mutare.exs`.
- **Validated options struct (done).** The shared keyword list that threaded
  through `Config → Schema → Runner → Sandbox` is now `Mutare.Options`, built and
  validated by `Options.new/1` at each public entry point. `Config` owns only file/CLI
  precedence and CLI-syntax translation; `Options` is the single normalization
  boundary for every source (including mutator resolution, bare reporter atoms, and
  the `:all`/`:builtins` default-set shorthand). An existing `%Options{}` is
  re-normalized and revalidated too, so a hand-built struct cannot bypass validation
  or retain an unresolved computed default such as `workers: nil`. Validation
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
  - **Retry** (`:harness_retries`, default `2`). A harness error can be
    *transient* (a filesystem/lock race under parallel workers), so the runner
    re-runs a harness-erroring mutant up to N times before recording it — a fresh
    `mix` boot is its own natural backoff. Only `:harness_error` is retried; a
    real verdict (passed/failed/timeout) never is. Retry lives in the runner's
    `run_mutant/4` path (via `run_mutant_attempt/6`), *not* in `Command` —
    `Command` does one clean run and reports its outcome; whether to re-run is
    an orchestration decision. (So
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
    callback. The collision rule lives in `Config.resolve_reporters/2`: `--report FORMAT:PATH`
    writes the machine format to a file *and* keeps the human
    report on the console; `--report FORMAT` takes stdout and drops the human
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
  Operational recommendation: keep the default `baseline_runs: 1` for the fastest
  local loop; use `baseline_runs: 2` or `3` in CI or on projects with known flaky
  edges, where one or two extra whole-suite boots are cheap compared with trusting
  a false kill.
  - **Decision: abort-and-name, not quarantine.** Matches the "abort loudly"
    and "mitigate, don't pretend" principles: we refuse to score a flaky suite rather than
    guess which tests to drop. **Deferred** as a follow-up: *quarantine* the flaky
    tests and proceed over the stable subset (needs the exclusion threaded through
    the baseline re-measure, the coverage probe, *and* every per-mutant run — and a
    reduced-suite score is a soundness caveat to surface).
  - **Unanimous-kill reruns (done).** A residual flake only visible under one
    mutant's timing can still escape a green baseline. `--kill-runs N`
    (`:kill_runs`, default **1** = unchanged behaviour) re-runs only kill
    outcomes and records a kill only when every attempt kills. If a later attempt
    passes, the mutant is recorded `:survived`; if a later attempt persistently
    hits the harness after its own harness/boot retries, it records
    `:harness_error` rather than pretending either verdict. The combine rule is
    **unanimous-kill** — the honest direction; "any-kill" would preserve the false
    kill flakiness manufactures. The runner implements this as an outer layer
    around `run_mutant_attempt/6`: harness retries settle one attempt first, then
    kill reruns combine settled test-suite verdicts. Under unanimous-kill only
    killed mutants pay the extra process boots, so the honest rule is also the
    cheap one.

### Option-spec registry + config/wiring split `[done]`

Two problems with how options were defined and carried.

**(1) Option knowledge was spread across four files**, so adding one option meant four synchronized
edits that silently drifted: the default + validator (`Mutare.Options`'s `@field_defaults` +
`validate_*!`), the CLI switch shape (`Mix.Tasks.Mutare`'s `@switches`), the 1:1 passthrough fold
(`Mutare.Config`'s `@passthrough_flags`), and the `--show-config` row (`Mutare.CLI.Info`). The drift
was already visible — `--show-config` silently omitted `partition_env`/`seed_app_build`/`quiet`/
`only_files`/`only_lines`.

**Fix:** one declarative source, **`Mutare.Options.Registry`** — an ordered `specs/0` list, one entry
per user option carrying `{default, cli, visible, show, validate}`. Everything else derives from it:
`Options` builds its `defstruct`/`@keys`/`new/1` from `defaults/0`+`specs/0`; `Config.put_passthrough_flags`
folds `passthrough_keys/0`; the Mix task's `@switches` is `Registry.cli_switches() ++
Config.cli_switches() ++ <project/inspect flags>`; `info.ex`'s `--show-config` is `Registry.display_rows/1`
(so every visible option appears — the omissions are now structurally impossible). Adding a typical
passthrough option is a single registry entry. The *exceptional* CLI translations (`--full`/`--only`/
`--report`/…) deliberately stay in `Config` (`cli_switches/0` + `merge/2`); the registry only owns the
1:1 passthroughs.

Two sharp edges:
  - **`specs/0` is a function, not a `@specs` attribute.** Its `:validate`/`:show` values are captures
    of this module's *private* functions (`&validate_paths!/1`), which a module attribute **cannot**
    hold — only a function body can capture a local. It rebuilds the list per call (cheap; called a
    handful of times per run).
  - **The registry must not compile-depend on `%Options{}`.** `Options` derives its struct from
    `Registry.defaults/0` (a compile-time dep `Options → Registry`), so a `%Mutare.Options{}` pattern
    in the registry would close a compile **deadlock**. Hence `display_rows/1` takes a plain map (no
    struct pattern) and the reporters validator reads `Options.formats/0` at *runtime* (an export dep,
    not compile). Hit this exact deadlock during the change; the fix is to keep the registry → options
    reference runtime-only.

**(2) `Mutare.Options` mixed configuration with runtime wiring.** `project` (a resolved
`Mutare.Project`) and the four live-progress hooks (`reporter`/`on_phase`/`on_start`/`on_scan`) are
not user config — they're execution context — yet lived on the same struct.

**Fix:** **`Mutare.Run.Context`** = `%{options, project, reporter, on_phase, on_start, on_scan}`.
`Options` is pure config again. The pipeline (`Schema`/`Sandbox`/`Runner`) threads a context, reading
config from `ctx.options` and wiring from its own fields. The key to low churn is **wrap-at-boundary**:
`Context.new/1` mirrors `Options.new/1` and, for a keyword list, **splits** the wiring keys off (via
`Keyword.split`) and routes the rest to `Options.new/1` — so every existing keyword call site
(`Schema.build(root, project: p, mutators: m)`, `Sandbox.prepare(root, schema, project: p)`,
`Mutare.run(root, sandbox: s)`) keeps working untouched, the wiring riding into the context and the
config into options. `Context.hook/2` is the no-op default (moved from `Options.hook/2`);
`Context.ensure_project/2` (moved from `Runner`) resolves a project from `root` when the direct API
leaves it unset. Naming: this is `Mutare.Run.Context`; the **unrelated** `Mutare.Runner.RunCtx` (the
per-mutant invariants: sandbox/selection/cap/scopes/retries) stays — different struct, similar name,
aliased `Context` vs `RunCtx` to keep them apart in `Runner`.

- **Plugin-config toolkit: `init/1` + `Mutare.Mutator.Families` (proposal 0003, done).** Two
  additive pieces for family-rich plugins (the motivating case: `mutare_ecto`'s ~410-line hand-rolled
  `Config`). `c:Mutare.Mutator.init/1` parses an instance's options **once**, at `Mutare.Mutator.Spec`
  resolution (stored as `spec.config`; a bad option raises at startup next to core's own option
  validation, not on the first mutated node), and dispatch delivers it as `context.config` on the
  three per-spec context paths — `mutate/2`, the context-aware structural arities, and `host/2` —
  via one `put_spec_context/2` helper. A module listed twice (the multi-repo/`:as` pattern) runs
  `init/1` once *per spec*. This deletes the plugin-side memoization dance (re-parsing
  `context.opts` per node, caching under a private context key, a double-headed `from_context/1`).
  `use Mutare.Mutator.Families` generates the family-catalog half (`all_families`/`default_families`/
  `parse_families!`/`family_enabled?` + the `family` type union, all overridable) so the
  `:default | :all | list | {base, except: […]}` grammar stays consistent with core's
  `{:builtins, except: […]}` instead of being manually mirrored per plugin. **One deliberate
  deviation from the proposal:** `route_arguments/2`'s context does *not* gain `:config`. Routing is
  per **call node** and shared by every mutator that meets it (its `routing_context` is documented
  opt-independent, and `macro_routes/0` is 0-arity — registration can't see options either); two
  instances of one module with different configs would otherwise demand conflicting treatments for
  the same position. The motivating plugin's classifier reads no config, confirming the cut. A
  config-dependent *emission* decision belongs in `host/2`/`mutate/2`, which do see `context.config`.
  `mutate_call_option_keys?/1` also still receives raw opts (a policy callback with its own
  argument, not a context consumer; changing it would break existing signatures for no motivated
  gain).

- **`finalize/2` — one enrichment seam across both delivery paths (proposal 0004, done).** A
  family-rich mutator must run the same *tag → filter → enrich* funnel on every mutant it produces
  (read the family off the tag, drop it when disabled, attach the family's note), but its mutants
  leave through two different callbacks — a `mutate/1`/`mutate/2` return and a host target's
  `:mutants` — so the funnel was duplicated verbatim per delivery site in `mutare_ecto`, and
  forgetting a site didn't error: it silently delivered unfiltered, note-less mutants. A helper
  (`Families.deliver/2`) would keep that failure mode; the optional `c:Mutare.Mutator.finalize/2`
  callback inverts control — **core** applies it to every produced mutation just before recording
  (`Dispatch.finalize_mutations/3`, shared by `tag/3` and `normalize_target/3`), so producers
  shrink to pure `Mutation.tagged(node, [family | finer])` construction and the funnel cannot miss
  a site. Decisions baked in: finalize is part of *production* (it runs before overlap suppression
  and ignore filtering; a tagged label on the finalized mutation wins over `variant/2` derivation,
  unchanged); a `:skip` drops the mutation and a host target whose mutants all skip is dropped
  whole; a **relayed** mutation (explicit `:producer` — the sub-contract case) bypasses the
  returning mutator's finalize, because the producing family's own funnel already ran when the
  mutation was generated via `expression_mutations/3` — "finalized exactly once, by the family that
  produced it". Structural-hook returns are *not* finalized (bare AST, no metadata to enrich —
  extending them would mean accepting `Mutation`s there first, a separate decision). Core stays
  family-blind: a mutant-level family taxonomy is plugin domain (the rejected alternative was a
  core-side `family_of/1` + filtering); each raw element is still validated by `normalize_mutant/1`
  *before* plugin finalize code sees it, and a bare-`nil` finalize return raises (ambiguous with
  `:skip`). Downstream this deletes `mutare_ecto`'s two funnel comprehensions and `split_tag/2`;
  `Config.enrich/3` becomes the body of `finalize/2`.

- **`Mutare.Test` rounded out for plugin suites (proposal 0005, done).** Four gaps the `mutare_ecto`
  suite papered over: (1) the source helpers (`diffs`, `diffs_for`, `assert_metamutant_compiles`)
  took no transform opts while `compile_metamutant/3` did — an accidental asymmetry that coupled the
  Ecto suite to `expand_uses: true` *happening* to be the default and forced raw `transform_string`
  fallbacks for `:macro_routes` tests; all now take a trailing `opts` forwarded to
  `transform_string/2`. (2) `metamutant_source/3` returns the rendered metamutant for `=~`
  scaffolding checks, so plugin suites stop destructuring `%Transform.Result{}` (de-facto public in
  six Ecto files). (3) `observe_mutant/3` composes `site_id/2` + `with_active_mutant/2` into the
  flip-and-compare pair `{baseline, mutated}`; the baseline runs **first and pinned to
  `Selector.baseline()`** (not the current selection), so a leaked active id can't masquerade as
  baseline and a wrong first element indicts the fixture, not the mutant. (4) A shipped
  `Mutare.Test.RoutingExtension` — two pass-through macros routed `:skip` /
  `[:expression, :skip]` — replaces each plugin's hand-rolled no-op routing provider
  (`MyApp.QueryHelperMutator`) for foreign-routing composition tests. Deliberately scoped down from
  the proposal's "each treatment kind": it ships as an *extension* (so `:hosted` is illegal on it by
  contract), and `:interpolated`/`{:keyword, …}` assert semantic facts about a real DSL that a
  generic pass-through can't honestly claim — those stay modelled per-adapter (the unshipped
  `test/support/host_mutator.ex` fixtures show how). The domain halves of the Ecto harness (SQLite
  boot, seeding, `Repo.all` wrapping) stay plugin-side by design.

- **Declarative environment guard — `required_modules/0` (proposal 0006, done).** A DSL plugin's
  target library must be loadable in the Mutare process or its routing registers against nothing,
  and the failure mode is *silently incomplete routing* (mutants that never fire, or a query
  mutant that poisons the build), not an error. `mutare_ecto` hand-rolled the guard
  (`ensure_ecto!/1`) and had to invoke it from **both** registration callbacks — `macro_routes/0`
  and `hosted_macros/0`, since either can be the first entry point depending on configuration — a
  subtlety every DSL plugin would rediscover. Now an optional `required_modules/0` is checked
  **once** by core: in `Mutator.Spec` resolution (before `init/1`, so a plugin fails on the
  deployment error, never on what its `init` does without the library) and in
  `Extension.validate!/1`, raising the core-owned `Mutare.EnvironmentError` — one consistent
  message for every plugin, before any source is read. Decisions baked in: **loadability is the
  whole check** (`Code.ensure_loaded?`; app-started/version-floor requirements stay the plugin's
  own raise from `init/1`/`macro_routes/0` — documented as the escape hatch on the callback); the
  callback is declared only on `Mutare.Mutator` and *recognized by export* on extensions, because
  also declaring it on `MacroRouting`/`MacroHost` would trip the compiler's conflicting-behaviours
  warning on any module implementing several (exactly the `Mutare.Ecto` shape). Deferred: the
  deeper degradation where the *target app's own* modules are unresolved isn't expressible as a
  static module list; if it ever needs a hook, an arbitrary `verify_environment!/0` would grow
  next to this guard. Downstream this deletes `Mutare.Ecto.ensure_ecto!/1`, its module list, its
  two invocation sites, and its hand-written error prose, replaced by a one-line
  `required_modules`.

- **`Mutare.AST.numeric_alternatives/3` — the off-by-one/zero table published value-level (done).**
  A host that mutates a literal core can't reach (`mutare_ecto`'s `Fragment`: an integer/float
  written *raw* into an SQL condition, not under a `^` pin — so neither core's own families nor the
  sub-contract seam below apply) had to hand-mirror `Helpers.numeric_mutations/3` byte for byte:
  the `succ`/`pred`/`zero` candidate table, the equal-to-original drop, and the label-merging
  collapse (`1` → one `0` tagged `["pred", "zero"]`). That mirror is the drift hazard, not the
  ~25 lines: the plugin's `# mutare:ignore[ecto:zero]` vocabulary and collapse semantics only agree
  with core's `[integer:zero]` by accident of copying. `Helpers` is `@moduledoc false` on purpose,
  so the fix is the same move `sentinel_string/0`/`sentinel_atom/0` already made — publish the
  *convention* on `Mutare.AST`, next to the sentinels, and make the built-ins consume it:
  `Helpers.numeric_mutations/3` is now a two-line wrapper (`Mutation.tagged(literal(v), labels)`
  over the pairs), so there is one table. Decisions baked in: it is **value-level**
  (`[{value, [label]}]`), not `Mutation`-level — a plugin wraps values in its own tag shape and can
  filter *before* building nodes (the JSON-path case must drop a negative index, which
  `literal_value/1` can't read back from the unary-minus `literal(-1)` node); labels are always a
  list at this layer (`Helpers` keeps its `one_or_many/1` when tagging, so the built-ins' emitted
  variants and ids are byte-identical); and it is deliberately *numeric only* — no type-dispatching
  `literal_alternatives/1`, because the string/atom/boolean arms are one-liners with no shared logic
  and their ownership splits (`nil`, `true`/`false`, convention atoms) are policy each side must
  own for itself. Downstream this deletes `mutare_ecto`'s `Fragment.value_mutants/3` and its three
  inline candidate tables.

## Host sub-contracting of fragment interiors (pin islands)

A `:hosted` argument is left entirely raw by core and every mutant there comes from the host —
correct for the DSL itself, but a hosted fragment can contain **islands of ordinary Elixir**
(everything under an Ecto `^` pin) that are core's business and nobody else's. Before this seam,
a plugin author faced a trilemma: leave pin interiors dark (a blind spot that depends on spelling
— `u.score > 18` covered, `u.score > ^18` not), hand-mirror core's value conventions inside the
host (drift, wrong attribution), or apply DSL semantics to Elixir code (mutare_ecto's accidental
status quo: an SQL-rationale `^(min * 2)` → `^(min / 2)` whose `/` changes the parameter's type —
a crash-mutant).

Not the `:interpolated` treatment's territory, though the two are cousins: `:interpolated` is an
*argument route* — the adapter declares a whole macro position interpolated data and **core**
delivers there (introducing or descending the `^` itself) — while this seam covers islands
*inside a `:hosted` fragment*, a region core never routes into, so only the host can carry the
mutants out. Same user-visible outcome (core's families reach pin interiors), disjoint positions,
one producer each.

**The shape:** the host sub-contracts designated interiors back to core's *generation* while
keeping *delivery* 100 % host-owned (an in-place selector is illegal inside a query clause; every
interior mutant rides the host's weave). Three additive pieces:

1. **`Mutare.Analyze.expression_mutations/3`** (impl: `Mutare.Transform.Analyze.Collect`) — the
   collect mode of the analyze pass. Deliberately **not** a parallel walker: it runs the real
   `Analyze.annotate/2` plus the same pre-emission passes emission runs (`Overlap.resolve/1`, the
   call-option gate — extracted to `Candidate.Delivery.gate/1` so the two paths share it), then
   reads the annotations back as rebuild-per-mutant data. Sharing the walk is what makes the
   parity contract ("a host cannot out-mutate core") structural rather than aspirational — the
   parity test in `analyze_test.exs` pins it. Node-level producers only; `Candidate.InPlace`
   only (clause-pattern mutants inside the subtree are structural-delivery and stay uncollected);
   hosts excluded from the spec list (no recursive hosting — a nested `{:hosted, …}` stays raw
   either way). Variant labels are resolved *at collect time* (node-level pair), because once the
   host wraps the rebuild the fragment pair no longer has the shape `variant/2` derives from.
2. **`context.mutators`** threaded to `host/2` (`Analyze.Macros.attach_hosted_candidates/5`) —
   without it the host can't know which families are on, under what `:as` names, with which opts.
3. **`producer:` on `%Mutation{}`** — per-mutant attribution. `Dispatch.normalize_mutant/1`
   quads carry it; `HostedEmit` records the Site under `producer || cand.mutator`, so qualified
   ignores resolve against the producing family's vocabulary (`[integer:succ]` suppresses the
   in-pin integer; `[my_host]` doesn't touch it). The rule is uniform: a `producer` on an
   ordinary `mutate/1,2` return also re-attributes (one rule, no host-only special case).

**Rejected alternative — recursive island routing:** a treatment grammar where a `:hosted`
argument marks interior `:expression` islands core analyzes itself and merges into the host's
Target. It breaks the contract stated verbatim in `MacroHost`'s docs ("Core leaves hosted
fragments raw"), splits one region between two producers (overlap/claim bookkeeping), and still
needs the host consulted for the rebuild — much more core surface for the same user-visible
mutants.

**Accepted fidelity edges** (documented in `Collect`'s module comment): rebuilds of a bitstring
construction carry the analyzer's `::binary` type pins (cosmetic, compile-equivalent); candidates
the analyzer pruned for selector-delivery reasons (escaping-binding ancestors) stay pruned in
collect too — under-mutating those rare shapes keeps the shared-walk property exact. Consequence
worth remembering: with only a DSL plugin enabled and no core families, a pin interior now
mutates to *nothing* — consistent (the user turned the families off), but a behavior change from
any plugin's previous accidental always-on descent.

**Whole-call sub-contract (free-standing `dynamic`, proposal 0008, done).** The same island
appears on a second delivery path the seam originally didn't reach: a registered macro in
ordinary expression position whose routing keeps an argument raw — Ecto's free-standing
`dynamic([p], p.views > ^(min * 2))`, a `:skip` route — is offered *whole* to `mutate/2`, which
rewrites it in place (no host, no weave), but `mutate/2` got no `:mutators`, so the pin interior
stayed dark and hole-or-not depended on spelling (the identical condition in a `where` got island
mutants). Fix: `Analyze.Macros.analyze_known_macro/5` injects the same non-host spec list into
the whole-call offer's context, one function above the host-path injection; the output half was
already uniform (`producer || spec` on the shared normalize path, and relayed mutations already
bypass the returning mutator's `finalize/2`). Deliberately **gated on registered macro calls,
not injected into every `mutate/2` offer** (the considered alternative): sub-contracting is sound
exactly where the sub-contracted region is core-raw, and only macro routing makes regions raw —
an ordinary node is fully core-descended, so a sub-contract inside one double-produces the same
logical mutant silently (no error to catch it). The gate encodes "whoever declared a region raw
may sub-contract inside it" structurally, and — the practical half — keeps the
`ordinary_mutators/1` export probe off the per-node hot path: `Dispatch.mutations/3` runs at
essentially every node, `analyze_known_macro/5` only at registered macro calls. Recursion stays
bounded: collect runs the real annotate descent, so a registered macro *inside* an island gets
the injection again, but every hop moves strictly deeper into one finite tree, and hosts stay
excluded from the injected list. `SubcontractNodeMutator` (`macro_mutator.ex`) is the fixture;
`subcontract_node_test.exs` pins attribution, per-family qualified ignores, no double production,
runtime switching, and parity — the same island yields the same logical core mutants via hosted
weave and via whole-call rewrite. (Observed while testing, pre-existing and orthogonal: a node
whose Sourceror meta carries a same-line comment — e.g. a `# mutare:ignore` directive — renders
that comment into the Site's `original_code`/`mutated_code`; the built-in in-place families do
the same.)

## Consolidations weighed and left as-is

A refactoring pass folded most of the cross-module duplication — shared AST/resolution/suppression
helpers (`Mutare.AST.literal_value`/`absolute_call`, `Aliases.resolve_node/2`,
`Transform.Suppression`), the `Uses` split (`EnvMirror` + `Harvest`), the selector emit split
(`SelectorEmit.claim_items`/`ids_from_clauses`), and making `mutate/1` an optional callback.
Three near-
duplications were measured against the cost of unifying them and **deliberately kept** — the merge
buys less than the duplication costs:

  - **`Mutare.Mutators.RegexLiteral`'s byte-walks — `[done]`, collapsed onto one token reader.** The
    four walks (`scan`, `alt_walk`, `mode_walk`, `inert_walk`) each re-derived the same escape /
    character-class / group / flag / inert skeleton; they are now folds over a **single** `tokens/2`
    reader that owns all of it once. A token is `%{kind, text, offset, in_class, flags}` (a `:bound`
    carries its parsed bound, a `:group_open` its `removable?`); `text`/`offset` let a consumer splice a
    replacement by `binary_part`, and inert (`\Q…\E` / `x`-comment / `(?#…)`) spans are a single
    `:inert` token whose content is *not* lexed, so every pass skips them by simply not matching that
    kind. Each consumer keeps only its own accumulator — `scan_patterns` a `prev_quant` reduce,
    `alternation_patterns` a frame stack, `mode_aware_patterns` a `flat_map`, `anchor_patterns` a glance
    at the first/last token (escaping + inertness already resolved, so its old `escaped?`/`in_inert?`
    string heuristics fell away). How the risk was managed: a **byte-identical differential fuzz** against
    the pre-refactor module over 300k patterns showed the new folds match the old walks on **every
    compiling original** save two *improvements* the shared reader brought for free — it now treats a
    `(?#…)` PCRE comment as inert for `scan`/`alt` too (the old `inert_spans` only knew `\Q`/`x`-comments,
    so `scan` had been mutating comment content into guaranteed-equivalents), and it fixed a stray
    `alt_walk` miss. `Flags.open/2` grew a `:push | :mutate | :comment` tag so the reader can classify a
    `(`-token (real group vs bare `(?m)` modifier vs `(?#…)` comment) — the one API ripple. (The forcing
    function the earlier note named — the escape grammar growing — is now also where *new* lexing goes:
    one place, not four.) Subsequent review then drove the lexer to the full PCRE corner-grammar, each a
    one-clause add now that there's one reader: a **POSIX class** `[:alpha:]` is consumed whole (its inner
    `]` no longer closes the enclosing class → no phantom frame); a **`(*VERB…)` control verb** is an inert
    atom (its literal `(`/`|` argument can't push a frame or read as alternation); the **inline-flag set**
    is exactly `i m s x J U X` (engine-accepted scoped *and* unset — `X` was missing, `u`/`n` bogus); an
    **`x`-comment ends at CR *or* LF**; a **`\cX` control escape** is one three-byte escape (its argument
    can't push a frame); and the two span flavours were split — an **ignored** `:comment`
    (`x`-comment / `(?#…)`, behind which a quantifier suffix is still visible) vs an **inert atom**
    `:inert` (`\Q…\E` / verb, which *stops* suffix scanning) — so `scan`'s `prev_quant`/suffix detection
    looks *through* ignored text (`a+(?#c)?`, `a+ ?`/x are lazy, not collapsible) but not through atoms.
    Finally, a quantifier on a **zero-width atom** (a *capture-free* lookaround `(?=…)`, or a
    `\b`/`^`/`$` assertion — tracked by `scan` via a group stack the reader tags) is idempotent, so the
    collapse/lazy/same-class variants are guaranteed-equivalent and dropped, keeping only the
    "always-passes ↔ requires-once" class-changing swap (`(?=a)+` → `(?=a)*` only) — and the same
    class rule prunes its **bounded** form (`(?=a){2}` → `{1}`/`{3}` both "requires", dropped;
    `(?=a){1}` → `{0}` crosses to "always-passes", kept). The **capture-free** qualifier is load-bearing:
    a lookaround that *captures* (`(?=(a))`) is observably non-idempotent — greediness/count change the
    captured text and any later backreference (`(?=(a))*` greedy captures `a`, lazy `*?` leaves it
    unset) — so the group stack carries a `{lookaround?, capturing?, contains_capture?}` per frame,
    propagating a nested capture (even through a `(?:…)`) up to the enclosing lookaround on close; a
    tainted lookaround is *not* zero-width, so all its quantifier/bound mutants are kept. Two final flag corners: a **`\cX`** control
    escape is one three-byte escape; and a *leading* anchor (`^` **or** `\A`) under **`/mf`**
    (firstline) is pinned to the subject start, so the `^`↔`\A` swap is a guaranteed no-op in both
    directions and suppressed. "Leading" is tracked by `mode_aware_patterns` (preceded only by
    non-consuming tokens — other anchors/assertions, inline `(?…)` modifiers, and PCRE-ignored text:
    comments and, under `/x`, whitespace — the last shared with the scan pass via `scan_ignored?/1`, so
    `  ^a/fx` still sees `^` as leading), so `(?m)^a/f` and `\Aa/fm` are covered, not just an offset-0
    `^`; a group (even a zero-width lookaround) is
    conservatively treated as consuming, so the under-approximation only ever *misses* a no-op, never
    drops a killable swap. Two non-grammar fixes rode along: (1) the compile-safety check normalises
    the deprecated `/r` modifier to its `/U` alias *for the validation `Regex.compile/2` only* (the
    rendered mutant keeps `/r`), so the once-per-candidate check no longer floods a run with
    `/r`-deprecation warnings; and (2) — a real **poison** gap — `Regex.compile/2` validates PCRE but
    not the *rendered Elixir source*, and the two diverge on `#{` (PCRE: literal `#`/`{`; Elixir:
    interpolation), so a collapse of `#+{` → `#{` passed the PCRE backstop yet poisoned the metamutant.
    The backstop is now **two gates**: PCRE-compilable (gated on the original, as before) *and*
    renders-and-reparses to the same single-binary sigil (checked unconditionally — a non-rendering
    candidate poisons regardless of the original). Gated cheaply on the candidate containing `#{` at
    all (the only sequence Sourceror leaves un-escaped), so the round-trip runs only when it might bite.
  - **`Mutare.Transform.Analyze.Conditions`' parallel spine-walks** (`spine_rewrite`, `spine_bindings`,
    `eval_steps`, `offspine_escaping_binding?`, `prune_binding_ancestors`). All share one structural
    skeleton (stop at `@binding_isolating_forms`, recurse-left at `@short_circuit_ops`, flag at
    `@branch_forms`, special-case `:=`) and differ only in what each accumulates. A generic
    `spine_walk(node, acc, handlers)` would collapse the skeleton — but these walks are subtle (the
    binding-escape analysis is correctness-critical and the tests lean on surviving-equivalent
    reasoning, so a generalisation mistake wouldn't obviously fail). The pins now exist —
    `conditions_property_test.exs` checks each walk against a reference model and the hoist
    rewrite against *evaluation* (value, bindings, effect order) over generated conditions
    (`Mutare.Test.ConditionGen`), for which the walks are `@doc false` public — so the
    generalisation is unblocked, though still not attempted; until it is, the explicit walks stay.

The other two items from that pass are documented where they live: the `Uses` env-mirror **seqlock
invariant** in `Mutare.Transform.Uses.EnvMirror`'s module comment (the home the extraction gave it),
and the **harness-retry contract** — only `:harness_error` is retried, because the kill outcomes
`Command.outcome/2` recovers (`:suite_compile_error`, `:atom_exhausted`) are already distinct by the
time `Runner.run_mutant/6` reads `result.outcome` — at that guard.

### Mutator capability behaviours — split the `Mutare.Mutator` bag `[done]`

`Mutare.Mutator` had grown to **twelve** `@optional_callbacks` spanning five unrelated jobs — node
mutation (`mutate/1`, `mutate/2`), structural positions
(`return_replacements`/`condition_replacements`/`pattern_mutations`, each with a context-aware `+1`
arity), macro/DSL targeting (`hosted_routes/0`, `macro_routing/1`, `host/2`), and the in-RHS suppression
classifier (`empty_collection?/1`, subsequently removed with the unsound body suppression above).
A reader opening the behaviour to write a one-line operator swap met all of it. At 0.1.0, before
there are external mutators to break, was the moment to fix the shape.

**Two ways to fix it, and why one was wrong.** The choice was *split the behaviour* vs *add an
explicit `capabilities/0` declaration*. The declaration is the wrong tool for Elixir:
`function_exported?` is already an implicit, zero-drift capability check, and the whole codebase is
built on "discovered by export / classified positively" — a `capabilities/0` would be a second source
of truth that can disagree with what's actually exported (declare `:host`, forget `host/2`). The split
is the house style: it's exactly the capability-named-peer move `Mutare.UseExpansion` made for
vocabulary-vs-judgment, and the principle is recorded above ("a new capability gets a capability-named
peer, not a declaration mechanism").

**The split.** `Mutare.Mutator` keeps `name/0` + the node-level producers (`mutate/1`, `mutate/2`).
At the time it also kept `empty_collection?/1` because that classified a mutator's own node output;
the guard-only correction above later removed it entirely. Two companion behaviours, declared
*alongside* `Mutare.Mutator`:
`Mutare.Mutator.Structural` (the position-routed hooks + their structural `context` type) and
`Mutare.Mutator.MacroHost` (the three DSL-targeting callbacks + the `routing_treatment` /
`keyword_value_treatment` types). The fault line was visible in the data: the macro-host callbacks
have *zero* built-in implementers — they exist purely for external library mutators. So "teach Mutare
a macro's shape" is genuinely a different capability from "produce a mutation."

**What it is and isn't.** It is **documentation/ergonomics**, not a structural change: dispatch is
byte-for-byte unchanged. `Mutare.Mutator.Dispatch` discovers every hook by `function_exported?`, never
by which behaviour declared it, so moving a `@callback` to another module changes nothing at runtime —
the producing-callback set in `implemented_by?/1`, the `implementing/3` discovery, and the
prefer-the-`+1`-arity dance all still work. The win is bounded but real: the core `Mutare.Mutator` doc
shrinks to the ~4 callbacks 95% of authors touch, and each extension capability gets a focused home.
The irreducible load — Mutare routes five kinds of positions — is unchanged; a split reorganizes, it
doesn't reduce.

**The one mechanical hazard.** Every affected module used an **explicit** `@impl Mutare.Mutator` (not
`@impl true`), which turns into a hard `--warnings-as-errors` failure the instant its callback leaves
`Mutare.Mutator`. So each of the five built-ins (`ReturnValue`/`GenServer`/`IfCondition`/`PatternSwap`/
`PatternWildcard`) and the macro/structural test fixtures gained the new `@behaviour` line and had the
*moved* callback's annotation flipped to `@impl Mutare.Mutator.Structural` / `.MacroHost`, while
`name/0`'s stayed `@impl Mutare.Mutator`. The `host_mutator.ex` fixtures share so many identical
`@impl`/`def hosted_routes` blocks that a rule-based pass (flip only the `@impl` immediately above a
`hosted_routes`/`macro_routing`/`host` def) was the safe edit, not hand-anchored replaces.

### Macro routing and `use` expansion — capability peers, not duplicated extension callbacks `[done]`

The first capability split still left the awkward part visible: both a non-mutating extension and a
mutator exposed `macro_routes/0`, but through two different behaviours. The declaration itself was
identical; only its **provenance** changed what core did. Routes found through a mutator were stamped
with that module as a possible selector host, while routes found through an extension were rejected
if they mentioned `:hosted`/`:routing`. In other words, the API duplicated one fact and the collector
silently supplied the real distinction.

Before 0.1.0, the surface was split on the actual capabilities:

- **`Mutare.MacroRouting.macro_routes/0`** declares static library vocabulary. Enabled mutators and
  modules under `:extensions` are both inspected for it. Its entries may use only `:expression`,
  `:pattern`, `:binding_pattern`, and `:skip`; it is global, merged, and opts-independent.
- **`Mutare.Mutator.MacroHost.hosted_routes/0`** declares only routes containing `:hosted` or the
  `:routing` classifier. The registry stamps these with the contributing mutator, then validates the
  corresponding `host/2` / `macro_routing/1` callback. Returning a static-only entry here is a loud
  contract error, just as returning a host-dependent entry from `macro_routes/0` is.
- **`Mutare.UseExpansion.expand_use/3`** is solely the ordered, opts-aware `use` override. It keeps
  the first-non-`:decline` dispatch and the loud `Mutare.UseExpansion.ContractError` boundary.
- **`Mutare.Extension`** is configuration plumbing, not another behaviour. `:extensions` accepts a
  non-mutating module implementing `Mutare.MacroRouting`, `Mutare.UseExpansion`, or both; a package
  such as Gettext therefore remains one entry while the callbacks have one owner each. Mutators are
  rejected from this list and discovered through `:mutators` instead.

The user-facing `:plugins` and `:macros` keys became `:extensions` and `:macro_routes` at the same
pre-release boundary. There is deliberately no compatibility alias: accepting both names would make
the old conceptual split part of the released contract. Likewise there is no `capabilities/0` or
`extensions/0` manifest; exported callbacks remain the zero-drift capability check.

### Macro routing owns all routing; MacroHost only hosts `[done]`

The split above left a conceptual seam in the wrong place: `Mutare.MacroRouting` owned only static
routes, while `Mutare.Mutator.MacroHost` still owned both `hosted_routes/0` and the shape-aware
`macro_routing/1` classifier. That meant routing had two registration surfaces and a module called
`MacroHost` could be implemented solely to classify arguments without ever hosting a mutation.

The capability boundary now follows the operation:

- **`Mutare.MacroRouting` owns all routing.** `macro_routes/0` is the single registration surface
  for static, `:routing`, and `:hosted` entries; optional `macro_routing/1` classifies concrete call
  shapes. Both enabled mutators and non-mutating extensions may classify dynamically.
- **`Mutare.Mutator.MacroHost` owns only selector delivery.** Its sole callback is `host/2`. A
  mutator that routes a static position `:hosted` implements both behaviours. A dynamic router only
  needs `MacroHost` if a concrete classification actually returns `:hosted`; the resolver rejects
  that result loudly otherwise.
- **`Mutare.Macro.Spec` records the roles independently.** `router` names the provider of
  `macro_routing/1`; `host` names the enabled mutator providing `host/2`. Static routes need neither,
  a dynamic extension has only a router, a static hosted route has only a host, and a shape-aware
  hosting mutator normally has both. This removes the old overload where `host` also meant router.

Declarative `:macro_routes` remains static because configuration cannot supply callbacks. Extensions
may classify dynamically but cannot use `:hosted`, since they deliberately produce no mutations.
The registry still discovers capabilities by exported callbacks and keeps routing declarations
opts-independent.

### Hardening the macro-routing interface for commitment

> *Superseded in part by the next entry ("…one route, many hosts"): `macro_routing/2` became
> `route_arguments/2`, and the single-`host` `{spec, router, host}` `Entry` became a host-list
> subscription. The shrink-and-future-proof rationale below still holds; those two shapes do not.*

Before exposing the routing/hosting behaviours as a contract third parties build on, the surface was
tightened. The capability *boundaries* from the previous entry were right; the work here shrank and
future-proofed what gets committed.

- **Providers live off `Mutare.Macro.Spec`, on the registry's `Entry`.** The `router`/`host`
  fields moved from the public `Spec` struct onto an internal `Mutare.MacroRouting.Registry.Entry`
  (`{spec, router, host}`), stamped only from the contributing module. A user-built `Spec` now
  *structurally* cannot carry (or forge) a provider, so the `clear_providers` defense and the
  `put_router/2`/`put_host/2` setters are gone — the attack they guarded is no longer expressible.
  `lookup/4` returns an `Entry`; `Spec` is committed as pure routing data.
- **`macro_routing/1` → `macro_routing/2`.** The classifier takes an opt-independent
  `t:Mutare.MacroRouting.routing_context/0` (currently `%{pipe_mode: ...}`) so the piped-vs-visible
  arity it must already reconcile is *given*, and so the callback can gain context later without a
  breaking arity change. The context deliberately carries no mutator opts — routing stays a global
  library fact.
- **A hosting mutator needs no vestigial `mutate/1`.** `host/2` is already a producing callback and
  `mutate/1` is optional, so `name/0` + `host/2` is a complete mutator. The reference hosts dropped
  their `def mutate(_), do: :skip`, and the docs teach the minimal form plus a "which behaviours do
  I implement?" table.
- **`macro_routes/0` advertises tuples; struct passthrough is internal.** The public entry form is
  the `{module, name, …}` tuple (`t:Mutare.MacroRouting.route/0`). `resolve/1` still accepts a
  resolved `%Spec{}` idempotently, but only because the `:macro_routes` option is validated once and
  re-resolved in `build/3`; that round-trip is not part of the callback contract.
- **Silently-inert callbacks are rejected at build.** Because capability discovery is by exported
  callback, a typo'd or forgotten route would leave a `host/2`/`macro_routing/2` dead. `build/3` now
  rejects a module whose hosting/classifier callback no route ever reaches, naming the fix.
- **`Mutare.MacroRouting.Registry` (and its `Entry`) are marked internal.** The committed public
  surface is the behaviours, the `Mutare.Macro.Spec` entry forms, and the `Transform.Calls`
  readers — not the registry plumbing.

### Macro routing as an ecosystem contract: one route, many hosts

The first hardening pass still encoded an ecosystem assumption in the registry: every route had
one `host`, stamped from the same module that declared its routing. That works when one package owns
an entire DSL adapter, but not when independent mutation packages target the same Ecto/Phoenix DSL.
It also made duplicate route keys silently last-wins, so installing an unrelated extension could
remove a host without an error.

The committed boundary now separates three things completely:

- **Routing is one library fact.** `Mutare.MacroRouting.macro_routes/0` declares treatments, and the
  shape-aware callback is the more direct `route_arguments/2`. Identical static declarations
  coalesce; conflicting code providers raise `Mutare.MacroRouting.ContractError`. Declarative
  `:macro_routes` remains the one explicit final override.
- **Hosting is a subscription.** `Mutare.Mutator.MacroHost.hosted_macros/0` declares only macro
  identity, never duplicate routing semantics. Every enabled matching host receives the call, so
  one routing extension can support several independent mutators. A static declarative `:hosted`
  route is valid when an enabled host subscribes to it.
- **Callbacks receive stable values.** Routers and hosts receive `%Mutare.MacroRouting.Call{}`
  (natural module atom, resolved identity, visible args, pipe mode/effective arity, rebuild), not a
  raw node that requires reading private resolution metadata. Dynamic routing returns the opaque
  `ArgumentRoutes`, whose `visible` and `piped` spaces are explicit and length-checked. Static and
  dynamic routing share the same recursive treatment grammar, including `:pinned` and
  `{:keyword, …}`.

Host output likewise became the opaque `Mutare.Mutator.MacroHost.Target`, built through `new/4`,
instead of an untyped map. The public route tuple now has an exact type, while `Mutare.Macro.Spec`
is hidden as registry normalization data. Callback failures, malformed results, missing providers,
and provider conflicts use the structured routing `ContractError`; user configuration syntax stays
`ArgumentError`.

Two composition details were fixed immediately after that boundary landed. First, independently
subscribed hosts can return targets for the same source fragment. Emitting their splices naively in
sequence lets a later `List.replace_at` erase the earlier selector while leaving its Sites behind.
`HostedEmit` now remembers the selector for each `{range, logical_original}` target and uses it as
the next selector's catch-all, nesting the selectors so every recorded id remains executable.
Second, the unused-host check cannot use raw selector overlap: a broad dynamic route may overlap a
host while a more-specific static `:skip` route wins every actual lookup. Reachability now evaluates
representative concrete calls through the real specificity cascade; because routes contain only
equality slots and wildcards, every declared constant plus one unmatched sentinel per wildcard
dimension exhausts the lookup-equivalence classes without enumerating an open atom universe.
An exported `host/2` paired with `hosted_macros/0` returning `[]` is rejected at the same boundary;
otherwise the empty list disappears during collection and bypasses that reachability audit.

### Tiering the routing docs; hosts read their targets back from the route

An external review of the extension boundary agreed with the design but flagged two
audience problems before commitment. Both were resolved with docs plus one fixture change —
no API was added.

First, the README's "Skipping macro arguments" section listed all seven treatments in one flat
list, presenting `:pinned`/`{:keyword, …}`/`:hosted` as routine project config. They aren't:
`:skip`/`:expression`/`:pattern`/`:binding_pattern` are the user escape hatch ("this argument
isn't runtime code"), while the other three carry adapter-grade contracts (scalar-only `^`
interpolation; a required enabled host). The README now shows only the user tier and points
adapters at the two behaviours' moduledocs — subtractive on purpose, since the moduledocs
already own the SPI (the Mix task help was already tiered correctly). `Mutare.MacroRouting`
gained a compact "The committed surface" section naming exactly what an adapter may rely on
(the behaviours, `Call` with additive-only fields, the `ArgumentRoutes` constructors/accessors,
`Target.new/4`, the `Transform.Calls` readers, `ContractError`'s fields-not-messages) and that
the registry/spec/metadata/candidates/nesting are not it.

Second, the review called `host/2` receiving the whole call "the main footgun": the route says
*somewhere here is hostable*, and a host seemed to need a parallel classifier to find where. The
requested helper already existed — `Transform.Calls.macro_treatment/1` returns the author-vocabulary
treatments from the node's routing stamp, and the stamp rides the same node `Call` carries — it was
just documented only for *nested* macros. The `MacroHost` docs now state the rule ("`:hosted` is
permission and a delivery mode, not a target list") and position `macro_treatment/1` on the host's
own `call.node` as the way to read the `:hosted` positions back instead of rediscovering them. The
keyword-hosted fixture's `host/2` now does exactly that (dropping its duplicate `keyword_leaves`
classifier), so the existing nested-keyword hosted tests prove the read-back contract end to end.

While there, a `Target`'s `:range` gained the same fail-loud validation as its `:wrap` — checked at
`Target.new/4` for immediate author feedback and again at the dispatch trust boundary (the struct
can be forged) — so a malformed range raises a `ContractError` naming the host instead of crashing
at site-recording time.

A second tiering pass hardened the same boundary in prose. The README's pointer paragraph still
said the adapter treatments "are accepted in `macro_routes:` too", which read as an invitation to
put them in project config; it now says the user tier is the *whole* `.mutare.exs` vocabulary and
that wanting more means you're writing an adapter. The consequences of a wrong assertion —
`:pinned` on a DSL that rejects `^` fails the single compile and is recovered as poison (mutants
discarded, rebuild paid); a misrouted `{:keyword, …}` silently loses coverage; `:hosted` without an
enabled subscriber aborts at scan time — are now stated where adapter authors read: expanded in the
extending guide's routing section, compact in the `Mutare.MacroRouting` moduledoc's new "tiered
vocabulary" paragraph.

The pass initially stopped at docs ("the tier is a responsibility boundary, not a validation one"),
on the theory that an app author vendoring an adapter's route line was legitimate. Reversed the same
day: the vendoring case doesn't need config — a one-module extension carries the same line with an
owner attached — and leaving the footgun loaded contradicted the tier the docs had just drawn. Now
`Registry.validate_config!` rejects a declarative entry whose args are adapter-graded
(`Spec.adapter_graded?/1`: `:pinned`, `:hosted`, or a `{:keyword, …}` wrapper — nested values need
no recursion since the wrapper itself triggers) with an `ArgumentError`, the same class as the
existing declarative-`:routing` rejection at the same choke point; code-provider routes are
untouched. `:routing` stays out of `adapter_graded?/1` on purpose — it is rejected on its own terms
(config cannot supply the callback), and folding it in would misreport that error. One test
consequence: registry tests could no longer inject broad/hosted routes through the config argument,
so the covering-selector check is now exercised by a fixture (`BroadHostedRouteMutator`, whole-module
`:hosted` route + narrower subscription) and the static recursive-grammar transform test moved to an
extension provider (`KeywordInterpolatedRoutingExtension`, né `KeywordPinnedRoutingExtension`),
with a companion test pinning the config rejection.


### Renaming the `:pinned` treatment to `:scalar_interpolation`

The adapter-grade treatment introduced for Ecto's keyword shorthand (see *`:pinned` — `^`-pinned
in-place mutation* above) was named for its delivery mechanism: the selector gets wrapped in `^`.
That name undersold — and slightly misled about — the contract. It read as "some DSL interpolation
marker", when what an adapter is actually asserting and getting is narrower on both sides: **reuse
core's own mutators on this value, but only those that swap a scalar in place**, delivered through
`^` interpolation. Renamed `:scalar_interpolation` so the atom carries both halves of the contract
(scalar-only, interpolation-delivered); the limits are now spelled out where the treatment is
defined (`Mutare.MacroRouting`'s route_arguments doc — scalar-only enforced at transform time,
`^`-acceptance unverifiable and failing as poison, in-place-swaps-only so a variable yields no
mutants) rather than scattered. Deliberately **not** renamed: the emission-side vocabulary
(`Candidate.InPlace.pin?`, `pin_if_needed/2`, `pin_inplace_candidates/1`) still speaks of pinning,
because there it names the emitted `^` shape — the mechanism — not the route. Nothing has shipped
yet (0.1.0 is unreleased), so the rename is free — no changelog entry, no compatibility shim; a
route still returning `:pinned` fails treatment validation at scan time with the usual
invalid-treatment error.


### `:scalar_interpolation` becomes pin-transparent — and becomes `:interpolated`

Probing "what if the value is `^(cond …)`?" showed the scalar framing was wrong in the *other*
direction. An already-`^`-pinned value routed `:scalar_interpolation` hit the compound rejection —
its mutations sit on descendants of the `{:^, …}` top node — so a **static** route aborted the
whole run on idiomatic target code (`where(q, total: ^(a + b))`), a shape where the route's
assertion isn't even violated: past a user-written `^` the code is plain Elixir evaluated at query
build time, where bare selectors are legal. New `route_macro_arg/4` clause: a `{:^, meta, [inner]}`
value descends `inner` as ordinary runtime — arbitrarily deep, no scalar restriction — and leaves
the user's `^` where it was written. The scalar-only rejection now fires for *bare* compounds only,
the case where the assertion genuinely fails. With that, "scalar" no longer described the contract
(a pinned cond mutates deep in its branches), so the treatment was renamed once more, to
`:interpolated`: the value is interpolated data, and core delivers every mutation through the
interpolation — introducing the `^` for a bare scalar, descending inside an existing one. Tested
via `Mutare.PinnedCondFixture` / `Mutare.PinnedListFixture` (hosted_test).


### Owner-death reaping — sandbox runs halt on stdin EOF `[done]`

`System.cmd/3` never guaranteed a sandbox `mix` dies with the Mutare run that spawned it: when
the owning BEAM exits abnormally (SIGKILL, OOM-kill, a closed terminal), Erlang only closes the
port's pipes, and a compute-bound `mix compile`/`mix test` that isn't writing to stdout never
notices — it runs on, reparented to init. Observed in the wild: a `mix compile` orphan at 15 GB
RSS, a survey finding orphans aged 13 h–6 days plus dozens of leaked `/tmp/mutare_sandbox_*`
dirs on a RAM-backed tmpfs. Note the *capped* runs were never the long-lived offenders: the
timeout watcher lives inside the child and self-halts it whether or not the owner survives. The
multi-day orphans are the **uncapped** invocations — the one-time compile above all — or any run
whose owner died before the cap.

**Decision: extend the self-halt primitive, don't adopt a process-tree killer.** The obvious
fix, `muontrap`, wraps the spawn in a C port binary that kills the child's process group when
the Erlang side goes away. It works, but it puts `elixir_make` + a working C toolchain into
every consumer's dep tree, drops Windows, and reintroduces exactly the mechanism PHILOSOPHY
rejects ("kill a hung OS-process tree… platform-specific signals"). The portable alternative
falls out of what a port already is: every sandbox run's stdin is a pipe whose **write end only
the owning BEAM holds**, and the kernel closes descriptors on *any* death, SIGKILL included — so
EOF on stdin *is* the owner-died signal. A third injected snippet
(`Mutare.Sandbox.Command.Invocation.owner_watch_ast/0`) blocks in `:io.get_line/2` and
`System.halt/1`s on `:eof` with `Command.owner_lost_exit/0`. Prototyped before adopting:
owner-SIGKILL → child-dead in 15–50 ms, including 4 concurrent workers (sibling ports do not
inherit each other's pipe write ends — OTP's forker closes them) and a mid-`mix compile` kill
via the config injection.

Mechanics live in the owning moduledocs (`Invocation.owner_watch_ast/0`, `Mutare.Sandbox`).
Two decisions worth recording:

- **Injected at `config/config.exs`, not just the test bootstrap.** Mix evaluates config before
  the compilers run, so the one injection covers the run the bootstrap never reaches — the
  one-time metamutant compile, precisely the most orphan-prone invocation — plus every run's
  boot phase. A target shipping no config gets a generated one (mix loads the default
  `config_path` whenever the file exists). A custom `config_path:` is **deliberately not
  resolved** — that would mean divining it from the target's `mix.exs` (regex- or AST-reading
  build code was weighed and rejected as over-clever for how rare the layout is). Such a
  project simply never loads the injected file: its one-time compile goes unguarded, while
  its `mix test` runs still carry the watcher via the test bootstrap. If that gap ever bites
  in practice, `muontrap` (spawn-side process-group reaping, no injection or layout knowledge
  needed) is the honest fix — not a smarter guesser.
- **Env-gated (`MUTARE_OWNER_WATCH`), armed only by `Invocation.mix/4`.** Not hygiene:
  stdin-EOF means "owner died" only when stdin is the owner's pipe. A sandbox `mix test` run by
  hand in a kept sandbox, or by CI with stdin at `/dev/null`, would otherwise halt instantly.

Accepted limitation: OS processes the *target suite* spawns (a chromedriver, a node) die with
the suite's VM only if their own lifecycle is tied to it — a group/cgroup kill (muontrap) is the
only full answer there. Revisit if it bites in practice.

Windows: the mechanism is deliberately OS-neutral — the OS closes a dead process's pipe handles
on win32 too, and the watcher halts on `:eof` and `{:error, _}` alike (part of why muontrap,
POSIX-only by construction, was passed over) — but it is *unverified* there: CI has no Windows
lane and the regression tests' harnesses (kill(1), a `#!/bin/sh` shim) are POSIX, so both are
`:os.type()`-gated with skip messages saying exactly that.

Deferred, same diagnosis (see `FIX-subprocess-lifecycle.md` while it lives):

- **The one-time compile still has no wall-clock cap.** `[resolved — see "Wall-clock cap for
  the one metamutant compile"; the baseline and coverage probe remain uncapped]` A thrashing
  metamutant compile now dies
  with its owner, but still blocks a *live* run in `System.cmd` indefinitely. The config
  injection point can host a timeout watcher for it (a `MUTARE_COMPILE_TIMEOUT` sibling of the
  test watcher) — no `Task`-wrapper needed on the runner side. The baseline and coverage probe
  are likewise uncapped.
- **No sweeper for leaked sandboxes.** `try/after` cleanup can't survive a hard kill. A safe
  sweep exists if wanted: fresh-mode dir names embed the creator's OS pid
  (`mutare_sandbox_<pid>_<n>`), so pid-liveness + an mtime threshold is the staleness test
  (never mtime alone — a live run's dir root goes stale-looking mid-run); only dirs bearing the
  ownership marker may be removed, and kept-mode digest-named caches never.

Regression coverage: `subprocess_lifecycle_test.exs` (SIGKILL the owner mid-compile, assert the
compiling BEAM reaps itself; verified red with the gate disarmed) and the PATH-shim gate test in
`invocation_test.exs` (`mix/4` arms the gate on every run).

### OOM containment — `:sigkilled` never retried, `:max_heap_mb` heap cap `[done]`

The incident: a `guard_drop`
on `Phoenix.Router.Scope.push/2` made a "normalize the shorthand, recurse" clause
unconditionally self-recursive — each iteration wrapping the previous value in one more
keyword list, all of it reachable, BEAM tail-call-optimized so no stack overflow ever fires.
~25GB RSS in **under a second**, kernel OOM-killed (exit 137) — and then `:harness_retries`
re-ran the identical mutant back-to-back and it detonated *again*. The wall-clock watcher
structurally cannot help: it sleeps inside the starved VM and a sub-second blowup outraces
any deadline it could hold. Two independent mitigations, both shipped:

- **`:sigkilled` (exit 137) is decoded by name and never retried.** The mirror image of
  `:boot_failure` (known-transient, retried *harder*): an OOM kill is deterministic given the
  mutation, so a hot retry re-detonates on the host. The trade-off was weighed: a *transient*
  SIGKILL (an innocent run reaped under a guilty neighbour's memory pressure, an external
  kill) loses its retry and records one excluded-from-score harness error — cheap; retrying a
  real one costs the machine. Fail toward the host. The verdict stays `:harness_error`; the
  warning names the likely cause and points at `--max-heap-mb`.
- **`:max_heap_mb` — the self-halt philosophy applied to memory.** Same reasoning that
  rejected muontrap above (no cgroups, no process groups, no C toolchain, nothing
  platform-specific): the emulator already owns a per-process kill switch, `+hmax`
  (default `max_heap_size`), injected via `ELIXIR_ERL_OPTIONS` on the *runtime* runs —
  baseline, probe, per-mutant. The runaway process (the test process exercising the mutant)
  dies with reason `:killed` → an ordinary, fast test failure → the mutant records `:killed`
  in milliseconds instead of racing the kernel for the host. Running the **baseline under the
  same cap** doubles as validation: a cap too small for the suite fails loudly up front, not
  as false kills mid-run. The one metamutant compile is deliberately uncapped (~25× sources;
  compiler processes are legitimately huge). Opt-in (`nil` default): a cap that silently
  killed a legitimately memory-hungry suite process would manufacture false kills, so the
  user picks the number. Known limit (in `Invocation.heap_cap_env/1`'s doc): `max_heap_size`
  counts the process heap — lists/tuples/maps, the runaway-recursion shape — not off-heap
  refc binaries; a pure binary-append blowup escapes it.

Regression coverage: `heap_cap_test.exs` reproduces the incident's growth shape (on-heap list
doubling behind a droppable guard) with an intrinsic emergency bound sized *above* the cap-kill
threshold, so the test distinguishes a working cap (process killed, no bound reached) from a
broken one (bound reached) without ever endangering the host; `harness_test.exs` proves an
exit-137 mutant runs exactly once despite a generous `harness_retries` budget.

### `PatternWildcard` counted a module-attribute read as a variable `[done]`
Found running Mutare against stock phoenix_live_view: `lifecycle.ex` heads like
`def after_render(%Socket{private: %{@lifecycle => lifecycle}} = socket)` produced two
compile-breaking mutants (34 poisoned sites across the file). An attribute read in a pattern
(`@lifecycle`) is a compile-time constant key, but its *inner* AST node (`{:lifecycle, meta, nil}`)
has plain-variable shape, and the occurrence walk descended into it:

  - it was offered as a wildcard target itself → the nonsense `@_`;
  - it was **counted** as a second occurrence of the same-named real binding, so the
    "a binding always remains" policy believed thinning was safe and wildcarded the
    one real `lifecycle` — stranding the body read (`undefined variable`, hard
    CompileError, exactly the class the family exists to never produce).

Fix: attribute nodes are opaque to the walk — neither counted, descended, nor replaced —
the same treatment pins (`^x`) already got, next to the bitstring-spec exclusion (the
previous instance of "var-shaped AST that isn't a variable"; `__MODULE__` never bit only
because underscore-prefixed names were already excluded). Regression tests cover both
halves (not offered; not a phantom duplicate). The poison pre-filter would have recovered
these at runtime, but built-in families must be compile-safe *by construction* — poison is
the backstop for the unknown, not a license.

### Type inference and verification off for the metamutant compile `[done]`
On Elixir ≥ 1.18/1.19 the dominant cost of the one metamutant compile is not codegen but the
**type checker**, and on some targets it is not a tax but a cliff. Measured cold (deps
pre-seeded, OTP 26 / Elixir 1.19.5, 16 cores, `MaxRSS` via `/usr/bin/time -v`):

  - **phoenix_live_view (~23k sites) never finishes on stock config**: killed after 80+ min
    (vs ~30 s for the unmutated app). Five modules trigger it (`diff.ex`,
    `tag_engine/compiler.ex`, `channel.ex`, `upload_config.ex`, `test/client_proxy.ex` — the
    `--long-compilation-threshold` warnings name them). With signature inference off the
    compile phase is **14 s**; the verify pass alone still costs **~12.5 min** (cross-module
    type checking against stdlib/dep signatures), so both must go: inference off + verify off
    → **14 s total**. The pathology is shape-dependent, not volume-dependent: Mutare-on-Mutare
    (22k sites) and phoenix (14.5k) compile in ~11 s with the checker fully on.
  - Both switches are **diagnostics-only** — warnings on a build artifact nobody lints; the
    compiled code a mutant executes is byte-identical, so unlike `no_ssa_opt` there is no
    per-run price. Poison detection is untouched: it reads hard compile *errors*, raised
    during compilation, not verification.

Delivery is split by what each switch is (all three compile-tuning switches keep one home,
`Mutare.Sandbox.CompilerOptions`):

  - `--no-verification` → `CompilerOptions.compile_args/1`, spliced into the runner's one
    `mix compile`. **Version-gated** (`>= 1.19.0`, when the switch appeared) because an
    unknown switch makes `mix compile` abort — the opposite failure mode of
    `ERL_COMPILER_OPTIONS`, where unknown options are silently ignored. Pre-1.19 verify has
    no cross-module type checking, so nothing meaningful is forgone.
  - `infer_signatures: false` is project-level `elixirc_options` with **no CLI or env form**.
    The original delivery used `Code.put_compiler_option/2` in the `config/config.exs`
    prefix, which took the stock phoenix_live_view sandbox from 80+ min (killed) to 21 s.
    This was superseded by the project wrapper below: Mix 1.20 overwrites the global
    setting even without an explicit target override, and custom config paths never
    loaded that prefix.

Memory, the question that prompted the measurement, turned out secondary: peak RSS of the
compile is base (~110 MB) + the few biggest generated modules (210–380 MB each above base;
mutare 558 MB / phoenix 589 MB / phoenix_live_view ~1.1 GB at 16 schedulers). It is
floor-bounded by the single biggest module, so concurrency capping (`ELIXIR_ERL_OPTIONS`
`+S 2:2`) trims 23–51% of peak for 1.4–2.8× wall — a plausible future `--compile-workers`
opt-in for memory-starved CI, not a default. `no_ssa_opt_alias` is memory-neutral (324 vs
319 MB on the worst module). No memory work shipped; the numbers live here for when it bites.

### Inference must be disabled in the effective sandbox project `[done]`

Elixir 1.20.4's
[`Mix.Tasks.Compile.Elixir`](https://github.com/elixir-lang/elixir/blob/v1.20.4/lib/mix/lib/mix/tasks/compile.elixir.ex)
unconditionally reads inference from
`elixirc_options`, defaults it to true, and supplies the result to the compiler. A
global `Code.put_compiler_option(:infer_signatures, false)` during configuration therefore
does not protect the metamutant. Observing that global setting immediately after the
snippet runs cannot test the actual contract.

`CompilerOptions.project_source/1` now appends a dependency-free `before_compile` hook
to the sandbox's root and umbrella-child `mix.exs` modules. Only Mix project modules are
wrapped: `project/0` calls its original implementation, preserves its computed options,
and sets `infer_signatures: false` when the running Elixir supports it. The hook follows
the target's own hooks, including one that generates `project/0`. Generated coverage
support projects receive the same wrapper. The target checkout stays unchanged.

This deliberately reverses the former precedence rule: an explicit target
`infer_signatures: true` used to win over the config prefix. The sandbox now overrides
that setting too, because inference on the generated metamutant can stall the one
compile regardless of why the target enabled it. Other compiler options retain their
target-defined values; the explicit/computed-options tests exercise this override.

Why wrap the function instead of updating `Mix.ProjectStack` from config? Mix pushes
cached umbrella project modules again without re-evaluating `mix.exs` or the root config;
a stack-only override disappears at that point. A `project/0` wrapper also covers custom
config paths without interpreting the target's configuration. Every baseline/probe boot
sees the same inference setting, so it cannot initiate a recheck solely because that
setting changed since the initial compile.

Regression tests observe the setting inside a module compiled by real sandbox `mix
compile`, then run baseline/probe boots and assert the compilation manifest stays
unchanged. Explicit/computed compiler options, custom config paths, generated project
functions, and cached umbrella children are covered as well. These tests passed on
Elixir 1.19.5 / OTP 26 and Elixir 1.20.4 / OTP 27.3.4.13.

The wrapper follows `defmodule` forms in `mix.exs` (including explicit
`Kernel.defmodule` and keyword-`do:` bodies), stopping at quotes so exported templates
never acquire a dependency on the sandbox bootstrap. The injected hook atom uses
`AST.literal/1`: a bare quoted atom crashes the formatter in a keyword-`do:` body.
Parsing and rendering are best-effort and return the original source on failure.
Discovery includes unused umbrella directories and scaffolding templates; failing
to optimize one must not make it required for sandbox preparation. An unusual project
whose entire Mix project module comes from a
separately required file does not receive the hook. Supporting that layout would require
intercepting module creation or extending the overlay to external build sources; neither
is inferred by evaluating the target's build code in Mutare's process.

**The wrapper must agree with the transplanted build.** Elixir 1.18/1.19 includes
`elixirc_options` in its incremental cache key. The target's manifest usually records
`[]`; our wrapper returns `[infer_signatures: false]`. Relocating paths alone therefore
discarded the entire app seed on the first sandbox compile, despite reporting reused
beams. Tests that started with an empty build and checked only later boots missed it.
`CompilerOptions.seed_manifest/1` now adjusts only that inference entry when `Seed`
transplants an app's Elixir manifest. Disabling diagnostic inference leaves those
original beams usable; every other cache-key component remains intact, so real option
changes still force a rebuild. Retained sandbox builds and dependency builds never pass
through this adjustment. Unlike path relocation, this reads a private Mix layout: it
recognizes the 1.18/1.19 manifest versions and leaves unknown layouts alone, accepting a
cold compile when necessary. Elixir 1.20 tracks inference separately from the cache key.
Real-compile regressions precompile the target, select one source, and observe that
untouched modules compile only in the target, including umbrella siblings. They also
check explicit options plus xref exclusions, a changed `:docs` option, and subsequent
baseline/probe boots.

### The seeded manifest must follow the wraps that landed, not the ones attempted `[done]`

`CompilerOptions.project_source/1` only reaches the `mix.exs` files `Mutare.Sandbox` overlays,
and those come from `Project.project_dirs/1` — the root, plus each umbrella child. Anything
else in `_build/<env>/lib` that is not a dependency compiles with inference **on**: most
concretely a `path:` dependency living outside `deps/`, which is seeded like an in-project app.

Stamping such an app's transplanted manifest with `infer_signatures: false` is worse than not
wrapping it, and worse in two ways at once. Inference stays on, so the app keeps the
slow-compile cliff the wrapper exists to remove; and Mix computes the cache key from the app's
*actual* effective options, sees a mismatch, and cold-compiles the whole app, discarding the
seed. `seed_one/7` reports `{:seeded, reused, …}` either way — its success predicate only asks
whether every metamutant beam was deleted — so the failure arrives as a success line.

**Sharing one list was not enough, and the first fix asserted rather than observed.**
`wrapped_apps/2` originally derived the stamped set from `%Project{}.apps`, on the reasoning
that both halves read `project_dirs/1`. They do — but the list is what Mutare *offers*, and
three paths decline it after the list is consulted, none of them visible to the caller:
`project_source/1` rescues an unparseable source or a render Elixir cannot read back;
it finds no module to hook when the project is built in an externally required file
(`Code.require_file/2`); and `Sandbox.project_files/2` drops a `mix.exs` it cannot read. The
middle one is the trap — the source still comes back **changed**, because the bootstrap is
prepended unconditionally, so `!=` cannot be used to recover the outcome.

`project_source/1` therefore returns `{source, hooked?}`, `override_files/3` collects the paths
that reported `true`, and `prepare/3` threads that set to `app_build/6`. Both sides still start
from `project_dirs/1` and rebuild the key with the same `Project.project_file/1`; what changed
is that the stamp now follows an observed outcome instead of an intention.

One gap remains, and nothing available before the compile closes it: `hooked?` reports the
*source rewrite*, while the hook makes the real decision at compile time (`Mix.Project`'s
after-compile hook registered, `project/0` defined). A `mix.exs` holding only an unrelated
helper module beside a required-in project reports `true` and is still declined. The manifest
is stamped before the compile that would say so, so the residual false positive is accepted —
it is strictly narrower than the blanket one it replaces.

The regression test for the original fix was itself an instance of the bug: its fixture wrote
no `mix.exs` at all, so nothing was ever wrapped, and it asserted that the child app *was*
stamped. It now materialises a wrappable child and checks the sandbox copy really carries the
hook, with a companion case where a listed app's `mix.exs` declines the wrap and must be left
unstamped.

**Not fixed, and older than this work:** `Project.umbrella_root?/1` requires a literal `apps/`
directory, and `app_entry/1` hard-codes `Path.join("apps", name)`. An umbrella declaring
`apps_path: "packages"` is not recognised as an umbrella at all — `resolve/2` falls through to
`single_app/1`, discovery scans the root's (empty) `lib/`, and the run finds zero mutants and
does nothing. That is a whole-pipeline gap, not a wrapper gap; wiring the wrapper to a layout
the scanner cannot reach would only make it fail later. Fixing it means reading the declared
`apps_path` value in `declares_apps_path?/1` (which today only checks the key *exists*) and
threading it through app discovery, scoping, and umbrella test narrowing.

### A declined inference wrap is narrated, and the render check compares programs `[done]`

The entry above made the seed follow the wraps that landed, but left the declining paths as
silent as before. A declined `mix.exs` compiles with inference on (the 14 s → 80+ min cliff), and
nothing said so: the compile simply ran long enough to look like a hang. Three changes followed
from one review finding.

**Narrated like Seed's own fallback.** `project_source/1` now returns `{:hooked, source}` or
`{:declined, source, reason}`. `Sandbox.prepare/3` logs each decline at debug level and fires
`{:inference_override_declined, %{file: _, reason: _}}` on `:on_phase`, which `Live` renders under
`--verbose`. The no-module path is narrated too: it is not a rescue, but it has the same
symptom. Only `prepare/3` narrates. Poison recovery's `rematerialize/2` never re-wraps, so the
note appears once per run. Verbose-only follows Seed's precedent and is not a settled judgement:
poison rounds print in every mode for the same "reads as a hang" reason. The cost of every-mode
here is that a persistent condition (a scaffolding template, a required-in project) would print
on every run.

**`rescue` gained a `catch`.** A `throw` or `exit` from Sourceror or the formatter escaped the
bare `rescue` and aborted sandbox preparation, the opposite of best-effort.

**The guard compares what Elixir reads, not whether it reads.** `Code.string_to_quoted!(rendered)`
proved only that the render parsed. A Sourceror slip that still parses (a moved expression, an
altered literal, a dropped hook) would have become the sandbox's entry point. A dropped hook would
also still report `hooked?`, which `Seed` trusts. Now Elixir's parse of the render must equal the
bootstrap followed by Elixir's parse of the original, hooked by the same walk. The walk runs
unchanged on both AST dialects, because `AST.key_atom/1` reads either keyword encoding and
normalisation unwraps the hook's literal block. Normalisation erases only what a render
legitimately re-spells:

  - metadata;
  - block nesting (Sourceror parenthesises a hooked module body into its own block);
  - an empty block, which Sourceror renders as `nil`;
  - a `~c` sigil without interpolation or modifiers, which Sourceror emits for a single-quoted
    charlist in call arguments and statements (it keeps the quotes inside a keyword value).

Each normalised form evaluates exactly as what it replaces, so no change of meaning can pass
through them. An interpolated charlist is not normalised, so a render that re-spells one declines.

Measured over every `mix.exs` under `~/dev` (5,053 files, 982 distinct): 971 hooked and 11
declined as unparseable. The 11 are Phoenix installer EEx templates, which the old guard declined
too. None was declined for meaning. The first version of the check declined one real file,
`System.cmd("make", ['clean'], …)` in a do-block; that was the `~c` re-spelling, found this way
and now pinned by the layout-only test. No real Sourceror slip turned up, so the check guards a
class of failure, not a known instance.

### The hook keeps the value a module body evaluates to `[done]`

`defmodule` returns `{:module, name, binary, value}`, `value` being the last expression of the
body. Appending `@before_compile …` to the body made that value `:ok` (registering an attribute
evaluates to `:ok`), so a `mix.exs` that matches on it — `{:module, _, _, :ready} = defmodule …`
— raised `MatchError` in the sandbox while `project_source/1` still reported `:hooked`. The
render check could not catch it: `same_program/2` compares the render against the *same* walk,
so a walk that changes meaning passes its own test. That is the check's boundary — it guards
the renderer, not the rewrite — and it is worth remembering when the walk changes.

Two ways to keep the value. Prepending the hook keeps the body's last expression last, but
before-compile hooks run in registration order, and ours must run *after* the target's own so a
`project/0` those generate is already defined when ours checks `Module.defines?/2` (the
integration test "project defined by an earlier before_compile hook is also wrapped" pins
this). So the hook stays appended and the body's value is carried past it in a variable:
`mutare_sandbox_module_value = (body); @before_compile …; mutare_sandbox_module_value`. An
`alias`/`import` inside the parenthesised body still scopes over the body's own statements, and
nothing after the block needs them. The variable is a plain name once rendered, hence the
unmistakable spelling. Re-swept over every `mix.exs` in the repo (examples, `deps/`, the
`tmp/` sandboxes: 195 files) after the change — all still hook.

### Interpreted module definitions `[experiment — no default change]`

Elixir 1.20's `elixirc_options: [module_definition: :interpreted]` changes execution of
module-definition code during compilation; defined functions still become ordinary BEAM
code. The sandbox project wrapper preserves an explicit choice of this option. A gated
integration test on Elixir 1.20.4 / OTP 27.3.4.13 runs a retained sandbox first with
`:interpreted`, then with `:compiled`: both correctly attribute one compile-poisoning mutant,
recover, and kill the two compile-safe mutants. A module records the effective mode during
compilation, so the fallback is observed rather than assumed.

A small compile-only experiment on that toolchain, 16 schedulers, used the pre-improvement
`bench/compile_shapes.exs` case-100 metamutant (1,467,730 source bytes). Source generation was
outside the timed interval; three alternating runs per mode used `mix compile --force
--no-verification --profile time`, `MIX_ENV=test`, `MIX_DEBUG=1`, and
`ERL_COMPILER_OPTIONS='[no_ssa_opt_alias,time]'`, with inference disabled in both projects.
`/usr/bin/time` measured wall time, user+system CPU time, and peak RSS:

| Module definitions | Median wall | Median CPU | Median peak RSS |
| --- | ---: | ---: | ---: |
| `:compiled` | 5.02 s | 8.92 s | 285,996 KiB |
| `:interpreted` | 5.04 s | 8.96 s | 305,748 KiB |

No compilation win on this generated shape, and about 6.9% more peak memory. This small
synthetic experiment says nothing universal about large projects or other generated shapes;
it does not justify a new default. Retain the explicit project opt-in, particularly given
the interpreter's less precise error stacktraces and 20-argument limit for anonymous
functions executed during module definition. Neither limit applies to ordinary defined
functions in the resulting application.

### Wall-clock cap for the one metamutant compile `[done]`
The deferred item above, built exactly as sketched there — made urgent by the type-checker
cliff two entries up (a compile that runs 80+ minutes is indistinguishable from one that
never finishes, and the owner-death watcher only helps when the *owner* dies; a live run
blocked in `System.cmd` indefinitely). The design reuses both existing primitives, one new
name each:

  - **The watcher** is the per-mutant timeout watcher verbatim (`Invocation.deadline_watcher/1`
    now builds both), armed by its own env var (`MUTARE_COMPILE_TIMEOUT`,
    `Invocation.compile_timeout_env/0`) and hosted in the `config/config.exs` prefix — the
    same "config runs before the compilers" property the owner-death watcher uses.
    A dedicated variable, not `MUTARE_TIMEOUT`, because the config
    prefix is evaluated on *every* sandbox boot: only the runner's compile invocation sets it,
    so the baseline, the coverage probe, and every per-mutant `mix test` evaluate the watcher
    inert. It halts with the existing `Command.timeout_exit/0` (124) — same meaning,
    "self-halted past a wall-clock cap".
  - **The option** is `:compile_timeout` (`--compile-timeout`, ms), default **30 minutes**,
    `nil` to disable. Generous on purpose: the cap bounds *pathological* compiles (the
    observed multi-day orphans, the 80-minute type-checker cliff), not legitimately slow
    ones — a cold compile of a big target with unseeded deps is the slowest honest case and
    stays far under it. No baseline exists yet to derive from (contrast `:timeout`), so a
    fixed generous default is the only shape available.
  - **The decode**: `Runner.compile/3` maps exit 124 to `:compile_timed_out`, a new top-level
    error like `:dependency_failed` — and like it, *never* fed to poison recovery: there is no
    compiler error to attribute to a mutant, and a rebuild cannot make an oversized compile
    faster. Each poison-recovery retry does get a fresh cap (the env is set per invocation).
    The Mix task's message names the option and points at the known pathological class.

Regression: `compile_timeout_test.exs` (`:runner`) — a module body that sleeps 10 minutes at
compile time (baseline code, untouched by the pinned arithmetic run) under a 2 s cap surfaces
`{:error, :compile_timed_out, _}` in ~3 s wall; any broken link in the chain
(env threading → config snippet → self-halt → decode) would instead hang to the test's own
timeout.

Still uncapped, knowingly: the baseline and the coverage probe (the remainder of the deferred
bullet). Both run *after* a successful compile with the suite's own semantics, so a cap there
wants `:timeout`-style derivation rather than a fixed bound; deferred until it bites.

### Coverage-probe livelock in unlabeled hot loops `[fixed — memoized label recovery + probe cap]`
The deferred half of the entry above bit immediately: `mix mutare` on phoenix_live_view got
"stuck forever" at the probe stage — a green ~2-minute baseline whose *instrumented* run never
finished (BEAM pinned at ~1100% CPU, output trickling then flatlining). A SIGUSR1 crash dump of
the spinning node showed every busy process inside `mutare_cov:hit/1` →
`Enum.find_value` → `label_of` → `Process.info/2`, called from LiveView's hottest loops
(`Phoenix.LiveView.Channel.render_diff/3`, `LiveViewTest.TreeDOM.do_reduce/3` under
`ClientProxy.init/1`).

Root cause: `hit/1` resolved the owning-test label **before** consulting the per-process seen
cache, so the cache only ever suppressed ETS writes — the label dance ran on *every* hit. For a
labeled test process that was one full `Process.info(self(), :dictionary)` copy per hit (OTP ≤ 26);
for an **unlabeled** process (a LiveView channel, a `ClientProxy`) it was an own-stacktrace build
plus a `$callers`/`$ancestors` walk doing cross-process `Process.info` — a signal round-trip per
pid that also interrupts each target. Millions of hits inside render/diff loops multiplied a
~2-minute suite into an unbounded crawl, and the round-trips hammered every process in the
attribution chain, which is why the whole node was busy, not one process.

The fix keeps the freshness contracts and moves the cost to where each contract needs it
(`Mutare.Coverage.HelperTemplate`, `label/0`):

  - **Own label**: still re-read every hit (a reusable process relabeling itself must be seen),
    but via `Process.get(:"$process_label")` — `Process.set_label/1` stores under that pdict key
    on every supported Elixir/OTP, so the per-hit cost is a pdict lookup, not a dict copy.
  - **Recovery tiers** (own-stack ExUnit frames; the caller/ancestor walk): memoized in the pdict
    as `{callers, witness, label}` and revalidated per hit with local reads only — recomputed when
    the `$callers` value changes (a reused worker serving a new caller; also lets a memoized
    "unlabeled" result upgrade once a caller appears) or the witness pid that produced the label
    dies (the long-lived-Task-outlives-its-test case, which must degrade to unlabeled/whole-suite).
    The walk now also skips remote pids — `Process.info/2` raises on them, and a cross-node caller
    maps to no local test file.

Empirically: the same sandbox that spun >30 minutes without finishing completes its probe run in
**18.5 s wall** with the memoized helper (a ~17 s suite — instrumentation overhead back to noise).
Regressions: `helper_template_test.exs` pins the two new revalidation edges (caller-chain change
re-attributes; unlabeled-then-gains-a-caller attributes) alongside the existing relabel and
caller-death tests.

And the probe is no longer uncapped: `CoverageProbe.run/5` now takes a cap — `Runner.probe_cap/2`,
10× the per-mutant cap, i.e. the `:timeout`-style derivation the entry above asked for (default
30× baseline, floor 100 s) — armed through the ordinary `MUTARE_TIMEOUT` self-halt watcher. An
overrun exits 124, is named in the warning ("overran its cap" — pointing at the remedy), and
degrades to run-all like any other probe failure: coverage is advisory, so a pathological capture
must cost selection quality, never hang the run. The cap is configurable as **`:probe_timeout`**
(`--probe-timeout`, ms), mirroring `:timeout`'s explicit-beats-derived shape (`nil` = derived);
deliberately *no* uncapped setting — a legitimately slow instrumented suite wants a bigger number,
not the hang back (`:full` is no escape either, that mode probes too). The **baseline** stays
uncapped, knowingly — it has no earlier timing to derive from, and a hung baseline is the suite's
own behavior, not instrumentation's.

### Selection-quality hardening: probe retry + `on_exit` attribution `[done]`
Follow-on to the livelock entry above, prompted by the observation that every path into
"run the whole suite" — the probe's run-all degrade at run level, the unlabeled bucket at
mutant level — makes mutation testing de facto infeasible on a large target. Two levers, both
sound; two weighed and left (for now):

  - **The probe retries once before degrading** (`@probe_attempts` in `CoverageProbe`). The
    baseline was confirmed green *moments* earlier, so a non-zero probe is far more often a flaky
    test than anything systematic — and one flake used to cost the entire run's selection,
    silently. Each attempt clears the dump first (`after_suite` writes it even for a failing
    suite, so a failed attempt leaves a partial dump the retry must not trust). A **cap overrun is
    not retried**: it is systematic, and the retry would just burn another full cap. Regression:
    `coverage_test.exs` "probe-only flake is retried" (marker-file flake: fail the first
    `MUTARE_COVERAGE` run, pass ever after → the uncovered mutant stays `:no_coverage` instead of
    a run-all survivor).
  - **`on_exit` callbacks registered in a test body now attribute** to their test's file
    (`on_exit_frame/1` in the helper) instead of falling to the unlabeled (whole-suite) bucket.
    Two stack signals are required together: ExUnit's per-test `on_exit` runner-loop frame
    (`ExUnit.OnExitHandler.on_exit_runner_loop/0` — the callbacks run in a dedicated per-test
    process, so the label memo can't leak across tests) *and* a `:"-test …/N-fun-M-"` closure
    frame, whose embedded space can't occur for a target's own function. Requiring both is the
    soundness line: an `on_exit` failure fails the *owning* test (its file kills the mutant), but
    a detached `spawn` from a test body carries the identical closure frame and may only be
    observable from another file — it must stay unlabeled. Also deliberately not recognised:
    `-__ex_unit_setup…` closures (a `setup`-registered `on_exit`), which can live in an
    `ExUnit.CaseTemplate` whose `test/support/*.ex` source is not a runnable test file — feeding
    that to `mix test` would be worse than conservative. If ExUnit renames the runner loop, the
    match stops firing and `on_exit` ids degrade back to unlabeled — never wrong.

Weighed and left until asked for: **abort-instead-of-degrade** (a `--strict-coverage` that fails
the run rather than accepting run-all) and a **`:max_run_all` gate** (abort if selection quality
collapses past a budget) — both are policy knobs on top of the same signals, easy to add when a
large-project user wants the loud-failure contract. Also rejected on soundness grounds: salvaging
a *partial* dump from a failed probe — an id attributed to file A may also be covered by a file
the aborted run never reached, so its covering-file set is silently incomplete and selection built
on it can manufacture false survivors; retry-then-degrade is the sound shape.

### PropCheck counter-examples DETS corruption under concurrent workers `[fixed]`
Found dogfooding mutare on itself with `--workers 4`. `PropCheck.App` starts
`PropCheck.CounterStrike` at *application boot* — i.e. on every `mix test` invocation,
whether or not a `:property` test actually runs — which opens a single on-disk DETS file
(`_build/propcheck.ctex` by default). Under `--workers N` (N > 1), several `mix test` OS
processes boot concurrently against the *same* sandboxed `_build`, and DETS isn't safe for
concurrent multi-process opens: the shared file gets corrupted. Once corrupted it stays
corrupted on disk, so with `--keep-sandbox` every subsequent run — any mutant, even a future
invocation — fails `PropCheck.CounterStrike.init/1`, and the *entire* baseline suite reports
not-green; mutare surfaces that only as undifferentiated `:harness_error` on every mutant, with
nothing pointing at PropCheck as the cause.

Fixed in `mix.exs`'s `project/0`: give each `mix test` process a private counter-examples file
while under mutation, via the `propcheck: [counter_examples: …]` project-config key PropCheck
itself reads (`PropCheck.Mix.resolve_counter_examples_file/0` checks `Application.get_env(:propcheck,
:counter_examples)` first, then falls back to this key via `Mix.Project.config()`, then the shared
default). Keyed on `MUTARE_ACTIVE_MUTANT` (set on the baseline, the coverage probe, and every
mutant run — see `test/test_helper.exs`) and namespaced by `System.pid()` (the invoking BEAM's own
OS pid, stable for that process's lifetime, distinct across concurrent workers) — since each
`mix.exs` is evaluated fresh per OS process, this reads correctly per invocation with no
extra plumbing. Normal local/CI runs (no `MUTARE_ACTIVE_MUTANT`) fall through to `nil`, which
resolves to the ordinary shared, cross-run-cached default file — unchanged.

One follow-up caught before it shipped: the private file must live *inside* the sandbox
(`Path.join(File.cwd!(), "_build/propcheck-#{pid}.ctex")` — every sandboxed `mix test` has its cwd
set to the sandbox root, per `Sandbox.Command.Invocation`), not in the OS-wide tmp dir. The
sandbox directory is a subdirectory of `System.tmp_dir!()`, not the same path, so a file written
directly to `System.tmp_dir!()` is a *sibling* of the sandbox, not a descendant — an ephemeral
(non-`--keep-sandbox`) sandbox's teardown (`Runner.cleanup_sandbox/2`, `File.rm_rf(sandbox)`) would
never reach it, leaking one small DETS file into `/tmp` per mutant run (baseline + probe + every
mutant), forever, in both sandbox modes alike.

### Why `:mutare` (and companion mutator packages) need `only: [:dev, :test]`, not just `:dev`
The scan — where mutator modules actually run, whether built-in, a hand-written custom mutator,
or a companion package like `mutare_ecto` — executes in the process that invoked `mix mutare`.
That task declares no `@preferred_cli_env`, so it inherits whatever env it's run under: `:dev`
by default. The sandboxed side is fully decoupled from all of this — the injected bootstrap
(selector reader, timeout/owner-death watchers, coverage helper) is plain generated source with
zero `Mutare.*` references (`Sandbox` moduledoc), and the per-mutant `mix test` subprocess never
loads `Mutare` or any mutator module. So "does the mutator run inside the sandbox" is never the
reason `:test` is needed — it isn't, for built-in, custom, or companion mutators alike.

What actually forces `:mutare` into `:test` is Mix's dependency-env model: a dep scoped
`only: [:dev, :test]` gets *compiled* whenever the current build is in `:test`, independent of
whether your own code references it. `Mix.Tasks.Mutare.Install` scopes every companion package
that way (`maybe_add_dep/2`), so `mutare_ecto`/`mutare_phoenix`/etc. are compiled on every
ordinary `mix test` you run — not only when `mix mutare` itself runs — and that compile needs
`Mutare.Mutator`/`Mutare.Mutator.Families` reachable, so `:mutare` must be present in `:test`
too. A hand-written custom mutator hits the identical wall if it lives under `test/support/`
(the conventional location — see `guides/extending.md` and Mutare's own `test/support`
fixtures): `elixirc_paths(:test)` compiles it on every plain `mix test`, sandboxed or not.

Second, independent reason: some CI pipelines set `MIX_ENV=test` globally and run every `mix`
command under it, including `mix mutare`. Since the task has no preferred env of its own, a
`:dev`-only `:mutare` would make `MIX_ENV=test mix mutare` fail to even find the task.

Neither reason is about the sandbox or about who authored the mutator — it's about which env(s)
actually compile the mutator module, wherever it lives. A project that (a) never invokes any
`mix` command under `MIX_ENV=test` except `mix test` itself, and (b) keeps every custom mutator
and companion package scoped `only: [:dev]`, could genuinely skip `:test` — but that's a fragile
deviation from what the installer and README set up by default, not a recommended configuration.

### Report diff fidelity for interpolated strings that escape the quote `[fixed]`
A dogfood run on a Phoenix app rendered two corrupt survivor diffs on
`|> toast("User status set to \"#{new_status}\".")` — the `string` family's whole-literal
swaps came back as `toast(""")` and `toast("mutare"")`, a stray closing quote after the
replacement. Same class as the sigil escaped-delimiter fix above, and literally the same
upstream mechanism: Sourceror parses with escapes kept raw (`\\`/`\n`/`\t` stay two-char
sequences — which is why those never bit), **except** the tokenizer collapses an escaped
closing delimiter, and that collapse applies to plain interpolated strings too (`\"` → `"`,
`\'` → `'` in a charlist). `get_end_pos_for_interpolation_segments/3` then sizes the tail
after the last interpolation by stored `String.length`, so the range ends one column short
per trailing `\"` and `Sourceror.patch_string` leaves the original closing quote in place.

Only the *interpolated* form is affected: a non-interpolated string parses as a single
`__block__` literal whose stored content keeps the backslash (Sourceror's count is right),
and an escape *before* the last interpolation is absorbed by the interpolation's absolute
`closing` metadata (same subtlety (c) as the sigil entry). The collapse was confirmed for
all three interpolated containers — string (`<<>>` + `delimiter` meta), charlist
(`List.to_charlist` call), quoted atom (`:erlang.binary_to_atom` call) — so
`Mutare.Transform.NodeRange.get/1` now applies the same trailing-binary-segment count to
each; the exactness argument carries over verbatim (a bare quote in stored tail content
can only have come from `\"`). Heredocs fall through (the fence never escapes its tail),
as does a delimiter-less `<<…>>` (a real bitstring, BitstringLiteral's domain).

Two punts, both deliberate: (a) the correction keeps the sigil fix's single-line
guard, because Sourceror's own end column for a multi-line tail is computed
start-relative (`start_pos[:column] + length`) and is wrong on its own — there is no
stable base to add columns to; (b) a paren-less call whose *last argument* is such a
string (`foo "a#{x}\"b"`) still ranges the enclosing call through the uncorrected
`Sourceror.get_range` recursion — `NodeRange` corrects only the node it is handed, same
as the sigil fix. Neither shape has surfaced in a real diff yet.

A pure report-rendering fix; regression tests assert the corrected widths per container
and that the exact reported shape renders clean, re-parseable diffs
(`transform/node_range_test.exs`, `report_test.exs`).

### Interpolated atoms & charlists mutate as a whole; BitstringLiteral no longer claims atom content `[done]`
An interpolated quoted atom `:"a#{x}b"` parses as `:erlang.binary_to_atom(<<segments>>, :utf8)`
with the parser's `:delimiter` on the *call* meta — unlike an interpolated string, whose
`:delimiter` rides on the `<<>>` itself and is the discriminator the analyzer's three-way
`{:<<>>, …}` split keys on (see "Three constructs share the `{:<<>>, …}` shape"). So the
atom's inner `<<>>` looked like a bare bitstring construction: BitstringLiteral collapsed
it to `<<>>` — a compile-clean but *misattributed* mutant (really `:"…"` → `:""`, reported
as `:bitstring`, so `# mutare:ignore[bitstring]` semantics lied) with a corrupt diff (the
range was the inner content's, and the patch text `<<>>`). Meanwhile the natural whole-value
swap — the analogue of StringLiteral owning whole interpolated strings — didn't exist: no
mutator matched the call shape.

The fix is two independent halves, and it matters which half lives where:

  * **Ownership is just mutator clauses.** The generic runtime walk already *offers* the
    whole call node to every mutator; AtomLiteral now matches the `binary_to_atom` shape
    (→ the sentinel; always applies — the runtime value is never statically `:mutare`) and
    CharlistLiteral matches interpolated `~c`/`~C` sigil content *and* the legacy
    `'a#{x}b'` (`List.to_charlist` call) shape (→ `~c""`/`~c"mutare"`, rendered in the
    modern syntax). Every clause gates on `:delimiter` — the parser-authoritative "this is
    literal syntax" stamp, same guard as StringSigilLiteral — so a hand-built call of the
    same shape is never treated as a literal. No analyzer change was needed for charlists
    at all: the sigil path already routes via `descend_sigil/2`, and the legacy form wraps
    its segments in a plain *list*, which the walk descends but never offers.
  * **The analyzer change is only for the atom's wrapper.** A dedicated `analyze/3` clause
    (delimiter-gated, falling through to the generic call path otherwise) offers the whole
    node and then descends the content *segments* directly — the `descend_sigil/2` move —
    so the inner `<<>>` is never offered (no BitstringLiteral collapse) and skips the
    construction `::binary` pin path (it's string content, not a construction; the pin was
    a no-op there anyway since interpolation segments are bare binaries / already `::`-typed).

Interior expressions kept mutating throughout (`#{x + 1}` was never the problem), and
`Overlap` is indifferent — a whole-value swap's footprint is the whole host, not a covering
descendant, so interior mutants survive alongside it.

One report sharp edge: the *keyword-shorthand* interpolated key (`%{"k#{x}": 1}`,
`format: :keyword` on the call meta). Sourceror's range for it stops **before** the written
colon, while a plain keyword key's (`foo:`) includes it — so the whole-key swap would have
patched `%{:mutare: 1}`. `NodeRange`'s `binary_to_atom` clause now bumps the end column for
`format: :keyword`, and `Mutare.Site` recognises the shape as a keyword key, rendering both
diff sides in keyword form (original via string surgery on `Sourceror.to_string/1`'s value
form — move the colon — mutated via the existing `Macro.inspect_atom(:key, …)` path). Same
class as the `trim: true` keyword-key fix, one shape further out.

`~C` was a genuinely separate gap folded in here: CharlistLiteral matched only `:sigil_c`,
so `~C"abc"` had no charlist mutants at all. It now owns both heads, preserving the head in
the replacement (`~C` stays `~C`, like `~w`/`~W`) — and `AST.empty_collection_literal?/1`
already listed `sigil_C`, so the guard-`in` empty-drop composed without change.

The *plain* legacy `'abc'` was a third, subtler asymmetry: it parses as an ordinary list
literal (`{:__block__, [delimiter: "'"], [charlist]}`), so it only ever got List's `[]`
collapse — the content itself was never challenged by a sentinel the way `~c"abc"`'s is
(a test pinning just "non-empty" killed everything on offer). Resolved as an ownership
split rather than a handover: List keeps the empty collapse (the node *is* a list literal
to it; CharlistLiteral emitting `~c""` too would duplicate it), and CharlistLiteral adds
only the sentinel, keyed on the `'` delimiter (a delimiter-less `[97, 98]` stays a plain
list). `''` gets the sentinel too — List skips the empty list, mirroring `~c""` — and
`'mutare'` is skipped as already-sentinel. Canonical statement of the split lives in
CharlistLiteral's moduledoc, per the ownership-split convention.

The property generators' interpolated-container gen (`interp_string_gen`) now also emits
quoted atoms and `~c` charlists, so the render/compile/baseline/activation soaks exercise
both routes (the rendered module re-parses with the `:delimiter` both gates key on).
Regression coverage: `mutators_literal_test.exs` (clauses incl. the no-delimiter skips),
`transform_test.exs` (routing: whole-swap + interior, no `:bitstring`/`:list` sites),
`transform/node_range_test.exs` (the colon bump), `report_test.exs` (clean, re-parseable
diffs for all three forms incl. the keyword key).

### Per-mutation report-location override: `Mutation.at/2` / `at_drop/1` `[done]`
A macro-aware mutator that returns a **whole-node rewrite** from `mutate/1,2` — rebuild and
return an entire registered-macro call (the `mutare_ecto` whole-`from` case) — had its site
location and diff welded to the offered node. For a multi-line `from(...)`, every clause mutant
(a `where:` drop, an `order_by:` flip) reported at the `from` line, and since `# mutare:ignore`
is line-keyed, a user could only suppress the *whole* query at once. The hosted path already
solved the location half via `MacroHost.Target.range`; the ordinary in-place path never grew the
equivalent hook.

`%Mutare.Mutator.Mutation{}` gains an optional `:attribution` (built by `Mutation.at/2` — a
replacement clause — or `at_drop/1` — a removed clause). It decouples the three roles the offered
node used to fuse: the node is still **spliced** to build the metamutant (unchanged), but the site
is **located** and **diffed** at the named clause. The constraint that forced carrying *both*
clause nodes (not just a narrowed range): `Report.patch/2` pairs `site.range` with
`site.mutated_code`, so range and code must describe the same span — a range-only override would
splice whole-query text over a clause and corrupt the diff. Because a whole-node rewrite's textual
footprint is local (one clause differs), a `{original_clause, mutated_clause}` pair *does* patch
coherently, and the plugin already holds both.

Three decisions worth recording:

  * **Struct, not a widened tuple, for the `Dispatch.mutations/3` result.** Attribution has to
    survive the `%Mutation{}` → result flattening in `Dispatch`. The result was a
    `{spec, node, note, variant}` quad pattern-matched in ~8 places (`Transform.Tag`,
    `Captures`, `test.ex`). A 5-tuple would break each match by arity — silent
    `FunctionClauseError`s if any were missed — so it became `%Dispatch.Result{}`: the consumers
    that ignore attribution match `%Result{}` and read only the fields they use; the one that
    honours it (`Analyze.Attach`) reads `:attribution`. The public `Mutare.Analyze.expression_mutations/3`
    quad is **not** this shape (it is built by `Collect` from `Candidate.InPlace`, decoupled), so
    the extension contract and its fixtures were untouched.
  * **Reuse the existing delete-site machinery.** `Site.in_place_drop/5` / `delete_site/7` /
    `operation: :delete` already existed (for `RescueDrop`), so `at_drop/1` is wiring, not new
    delivery code. Attribution branches live entirely in `Candidate.Delivery.build_site/5`: the
    selector still splices `c.mutated`, so attribution is a pure Site-time reinterpretation —
    `Overlap`, id assignment, and the metamutant see the offered node exactly as before. One
    field on `Candidate.InPlace` (`:attribution`), not three parallel nullable reporting fields,
    so "these move together" is structural.
  * **A containment guard, warned not raised.** Core can't prove the plugin pointed `:attribution`
    at a clause *inside* the rewrite, but `Analyze.Attach` catches the two ways it mislocates: a
    clause that isn't rangeable (`NodeRange.get/1` returns `nil` *or raises* on a synthesized node
    — both collapsed by a rescue) or one whose span escapes the offered node's. Either warns and
    falls back to attributing the offered node — a mutator bug degrades loudly but never crashes
    the transform or emits a diff pointing at unrelated source.

One accepted cosmetic wrinkle: a dropped clause that is a bare keyword pair (`select: 2`) renders
its one-line `Site.describe/1` summary in tuple form (`{:select, 2}`), because `Sourceror.to_string`
of a bare pair loses the `format: :keyword` presentation. The **diff** is unaffected — the delete
branch reads raw source lines by range — and the replace path attributes to the *value* node (the
idiomatic `order_by:`-value flip), which renders cleanly. Regression coverage:
`attribution_test.exs` (location, clause-level diff, per-clause `# mutare:ignore`, the
mis-attribution fallback) with fixtures `Mutare.Test.AttributedQueryMutator` /
`MisattributedQueryMutator`.

### The `:structural` shared mark — a mutator pins a position for every value family `[done]`
**Superseded** by "Call routing: `:skip`, `:raw`, `:interior`, keyed refinements" below — the
`:structural` label and `pinned?/1` are gone; an adapter routes such a position `:raw` instead.


The motivating case is `mutare_ecto`'s: `Ecto.Changeset.apply_action/2`'s action atom is never
consulted on the success path and only stamps `changeset.action` on the error path — metadata, not
behaviour — so `AtomLiteral` mutating `:update` there mints a near-equivalent mutant whose only
kill is a test asserting the label itself. The plugin owns that knowledge and could already
*declare* it (`argument_marks/1` is folded from every enabled mutator, alias/import/pipe-resolved),
but no reader existed: the one shared label, `:timeout`, is read **value-aware** (`AtomLiteral`
holds back only `:infinity`, so even mislabeling wouldn't have worked), and the exact semantics
wanted — "the position, not the value, is what was pinned; skip outright" — lived only behind the
`:skip_arguments` self label, which is per-instance and deliberately unforgeable by other mutators
(see the namespacing note under "Argument marks").

The closing move is a promotion, not new machinery: `Mutator.structural_label/0` (`:structural`)
is public shared vocabulary with a core-defined meaning, and `Mutator.pinned?/1`
(`self_marked?/1` or the `:structural` check) is the one gate every `:skip_arguments`-honouring
value family runs — the `SkipArguments` mixin picked it up in one line, and
`IntegerLiteral`/`AtomLiteral` swapped their hand-rolled `self_marked?/1` calls. The reader set is
*exactly* the `:skip_arguments` set, so "which families react" is a rule, not a list to maintain
(`ConventionAtom` stays excluded, the same high-signal stance as its `:skip_arguments` exclusion).

Two properties kept deliberately:

- **Still opt-in per label.** The label's meaning is core-defined but the reaction lives in each
  reader's gate — a custom value family that neither uses the mixin nor calls `pinned?/1` still
  fires at the position. The alternative — enforcing a reserved label at the offer layer, the way
  macro-routing `:skip` is transform-enforced — was rejected: it would turn marks from shared
  vocabulary into a cross-mutator veto, contradicting the facility's founding inversion ("the
  meaning of a mark lives entirely in the mutator").
- **Declarer-scoped, like every mark.** Disable the declaring mutator and the positions mutate
  again — correct, because the knowledge is the declarer's, not the transform's.

Known limit, on purpose: a `:structural` mark pins the *named value node* only (the general
mark-the-value-node rule above), so an identifier **list** (`validate_required(cs, [:name])`)
isn't coverable this way — the mark would land on the list node while the value families are
offered the interior atoms unmarked. Descent-propagating marks are a separate feature if ever
wanted. A second, smaller one falls straight out of the reader rule: `ConventionAtom` isn't in the
`:skip_arguments` set, so a `:structural` position whose value happens to be a convention atom
(`:ok`/`:error`, `:cont`/`:halt`, `:lt`/`:gt`) still gets that family's sibling swap. Accepted — the
alternative is a bespoke exception to the "reader set = the `:skip_arguments` set" rule, which is
the maintainable part. Exercised in `transform_duration_test.exs` ("the shared :structural label");
the flagship declarer is `mutare_ecto`'s `argument_marks/1` (`apply_action`/`apply_action!`).

### Sourceror comments leak into `original_code`/`mutated_code` — strip at the render boundary `[fixed]`

Sourceror attaches every comment to exactly one node, and the node it picks is the first one
*opening* the comment's line: a trailing `# mutare:ignore[…]` on `p.a > ^x and` lands as a
`:leading_comments` on the leftmost **leaf** `p`, a comment before `end` as a
`:trailing_comments` on the enclosing `def`. `Sourceror.to_string/1` renders whatever the
subtree carries, so the comment surfaced at every ancestor's render (the comparison, the whole
`and` chain) — and, because a swap reuses the original's operands, in `mutated_code` too. That
last part made it more than cosmetic: `Mutare.Report` splices `mutated_code` over the site's
range, so the survivor diff showed the directive twice (once on its own line above, once still
trailing the patched line). The directive itself keyed fine — `Mutare.Ignore` reads
`previous_eol_count`, not the bucket.

Fixed at the **render boundary**, not the parse: `Mutare.AST.to_string/1` now
`strip_comments/1`s the whole subtree (both keys, `Macro.prewalk`) before rendering, and `Site`'s
four renders route through it. Two alternatives weighed and rejected:

- **Strip after parsing, once per file.** Cheaper on paper and it would make
  `MatchPatterns`' pre-strip unnecessary, but it changes what every mutator sees and what the
  metamutant renders to fix a report-only problem, and it has to be sequenced after
  `Ignore.directives_from_ast/1`, which harvests from the same tree. The report renderer is the
  thing that was wrong; "two renderers, on purpose" says fix it there.
- **Strip only the top node's meta.** Doesn't work — the comment sits on the leaf, so every
  ancestor's render must strip *its subtree*.

Cost is nil: `Sourceror.to_string/1` already walks the tree to extract comments
(`extract_comments`, `collapse_comments: true`), so this is one walk in place of another, only on
the sites `Hydrate` actually renders. `Analyze.MatchPatterns` keeps its own pre-strip (now the
shared `AST.strip_comments/1`) — the `=`-match pattern is re-emitted per dispatcher clause, and
that strip is what stops the generated branches each repeating the statement's comment; the
recorded site no longer depends on it. `Mutare.Test`'s rendering and any custom mutator's
`AST.to_string/1` pick up the same behaviour for free. Exercised in `site_test.exs` ("comment
metadata in the rendered code") — the clause-drop case is what kills the `:trailing_comments`
deletion, which the pre-hoist helper had documented as an equivalent survivor.

### `clause_drop` was always-on and unregistered `[fixed]`
`clause_drop` shipped as the one structural built-in outside the `Mutare.Mutators` `@registry`,
generated unconditionally by `FunctionPlan.build_drops/1`. The original reasoning (recorded under
"Return-value mutators") was that `return_value` earned registry membership because it is
high-volume and users would want to toggle it, and `clause_drop` did not.

That reasoning didn't survive contact with the rest of the surface. Being unregistered meant:

  * `mutators: [:arithmetic]` still emitted clause drops — silently contradicting the documented
    "without `:builtins`, the list replaces the defaults" contract, with no way to opt out.
  * The family was absent from `mix mutare --list-mutators`, yet appeared in reports as
    `clause_drop` and was a legal `# mutare:ignore[clause_drop]` token — undiscoverable but not
    unused. Mutare's own `report.ex` carries four such directives, which is the evidence that
    users *do* want the toggle the original note assumed they wouldn't.
  * `Mutators.vocabulary/1` needed a `Map.put("clause_drop", :none)` special case to keep the
    ignore filter working, and the property suite needed `families() ++ [:clause_drop]`.

Registering it removed all three. There was never a structural obstacle: `GuardDrop` is
transform-managed too — no producing callback, discovered by module identity via `Spec.find/2` —
and had been registered and gated three lines above `build_drops` the whole time. `ClauseDrop` now
follows that exact shape, so `@transform_managed` holds all three of `GuardDrop` / `RescueType` /
`ClauseDrop`.

**The consequence worth knowing:** a clause drop is the *only* mutation a plain unguarded
multi-clause group admits, and mutations are what make a group lift. So disabling `clause_drop`
also stops such groups being lifted at all. Three tests were pinning lifted-path behaviour
(`super` forwarding through the dispatcher closure, return mutants landing in a lifted group's
original clauses, `:skip_lifting`) while narrowing `:mutators` to a set that no longer lifts —
they now name `ClauseDrop` explicitly as the thing that lifts the group. A narrowed run that wants
the lifted path must ask for a family that produces a lifted mutation.

### Call routing: `:skip`, `:raw`, `:interior`, keyed refinements; `argument_marks` replaces `:skip_arguments` `[done]`

The trigger was a small, ordinary wish: "calls to `Mixpanel.track/3` aren't worth testing — don't
mutate them, event name and details included." Working out where that belongs pulled the whole
"leave it alone" surface straight, pre-publication. The result is two facilities with one job each,
and a rename.

**The model.** Two mechanisms already existed for not mutating something at a call, and they differ
on the axis that matters:

- **Routing** (`macro_routes` → registry → `Resolve` stamp → `Analyze`) is *transform-enforced and
  descent-scoped*: it decides how core walks each argument, and no mutator is consulted.
- **Marks** (`argument_marks/1` → `meta[:mutare_marks]` → `context.marks`) are *mutator-interpreted
  and value-node-only*: core stamps a label, the mutator decides (the timeout table declines a
  duration literal but lets `base * 2` mutate its `2`).

Whole-call exclusion is a routing statement. And routing already keyed on the *resolved*
`{module, fun, arity}` with no macro check — `Options.Registry` resolves `macro_routes` "purely
syntactically" — so `{Mixpanel, :track, 3, :skip}` (old vocabulary) already stripped every argument
mutant off a plain function. The mechanism was never about macros; only its *name* was. Companion
packages had quietly been routing functions for a while (`mutare_phoenix_swoosh` routes
`Phoenix.Swoosh.put_layout/2`).

**A route answers two questions** about a call: is the call node itself offered to mutators, and
what is each argument? The old `:skip` answered only the second ("this argument is raw") and always
said yes to the first — by design, so an Ecto adapter's `from/2` mutator still fires on the whole
call. "Not worth testing" needs *no* to the first as well. Hence a distinct word.

**The vocabulary now.**

- `:skip` is the **call-level** word and is valid only as a route's bare treatment: the call is an
  *inert leaf* — no whole-node offer, nothing inside the parentheses descended. Everything else
  follows from "leaf": a skipped call in tail position still gets the enclosing function's
  `return_value` mutants (they test the function, not the call); a **piped receiver is the `|>`'s
  other operand, not part of the leaf**, so `Repo.insert!(u) |> Mixpanel.track(…)` keeps the
  insert's mutants (the argument-level treatments *do* reach back into a piped LHS at position 0 —
  a semantic claim about a position holds however the position is filled; a policy claim is about
  the call as written). `RouteStamp` stamps the bare atom `:skip` rather than a per-position list,
  so every reader sees one distinguished value; a `:skip` inside a list is rejected with a message
  naming `:raw`. Also honoured on the guard path (`Tag`), on module-level block macros, and by
  `Calls.routed_treatments/1` (which returns `:skip`).
- `:raw` is the old argument-level `:skip`, renamed. The README had been explaining it as "mark the
  non-runtime arguments as *raw*" all along, and `:opaque` would have been wrong for a function
  argument (`validate_required(cs, [:name])`'s list is transparent Elixir you just don't want
  touched). Mutare-wide, `skip_*` means *produce no sites*; a `:raw` argument can still receive
  sites from a host sub-contracting an island, so it isn't a skip.
- `:interior` completes the axis: offer the node? / descend? — `:expression` both, `:raw` neither,
  `:interior` descend-only. The recurring shape is a container whose emptying is a crash-kill while
  its members are the signal (an assigns map for `render/3`, Swoosh bodies, LiveView `assign/2`).
  Implemented as annotate + strip the node's *own* in-place candidates — the mirror image of
  `:interpolated`'s `pin_inplace_candidates/1`, which draws the same own-vs-descendant line.
- **Keyed refinements** `[leading, key: position, …]` (leading defaults to `:expression`; pairs may
  nest) refine one option value of a *literal* keyword argument — the trailing sugar or an explicit
  `[k: v]`, both shapes. Semantics: the argument follows `leading`; each named key's value follows
  its own position; the key, sibling pairs, and the list itself are untouched by the refinement (so
  keys still go through the ordinary call-option-key policy and `List` still collapses an explicit
  list). A non-literal argument (a variable, a `Keyword.merge/2`) has no keys to refine and takes
  `leading` alone. Normalized to `{:keyed, leading, pairs}` in `Spec` so a refinement is never
  confused with the per-position list it sits in. Implementation (`Analyze.Routed`, and its guard twin
  `Tag.tag_routed_arg/4`): every pair is routed **once**, by its final position — the named value by
  the refinement's, keys and unnamed values by `leading`'s reading one level down (`:interior`
  withholds only the container) — and the container is offered by `leading`. A first cut routed the
  whole argument by `leading` and then re-routed the named values from the raw source; the discarded
  candidates were free but the *work* was not — every named value was analyzed twice, and nested
  calls routed the same way compounded it (eight `f(k: f(k: …))` levels ran a mutator 256 times over
  the innermost literal). Choosing the final position before descending keeps the once-per-node
  invariant. Every routing traversal must know the `{:keyed, …}` shape — `hosted_hosts`,
  `binding_pattern_treatment?`, the misshapen-keyword advisory and `attach_hosts` all recurse into
  it; a `[:raw, where: :hosted]` value whose hosts were attached but never collected silently
  produced nothing. It is a *refinement of an expression*, deliberately distinct from the
  adapter-grade `{:keyword, [t…]}`, which *replaces* the treatment of a DSL keyword shorthand (keys
  are field names and go raw, values are routed positionally by a shape-aware classifier).
- Adapter words (`:interpolated`, `{:keyword, …}`, `:hosted`, `:routing`) are unchanged. The tier
  rule is unchanged too: config accepts only words that can *remove or re-route* mutants; a keyed
  refinement is graded by its contents.

**The rename.** `:macro_routes` → `:call_routes`; `Mutare.MacroRouting` → `Mutare.CallRouting`
(`call_routes/0`); `Mutare.Macro.Spec` → `Mutare.CallRouting.Spec`; `Resolve.MacroStamp` →
`RouteStamp`; `Analyze.Macros` → `Analyze.Routed`; `meta[:mutare_macro*]` → `:mutare_route*`;
`Calls.resolved_macro_call/1` → `resolved_routed_call/1`, `macro_treatment/1` →
`routed_treatments/1`. `Mutator.MacroHost` keeps its name — hosting *is* about DSL fragments in
macros. Older NOTES sections keep their "known macro" wording; read it as "routed call".

**Why one registry, not a separate `skip_calls` option.** A separate option read well but split one
mechanism across two keys with no precedence rule between them. One registry lets the existing
specificity cascade answer every conflict (`{Mixpanel, :track, 3, [...]}` beats
`{Mixpanel, :*, :skip}`), `reject_duplicate_config!` catches a key written twice, and `--skip-call`
is pure sugar over a route (the one CLI flag that *appends* to a file value rather than replacing
it — a one-off "and also skip this" run shouldn't restate every configured route).

**`argument_marks` as a config option; `:skip_arguments` retired.** Users should have the full
power of the built-in timeout table for their own functions, and the table's power is exactly what
routes can't express: a *value-aware* reaction (`IntegerLiteral` declines any integer,
`AtomLiteral` only `:infinity`, `Task.yield_many/2`'s one slot holds a bare timeout or an options
list) on the argument's own node. That power rests on the founding inversion — the meaning of a
mark lives in the mutator — so a user-facing version can only ever *extend the position tables of
labels mutators already understand*. First cut: a label as a bare treatment word inside routes
(`[:expression, [recv_timeout: :timeout]]`). Rejected for colliding the marks namespace with the
treatments namespace, and because it would have forced marks' sparse grammar (name the positions
you label) into routes' dense one (a treatment per position). So: a separate `argument_marks:`
option whose entries are *exactly* what `argument_marks/1` returns — one grammar for marks, code and
config alike; a user reading `IntegerLiteral`'s table can write a config line in the same shape.
Fed to `ArgumentMarks.build/2` as a run-level declarer; labels union as before. A configured label
must be one some mutator declares positions for (`Mutator.declared_labels/1`) — checked once in
`Options.new/1` against the enabled mutators *plus every built-in family*, so `--mutators arithmetic`
never invalidates a `:timeout` entry while a typo still fails at startup. Exact arity only (the
marks registry has no wildcards, and arity-keying is a documented feature).

With that, the per-family `:skip_arguments` option had nothing left to do that a `:raw` route or a
`:timeout` mark doesn't do better: the `SkipArguments` mixin, `skip_arguments_marks/1`, the
per-instance self-label machinery (`self_mark`/`self_label`/`self_marked?`) and `pinned?/1` are gone;
`IntegerLiteral`/`AtomLiteral` gate on `:timeout` alone. The `:structural` shared label went with
it: its reader set was defined as "the families that honour `:skip_arguments`", and an adapter
routing `apply_action/2`'s action or `attach_hook/4`'s names `:raw` is strictly stronger on an atom
(it closes the ConventionAtom leak the `:structural` note accepted as a limit). The marks facility
now means one thing: value-aware mutator knowledge.

**Smaller decisions.**

- A **configured** `:skip` that displaces an adapter's `:hosted`/`:routing` route counts as
  reachable in `Registry.validate_hosts!` — the user turned the call off; that is not the adapter's
  `:unused_callback` contract violation. A *code-provided* `:skip` next to a host subscription still
  is.
- The **guard path** (`Tag`) now honours routes — the both-offer-paths discipline the marks already
  followed: `:skip` → leaf, `:raw` → argument untouched, `:interior` → walked and then the target
  on the argument's own node dropped (the twin of `Routed`'s strip; guards do allow tuples and
  maps, so `is_tuple({x, 1})` under `:interior` keeps the `1` and loses the `{}` collapse), a keyed
  refinement → each named value by its key's position over a literal keyword list, the container
  and the rest by the leading treatment. `:pattern`/`:binding_pattern` and the adapter-grade words
  have no guard meaning (a pattern or a DSL fragment is not guard-legal) and fall through.
- **Ineffective-configuration diagnostics** mirror `skip_lifting`'s: `ConfigMatches` reads two
  stamps the resolver already places (`:mutare_route_call` → the winning route's key, wildcards
  included; a new `:mutare_mark_call` on any call a mark declaration matched, the pipe's RHS
  included), the count pass reports them, `Schema.detect_ineffective_config/3` diffs them against
  `options.call_routes` / `options.argument_marks` on a full scan, and `CLI.Diagnostics` warns.
  Recording the match at the resolver rather than re-deriving resolution in a second walk keeps the
  diagnostic honest by construction.
- Companion packages: `dynamic`/`is_named_binding` in `mutare_ecto` were registered `:skip` under
  the old meaning *because* they rely on the whole-node offer — they are `:raw` now, the one place
  the rename changes behaviour if missed.

**Deferred, on purpose.** (1) A user-defined label *table* (`labels: [no_strings: [:string]]`,
enforced at the offer layer) would restore per-family selectivity; NOTES already rejected
offer-layer enforcement for core-defined labels, the need is rare, and a `:raw` route covers the
common case. (2) `:interior` at module level: `analyze_module_macro_block/2` honours `:skip` and
`:raw` only; the other positions fall through to the scaffold/runtime guess as before. *(Closed in
the fourth review round below: keyed refinements are honoured there too, and `:interior` collapses
to the default because a module-level container is never offered.)*

**Structural heads (2026-09-05).** `{Kernel, :if, 2, :skip}` did nothing. The resolver stamped
it — `if` is a `Kernel` macro like `match?`, and the registry keys on the resolved head — but
`Analyze`'s dedicated `if`/`unless` clause (like `cond`, `case`, `with`, the negation and connective
clauses) precedes the generic call clause, the only place the routing stamp was read. An accident of
clause order, not a position: the same route on `+` already worked. Two facts were tangled.

*`:skip` is a claim about the resolved head, whatever the analyzer does with it*, so it must be
honoured before any form clause — and now is, once, in a dispatcher at the head of `analyze/3`
(every recursion re-enters there), with twins at the entries of `Tag`'s guard and pattern walks, an
inner-operand check in the negation clauses (`x not in y` parses as `not(x in y)`; a skipped inner
`in` is a leaf under an ordinary `not`), and a leaf rule in `Returns.map_return_tails` (a skipped
`if` at a tail gets the *function's* return mutants on the whole node, never per branch — "nothing
inside" holds for tails too).

*Positions are not a thing on a structural head.* A positional route there could only be ignored
(the silent failure we had) or honoured by swapping the structural analysis for the generic argument
walk — losing the condition replacements, the hoist, the pattern contexts, without the user knowing.
So `Mutare.Transform.StructuralForms` classifies a resolved head once — `:call` / `:structural`
(`if`/`unless`, `|>`, `!`/`not`, `in`, `and`/`or`/`&&`/`||`, every `Kernel.SpecialForms` form) /
`:declaration` (`def`/`defp`, `defmacro`/`defmacrop`, `defmodule`, `defimpl`/`defprotocol`/
`defdelegate`, `use`, `@`) — and two readers apply it. `Spec.new/4` rejects an explicit key with an
`ArgumentError`: a positional route on a structural head, or *any* route on a declaration (a
"skipped" `def` would still be lifted and return-annotated by paths no stamp reaches, and
`# mutare:ignore` owns that job). `RouteStamp` declines to stamp a *wildcard* route (`{Kernel, :*,
:raw}`, `{:*, :and, …}`) whose cascade reaches such a head: its positions don't apply, the head is
analyzed as usual, and the route is not counted as matched there — so a name-only positional route
that only ever hits `Kernel.and` surfaces as ineffective. Special forms became resolvable for this:
bare `case`/`with`/`fn`/`=`/… resolve to `Kernel.SpecialForms` **by name** (their nominal arities
don't track the AST — a `with` node has one argument per clause plus the block — so
`{Kernel.SpecialForms, :with, :skip}` is the form to write); before, they resolved to nothing and a
route on them was silently ineffective. `Poison.Hint` follows the same table (`:skip` for a
structural head, a comment for a definition), so a pasted hint never trips the new rejection.

Degenerate cases fall out coherently, which is the sign the rule is right: `{Kernel, :|>, 2, :skip}`
makes a pipeline inert, `{Kernel, :*, :skip}` every Kernel call (definitions excluded). Deferred:
honouring positional routes on `if` by teaching the routed path the condition machinery — no use
case, and `# mutare:ignore[conditional]`/`--mutators` already cover "no condition mutants here".

**Review fixes, same day.** Three more paths bypassed the dispatcher or the routed argument
walk. (1) The resolver's specialized `walk` clauses — `|>` (pipe-mode bookkeeping), `quote` (the
live-parts-only walk), `&fun/N` (the ref-not-call shape) — returned their head's meta unstamped, so
`{Kernel, :|>, 2, :skip}` and `{Kernel.SpecialForms, :quote, :skip}` were accepted and inert; each
now stamps its head through `stamp_bare_call/4` before its own descent. The compiler-internal forms
a user never writes as a call (`__block__`, `__aliases__`, `__cursor__`, `.`, the nullary
`__MODULE__`/`__ENV__`/…) are a fourth class, `:internal`, rejected outright — the alternative was
stamping every literal's `__block__` wrapper to honour a route nobody can mean. (2) The structural
pattern families run *outside* the dispatcher — `MatchPatterns` offers a `=`'s LHS after
`annotate/2` returns, `FunctionPlan` offers head arg lists, `ClausePatterns` offers clause patterns
— so `{Kernel.SpecialForms, :=, :skip}` still swapped `{x, y} = v`, and a skipped `%{}` in a head
still had its bindings swapped. One predicate, `Meta.contains_skipped?/1`, now gates them at their
shared entry (`PatternStructure.node_mutations/3`, plus the head arg list in `FunctionPlan`, plus
the skipped `=` itself): a pattern holding a skipped form is not restructured at all — conservative
on purpose (a swap across the skipped form would mutate inside it, a swap beside it would not), and
the literal walk still mutates beside it. (3) The negated-equality clauses in `Analyze` and `Tag`
analyzed the inner operands directly, so `{Kernel, :==, 2, :interior}` held on `x == 2` and not on
`not (x == 2)`; the inner node now takes the ordinary call path (`do_analyze_call_node/3` /
`tag_args/3`) with the redundancy drop applied on top. The negation-over-`in` and double-negation
clauses need nothing: `in`, `!` and `not` are structural, so no positional route can reach them.

**Second review, same day — literal forms are not routable.** The next round found `{1, 2}`
escaping a `{}` skip (a two-tuple is a bare tuple in the AST, not a `{:{}, …}` node) and
`%__MODULE__{a: 123}` escaping a `%{}` skip (the struct clause destructures its map without passing
through the dispatcher). Both are symptoms of one mistake: `{}`, `%{}`, `%`, `<<>>`, `=`, `^` and
`::` are literal and pattern *syntax*, not calls, and "skip every tuple" is a literal-family concern
the literal families already own (`--mutators`, `# mutare:ignore[<family>]`) — honouring it would
mean chasing every walk that destructures data. `StructuralForms` now partitions
`Kernel.SpecialForms` explicitly: the *construct* forms (`case`, `cond`, `with`, `for`, `try`,
`receive`, `fn`, `quote`, `unquote`/`unquote_splicing`, `super`, `&`) take `:skip`; the *directives*
(`alias`/`import`/`require`) are declarations like `use`; the *literal and pattern* forms are a
`:literal` class no route may name; the rest is compiler-internal (and a form none of the lists
name falls there too — the conservative reading for a future Elixir). The pattern-side gates from
the previous round stay: a pattern can still hold a routable Kernel head (`"a" <> rest`, `-1`), and
the structural families' contract (a custom `pattern_mutations/2` may restructure anything) is what
they enforce, though the built-ins never cross such a head; only the `=`-statement gate went, since
nothing can reach it now. Two real leaks fixed alongside: the guard `in`-RHS walk (`tag_in_rhs/3`)
built the range/list node's children directly, so `{Kernel, :.., 2, :skip}` and positional routes
on `..` were ignored in `x in 1..5`; and `analyze_statement/3` discovered a `:binding_pattern` route
on the RHS stage of a *skipped* pipe (`[x, y] |> destructure(v)` under `{Kernel, :|>, 2, :skip}`)
and attached pattern-swap candidates past the boundary.

**Third review, same day.** (1) The per-pair keyed routing offered every key through the leading
treatment, block keys included — so `{MyMacro, :wrap, 1, [[do: :raw]]}` handed `do:` to
`AtomLiteral`, and `wrap(mutare: body)` failed to expand. The generic pair clause has always kept a
block key raw (`Syntax.block_key?/1`); both keyed walks (`Routed.route_key/4`, `Tag.tag_key/4`) now
apply the same rule. (2) `{Kernel.SpecialForms, :unquote, :skip}` was accepted and inert: quoted
data is walked by the quote-specific passes, not by `analyze/3`, so the dispatcher never saw an
unquote. The resolver's quoted-data walk now stamps a live unquote through `stamp_bare_call/4`, and
`QuoteEscape.analyze_quoted_data/4` reads the stamp at its unquote clause. (3) `Report.Live`'s
compile-poison line rendered `{Module, :fun, :raw}` for every recovered macro — `{Kernel, :in,
:raw}` included, which the validator now rejects. `StructuralForms.hint_treatment_for/2` (the
module as the compiler prints it) is the one classification both `Poison.Hint` and `Live` render
from: `:raw` for a call, `:skip` for a structural head, a `# mutare:ignore` pointer when no route
can name the head.

**Fourth review, same day.** (1) `analyze_module_macro_block/2` honoured `:raw` and `:skip` only,
so `{DSL, :literal, 1, [[do: :raw]]}` on a module-level block macro still mutated the `do:` body —
and a macro whose head demands a literal (`defmacro literal(do: 42)`) then failed to expand, where
the uniform `:raw` route compiled. `route_module_arg/4` now routes each position: `:raw` as
written; a keyed refinement per pair — named values by their position, the rest by the leading
treatment's reading, every key raw (keys are compile-time at module level), the default for a value
keyed by its key (a block body is the runtime guess, an option value scaffold); everything else the
module-level default, which is what `:expression` means there and what `:interior` collapses to (a
module-level container is never offered, so there is nothing to withhold — the earlier deferred
note is closed). (2) `--skip-call` appended to the file's `call_routes:`, so a file entry for the
same call — even an identical skip — tripped the registry's one-override-per-key rule and aborted
the scan. `Config.append_skip_calls/2` now merges by normalized route key: the flag replaces a
file entry for the same call, unrelated entries stay, a repeated skip is stated once; an entry the
registry would reject keeps its place so `Options.new/1` reports it.

**Fifth review, same day — decisions on a skipped condition.** `if String.valid?(x)` under
`{String, :valid?, 1, :skip}` still produced `IfCondition`'s `true`/`false`: the dispatcher returned
the skipped node, but `Conditions.finish_condition/3` (the plain `if`/`unless` path and every `cond`
clause) then offered it to `condition_replacements/1` — a structural pass that never read the stamp
— and `hoist_if?/2` would have lifted a binding out of it. Both read `Meta.skipped?/1` now. The
model: `condition_replacements` is an offer *of the condition node*, structural or not, and its
node-offered twin — `Conditional`'s `true`/`false` on a skipped `x > 0` — was already withheld by
the dispatcher; the two families must agree, or a user could not say why one condition kept its
decision mutants and the other lost them. The one deliberate exception stays: return-value mutants
on a skipped tail, which belong to the def clause (`Returns` attaches them at the function level,
the user's explicit call), not to the call.

### A call-level `:skip` must not route the pipe less safely than what it displaced `[done]`

`:skip` stamps a bare `:skip` and writes no piped stamp, reasoning that a piped receiver is the
`|>`'s left operand — a sibling of the skipped call, hence ordinary runtime, which is what keeps
`Repo.insert!(u) |> Mixpanel.track(…)`'s receiver mutants. That holds only where position 0 accepts
runtime code. `Kernel.match?/2` routes position 0 `:pattern`, and configuring
`{Kernel, :match?, 2, :skip}` — or the `--skip-call Kernel.match?/2` flag — displaces that route,
so `1 |> match?(x)` analyzed its receiver as runtime and spliced a selector `case` into a match.
A supported flag produced `case is not allowed in matches`, against the positive compile-safety
invariant, and `:skip` thereby made a call *less* safe than no route at all.

`Registry.Entry` now carries `displaced`, the code-provided spec a configured `:skip` overrode, and
`RouteStamp.stamp_skipped_pipe/4` stamps that route's piped treatment. A displaced *classifier*
answers `:raw`: its treatments are computed per call node by the router the user just skipped, and
the adapter-grade DSLs classifiers describe are exactly where a spliced `case` is illegal.
Displacing nothing keeps the documented default. The rule is one-way — a `:skip` may withhold
mutants, never grant a position more freedom than the route it replaced.

### `:interior` has to account for the operand the suppression withheld `[done]`

`:interior` analyzes its argument and then drops the candidates on the argument's own node. The
equivalent-sibling suppression withholds an operand *because the enclosing negation carries the
mutation for both* (shapes 1-3: a negation over the same operator, over `in`, over an equality) —
and that negation is exactly what `:interior` drops. The pair vanished together, so
`MyApp.consume(not not x)` produced no `logical` or `conditional` mutants at all, though the inner
`not x` was eligible and the route promises an argument's contents.

`Routed.route_macro_arg/4` now re-analyzes that operand on its own once the root is withheld. With
no surviving sibling to duplicate, its mutations are distinct again: withhold the root of
`not (a == b)` and the operand's flip leaves `a == b`, which is neither the original (`a != b`) nor
the outer's strip. Ordering operators are untouched — shape 3 excludes them, so they were offered
in their own right already. The root still goes through `annotate/2` first, so it keeps every other
stamp analysis puts on it; only its own candidates go.

### Duplicate return constants yield to node-level replacements `[done]`

An atom return tail such as `:foo` produced `:foo → :mutare` twice: once from
`AtomLiteral`, once from `ReturnValue`. Interpolated atom tails had the same overlap.
Excluding atom tails from `ReturnValue` altogether would also lose the distinct
`:foo → nil` mutation; teaching it which atoms another family handles would duplicate
eligibility rules and ignore whether that family actually produced a candidate.

`Candidate.Delivery.gate/1` now drops a `Candidate.Return` when a surviving
`Candidate.InPlace` on the same node already produces the same scalar constant. It runs
after mutator policy filtering and before id assignment. Comparison reads literal values
and uses strict equality, so formatting metadata does not prevent a match and `0` stays
distinct from `0.0`. Non-scalar replacements are deliberately outside this check.

The node-level candidate owns reporting and ignore matching, independent of mutator order.
If that family is disabled or declines the node, the return candidate remains. The check
does not rerun mutators, compare separate source nodes, or replace `Overlap`'s broader
call-rewrite/descendant suppression. Poison skips happen later, so skipping the retained
candidate cannot revive its duplicate or shift subsequent ids; count and render share
the same gate.

The gate lives in `Delivery` rather than `Overlap` because it must see *post-policy*
candidates: `filter_policy/1` runs per node inside the emit traverse, while `Overlap.resolve/1`
runs over the whole tree before it. An `InPlace` its mutator opted out of must not suppress
anything.

`ReturnValue.redundant_literal?/1` looks subsumed by this and is not — measured before deleting
it. It keeps the family off *literal* tails by shape, unconditionally; removing it added 1180
mutants (+4.3%) across this repo's own `lib/` and removed none (544 list, 402 boolean, 180
string, 34 numeric tails). The value gate catches none of them, because `nil`/`:mutare` collide
with nothing the node-level families emit. The boolean tails are the reason to keep the rule:
115 `false → nil` mutants stay falsy, so every `refute`-style assertion lets them through —
only a strict comparison or a `false` pattern match kills one — and the matching 115
`false → :mutare` only restate `boolean`'s own `false → true`. Shape-level ownership for
literal tails and value-level dedup for everything else are complementary; neither replaces
the other.

### Unit-returning functions are not return-value positions `[done]`

A function whose every return path, across all its clauses, is literally `:ok` or `nil` returns
**no data**. Its tail used to draw three mutants from two families — `return_value`'s
`nil`/`:mutare` pair and `convention`'s `:ok → :error` — and all three survive whenever the caller
discards the value, which is the norm for a side-effect helper (`defp notify(x) do Logger.info(…);
:ok end`, `terminate/2`, an `Enum.each` callback). Their only kill is a test asserting a static
fact (`:ok = notify(x)`), and pressing callers for that is the wrong pressure: the value is `:ok`
by construction, and a typespec already says so. `Mutare.Transform.UnitReturns` now classifies
such functions in a pre-pass after `Resolve` and stamps their leaf tails (`Meta.unit_tail?/1`);
`Analyze.Attach.offer/4` never offers a stamped tail and `Analyze.Returns` attaches nothing there.
Exercised in `unit_returns_test.exs`.

**How the criterion was narrowed — three things it is not.**

- *Not privacy.* The first framing was "skip return-value mutation on `defp`": private functions
  can't be called from tests, and a survivor there often reflects usage the code doesn't have.
  But no mutant is killed by calling its function directly — a `defp` mutant dies through a
  public caller on tested inputs, exactly like every other mutant in that `defp` — so the
  argument would apply equally to the arithmetic swaps there, which nobody wants. And in Elixir
  the logic *lives* in `defp` (`do_*` recursion, `with`-step helpers); a visibility skip would
  remove the family from where it has teeth. What the framing was pointing at is the *discarded
  unit return*, which is just as discarded in a `def`.
- *Not "constant return".* "Every path returns the same constant" says the return carries no
  information *about which branch ran* — true — but a constant can still be data:
  `def default_status, do: :pending` and `def max_retries, do: 3` are named constants whose
  value is the whole point, and `:pending → :mutare` / `3 → 4` ask whether any test observes
  them. Generalizing to strings, numbers, or compound literals makes it worse, not better. `:ok`
  is different by convention only: it is Elixir's spelling of unit, the way `void` is a return
  type with nothing to mutate. Dialyzer can't tell `:ok` from `:pending` either — both are
  singleton types — so the distinction is conventional, and the convention is real.
- *Not typespecs.* `@spec f(…) :: :ok` would recognise the one shape the body rule misses — a
  unit-returning **call** tail (`defp notify(x), do: Logger.info(x)`) — and `Code.Typespec`
  reads declared specs (a `defp`'s included) straight off a BEAM. Rejected all the same: it would
  be the first spec-aware part of the tool, a commitment every later change has to keep
  honouring, bought for one check; a syntactic spec reader is a partial reader of a type
  language (flattening a union is a recursion on both sides of `|`; `my_ok()` needs type
  resolution; the line between them is wherever you stop); and the BEAM route needs the target
  compiled and current, which a transform that runs on source can't assume.

**Why the body-shape criterion, precisely.** It has no type language to normalize — each leaf is
or isn't one of two literals — and its errors run one way: it can *miss* a unit function (a call
tail, a variable bound to `:ok`, an else-less `with`, whose implicit pass-through is a return
path), but it never classifies a data-returning function as unit. One `:ok` path beside a
`{:error, _}` path is the success bit, and mutating it is how the tool finds an untested happy
path. `nil` counts as the other unit spelling (every value family already leaves it alone), so an
else-less `if` around a side effect — `:ok | nil` — qualifies. A tail that never *returns*
(`raise`/`reraise`/`throw`/`exit`, bare-and-not-displaced or `Kernel.`-qualified, and the
`:erlang` primitives) is no return path, so the `validate!` shape — `:ok` or raise — is unit; the
raising tail is left unstamped, because `raise … → nil` is the mutant that asks whether the error
path is tested. (Mutare's own `Ignore.validate_entry!/5` carried a
`# mutare:ignore[convention, return_value]` for exactly that shape, and `Run.Context.hook` one
for a `fn _ -> :ok end`; both directives became ineffective and were removed.) Symmetrically, only
what the *caller* receives counts: an `else` — on a `try`, or on a `def`, where it is the implicit
one — consumes the `do` value rather than returning it, so a `do` tail under an `else` is an
ordinary value position and stays mutable (swapping it picks a different `else` clause, a real
behaviour change under an unchanged unit return), and a displaced `if` is somebody else's macro,
which need not return a branch value at all.

Grouping is by `{name, arity}` across the module body, pruned at nested scopes; a dynamic head
(`def unquote(n)()`, or the whole-head `def unquote(head)`) leaves the module unclassified, a
spliced head blocks its name, and a `defdelegate` blocks the signature it names — its expansion is
a sibling `def` clause nothing static sees, and "one explicit clause, delegate the rest" is exactly
where a visible `:ok` carries a success bit. Delegates are read through the same two planner
helpers as defs, so a dynamic delegate head forfeits the module too. A clause inside a `quote`
blocks for the same reason a delegate does — `Module.eval_quoted(__MODULE__, …)` can inject it
here, but `Resolve` stamps nothing in a quote (it resolves where it is *invoked*), so `raise("x")`
there may be a local `raise/1` that returns. So does a **qualified** definition
(`Kernel.def f(x)`, an aliased `K.def`) — read by name alone the node is just a call, though the
clause it mints is as real as a bare one — and a definition nested in a *live* one
(`def g, do: unquote((def f(:bad), …; 1))`, which runs during the outer expansion and adds a clause
here, unlike a quoted one, which can only reach another module). Scope boundaries are read through
the resolver for the same reason: a displaced `defmodule/2` is somebody else's macro and may splice
its block into the caller, so what is inside it is a sibling. The planner's residual holes,
reused; the hole that remains is the planner's too:
a clause a *macro generates* beside visible clauses of the same signature (a `defhandler`-style
macro's `{:reply, …}` clauses next to a hand-written `:ok` fallback) is invisible, so the visible
fallback reads as unit. Narrow — `use`-injected defaults
are `defoverridable` and get replaced, not joined; non-overridable generated clauses beside
hand-written ones of one signature draw the compiler's "clauses not grouped" warning — but it is
the one way the classification can silence a data-returning function, and the moduledoc says so.

**Transform-enforced, not a mark.** "The `:structural` shared mark" above rejects turning marks
into an offer-layer veto: a mark's meaning lives in the family that reads it. This classification
is the transform's own — where a clause returns is knowledge only the return-path walk has — so it
is enforced where call-routing `:skip` is, and every family is off a unit tail without opting
in, `ConventionAtom` included (whose deliberate exclusion from the `:structural` reader set is
untouched). The walk itself is `Analyze.Returns`' leaf-tail descent, published single-tree in a
*classification* mode that is conservative where attachment is permissive (an else-less `with`
and a construct that only looks like one — a name at an arity its special form does not claim
(`try(1, do: :ok)` is a local `try/2`), or an `if` displaced out of `Kernel` — are delivered whole;
a `do` an `else` consumes is not yielded at all; an unroutable clause block is a leaf), so the two
notions of "return path" share one walker and can't drift.

**Growth path, if survivors warrant it — none of it spec-aware.** A tail that is a *local* call
to a function already classified unit (a module-local fixed point in the same pass) is the
body-side answer to `my_ok()`; a table of known unit-returning calls (`Logger.*`, `IO.puts`,
`Process.sleep`, `:telemetry.execute`) through `Calls.resolved_call/1` is the machinery the
timeout table and `CallRemoval` already use. Both deferred until a run shows them removing
survivors.

**Incidental finding.** A bare-atom tail drew `:pending → :mutare` twice — from `atom` and from
`return_value` (whose moduledoc says bare atoms stay eligible while `AtomLiteral` owns them). An
ownership-split gap, unrelated to unit returns; "Duplicate return constants yield to node-level
replacements" above closes it at the value level. The shape-level remnant stands: a tuple/map
*literal* tail is in the same position (`return_value`'s `nil` and `TupleLiteral`'s `{}` die to the
same test), which the value gate deliberately doesn't reach (non-scalar), and which would fit
`ReturnValue.redundant_literal?/1` the way ints/strings/lists already do.

**Behaviour callbacks are exempt (0.1.1).** Publishing `mutare_oban` against 0.1.0 exposed the
premise's boundary: `def perform(_job), do: :ok` in an `Oban.Worker` is body-shape unit, but its
caller is Oban's runtime, which reads `:ok` as one of six `t:Oban.Worker.result/0` outcomes — the
success bit the criterion promises to keep is there, held by a caller the source never shows. The
same holds for any callback: the behaviour's runtime, not a helper's caller, consumes the value,
and the tool can't tell a `terminate/2` (read by nothing) from a `perform/1` (read closely) by
looking at the body. So `UnitReturns` now excludes a signature that is a callback of one of the
module's stamped behaviours (`Behaviours.behaviours/1`, through `behaviour_info(:callbacks)` when
the behaviour is loadable — stdlib always, a companion's library via `required_modules/0`) or
whose first clause an `@impl` (other than `@impl false`) precedes — the syntactic signal, which
also covers an unloadable behaviour. The error direction is the pass's own: a truly unit callback
regains a low-value survivor; a contract-`:ok` callback keeps the mutant that asks whether the
outcome is asserted. Considered and rejected: a per-mutator opt-out from the stamp (every
behaviour-gated return family would have to remember it, and the stamp is transform-enforced on
purpose), and dropping the swap from `mutare_oban` (the mutant is the point of that family).

### Rendering never consults the target's formatter configuration `[done]`

`Sourceror.to_string/2`, left to its defaults, calls `Mix.Tasks.Format.formatter_for_file/1`
to pick up `locals_without_parens` — on **every** call, evaluating the current project's
`.formatter.exs` (its `import_deps`, its plugins) inside the calling process. Under `mix
mutare` the current project is the *target*, so scanning a Phoenix app loaded
`Phoenix.LiveView.HTMLFormatter` into Mutare's process once per rendered node, and on the
v0.1.0 smoke test Mix refused the `import_deps` lookup outright ("Unknown dependency
`:ecto_sql` given to `:import_deps` in the formatter configuration") right after an
in-process partitioned `deps.compile` had left Mix's dependency cache in a state the
formatter could not read — the scan died before a single mutant. The renderer has no
business there: the metamutant is a build artifact that only has to compile, and a local
call with or without parentheses is the same code. Every render now goes through
`Mutare.AST.render_opts/1`, which pins `locals_without_parens: []` (`AST.to_string/2`,
`Transform.Render`, and the two round-trip renders in `RegexLiteral` and `Uses.Harvest`).
Observable difference: none for parsed code, since Sourceror keeps the spelling a parsed
call's metadata records; a node built without metadata renders with parentheses, which it
already did in every project without a `locals_without_parens` of its own (Mutare's and
the companions' included). `ast_render_test.exs` pins it with a `.formatter.exs` naming an
unknown dependency in the working directory.

### The installer must fetch the deps it adds `[done]`

Igniter fetches the dependencies an installer *declares* (`Igniter.Mix.Task.Info`'s
`installs`/`adds_deps`) before running it, and applies whatever `igniter/1` changed —
`mix.exs` included — at the very end, with no fetch after. `mutare.install` picks the
companion packages at run time from the project's own deps (`Igniter.Project.Deps.has_dep?`
on `:phoenix`, `:ecto`, …), so it adds them from `igniter/1`, and the v0.1.0 smoke test
showed the consequence: `mix igniter.install mutare` left six companions in `mix.exs`,
none in `mix.lock` or `deps/`, and a `.mutare.exs` naming their modules, so the very next
`mix mutare` failed at `deps.loadpaths`. The declared route (`adds_deps` in `info/1`) is
static and cannot see the project, so the fix is on our side of the contract:
`fetch_companion_deps/1` calls `Igniter.apply_and_fetch_dependencies/2` right after the
deps are added — applying only the `mix.exs` change and running `deps.get` — and hands the
remaining changes (`.mutare.exs`) on to Igniter's final apply. Skipped under
`Igniter.Test` (`assigns[:test_mode?]`), where fetching raises by design and the tests
assert on the igniter's deps.

### Factor compiler input before rendering `[done; cases and guards]`

The 2026-09 compile-time audit found several remaining products of independent sizes
in generated source. The changes preserve candidate order, report IDs, and first-order
mutation; reducing compiler input is the claim, not a proportional wall-time promise.

- **Tupled cases:** `CaseClauseEmit` evaluates the selector, evaluates the instrumented
  scrutinee once, then records the complete hosted ID set once before matching clauses.
  A raising scrutinee records no clause coverage; unmatched successful evaluation still
  records coverage and raises `CaseClauseError` with the original term. Body coverage
  stays inside the reached body. The old per-original-clause/fallback records repeated
  every hosted ID C+1 times. A 100-clause, 299-mutant integer fixture (100 `<i> -> :ok`
  clauses, `mutators: [:integer]`, Elixir 1.19.5 / OTP 26) went from 547,769 to 57,219
  source bytes and 36,758 to 7,571 parsed AST traversal nodes; coverage ID occurrences
  fell from 30,199 to 299. Manifest/poison recognition remains tested.
- **Exclusion guards:** `GuardBuild` sorts/deduplicates IDs into exact consecutive runs,
  compresses sufficiently long runs into interval exclusions, and combines remaining
  expressions in a balanced tree. A single non-integer escape preserves the previous
  strict-inequality behavior for floats and other terms. Holes, including poison skips,
  remain allowed. Excluding IDs 101..180 shrank from 399 to 31 traversal nodes, and 1,545 to
  125 rendered bytes. The threshold is seven IDs, where the interval form still pays for
  itself against the explicitly qualified comparisons it replaces (see below).
- **Generator cost:** `LiftedEmit` groups claimed candidates by source clause once,
  instead of scanning all M candidates for each of C clauses. This removes an O(CM)
  generator scan; it is separate from compilation of the resulting source.

**Every operator Mutare generates is now an explicit `:erlang` call** `[done]` — the gate
(`GuardBuild.gate/2`), the exclusions and the conjunctions joining them, and the coverage
record's `==`/`and` (`Recorder.record_ast/2`). `Mutare.AST.erlang_call/2` builds them and
`erlang_call_args/2` is the only way to recognise one, so a reader
(`Manifest.gate_id/2`, `Recorder.record_var/1`) cannot drift from the builder; the latter
tolerates the `{:__block__, _, [:erlang]}` wrapper a Sourceror reparse adds around the module
atom. Generated code no longer depends on the target's lexical environment, the same principle
`AST.absolute_call/3` already applied to the `CaseClauseError` re-raise.

**This was measured before being kept, and the measurement inverted twice.** Rendered size says
it is expensive. Mutare's own `lib/` as a fixed corpus (366 files, 29,537 mutants, all default
mutators, Elixir 1.19.5 / OTP 26):

| Generated source | bytes | AST traversal nodes |
| --- | ---: | ---: |
| `c06f221b`, before any of this work | 9,361,532 | 923,309 |
| this work, no operators qualified | 9,302,455 | 913,543 |
| this work, exclusions + conjunctions qualified | 9,662,894 | 950,545 |
| this work, everything qualified (shipped) | 11,477,485 | 1,089,037 |

That is +22.6% bytes and +18.0% nodes against the unqualified build — on a change whose stated
claim is *reducing* compiler input. Two things save it, and both had to be measured:

- **Compile time and memory move the other way.** A 2,000-function fixture (`def runN(x), do:
  x + 2`, `mutators: [:arithmetic]`), three alternating `mix compile --force --no-verification`
  runs each, medians: qualified 2.42 s wall / 452 MB peak RSS from 786,754 bytes; unqualified
  2.69 s / 505 MB from 598,655. **31% more source compiled 10% faster in 10% less memory.**
  A guard-heavy fixture (`bench` case-100) is a wash — 1.01 s vs 0.99 s over seven runs each,
  inside the spread.
- **Why:** `Kernel.and/2` in *body* position is a macro that expands to a three-clause `case`
  with a `badbool` error branch, while in a *guard* it already compiles straight to `andalso`.
  The coverage record carries two body-position `and`s **per generated function**, so the
  unqualified form paid two extra `case`s each; `:erlang.andalso` passes through untouched. The
  guard fixture is neutral because guards never had the penalty to begin with.

So rendered bytes and pre-expansion node counts are the wrong measure for this decision: they
count what the *parser* reads, not what survives macro expansion, and here the two point in
opposite directions. Keep measuring both, and never conclude from source size alone what a
compile will cost.

`bench/compile_shapes.exs` generates standalone, inference-disabled Mix projects for
comparing AST/source growth and profiling already-generated code with the same runtime.
Its README says how to run the cold-compilation and retained-sandbox selection comparisons;
measured results are recorded here rather than beside the generator, where they would have to
be regenerated on every change that moves a byte.

### Strict arithmetic operand sharing `[deferred; experiment removed]`

`StrictOperands` tried to share evaluated operands between certified Arithmetic
variants instead of copying each ancestor's raw subtree. Keeping macro-visible lexical
scope unchanged required import witnesses, salted temporaries, tuple-case boundaries,
and a special flattening path for literal right operands.

The initial Arithmetic-only benchmark missed IntegerLiteral's default selectors:
requiring an emitted RHS to remain a literal blocked flattening and made an 80-addition
fixture 1,987,142 bytes versus ordinary delivery's 832,076. Certifying selectors with
exclusively literal branches repaired that case, but did not justify sharing generally.
With all default mutators, a 160-addition literal-right chain shrank from 4,888,052 to
260,019 bytes; changing the RHS to a bound variable instead grew output from 3,690,232
to 6,257,900 bytes, despite reducing AST traversal nodes from 31,082 to 17,893.
Nested indentation outweighed the tree reduction. Original subtree size and semantic
eligibility did not establish that the emitted program would be smaller.

The implementation and its dedicated tests were removed; ordinary selector delivery
remains. The operand-specific certification, metadata, names, and scope walks were
removed too. The generator remains under `bench/`, with both literal and variable RHS
fixtures using the default set; raw `bench/results/` files are local, ignored
measurements. The sizes above are what that experiment measured, not what the current
tree produces — its arithmetic fixtures now render exactly as they did before it.
Revisit only with evidence
from representative default workloads, measuring emitted bytes and compilation as
well as AST size, and a rule that declines sharing when its scaffolding costs more.

### Static run selection controls emission, not ID reservation `[done]`

`Schema` still discovers every candidate in each scanned file. Its count pass records
matching local IDs only when a line filter needs them, using the Site constructor's
actual attribution (including hosted and custom report locations), without rendering
any diff text. The prefix-sum step then applies line selection followed by the global
cap and passes `emit_ids` to emission. Unrestricted scans keep the tally-only count path.

`ClaimState` advances every ID and retains every diagnostic Site, but creates artifacts
only for selected, non-poisoned IDs (also excluding ignored IDs now; see below). Unselected sites are **not poisoned**; their diffs
are not rendered and they disappear from the final report slice after directive checks.
Consequently a focused run no longer pays to compile a poisoning mutation on an
unselected line. Ignored and poisoned sites still consume cap positions: the old
from_files documentation said recovery would replace a poisoned site with the next
candidate, but the implementation retained poisoned Sites and never did that.

Wholly unselected files (or a selected slice entirely removed by recovery) retain the
exact original source. A lifted function with no remaining lifted variants and no body
selector needing its dispatcher falls back to its original clauses; generated group
numbers still advance. Tests cover stable IDs across files and recovery, ignored-site
caps and diagnostics, attributed and hosted selection, and focused compilation without
unselected macro poison. Report-time hydration still uses the pre-filter start ID.

App-build seeding compares metamutant entries with `Schema.sources` before counting
rewritten files, attributing them to apps, or deleting beams. An unchanged entry must
keep its seeded beam: merely retaining its key for reporting does not require a
recompile. An entry without a recorded original still requires deletion, preserving
the conservative behavior for manually constructed schemas.

The tradeoff is real: changing selection now changes the metamutant, whereas the old
full metamutant could be reused for every selection in the same files. Fixed-selection
retained runs still use the byte-aware sandbox writer. This change targets cold/focused
compiles, not free reuse while repeatedly changing flags.

**The `--since` CI flow gains from this and loses nothing** — checked rather than assumed,
because `--since` changes its selection on every run and README leads with it. Four points, in
the order they confused the first analysis:

1. **Line selection was already file-scoped.** `Schema.build/2` intersects the discovered files
   with the ones a line filter names (`restrict_to_line_files/3`) *before* `from_files/4`. A
   file the diff never touched was never in the schema, never rendered, never compiled — before
   this change or after. The "old full metamutant could be reused for every selection" tradeoff
   above is therefore **not** about unrelated files; it is about re-selecting *within* a file
   already in scope.
2. **What is left in scope is the diff's own files**, whose sources changed anyway. A cached
   sandbox must recompile them whatever the metamutant looks like, so specialising them costs
   nothing that was previously free.
3. **Both remaining effects are gains.** Measured on a four-module fixture with
   `--line lib/A.ex:2 --line lib/B.ex:1` (Elixir 1.19.5), before → after:

   | Schema entry | before | after |
   | --- | ---: | ---: |
   | `lib/A.ex` (one selected candidate line) | 3,633 B | 798 B |
   | `lib/B.ex` (named line hosts no candidate) | 3,651 B | 118 B, **byte-identical to the original** |

   The one compile now scales with the diff's *mutants* rather than the diff's *files*; and a
   file whose changed lines host nothing mutatable (a comment, a moved blank line, a rename)
   stops being rewritten at all, so `Seed.app_build`'s `Map.reject` keeps its seeded beam
   instead of deleting and recompiling it. End to end on a four-module project a focused run
   reports `reused 3 app beams, recompiling 1 metamutant beam`.
4. **The regression is confined to hand narrowing.** Running `--line foo.ex:10` and then
   `--line foo.ex:20` over a retained sandbox recompiles `foo.ex` where it used to be reused.
   That is a human iterating, not CI: a `--since` run's selection changes only because the
   diff changed, which already forced the recompile.

`worth_seeding?/2` had to change for point 3 to pay off: a zero *changed*-metamutant count is
now the best case for seeding (nothing recompiles), where it used to decline and cold-compile
the app.

### The reported slice and the emitted slice are checked against each other `[done]`

Selective emission left one slice derived twice. `render_jobs/2` decides which IDs the
metamutant emits, from the count pass's matching local IDs and a running `--max-mutants`
remainder; `restrict_lines/2` + `limit/2` decide which sites the report shows, by re-filtering
the finished Sites on `{file, line}` and re-taking the cap. Nothing connected the two. They
matched only because `assemble/3` folds files in the order `render_jobs/2` prefix-sums them
and Sites accumulate in ID order within a file, so "first N sites" and "first N selected IDs"
happened to name the same mutants.

That coincidence is invisible at the call site, and the obvious tidy-ups break it: sorting
`:sites` for a tidier report, reordering `assemble/3`, moving a filter past the cap. The
resulting failure is the expensive kind — a site the report shows whose mutant was never
emitted runs the suite unmutated, so it always passes and is scored a **survivor**, the
corruption "Empty coverage is a valid focused-run result" reached through another door. Probed
with an attribution that drifts between passes, the pre-guard schema returned one live
(unpoisoned, unignored) site against a metamutant byte-identical to the original.

`verify_selection!/2` now compares the two sets at the end of `from_files/4` and raises on
either difference — a reported ID nothing emitted (the false survivor) or an emitted ID nothing
reports (a mutant compiled but never run). It follows `verify_count!/3`: assert the invariant
where the assertion is cheap. Cost is one `MapSet` over the sites and one over the selection,
next to a scan that parses and renders every file. The regression fixture `DriftingLineMutator`
names the carrier node's line on its first call and the right operand's on later ones, drifting
the attribution without ever drifting the count — one test per direction.

Deriving the sites *from* the emitted set instead — one derivation, no drift possible — was
weighed and dropped. It cannot produce a false survivor, but it reconciles a disagreement
instead of reporting one: emission would silently overrule whatever `restrict_lines/2`
concluded about a site's line, and the `--line` scoping the user asked for would quietly change
meaning. A crash names the bug; a silent reconciliation buries it.

### Ignored mutants reserve IDs but emit no code `[done]`

Ignore directives are parsed from the original AST before emission, then matched in
`ClaimState` after each Site is constructed. That is the first shared point with the
final report location, producing family, and variant labels, including hosted fragments
and custom attribution. Ignored sites retain their IDs, reasons, diff fields, and cap
positions, but their artifact builder is never called. Selectors, coverage records,
lifted gates, and exclusion guards therefore contain only emitted mutants. An entirely
withheld file returns its original source bytes, allowing app-build seeding to reuse it.

The count sink still constructs no Sites and invokes no `variant/2` callbacks. It counts
every candidate, including ignored ones, so cross-file ID ranges and cap consumption
stay unchanged. Scope/qualifier validation runs before either sink, including for
zero-site files. Unselected and poison-skipped sites also receive their ignore reason,
preserving directive diagnostics and the existing combined ignored/poisoned flags.
Report-time site hydration uses the same claim path.

The motivating pre-implementation experiment used `emit_ids` on a synthetic
1,000-function fixture with half its mutants ignored: generated source fell from
399 KB to 221 KB. Three alternating forced compiles on Elixir 1.19.5 / OTP 26 gave
median wall time 2.84 s → 2.26 s (about 20% faster), with 25% less peak RSS. Those are
fixture-specific measurements; the payoff depends on how many mutants a project ignores.

A source-volume check of the implementation with 1,000 `x + 2` functions, arithmetic
mutations only, and half carrying trailing ignores retained IDs 1..1,000 and reduced
406,761 bytes to 228,865 bytes (43.7%). The compile timings above come from the motivating
`emit_ids` experiment; this check did not remeasure compilation.

### Raw-body outlining and runtime identity namespaces `[outlining deferred; namespaces done]`

Sharing large raw clause bodies remains worthwhile, but extraction needs a positive
eligibility contract: head bindings, function-sensitive macro expansion, implicit
rescue/catch/after boundaries, and super forwarding must survive the new function
boundary. Existing resolved-call stamps identify a call's module, not all the compile-
time context an arbitrary macro can observe. A whitelist covering only trivial raw
expressions would prove a much narrower benefit than general head/guard outlining.
The target's global or explicit Erlang inlining can also undo helper sharing; an
inlining policy belongs with an outlining design, not an incidental compiler override.

The namespace half is implemented separately below. Outlining remains deferred.

### Stable per-file runtime identities `[done]`

Schema builds now distinguish report ids from runtime identities. `Site.id` keeps the
existing prefix-summed report number; `Site.runtime_id` is `{root_relative_file, local_id}`.
`ClaimState` still reserves every report id and applies selection, ignores, and poison skips
there, but hands each artifact builder the local integer. No report offset enters generated
source. The two-pass schema build remains: counts still resolve global selection before
emission. Standalone transforms omit the internal `:runtime_namespace` option and retain
integer selection, including their existing `:start_id` semantics.

The precise invariant is **unchanged B source, transform inputs, and effective local emission
selection → byte-identical B metamutant**, even when A's candidate count or discovery scope
changes B's report range. Unchanged options alone are insufficient: a fixed global
`:max_mutants` can give B fewer selected candidates after A gains some. Renaming B or editing
its own candidate sequence can change its runtime identities. This is not a persistent mutant
identity for reusing historical verdicts, nor a promise that Mix will ignore real compile-time
dependencies on A.

One persistent-term slot holds `{namespace, local_id}`. A generated projection yields the
local integer for the active file, `0` at baseline, and `:inactive` for other files. Function
bodies hoist that projection with their existing selector read; inline/default positions
keep it self-contained. Gates and interval exclusions still use local integers, and inactive
files short-circuit coverage before reading its tracking flag. Selection remains one write,
with the existing self-hosting key override. The dependency-free bootstrap combines
`MUTARE_ACTIVE_MUTANT` with `MUTARE_MUTANT_NAMESPACE`; integer/baseline invocations explicitly
clear an inherited namespace.

**The translation does not spread through reporters.** `RuntimeId.index/1` translates the
coverage dump's five collections before the runner consumes them. The helper keeps one
process-dictionary seen-cache entry per namespace and qualifies an id as `{namespace, local_id}`
only when it writes the id to ETS, so two files' local id 1 stay distinct even within one test;
the dump groups local ids by namespace, and `Coverage.read_dump/2` flattens them before
translating. An unknown runtime id invalidates coverage and falls back to run-all.
`RuntimeId.file_index/1` translates lazy Manifest findings before Poison unions files;
the macro fallback now retains its call-site file until that conversion. Manifest recognises
the projection and excludes its zero branch from mutant regions. Hydration still derives
report ids from `schema.start_ids`; public DTOs and every reporter keep integer report ids.

**Poison drops an id its index doesn't know; it never raises on one.** Translating flipped what
a Manifest finding has to mean: an id read out of a metamutant used to need no site behind it
(metamutant ⊋ sites), and translating one demands metamutant ⊆ sites. Selection manufactures
findings that own no site. A file the cap or `--line` leaves nothing to emit renders pristine, so
no generated code anchors the salted dispatch name, and target source that happens to write a
selector's own shape (`case mutare_active do 1 -> ...`) reads back as local id 1. That phantom was
inert while ids passed through raw; under a bare `Map.fetch!` it killed the recovery the compile
failure had just started — the one moment Poison exists to survive. Dropping it attributes
nothing, which the caller already handles: the macro fallback, then the abort and its `Hint`.
`Schema.verify_selection!/2` guarantees every emitted mutant reaches a reported site, so an
untranslatable id is a phantom by construction, never a lost mutant.

Self-hosted fixture transforms now emit calls to the existing private coverage stand-in as
well. Previously only the stand-in's definition moved aside: a fixture still called the real
helper and could add unrelated ids to the outer probe. Strict runtime-to-report translation
would reject that polluted dump. Harness-built metamutants keep the real helper; fixture
calls and their xref attributes resolve through `Recorder.fixture_module/0` in the suite's
process. The bootstrap and written helper remain independent of that override.

**2026-09-08 investigation:** the existing retained-default fixture recompiled A and B after
an A-only candidate-count edit under global ids. A temporary namespace spike kept B's bytes
identical and recompiled only A; both no-change controls compiled nothing. The implementation's
`namespace_runner_test` verifies that result through the real sandbox, then reruns mutation
testing with B's changed report id. It also checks shared-test coverage and two-file poison
recovery. `runtime_id_test` compares per-mutant standalone/namespaced behavior, including
hosted fragments, defaults, guards, case/fn/rescue/binding delivery, and variable-name collisions.

Separate persistent-term slots per file were tried and removed. With inactive files reading
zero, every selector checked the coverage flag. In a temporary Arithmetic-only fixture
(Elixir 1.19.5 / OTP 26), seven alternating samples of 100,000 function calls gave the following
median microseconds. The legacy selector held an unrelated integer; namespaced variants held
an unrelated file identity. No coverage was enabled.

| Selectors per function | Legacy integer | Separate file slots | Global projection prototype |
| --- | ---: | ---: | ---: |
| 1 | 3,293 | 6,648 | 3,477 |
| 10 | 4,300 | 14,733 | 4,141 |
| 100 | 23,714 | 104,708 | 19,118 |

These are mechanism measurements, not suite speedup claims. The measured projection prototype
used `-1` for an inactive file; the implementation uses the atom `:inactive`, preserving the
coverage short-circuit without generating a unary operator. Projection adds source and compiler
work at each read, and namespace arguments add coverage payload; the gain is avoiding unrelated
retained-build recompilation. There is no claim of faster cold compilation or scan caching.

The final `:inactive` implementation was then measured with the same fixture and sampling
protocol, without concurrent tests or benchmarks. Legacy versus namespaced medians were
3,917 vs 3,872 µs (one selector), 4,643 vs 4,395 µs (ten), and 24,980 vs 19,673 µs
(one hundred). This narrow inactive-file check found no runtime regression; it does not
measure coverage-probe overhead or establish a general application speedup.

**2026-09-10: coverage probe hot path and dump.** `hit/2` first built a `{namespace, id}` list
on every call, ahead of the seen-cache check, and the cache keyed each id by that tuple, so a
repeat hit also hashed the file path once per id; the old `hit/1` had used its literal id list
directly. The dump spelled the path out once per id, because the external term format shares
nothing. The helper now keeps one process-dictionary entry per namespace,
`{:mutare_cov_seen, namespace} => {tid, %{id => keys}}`, qualifies an id only when recording it,
and writes an entry back only when one of its ids is new; `dump/1` groups every id collection by
namespace, and `Coverage.read_dump/2` flattens the groups before translating. The probe deletes
the dump before each attempt, so the reader keeps no flat-format fallback.

A scratch benchmark compiled HEAD's helper next to the working tree's in one VM, rebuilt the
nested-map variant by patching the working tree's cache function, gave each variant one warmed
worker holding a test label and 150 cached ids in each of N files, and took 11 interleaved
samples of 300,000 calls on an otherwise idle 16-core machine (load average 1.7). Paths were
either all 28 bytes with a 23-byte shared prefix or varied in length. Medians, in ns per call:

| Paths, cached files | Ids per site | Pre-namespace `hit/1` | `hit/2`, per-hit tuples | Nested map | Pdict entry per namespace (adopted) |
| --- | ---: | ---: | ---: | ---: | ---: |
| same-length, 30 | 1 | 214 | 274 | 278 | 219 |
| same-length, 30 | 4 | 293 | 527 | 333 | 275 |
| same-length, 30 | 16 | 668 | 1,562 | 574 | 508 |
| same-length, 100 | 1 | 217 | 278 | 216 | 218 |
| same-length, 100 | 4 | 298 | 516 | 273 | 273 |
| same-length, 100 | 16 | 650 | 1,552 | 510 | 512 |
| varied-length, 30 | 1 | 217 | 277 | 189 | 209 |
| varied-length, 30 | 4 | 292 | 513 | 244 | 264 |
| varied-length, 30 | 16 | 674 | 1,564 | 484 | 499 |
| varied-length, 100 | 1 | 218 | 284 | 222 | 207 |
| varied-length, 100 | 4 | 298 | 519 | 276 | 263 |
| varied-length, 100 | 16 | 666 | 1,609 | 527 | 509 |

A first fix nested one map by namespace (`%{namespace => %{id => keys}}`, the "Nested map"
column) and left a residual. A map of 32 or fewer keys is flat, and a lookup compares its binary
keys one at a time; paths of equal length compare byte by byte up to their first difference.
With 30 same-length paths cached, a 1-id hit cost 1.30× the pre-namespace call — no better than
the per-hit tuples it replaced. Past 32 namespaces the map hashes, and varied lengths end most
compares at the size check; with 30 varied-length paths the flat scan even beat the dictionary
hash (189 vs 209 ns at 1 id). The process dictionary hashes every key, so an entry per namespace
costs one hash of the path per call however many files the process has run: from 5% below to 2%
above the pre-namespace call at 1 id, 6–12% below at 4 ids, 21–26% below at 16. The price is one
dictionary entry per executed file instead of one in total.

Dump sizes are exact, not sampled: 200 files × 150 ids, each file's test module covering all of
its ids.

| Tests per module | Pre-namespace integers | Flat `{namespace, id}` | Grouped |
| --- | ---: | ---: | ---: |
| 1 | 1,090 KiB | 3,905 KiB | 791 KiB |
| 3 | 2,027 KiB | 4,842 KiB | 1,729 KiB |

Grouping undercuts even the pre-namespace dump: local ids stay below 256 and encode in two
bytes, where report ids above 255 take five. Test names, repeated once per id in `by_test`, make
up most of the three-test row.

### Try/rescue: whole-construct duplication `[benchmarked; eligible shapes factored]`

Include `try`/`rescue` alongside large-body head/guard mutations in the raw-body
outlining investigation above. `Analyze.ClausePatterns.rescue_clause_candidates/3`
builds a `rebuild_try` closure that replaces the rescue clauses and retains every
other block. Both type-list narrowing (`Candidate.CasePattern`) and whole-clause
removal (`Candidate.RescueDrop`) originally delivered a complete `try` per mutant,
including its unchanged `do` body and `after`. With M rescue mutations and B body
nodes, this produced O(MB) compiler input even though only a handler changed.
The catch-all selector branch carries the instrumented original; active rescue
mutants carry raw bodies, preserving first-order mutation. That delivery remains the
fallback; see *Rescue factoring experiments* below for the bounded optimization.

The motivating report was a 2.5 KB source with eight rescue types producing nine
complete tries and 32.8 KB with only `:rescue_type`. The existing benchmark matrix
already covers this mechanism through `rescue_types-{isolated,default}-NxB` and
`rescue_clauses-{isolated,default}-NxB`, crossing 2/4/8 types or clauses with
10/40/160 sequential body statements. Both isolated sets enable only `:rescue_type`.
Keep these grids beside `head_body` and `guard_body`, varying each dimension
independently; default-mutator runs expose the additional body selectors.

**2026-09-08 baseline, `0a614910` plus the benchmark event-trace checks in this
change:** Elixir 1.19.5 / OTP 26 (ERTS 14.2.5.15), compilation with
`ERL_FLAGS='+S 4:4'`, `MIX_ENV=test`,
`ERL_COMPILER_OPTIONS='[no_ssa_opt_alias,time]'`, signature inference disabled by
the generated project, and `mix compile --force --no-verification --profile time`.
The generator used 16 schedulers. Wall time and peak RSS below are medians of three
fresh-VM compiles per fixture, cycling through the fixtures between repetitions;
they include Mix boot, exclude generation and smoke checks, and were run without
concurrent tests or benchmarks. These are current costs, not measured savings from
a factoring implementation. Bytes count UTF-8 source; RSS uses MiB.

| Fixture | Sites | Source bytes | Generated bytes | Generated tries | Wall s | Peak RSS MiB |
| --- | ---: | ---: | ---: | ---: | ---: | ---: |
| `head_body-isolated-8x160` | 503 | 1,695 | 126,843 | 0 | 2.61 | 242.8 |
| `guard_body-isolated-8x160` | 16 | 1,739 | 42,891 | 0 | 1.55 | 147.2 |
| `rescue_types-isolated-8x10` | 8 | 549 | 7,357 | 9 | 1.55 | 110.5 |
| `rescue_types-isolated-8x40` | 8 | 849 | 12,757 | 9 | 1.81 | 117.1 |
| `rescue_types-isolated-8x160` | 8 | 2,049 | 34,357 | 9 | 3.06 | 164.4 |
| `rescue_clauses-isolated-8x10` | 8 | 1,142 | 13,008 | 9 | 2.20 | 131.8 |
| `rescue_clauses-isolated-8x40` | 8 | 1,442 | 18,408 | 9 | 2.38 | 161.4 |
| `rescue_clauses-isolated-8x160` | 8 | 2,642 | 40,008 | 9 | 3.79 | 200.1 |
| `rescue_types-default-8x160` | 660 | 2,049 | 196,983 | 9 | 6.00 | 235.5 |
| `rescue_clauses-default-8x160` | 702 | 2,642 | 215,731 | 9 | 7.20 | 268.5 |

The head fixture's IntegerLiteral set also mutates body literals, so its site count
is not a count of head mutations. The rescue-only rows isolate the duplication:
increasing B from 10 to 160 adds 750 parsed AST traversal nodes to either original
and 6,750 to either metamutant — exactly nine copies of the added body. The whole
grid emits three/five/nine tries for two/four/eight rescue mutations. Record AST
counts, source hashes, compiler profiles, wall/CPU time, and RSS when comparing a
future implementation; source size alone does not predict compiler cost (see
*Factor compiler input before rendering*).

**Semantics constrain the factoring.** Rescue heads cannot accept the selector
guards used for ordinary clauses (see *Rescue narrowing + clause drop*). Moving
the `do` evaluation outside the protected region would change which failures the
rescue handles. A candidate design must evaluate it once, preserve clause order
and fallthrough after a type/clause is removed, preserve exception normalization
and `__STACKTRACE__`/`reraise`, and retain the boundaries between `do`, `rescue`,
`catch`, `else`, and `after`. Handler/else/cleanup failures and throws/exits need
explicit checks, including cleanup's effect on an already-pending outcome.
`after` must execute exactly once on each applicable success or failure path, at
the same point relative to handling and propagation. Apply the same requirements
to the implicit `def ... rescue/catch/after` form and to the binding, macro-context,
and `super` obligations of raw-body outlining. Preserve nested body mutation,
coverage, IDs, and manifest/poison attribution as well.

The benchmark smoke checks now record ordered messages from `do`, the selected
handler, and `after`. Each fixture checks success, every listed exception type,
and propagation of an unlisted type, asserting one body entry and one cleanup
after the handler (if any). This replaces a sticky `Process.put(..., :done)` flag
that could pass even if only the first invocation ran cleanup. These baseline
controls do not prove a factoring design correct: the boundary cases above must
also run with rescue and nested body mutants active before any rewrite is kept.

### Rescue factoring experiments `[done for shared bound-handler shapes]`

The follow-up tried two broad rewrites before keeping a narrower one. **Extracting
the raw `do` body into a shared anonymous function** reduced compilation costs,
but added a `-run/arity-fun-0-` frame to both caught and propagated exceptions.
It also put the closure variable in scope for source macros. **Catching the raw
exception and selecting a native rescue around `:erlang.raise/3`** avoided the
extra function frame: the original class, reason, and stack are re-raised, then
Elixir performs its ordinary rescue matching and exception normalization. The
[Erlang `raise/3` contract](https://www.erlang.org/docs/26/man/erlang.html#raise-3)
supports that forwarding. This second prototype matched 2,000 explicit/implicit
rescue/catch/else/after scenarios, but its new catch variables changed what macros
observed through `Macro.Env.vars(__CALLER__)`. Ordinary `binding/0` reads that same
environment ([Kernel implementation](https://github.com/elixir-lang/elixir/blob/v1.19.5/lib/elixir/lib/kernel.ex#L3698)).
Neither broad rewrite was retained.

**The retained path reuses a binding the source already has.** `RescueEmit` factors
only when the selector is already bound in the current scope, the try has no
`catch`, and every rescue clause binds the same non-underscored variable over
literal exception types (or is a catch-all using that same variable). For example,
all branches may use `e`; a bare `[A, B]` or `A` head, mixed `e`/`other` bindings,
`_e`, unknown type expressions, and unbound scopes retain the existing whole-try
selector. At least two live rescue mutations are required. Eligibility follows a
positive syntax/scope contract; source handlers keep their visible binding names.

The outer try retains the protected body, `else`, and `after`. Its generated
`catch :error, e` forwards through a selector whose branches each contain only
`try do :erlang.raise(:error, e, __STACKTRACE__) rescue ... end`. The inner rescue
rebinds `e` to the normalized exception exactly where the source already bound
it; no additional name is visible to handler code. Unhandled errors propagate,
handler errors are not caught again, throws/exits pass through, and cleanup stays
on the outer try. No function is extracted, so function context, `super`, and
stack frames do not acquire a new function boundary. The existing selector
binding also fixes the chosen rescue before the body executes.

**Raw and instrumented bodies remain distinct where they differ.** A custom
mutation on a pipe stage causes the existing pipe emitter to expose its parameter
to macros inside that stage. Running that instrumented body during a rescue
mutant would change the macro's result compared with the old raw branch, even on
a successful call. The protected `do`, each `else` body, and `after` therefore use
a selector with wildcard patterns and guards reading the already-bound active
variable: one raw body for the live rescue IDs, one emitted body for everything
else. This adds no bindings to either body. Equal raw/emitted ASTs are shared
directly. The large-body cost is now at most two copies, independent of rescue
count; handler bodies themselves still have one copy per rescue variant.

Candidate discovery and the full-try replacement IR are unchanged. Claim all
candidates in their original order, then separate live rescue and whole-node
mutants; ignored, skipped, and unselected IDs still reserve their positions.
Whole-node mutants bypass the factored try. Record live rescue coverage once
before protected evaluation, including successful calls. The inner handler
selector preserves the existing manifest/poison ownership of each variant.

**2026-09-08 comparison against the saved unfactored fixtures:** same Elixir/OTP,
four schedulers, compiler flags, and inference setting as the baseline above.
Three alternating before/after fresh-VM compiles per fixture; medians below.
Generation, smoke checks, and tests ran outside the timed compiles. Every row has
eight types/clauses and 160 body statements. RSS is per-process peak MiB.

| Fixture | Generated bytes before → after | AST nodes before → after | Wall s before → after | Peak RSS MiB before → after |
| --- | ---: | ---: | ---: | ---: |
| `rescue_types-isolated-8x160` | 34,357 → 8,336 | 7,830 → 1,368 | 3.09 → 1.43 | 163.6 → 113.5 |
| `rescue_clauses-isolated-8x160` | 40,008 → 14,539 | 8,866 → 2,404 | 3.64 → 2.25 | 201.8 → 144.3 |
| `rescue_types-default-8x160` | 196,983 → 185,930 | 22,890 → 17,327 | 5.80 → 5.14 | 242.6 → 198.6 |
| `rescue_clauses-default-8x160` | 215,731 → 207,540 | 25,116 → 19,553 | 6.89 → 5.68 | 308.2 → 238.7 |

Default-mutator median wall time fell about 11–18%, peak RSS 18–23%; CPU time
fell from 8.01 to 7.22 seconds and 9.04 to 7.77 seconds respectively. Wall-time
spread was material (type/default before 4.38–6.15 s, after 5.00–5.22 s), so these
are fixture observations, not a general speedup promise. Byte savings under
defaults are smaller than AST savings because the shared instrumented body moves
deeper into a selector. The number of tries actually grows from nine to ten:
nine small handler-only tries plus one outer try replace nine complete copies.

All 36 rescue grid projects compiled and passed baseline smoke checks. The
`RescueEmitTest` source-patch comparisons cover 4,000 baseline/active-mutant cases
across explicit and implicit forms, with and without catch, plus default body
mutants and catch-all fallthrough. Dedicated regressions cover direct/reraised
stack frames, macro-visible bindings, raw pipe-stage scope in all three shared
blocks, coverage on success and failure, selection snapshots, whole-node bypass,
skipped IDs, manifest attribution, and fallback scopes/shapes. The rejected
prototypes and raw timing logs were kept locally, outside production code.

Validation: the full suite passed with 3,092 tests, 12 properties, and 88 doctests
(zero failures, one skipped); compilation with warnings as errors, formatting,
and Credo passed too.

### Anonymous functions: per-clause delivery `[done in bound scopes]`

A further source-volume check found `Analyze.ClausePatterns.clause_list_candidates/3`
still delivering `fn` and `receive` head/guard changes through whole-construct
`Candidate.CasePattern.replacement` values. An integer-only anonymous-function fixture
with 10 source clauses produced 29 mutants, 30 `fn` copies, 300 generated clauses, and
7,586 bytes; doubling to 20 source clauses produced 59 mutants, 60 copies, 1,200 clauses,
and 26,866 bytes. This is the old C×M multiplication in another delivery path.

**Implemented (2026-09):** `Candidate.FnClause` retains one raw mutant clause and its source
index. `FnClauseEmit` emits one `fn`, interleaving each clause's guarded variants immediately
before the original they replace. Originals exclude only their own live mutant IDs; a mutant
that fails its pattern or guard falls through in source order. Mutant bodies stay raw, while
original bodies retain their body/return selectors — except under a head mutant, where an
original a call falls through to runs its raw body (the rule below, under receives). Arity,
pins, captured source variables, alternative `when` guards, and `FunctionClauseError`
behavior are preserved.

The closure captures the already-bound active selector, and one creation-time record covers
the complete live head/guard ID set. A closure merely constructed is still covered; body
coverage remains invocation-time. No binding or function boundary is added around the fn,
preserving `binding()` and the lexical environment macros inspect. In scopes lacking that
binding (defaults, scaffold, nested modules, and implicit rescue/catch/else blocks), emission
keeps whole-fn selection. Candidates share the immutable raw source AST; only a live fallback
mutant rebuilds a full clause list. Removing that fallback requires a separate solution to
the macro-reflection constraint.

Fn candidates remain in the same metadata list as whole-node candidates. This preserves the
order of custom node offers, head/guard mutations, and the return/condition mutations an outer
construct appends later. A comparison with the previous analyzer confirmed identical complete
Sites and next IDs for integer-only probes and the guarded benchmark with both restricted and
default mutators. A regression pins the return-candidate ordering: separating the lists had
initially moved whole-fn return IDs ahead of the clause IDs. Ignored, unselected, and poisoned
IDs still reserve their original positions and generate no clauses or coverage entries.

`Manifest` recognizes each fn mutant's existing Erlang activation gate, records its entire
clause (including the mutated head/guard), and adds the whole fn as a structural-error
fallback. A poisoned guard maps to its individual ID, and skipping that ID compiles.

Repeated integer-only probes (`FnProbe.make/0`, patterns 1 through N, bodies `:ok`, Elixir
1.19.5 / OTP 26) measured:

| Source clauses | Mutants | Fn copies before → after | Fn clauses before → after | Source bytes before → after |
| ---: | ---: | ---: | ---: | ---: |
| 20 | 59 | 60 → 1 | 1,200 → 79 | 26,953 → 8,788 |
| 40 | 119 | 120 → 1 | 4,800 → 159 | 101,553 → 17,798 |

The existing two-argument guarded `bench/compile_shapes.exs` fixtures also become linear:
`fn-20` shrank from 142,618 to 23,947 bytes, and `fn-40` from 560,258 to 47,907 bytes.
With all default mutators, `fn_default-40` shrank from 720,605 to 86,976 bytes and from
399 fns to one. Tests compare every generated mutant of a multi-argument guarded fixture
against its independently patched source, and cover creation/body coverage, selector changes
after construction, nested closures, lexical reflection, fallback scopes, and poison recovery.

The separate receive rewrite follows below.

**Review corrections:** Per-clause fn/receive mutants retain both original and replacement
import witnesses in their raw clause body; whole-construct fallbacks wrap the replacement
with the same witnesses. Hidden import replacements therefore still fail compilation, and
the diagnostic maps to the affected mutant ID. In unbound scopes, fallback clause branches
and whole-node branches share one selector. Nesting the fallback beneath a whole-node
selector exposed its catch-all's `mutare_active` binding to raw-body macros. Regression
tests cover both import names in both delivery modes, poison recovery, and macro-visible
bindings when whole-node candidates coexist with head mutants.

### Receives: per-clause delivery `[done in bound scopes]`

`Candidate.ReceiveClause` now retains one raw mutant message clause, its source index, and
a shared reference to the normalized raw receive. `ReceiveClauseEmit` emits one native
`receive`, interleaving each clause's variants immediately before the original they replace.
The shared `ClauseVariants` builder also serves `FnClauseEmit`; it gates mutant clauses by
strict ID equality and excludes only that source clause's live IDs from its original.

**Mailbox order stays with the VM.** The rewrite does not consume or requeue unmatched
messages, add a catch-all, or implement a receive loop. For each queued message, source-order
clause precedence is preserved; the oldest message that matches under the selected mutant
is consumed, regardless of which clause matches it. A retargeted clause can leave its old
message queued and select a later message, or make an earlier queued message match. A later
clause's broadened variant never jumps ahead of an earlier original clause. Tests compare
both the result and the complete remaining mailbox against independently patched source
for every mutant, including literal swaps, guards, alternative `when` guards, guard drops,
pattern swaps and duplicate-pattern wildcarding.

**One timeout and one selector.** Only the `do` clause list changes. The optional `after`
block appears once, at its original position; its expression is evaluated once, and unmatched
arrivals do not restart the timeout. Tests cover queued and arriving messages, pinned
references, receives without `after`, zero/finite/infinite timeouts, invalid timeout values,
raising timeout callbacks, and after-only receives. Changing the global selector while a
receive waits does not change its captured dispatch value. No timeout literals become
message-pattern candidates.

All live head/guard IDs are recorded once on entry, before timeout evaluation, including
when the receive times out or its timeout expression raises. Body and after coverage stay
in the reached body. Mutant message clauses use raw bodies; originals and the after block
retain their emitted selectors, which cannot activate another ID during a head mutant's
run. No binding or function boundary is introduced around the receive. As with `fn`, scopes
without an existing selector binding retain whole-construct delivery so raw mutant macros
see their previous bindings; rescue and nested-module fallbacks have regression tests.

**Fallthrough and after bodies run raw under a head mutant.** "Cannot activate another ID"
was not the whole story: an emitted body can differ from the source even with every other
mutant inactive. A custom mutation on a pipe stage makes `PipeEmit` hoist that stage into a
`fn mutare_piped ->` closure, and a macro in the stage reading `Macro.Env.vars(__CALLER__)`
then sees `mutare_piped`. Whole-construct delivery ran the raw fallback there, so activating
a head mutant in a `fn` whose `_ -> x |> stage()` fallback held such a stage — or a receive
whose fallthrough clause or `after` body did — changed the mutant's observable result on
the per-clause path. `ClauseVariants` now applies the raw/instrumented split of "Rescue
factoring experiments" to every original clause body and each `after` body: where the raw
and emitted ASTs differ, the body selects on the already-bound active variable — emitted
for everything but the live head IDs, raw for them — with wildcard patterns, so neither
copy gains a binding; equal bodies are shared directly. The cost is the same bound the
rescue split has: at most two copies of a body that carries an instrumented stage, and one
of any other. Regressions in both emit test files pin the raw vars under every head mutant
and the instrumented vars at baseline.

Keyword-form receives retain the raw whole-node offer for custom mutators, while discovery
and fallback emission use the normalized clause list. Clause candidates remain in the same
ordered metadata list as whole-node and enclosing condition/return candidates. Complete
Sites and next IDs match the previous analyzer on integer-only probes and the guarded
benchmark with both restricted and default mutators. Ignored, unselected and poison-skipped
IDs keep their positions and emit no clause or coverage entry; withholding every head
variant still permits body mutations. `Manifest` records each gated message clause and the
whole receive as a structural-error fallback. A poisoned guard maps to one ID and skipping
it recovers compilation.

Integer-only probes (`ReceiveProbe.take/0`, patterns 1 through N, bodies `:ok`, `after 0 ->
:timeout`, Elixir 1.19.5 / OTP 26) measured:

| Source clauses | Mutants | Receive copies before → after | Message clauses before → after | Source bytes before → after |
| ---: | ---: | ---: | ---: | ---: |
| 20 | 59 | 60 → 1 | 1,200 → 79 | 29,718 → 8,831 |
| 40 | 119 | 120 → 1 | 4,800 → 159 | 107,078 → 17,841 |

For the existing guarded fixtures, `receive-20` shrank from 151,105 to 32,623 bytes and
`receive-40` from 558,085 to 65,209 bytes. With all default mutators, `receive_default-40`
shrank from 714,875 to 93,214 bytes and from 399 receives to one. These figures include body
selectors; the single `after` block is excluded from the message-clause counts above.

### Guard-only clauses: `with`/`for` `<-`, `with`/`try` `else`, `try` `catch`, `for … reduce:` `do` `[done in bound scopes]`

A survey of guarded clauses by construct (AST-walked over 409 `.ex` files: this repo, its
examples, and ten deps — sourceror, req, mint, finch, jason, nimble_options, owl, igniter,
rewrite, glob_ex) found the four clause-list deliveries covering nearly everything: `def`
heads 1344, `case` 315, `fn` 62, `receive` 3. The positions with no delivery were `with …
<-` 56, `with … else` 2, and `try catch`/`try else`/`for` generator 0 each. So in practice
this is one gap — the `with … <-` guard, at a sixth of `case`'s frequency — with four
siblings that share its shape and come along for free.

None of these can host an extra clause. A `<-` has no clause list at all, and a `with`
non-match must hand the *original* value to `else`, so the subject can't be tupled the way
`CaseClauseEmit` does either. A **guard-only** mutant, though, needs no clause of its own:
its pattern is the original's. `Mutare.Transform.ClauseGuardEmit` rewrites the clause's
guard into a guard *sequence* — one `<var> === <id> and <mutant>` alternative per mutant,
then the original gated by the exclusion of exactly those ids — with the same `:erlang`
gate builders (`GuardBuild`) the lifted heads and interleaved clauses use, so `Manifest`
already recognises the gate. Erlang tries each `when` alternative independently, a failing
(or raising) one fails only itself, and `andalso` short-circuits on the gate before an
inactive mutant's guard is evaluated — so the rewritten clause behaves exactly as if its
guard read the active mutant's, and as written under none. Verified in all five positions
before building (a `try catch` head with two patterns included).

Two limits are principled rather than deferred:

* **Guard-only.** Pattern-literal and structural pattern mutants in these positions would
  need a second clause. For `with <-` and `for` generators there is no way to get one; for the
  three clause-list positions the receive-style interleaving would work, but at 2 + 0 + 0
  occurrences in the survey it isn't worth a second mechanism. `GuardDrop` rides the sequence
  (its alternative is the bare gate), under the shared inert-guard rule and the same
  multi-pattern-head skip `fn` documents.
* **Not claimed outside a bound selector scope.** The gate reads the hoisted `mutare_active`
  variable — nothing guard-safe can read `:persistent_term` — and, unlike `fn`/`receive`, there
  is no whole-construct fallback because the clauses' bindings escape. So at module level, in a
  default-argument position, or in a nested module's `def`, `ClauseGuardEmit` drops the guard
  candidates *before* claiming: they take no id and leave no site, like any position never
  offered. (Dropping after claiming would leave an inert id reported as a survivor.)

Coverage is one record before the construct, for every live id — reaching the construct is
the guards' coverage, as it already is for a `case`'s later clauses. Bodies are left as
emitted (unlike the fn/receive raw-body split above): no body is duplicated or re-homed by
this rewrite, so nothing about the environment a body's macros observe changes.

Not done, and related: a `receive … after expr` timeout is still analyzed as a pattern (the
generic `->` clause), so a non-literal timeout's operators aren't mutated; fixing that needs a
timeout-mark row for the literal case (see "Argument marks").

### Return tails are delivered by node identity `[done]`

`Analyze.Returns` used to walk the analyzed tree and the raw tree in lockstep: the analyzed side
is where candidates attach, the raw side supplied each candidate's clean `original`/`range`. The
premise was that the two are one tree plus metadata, so a disagreement between them (a different
form, a different statement or clause count) was treated as impossible and fell back quietly — to
making the whole node one tail, or to skipping the block. The premise was false.
`Conditions.hoist_if/6` rewrites a tail `if` whose condition binds a variable the body reads into
`{:__block__, [], hoists ++ [if]}`, while the raw side is still the `if`. So the walk mutated the
whole `if` as one tail: the per-branch return mutants vanished, a coarse `if … end → nil`/`:mutare`
pair took their place, and in a unit-returning function that pair slipped past the `UnitReturns`
stamps, which sit on the branch leaves — a return mutant on a function the classification exempts.
The same happened in a `fn` clause body. Nothing warned.

Now the walk reads the raw tree alone — the single-tree walker classification already ran, so both
modes decide "return path" on the author's code — and files each tail's candidates under its
`Resolve.nid/1`. `deliver/2` prewalks the analyzed tree and appends them to the node carrying that
identity, wherever the analyzer moved it. Identity survives because the analyzer wraps and moves
nodes but keeps each node's meta — the property `Overlap` already relies on to match raw and
analyzed copies by nid. A tail left undelivered, or one that would carry candidates but has no
identity, raises: an analyze rewrite that loses a tail node is a bug, and attaching its candidates
to whatever node occupies the position records a mutant for code the author did not write there.
The lockstep guards (same-form matches, `length(a) == length(r)`) went with it, and so did the
equivalent survivor the statement-count guard left in dogfood runs.

**Rejected: teaching the lockstep walk the hoist shape.** Right for today's one rewrite, silent
again at the next.

**Cost.** One prewalk of the analyzed body per `def` clause and per `fn` (a nested `fn` is
re-walked by each enclosing level), where lockstep touched only the tail spine. Small beside
offering every node to every mutator.

### Test suite: async-safe compile helpers and the sync split `[done]`

An audit of the suite found four kinds of drift worth fixing at once; the decisions that are not
obvious from the code:

- **Two site types, on purpose.** `Mutare.transform_string/2` (and everything in the shipped
  `Mutare.Test`) returns public `%Mutare.MutationSite{}` DTOs, while
  `Transform.transform_string_with_sites/2` returns the internal `%Mutare.Site{}` — the one with
  `kind`/`placement` and the one `Site.describe/1` accepts. The suite's family tests assert on
  placement, which is core's business, not an author's, so they cannot route through the shipped
  helper. Hence `Mutare.Test.Metamutant.family_sites/4` (test-side, internal sites of one family);
  wrappers that only read the diff use the shipped `diffs`/`diffs_for`. A public
  `Mutare.Test.sites_for/4` was written and dropped: a suite refactor is no reason to grow the
  published API, and the diff-level helpers already cover what an author needs.
- **`Poison.ids/2`'s contract is the compiler's own stderr text.** The import-resolution poison
  tests hand it exactly that, so they cannot use `Code.with_diagnostics` (which is what
  `Mutare.Test.Compile` and every `Metamutant` assertion use — per-process, `async`-safe). They
  keep a real `:stderr` capture (`Metamutant.compile_error_output/3`, the one helper that touches
  the global device) and live in `transform_resolution_poison_test.exs`, `async: false`, so the
  other ~1800 lines of resolution tests run async. Every other `capture_io(:stderr, fn ->
  Code.compile_string(…) end)` in the suite was a warning-swallow and became a `Compile` call.
- **`*_runner_test.exs` is the convention, systematically.** One `:runner` test inside an
  otherwise pure module forces the whole module sync; every `Mutare.run/2`-driving test now
  lives in a `*_runner_test.exs` (`poison_runner`, `baseline_runner`, `ignore_runner` joined
  `case_runner`, `rescue_runner`, `namespace_runner`). `Report.Live` is an unnamed `GenServer`
  and sandboxes are per-test temp dirs, so runner modules *could* run concurrently; they stay
  sync for CPU headroom (180 s timeouts), which is also why they are out of the fast loop.
- **What must stay `async: false`, and what doesn't help.** Selector flips (`:persistent_term`),
  the global `:stderr`/`Mix.shell`/`Mix.env`/cwd, the property soaks' shared `Prop` fixture
  purge, and the named `:mutare_cov_*` ETS tables. Measured before/after on the fast loop:
  82.8 s (25.5 s async / 57.2 s sync) → 62.2 s (28.3 / 33.9). The remaining sync time *is* the
  runtime-flip tests (the rescue/receive emit files' "every mutant matches its source patch"
  loops are 2–5 s each), so moving flips into `*_runtime_test.exs` files would shorten nothing —
  the audit's suggestion to do so was wrong on that point.
- **Rendered-shape pins go through one place.** `Metamutant.lifted_pattern/3` and
  `lifted_name/4` derive from `LiftedEmit.base_name/4`, and `selector_tuple/0` is the one
  spelling of the in-place selector head, so a change to either composition moves every
  assertion. Literal pins remain only where the *salting* itself is under test (`names_test`,
  the `__mutare_0_` cases in `lift_test`).
- **Property pins added** (`:property`-tagged): the Conditions walks (above, under
  "Refactor candidates") and `runtime_id_property_test.exs` — for any subset of a file's ids,
  `:skip_ids` keeps every site (a skipped one `poisoned: true`) and `next_id`, and removes exactly
  those ids from the metamutant's manifest; a `:start_id` offset shifts report ids and nothing
  else, skip set included. Neither is a new fact (`Mutare.Transform` and NOTES "Stable per-file
  runtime identities" state both); they are now checked over generated modules rather than by
  example only.

### Data shapes: one struct per produced thing `[done]`

A pass over the tuples, bags, and parallel structs that had accumulated at the seams
between stages. The mechanics live in each module; what is recorded here is the *shape
decision* at each seam and the one place a public contract was deliberately left alone.

  * **One produced-mutation shape on both delivery paths.** `Dispatch.Result` is now the
    only thing a produced mutation becomes once the transform sees it: `Dispatch.to_result/2`
    validates the author-facing return (bare node or `%Mutation{}`) and resolves the recording
    spec (`producer || spec`) in one place, and the selector-host path carries the same
    `%Result{}`s on `Candidate.Hosted.mutants` that the ordinary path carries. The
    `{node, note, variant, producer}` quad and the `attribution_of/1` side-read it forced are
    gone. **`Mutare.Analyze.expression_mutations/3` keeps its `{spec, node, note, variant}`
    tuple on purpose**: it is a published contract that `mutare_ecto` destructures
    (`island.ex`), and it is a *generation* output the caller wraps into a `%Mutation{}` — not
    a delivery shape. Changing it would be a breaking companion release for no internal gain.
  * **`RunCtx` is the whole per-mutant bundle.** It now carries the `options` (config is
    *read* from them — `harness_retries`, `kill_runs`, `max_heap_mb`, `workers`,
    `max_survivors`, `confirm_timeouts` — never copied into a sibling field that could drift),
    the partition pool, the deadline, the hydrator, and the three resolved hooks, so
    `Stream.stream_and_collect(ctx, sites)`, `Stream.confirm_timeouts(ctx, results)`, and
    `MutantRun.run(ctx, site)` take the bundle plus the one thing that varies. The
    `:confirm_timeouts` gate moved *into* `confirm_timeouts/2`. (The heap cap is one of those
    reads: "The reserved env set is derived from the one env builder" had just swapped
    `RunCtx.heap_env` for a `max_heap_mb` field, and with `options` on the bundle that field
    was exactly such a copy.)
    `Compile`'s ad-hoc deps map is gone: its loop threads the `Run.Context` (root, options and
    `on_phase` all derive from it) plus the sandbox, and the attempt budget is
    `@poison_attempts - recovery.rounds` rather than a parallel countdown.
  * **Schema's phase records are structs.** `%Schema.Counted{rel, source, outcome}` with
    `outcome :: {:ok, %CountReport{}} | {:error, parser_error}` replaces the `:counted`
    5-tuple and its fifth-slot `facts` map (every fact the map carried is a `CountReport`
    field), and `%Schema.Job{}` replaces the render-job tuple plus the packed
    `{count, emit_ids}`; `render_one/3` reads the two render flags off the `Run.Context`
    instead of taking them positionally. The three ineffective-configuration detectors share
    one `full_scan?/1` gate and one union.
  * **`ClaimState` is claim state again.** The count pass's configuration diagnostics
    (`skip_lifting`/route/mark matches) were never touched by `claim/5`; they now live on
    `Ctx.matches` as a `%ConfigMatches{}` (the module that already collected two of them),
    and `Transform.count_report/2` returns a
    `%CountReport{mutants, selected_ids, matches, directives, degraded_uses}`. The last two
    are the facts "The count pass is the scan's only parse" added, which had parked
    `degraded_uses` on `ClaimState` as well; it is a `Ctx` field instead. Unlike `matches` it
    is read once off the annotated tree before the walk and never grows, so it rides `Ctx`
    only to reach `count_report/2`.
  * **Coverage dump: a `%Coverage{}`, strict shape, no rescue-as-control-flow.** The helper
    always writes all five keys (`HelperTemplate.dump_payload/0`), so the "absent key reads as
    empty" defaults were dead — and dangerous, since a truncated attribution read as empty
    could manufacture a false survivor. `valid_shape/1` now requires all five, and
    `translate/2` threads `{:ok, _} | {:error, {:unknown_runtime_id, id}}` through a `with`
    instead of raising `KeyError` out of `Map.fetch!/2` and rescuing it.
  * **Harvest returns `{directives, behaviours}`.** `collect/3` no longer smuggles a
    behaviour through the directive list as a `{:mutare_behaviour, mod}` tuple that every
    later step had to special-case away from `Macro.to_string/1`.
  * **Emit-side plumbing named, not flagged.** The clause-emit path takes a
    `delivery :: :lifted | :in_place` atom and `emit_clause_body/3` is two clauses (one per
    read strategy) instead of a boolean threaded through four functions and read twice at the
    bottom; `LiftedEmit.assemble/5` derives a `%LiftedEmit.Group{}` (signature, base name,
    dispatch variables, super closure) once and hands it to the clause builders, retiring the
    8-argument dispatcher builder; `RouteStamp.stamp/6` takes the resolve `env` rather than
    three of its fields spelled out at each of three call sites; and the
    `%Scope{active_bound: true, module_depth: 0}` pattern that four emit modules repeated is
    `Scope.active_var_bound?/1` (`ClauseGuardEmit`, written in parallel, had a fifth copy; it
    reads the helper too).
