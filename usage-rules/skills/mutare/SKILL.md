---
name: mutare
description: >-
  Drive Mutare (`mix mutare`), the compile-once mutation tester for Elixir: choose a
  scope that fits the job, run it within an agent harness's limits, read survivors and
  uncovered mutants, write tests that kill them, and suppress or route what should not
  be tested. Use when asked to mutation-test Elixir code, to check whether tests really
  constrain a change, to act on a Mutare report, or to configure `.mutare.exs`.
---

# Using Mutare

This skill covers what is specific to Mutare, and to an agent driving it. It
deliberately does not list flags. Look details up rather than guessing:

- `mix help mutare` is the complete offline reference: every option, its
  `.mutare.exs` key, its default, and sections on CI, umbrellas, database isolation,
  and the sandbox.
- `mix mutare --list-mutators` lists the mutator families and their ignore labels;
  `mix mutare --explain <family>` prints one family's exact swaps and exclusions.
- `deps/mutare/README.md` covers installation, companion packages, `call_routes:`,
  `argument_marks:`, and `# mutare:ignore`.

Two companion files hold the longer material:
[references/triage.md](references/triage.md) (what each kind of survivor usually
means and how to kill it) and
[references/troubleshooting.md](references/troubleshooting.md) (red baselines,
poisoned builds, harness errors, slow runs).

## What the mechanism implies

1. **One compile, then one `mix test` OS process per mutant.** Mutare rewrites the
   source into a *metamutant* that embeds every mutant behind a runtime switch,
   compiles it once in a sandbox copy of the project, runs a baseline, runs a
   coverage probe, then runs each mutant's covering tests in a fresh BEAM. A mutant
   costs a BEAM boot plus its covering tests, about a second each on a small
   project; it never costs a recompile. Mutant count and covering-test runtime
   decide how long a run takes.
2. **The sandbox is copied from the project and kept.** It lives at
   `$TMPDIR/mutare_sandbox_<hash of the project path>`, and the next run re-copies
   only the files that changed, so a re-run after adding a test recompiles nothing.
   The project is the source of truth: never edit files in the sandbox. The copy
   happens when a run starts, so edits made during a run reach only the next one.
3. **Each mutant runs only the test cases that executed it.** If code runs in a
   process no test can be traced to (an application-supervised GenServer, a bare
   `spawn`), its mutants fall back to the whole suite: still correct, but slow.
   `--per-file` widens selection to whole covering files, `--full` to the whole
   suite.
4. **Mutare mutates the source as written, before macro expansion.** Macros whose
   arguments are not ordinary runtime code (query DSLs, schema definitions) need
   those arguments *routed*. The companion packages (`mutare_ecto`,
   `mutare_phoenix`, …; `mix igniter.install mutare` detects which apply) carry
   routes for their libraries. A mutant that breaks the one compile is dropped as
   `poisoned`. If Mutare cannot attribute the compile error to a mutant, the run
   stops and prints the `call_routes:` entry to add.

## Pick a mode for the job

| Job | Run shape |
|---|---|
| Check that the tests you just wrote constrain your change | `--since master`: changed lines only |
| Harden one module | `--only lib/x.ex`, then iterate with `--max-survivors` and `--line` |
| Survey a whole project | size it with `--dry-run`, run in the background with `--report json:…` |
| First contact with a macro-heavy project | `--check` before any test run |
| Gate CI | "Continuous integration" in `mix help mutare` |

### Checking a change you made

This is the most valuable use for an agent. After you write code and tests, Mutare
shows whether those tests would notice if the new code were wrong.

    mix mutare --since master

- `--since REF` diffs from the merge base of REF and `HEAD` to the working tree, as
  a pull request does. That covers your commits, uncommitted edits, and every line
  of an untracked `.ex` file (unless `.gitignore` excludes it). A shallow clone
  that lacks the fork point is an error, not a silently wider scope.
- If the changed lines hold no mutation site (you touched only tests, say), the run
  prints `nothing to test` and exits 0.
- Deleted lines contribute nothing; `--since` tests the lines that now exist.

### Hardening a module

    mix mutare --only lib/billing/invoice.ex --max-survivors 5

`--max-survivors N` stops once N mutants have survived, in source order, which gives
you a batch to fix without paying for a full run. After fixing, recheck those lines:

    mix mutare --line lib/billing/invoice.ex:42 --line lib/billing/invoice.ex:57

`--line FILE:LINE` selects a whole line. The exact `file:line:column` the report prints
selects only the mutants at that position, though nested expressions that start at the
same character share it. The flag can be repeated, and it recompiles only the named files. Finish with an unrestricted run over
the module to see where it stands.

### Surveying a project

`mix mutare --dry-run` lists every mutant without compiling or running anything; its
header gives the count. `--max-mutants N` keeps the *first* N in source order, which
means the first files alphabetically, not a sample. To sample, use `--only` on a
representative file.

A full run on a real project takes minutes to hours. Run it in the background (see
below), and treat the result as a set of findings to report and prioritise, not a
list you must clear.

### Macro-heavy projects

`mix mutare --check` compiles the metamutant with poison recovery and runs no tests.
It reports poisoned mutants and prints copy-pasteable `call_routes:` entries for the
macros it could not handle. Add those entries to `.mutare.exs`, or install the
library's companion package. `mix mutare --list-macros` shows which macros already
have routes.

## Running it from an agent harness

- **Exit status 0 does not mean nothing survived.** Unless a gate (`--min-score`,
  `--max-no-coverage`, …) is set, a run with survivors exits 0. Read the report.
- **Long runs outlive tool timeouts.** Run anything bigger than one file in the
  background. `--time-budget 20m` bounds the per-mutant phase (compile, baseline,
  and probe come before it): Mutare stops launching mutants, lets the in-flight ones
  finish, reports the partial result, and skips CI gates.
- **Pass `--report json:mutare.json` on any run that might be cut short.** Mutare
  rewrites a JSON or HTML report bound for a file at every tenth of the mutants and
  within two minutes of any new result. It marks untested mutants `Pending` and
  replaces the file whole, so even a SIGKILL leaves the last checkpoint. A SIGTERM
  writes every report except SARIF from the results so far and exits with status
  143. SIGINT is not trapped and leaves only the last checkpoint. However the run
  ends, every mutant BEAM halts when the process that spawned it dies.
- **Redirect to files; never pipe into `tail` or `head`.** `mix mutare … | tail -40`
  shows nothing until the run ends, and if the harness kills the pipeline midway,
  the output dies with it. Run
  `mix mutare … > report.txt 2> progress.log` instead: the final report goes to
  stdout, progress to stderr. When stderr is not a terminal, progress is plain
  lines: each phase, each survivor as it appears, and a `PROGRESS` line with counts
  and an ETA at every tenth of the mutants and at least every two minutes.
  `grep PROGRESS progress.log | tail -n 1` tells you where a run stands. Leave
  `--quiet` off for anything you'll need to check on, because it silences those
  lines too.
- **Request JSON when you will process the results.** `--report json:mutare.json`
  writes the Stryker mutation-testing-elements schema and still prints the human
  report. The human report is the better one to read: it shows each survivor as a
  diff of the original line and lists uncovered lines by file. The JSON is the one
  to query:

  ```sh
  # survivors, one per line
  jq -r '.files | to_entries[] | .key as $f | .value.mutants[]
         | select(.status == "Survived")
         | "\($f):\(.location.start.line)  \(.mutatorName)  → \(.replacement)"' mutare.json
  # how many mutants had to run the whole suite (the slow ones)
  jq '[.files[].mutants[] | select(.testSelection == "suite")] | length' mutare.json
  ```

  Status values: `Killed`, `Survived`, `Timeout` (counts as killed), `NoCoverage`,
  `Ignored`, `CompileError` (poisoned), `RuntimeError` (a harness error; its
  `statusReason` carries the diagnostic), and `Pending` (not tested yet, in a
  checkpoint, or after an early stop or a kill).
- **Identify a mutant by file, line, family, and replacement, never by `id`.** Ids
  are assigned over the scanned scope, so a `--line` or `--only` rerun numbers
  mutants differently.
- **Run one Mutare per project at a time.** A second concurrent run on the same
  project is refused because it would share the sandbox. Don't have sub-agents each
  launch Mutare. Run it once, hand survivors out by file for test-writing, then
  recheck every line they touched in one `--line … --line …` run. (A separate
  `--sandbox PATH` makes a parallel run possible, at the cost of another full copy
  and compile.)
- **Budget the machine.** Each worker is a full `mix test` BEAM; the default is half
  the schedulers, at most 4. In a constrained container, lower `--workers`.
  `--max-heap-mb` turns a mutant that allocates without bound into an ordinary test
  failure instead of a host OOM.
- **Run `mix test` first.** Mutare needs a green baseline, and checking it yourself
  is faster than waiting for Mutare to find out.
- **Put project facts in `.mutare.exs`; pass per-run choices as flags.** Routes,
  `skip_lifting`, `partition_env`, and gates describe the project and belong in the
  file. Scope (`--only`, `--since`, `--line`) belongs to the run.
  `mix mutare --show-config` prints the merged result.

## Acting on survivors

A survivor makes a precise claim: *this exact change to this line passed every test
that executes it.* Each survivor resolves in one of four ways, and choosing among
them takes judgement:

1. **A missing or weak test**, the usual case. Write a test that fails under the
   mutant: exercise the public API and assert the value that the mutation changes.
   [references/triage.md](references/triage.md) lists what each family's survivors
   usually point to.
2. **Redundant code.** A guard that rejects nothing reachable, a `String.trim` of
   input that is already trimmed, a clause whose inputs the next clause handles
   identically: the mutant survives because the code does not matter. Deleting the
   code is a valid response, but it changes the program, so propose it to the user
   instead of doing it silently.
3. **An equivalent mutant**, which no input can distinguish from the original. For
   example, `x < 0` → `x <= 0` survives when both branches return `0` at `x = 0`.
   Suppress it with the narrowest directive and a reason:
   `# mutare:ignore[relational:<=] both branches return 0 at the boundary`.
4. **Code not worth testing**: logging, telemetry, analytics. Route the call once in
   `.mutare.exs` (`{Mixpanel, :track, 3, :skip}`, or `--skip-call` for one run)
   instead of annotating every line.

Keep the result honest:

- Ignored mutants leave the score's denominator, so every ignore raises the score.
  Never add one to move the number. Each ignore needs a reason a reviewer would
  accept, and when the equivalence argument is not airtight, report the survivor to
  the user instead of suppressing it.
- Narrow every suppression as far as it goes: `[family:label]` before `[family]`
  before a bare `# mutare:ignore`, and one line before a `-start`/`-end` region
  before `-file`. `--list-ignores` audits the existing directives, and
  `--strict-ignores` fails a run on any that no longer suppress anything.
- A test that kills a mutant by asserting implementation details (exact log text, a
  private function's name, a stacktrace frame) is worse than the survivor. Kill
  through behaviour.
- Assert strictly enough to see the change. `refute f(x)` cannot tell `false` from
  `nil`, one of the `return_value` family's replacements; `assert f(x) == false`
  can.
- The survivor list is the product; the score is a trend to watch. When you report
  to the user, lead with what the survivors reveal about the tests, grouped by
  shared cause ("no test sits on any boundary in `Pricing`", "all test strings are
  ASCII"), not with the percentage.

## Beyond configuration

When a project needs mutations the built-in families don't make (a
domain-specific swap), or needs a library's DSL handled properly, write a custom
mutator or an extension. The guide is <https://hexdocs.pm/mutare/extending.html>;
while developing one, run `mix mutare --check --verify-invariants`.
