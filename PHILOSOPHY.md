# The philosophy of Mutare

`DESIGN.md` is the blueprint and `NOTES.md` is the running logbook. This document
is the third thing: how Mutare *thinks*. The recurring ideas, the way decisions
get made, the values that survived contact with reality. If you understand these,
the rest of the code reads as inevitable.

---

## The spine: one invariant, and everything downstream of it

Mutation testing has a reputation for being an overnight job. The reason is
almost never the testing — it's the **recompilation**: every other approach
rebuilds the project once per mutant. Mutare's entire reason to exist is a single
bet:

> **Compile once.** Embed every mutant in one program behind a runtime switch,
> compile that program a single time, and run the suite N times by flipping an
> environment variable.

This is not one feature among many. It is *the spine*. Every other decision in
the project is subordinate to it, and the right question to ask of any proposed
change is always: **does this protect the one-compile invariant?** The per-mutant
cost must be process boot plus the covering tests — never a recompile. When that
invariant and convenience conflict, the invariant wins.

Everything else here is a consequence of taking that bet seriously.

---

## What the tool is *for*

**The diff is the product; the score is a trend.** The headline mutation score
is a number to watch over time. But the thing you actually act on is the list of
*surviving mutants*, each rendered as a one-line diff at `file:line`:

```diff
lib/billing/invoice.ex:42  [relational, in-place]  SURVIVED
-     if total >= threshold do
+     if total > threshold do
```

That says, to the character: nothing in the suite distinguishes `>` from `>=` at
the boundary. A missing test, precisely located. Mutare optimizes relentlessly
for that artifact being *clean and trustworthy* — which is why mutations are
minimal, why diffs are patched against the original source (not the build
artifact), and why a surviving mutant is never a lie.

**Interpretability over completeness.** Mutare is first-order only — exactly one
change per mutant. Higher-order mutants would cover more of the mutation space,
but "which change did the test catch?" becomes unanswerable. A tool whose output
you can't reason about is worse than one that probes less but means what it says.

---

## How it transforms code

**One general mechanism, one optimization — chosen by position, not by fiat.**
There is a cheap way (wrap an expression in an in-place `case` selector) and a
fully general way (duplicate the whole function and dispatch). The cheap way is
used wherever it *can* be — body expressions — and the general way (lifting)
where it *must* be — guards and clause structure, which drive dispatch and can't
host a `case`. Crucially, *placement is positional*: a mutator never declares
whether it's "in-place" or "lifted." The same operator swap is delivered in place
in a body and by lifting in a guard, because the transform decides from where the
node sits. (We deleted a `kind/0` callback precisely because it lied about this.)

**Use the right tool for each side of a problem.** The metamutant is a throwaway
build artifact: it only has to *compile*, so it's produced by AST rewrite. The
report has to be *beautiful*: a clean diff against the author's code, so it's
produced by range-preserving source patching. Two renderers, each fit to its
job. Forcing one mechanism to serve both would compromise both.

**Decouple things that only *look* coupled.** The sharpest example: we worried
for three milestones that the coverage probe would need to map shifted metamutant
line numbers back to original lines. It didn't. The probe works *entirely in
metamutant line space*; the report works *entirely in original line space*; the
two never need to be related. The hard problem dissolved once we refused to
couple them. When something feels intractably hard, check whether you've
imagined a dependency that isn't there.

**Be invisible at the boundary.** The public `f/arity` is unchanged after
lifting — callers, function captures, `@spec`, `@behaviour`/`@impl` all hit the
same name. The surgery happens entirely behind the module's front door. A
transform that changed the observable surface would be a transform you couldn't
trust on real code.

**Mutate the human's source.** Operators stay operators, clauses stay clauses —
we work pre-expansion, on what the author actually wrote. Instrumenting
macro-generated code is a different tool for a different question.

---

## How it runs

**Some isolation is non-negotiable.** Each mutant runs in a *fresh OS process*.
A mutant that corrupts an ETS table or crashes a supervisor must not bleed into
the next one, and reloading into a shared BEAM is a correctness trap. We bank the
death of *recompilation*, not of *process boot* — and boot is cheap, amortized by
running only the covering tests. We will trade speed for parallelism and test
selection, but never for isolation.

**Recover, don't abort.** Because every mutant lives in one build, a single
mutation that won't compile would sink the whole run. The naive safety net —
compile each candidate in isolation — costs N compiles and fights the spine.
Instead, Mutare *recovers* from the one compile it already does: on failure it
identifies the offending mutant from the error, drops it, and rebuilds. This is a
pattern, not a one-off: **prefer the design that costs nothing in the common
case.** The coverage probe reuses the baseline run; poison recovery is free until
something actually poisons; selection skips work rather than adding it.

**Defend the invariant with the simplest primitive that travels.** A mutation can
turn a terminating loop infinite, so each run is capped. Rather than kill a hung
OS-process tree (platform-specific signals, orphaned children), the mutant run
**halts itself** — a watcher calls `System.halt/1` after the deadline. Portable,
uncatchable, no `kill`/`ps`. The bootstrap injected into the target is likewise
dependency-free. Reach for the primitive that works everywhere before the one
that works cleverly.

**Never lie in the output.** The score is `killed / (total − no_coverage −
ignored − poisoned)`: mutants that *can't* be killed are removed from the
denominator, not silently counted as wins or losses. Skipped files are surfaced.
Test selection's one soundness risk — a kill that happens indirectly — is
documented and given an escape hatch (`--full`), not hidden. A mutation-testing
tool's whole value is telling you the truth about your suite; the moment it
fudges its own honesty, it's worse than nothing.

**Equivalent mutants: mitigate, don't pretend.** Detecting semantic equivalence
is undecidable, so we don't pretend to solve it. We *don't emit* the obviously
equivalent ones (multiply-by-1), we *keep* the subtly meaningful ones (the
`-0.0`-normalizing `+ 0`), we honor a `# mutare:ignore` annotation, and we'd
rather report a suspected-equivalent survivor than quietly drop a real one.

---

## How it gets built

**Walking skeleton first, then thicken.** The first milestone proved the entire
bet end to end — transform, compile once, switch, report — on a trivial case,
before any of it was good. Each milestone after is a shippable, tested, committed
slice; the big ones split again (M2a/M2b, M3a/M3b). You earn the right to the
next layer by making the current one real.

**Spike the risky mechanic before designing around it, and let reality rewrite
the plan.** Repeatedly, the move was: don't theorize about whether `:cover` import
works across processes, or whether a `Port` kill reaps the BEAM, or whether a
formatter can snapshot per-test coverage — *try it small first*. The most
important one failed: the planned per-test coverage via an ExUnit formatter was
unworkable (formatter events are async; coverage snapshots race), so test
selection became file-granular instead. The design serves what the tools
actually do, not what we assumed they'd do.

**Dogfood, because the tool is its own hardest test.** Running Mutare on its own
source found real compile-poisoning bugs (a `case`-valued map field, a
capture-arity `/`, a `?`-suffixed function name) and a genuinely subtle
self-hosting artifact (the suite's own tests stomping the selector key). The
honest move when a spike or a self-run contradicts the plan is to follow the
evidence — every one of those findings is recorded with its cause in `NOTES.md`.

**Compile-safety in layers.** Built-in mutators are compile-safe *by
construction* (swapping one operator for another reuses the operands and always
type-checks). Known dangerous positions are excluded *structurally* (guards,
capture arity). And the compile-poisoning pre-filter is the *backstop* for the
unknown — especially for user-written custom mutators. Three layers, weakest
assumption last.

**Write the limitations down.** Every deferral, every sharp edge, every "this is
the conservative choice and here's what it costs" lives in `NOTES.md`. A
limitation you've named is a decision; one you've hidden is a bug waiting to be
blamed on the user.

---

## In one breath

Pick one invariant worth protecting and let it organize everything. Make the
output something a human can trust to the character. Choose the mechanism that
costs nothing when nothing is wrong. Reach for the primitive that travels.
Decouple what only looks coupled. Try the risky thing small, and when reality
disagrees with the plan, reality wins. And never, ever lie in the report.
