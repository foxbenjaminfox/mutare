# Troubleshooting a Mutare run

Mutare's error messages usually name their fix; read the whole message before
acting. This page covers the causes that aren't obvious from the message alone.
`mix help mutare` has the matching options.

## "baseline suite is not green", but `mix test` passes

The baseline runs the suite against the metamutant with no mutant active, inside the
sandbox. Differences from a plain `mix test` that can break it:

- **Lifting shows through.** To mutate guards, head patterns, and clause structure,
  Mutare moves a function's clauses into generated functions behind a dispatcher
  that keeps the original name. Callers can't tell, but a test asserting a
  `FunctionClauseError`'s `function`/`arity`, an exact stacktrace frame, or
  `__ENV__.function` can. Prefer asserting the behaviour. Otherwise keep that
  function in place with `skip_lifting: [{Mod, :fun, arity}]` (or
  `--skip-lifting Mod.fun/arity`), which forgoes its guard, head-pattern, and
  clause-drop mutants. `mix help mutare`, "Troubleshooting baseline-only failures",
  has the details.
- **The sandbox lacks something the tests read.** The copy leaves out `.git` and
  anything outside the project root, including path dependencies that point outside
  it. A test that shells out to `git`, or reads a sibling directory, fails there.
- **Scheduler trimming.** Each run gets the schedulers divided by the worker count
  (the baseline too), so a timing-sensitive test can fail. Try `--schedulers all`,
  or better, remove the timing assumption.
- **A heap cap that is too small.** `--max-heap-mb` applies to the baseline as well,
  on purpose; raise it well above the suite's largest process.
- **A flaky test.** `--baseline-runs 2` makes flakiness explicit instead of
  intermittent. Fix the test: flakes also manufacture false kills later.
- **A bad kept sandbox.** A build artifact corrupted by an interrupted run.
  `--no-keep-sandbox` rebuilds from scratch; the message suggests this too.

Dependencies are not fetched inside the sandbox. If the compile reports a dependency
problem, run `MIX_ENV=test mix deps.get` in the project.

## The metamutant fails to compile

A mutant that the compiler rejects is attributed from the error, dropped as
`poisoned`, and the build retried, with a line of progress per round. When the error
can't be attributed (usually a macro that rejects an expression in an argument), the
run stops and prints a copy-pasteable `call_routes:` entry. Before a long run on an
unfamiliar project, run `mix mutare --check`, which finds all of this without running
any tests. For libraries with companion packages (Ecto, Phoenix, LiveView, Oban,
Gettext, Plug, Swoosh, Decimal), install the package rather than writing routes by
hand.

`--fail-on-poisoned` turns remaining poison into a CI failure. Poison from built-in
mutators on plain Elixir is a Mutare bug worth reporting.

## Many harness errors (`RuntimeError` in JSON)

A harness error is a run that reached no verdict. It is excluded from the score, and
`statusReason` carries the diagnostic. When most mutants have one:

- **Workers share state on disk.** All workers run in one sandbox, so a test that
  writes to a fixed path in the project or its `_build` collides with the same test
  in another worker. ExUnit's `@tag :tmp_dir` doesn't help: its path is derived from
  the test's name, and two workers can run the same test at the same time. Confirm
  with `--workers 1`, then give each OS process its own path, for example by
  including `System.pid()`. Every sandboxed run has `MUTARE_ACTIVE_MUTANT` set (to
  `0` for the baseline), which is how a project's config can tell it is under
  Mutare. PropCheck's counter-example file is a known case; Mutare's own `mix.exs`
  gives each process a private one:

  ```elixir
  propcheck: [
    counter_examples:
      if System.get_env("MUTARE_ACTIVE_MUTANT") do
        Path.join(File.cwd!(), "_build/propcheck-#{System.pid()}.ctex")
      end
  ]
  ```

- **Workers share a database.** Use `--partition-db` with one pre-created, migrated
  database per worker ("Database isolation across workers" in `mix help mutare`), or
  run `--workers 1`.
- **Config derives a name from the checkout.** The sandbox is a copy under the
  system temp directory with no `.git`, so a database named from the project's path
  or git branch (one per worktree, say) comes out wrong or fails to resolve. Read
  `MUTARE_PROJECT_ROOT`, the original project's absolute path, when it is set
  (same section of `mix help mutare`).
- **The kept sandbox has gone bad.** `--no-keep-sandbox`.

## Suspicious survivors

- **A survivor you think a test kills.** The default selection runs only the test
  cases that executed the mutant. In a stateful `async: false` module, a sibling test
  that never runs the line can still observe corrupted shared state; selection drops
  that sibling. Recheck with `mix mutare --line FILE:LINE --full`. If the kill
  appears, use `--per-file` for the project, or `test_selection: :coverage` in
  `.mutare.exs`.
- **A verdict that changes between runs.** Randomised tests (property tests
  especially) and load-dependent code such as timeout literals can catch a mutant on
  one run and miss it on the next. `--kill-runs 2` records a kill only if it repeats.

## Slow runs

- **Whole-suite fallbacks.** A mutant whose code runs in a process no test can be
  traced to runs the whole suite. After the coverage probe, a `↺` line says how many
  mutants will. `--verbose` tags each one's line `(whole suite)`, and the JSON marks
  it `testSelection: "suite"`. Application-supervised processes are
  the usual source, and so are browser-driven tests (Wallaby, Playwright): their
  requests run in server processes. In a Phoenix project using the Ecto SQL sandbox,
  listing `Mutare.Phoenix.Ecto` (from `mutare_phoenix_ecto`) under `:extensions`
  attributes each request to the test that sent it. Narrowing the scope with `--only`
  helps; `--per-file` does not.
- **Timeouts.** The per-mutant cap defaults to 3 × the baseline's duration, and each
  timeout is confirmed by an uncontended re-run before it counts as a kill. With many
  timeouts, that confirmation dominates. A tighter `--timeout` (in ms) shortens both,
  if the suite's real runtime allows it.
- **More mutants than the job needs.** Scope first (`--only`, `--since`,
  `--mutators`), and bound the per-mutant phase with `--time-budget`. `--verbose`
  prints per-phase timing and a line per mutant with its duration.

## Umbrella projects

Run from the umbrella root, and choose apps with `--app billing,web`, `--workspace`,
or a positional `apps/billing`. A mutant that would otherwise run the whole suite
runs only the test suites of its own app and the apps that depend on it (`--verbose`
tags it `(app + dependents)`, the JSON `testSelection: "app"`).
