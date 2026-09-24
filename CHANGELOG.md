# Changelog

All notable changes to this project are documented in this file.

The format is based on [Keep a Changelog](https://keepachangelog.com/en/1.1.0/),
and this project adheres to [Semantic Versioning](https://semver.org/spec/v2.0.0.html).

## [Unreleased]

## [0.4.0] - 2026-09-24

### Changed

- **A pipe stage is the call it is sugar for, everywhere Mutare reads code.**
  `left |> stage(args)` is resolved, routed, marked, offered to mutators and delivered as
  `stage(left, args)` — `Kernel.|>/2`'s own desugaring — whether or not the call has a
  route. No mutator is shown a call one argument short, so a custom `mutate/1` that matches
  `Enum.map(enum, fun)` matches the piped spelling too, and no family needs to know about
  pipes. Piped and direct spellings now yield the same mutants: a piped bare `a |> div(b)`
  is transposed like `div(a, b)`, a pipe of identical operands is no longer transposed, a
  piped `bnot` is stripped, the explicit `Kernel.++(a, b)` call form is transposed when
  written directly as well, a route's position 0 governs the piped operand in a guard as it
  does in a body, and a function tail written `… |> case do … end` gets the return-value
  mutants of its clauses, as the same `case` written directly always has, in place of
  `nil`/`:mutare` over the whole pipe. Reports keep the spelling the user wrote: a mutant
  that leaves the piped value alone is located at, and diffed as, the stage; one that
  moves or drops it is diffed over the whole pipe, and still located at the stage's line,
  so a `# mutare:ignore` over the stage and a `--line` naming it keep working in a
  multi-line chain. Two diffs read differently:
  - A removed stage reads `xs |> Enum.sort()` → `xs` (was `Enum.sort()` →
    `Elixir.Function.identity()`).
  - A transposed stage reads `foo |> Kernel.++(bar)` → `bar |> Kernel.++(foo)` (was
    `(&Kernel.++(bar, &1)).()`), and evaluates its operands in that order.

  A stage whose first position is a value — unrouted, or routed `:expression` or
  `:interior` — has its piped value evaluated once, ahead of the stage, as before; one
  routed `:lazy_expression` (below), or as syntax, never does. A pipe in code Mutare leaves
  as written — a `:raw` argument, the inside of a `:skip`ped call — is left exactly as
  written; through 0.3.1 a pinned operand there (`^x |> f()`) was rewritten, and a macro
  reading that syntax saw a different program at the baseline.

  **Breaking for mutator and extension authors.** The call handed to `route_arguments/1`,
  `host/2`, `mutate/2` and `variant/2` is the direct call: its identity, and its complete
  argument list with the piped operand at position 0. A classifier routes that operand by
  shape, `call.rebuild` can rewrite it, and it may be routed `:hosted` (previously a
  `ContractError`). A classifier's arguments are still the written syntax, since Mutare
  interprets only the regions the classifier's routes say are Elixir: a `|>` *inside* an
  argument is still a `|>` there, and an aliased call inside one still carries the alias.
  A classifier that matches argument shapes is unaffected; one that read a piped call one
  argument short must count the piped operand. After routing, a whole-call `mutate/2` or
  `host/2` sees the Elixir regions resolved and the `:raw`/`:hosted` regions as written;
  an island a host hands back through `Mutare.Analyze.expression_mutations/3` is resolved
  in the enclosing lexical environment the host's context carries. The operands of the
  node a mutator is offered are resolved code too: `Mutare.Calls.resolved_call/1` answers
  `Enum.count/1` for `xs |> Enum.count()` found as an operand, where it answered `nil` for
  the pipe. Removed, with no deprecation period:
  - The `mutate/2` context's `:pipe_mode`, and `Mutare.Mutator`'s `pipe_mode` type,
    `effective_arity/2` and `visible_index/2`. A clause matching `%{pipe_mode: mode}` no
    longer matches anything; read `length(args)` and index the arguments directly.
  - `Mutare.Test.node_mutations/2` replaces the three-argument form, which took a pipe
    mode. Test a pipe stage by writing the direct call.
  - `Mutare.CallRouting.Call`'s `pipe_left`, `pipe_mode` and `effective_arity`; its
    five-argument `new` becomes `new/4` (`node, module, name, rebuild`).
  - `Mutare.CallRouting.ArgumentRoutes`' `from_effective` and `from_visible`, replaced by
    `new/2` (one treatment per argument), and its `visible`/`piped` readers, replaced by
    `treatments/1`.
  - `c:Mutare.CallRouting.route_arguments/1` replaces `route_arguments/2`: its context
    argument carried only `:pipe_mode`.

- **The call-level `:skip` covers a value piped into the call.** A piped value is the
  call's first argument, so `a |> f(b)` under `:skip` is now the inert leaf `f(a, b)`
  always was; through 0.3.1 the piped value kept its mutants, in that spelling alone. A
  skipped stage in the middle of a chain therefore takes everything upstream of it along.
  To leave a call alone and still mutate what flows into it, route it by position, which
  reads both spellings alike: `{Mixpanel, :track, 3, [:expression, :raw, :raw]}`.

- **The concurrent mutant runs share the machine instead of each taking all of it.**
  Every worker is a whole `mix test` BEAM, and a BEAM starts a scheduler thread per core,
  so `--workers 4` used to ask a 16-core machine for 64 busy threads — slower runs, and
  slow-but-finite mutants pushed past their timeout. Each worker is now trimmed with `+S`
  to the new **`:schedulers`** option (`--schedulers N`), and the two divide the machine:
  give `--workers` and each gets your schedulers divided by it; give `--schedulers` and
  workers are your schedulers divided by it, capped at 4 as the default is (pass both to
  run more BEAMs); give neither and you get the old worker default (half your schedulers,
  capped at 4) with the schedulers split among them — 4 × 4 on 16 cores, 4 × 2 on 8.
  `schedulers: :all` (`--schedulers all`) restores untrimmed workers. What to expect: a
  trimmed run sees fewer `System.schedulers_online/0`, so ExUnit's default `max_cases`
  shrinks with it; the baseline and the coverage probe run under the same trim (the
  baseline validates the suite at that concurrency, and an async-heavy suite's baseline is
  slower for it; the probe records what a mutant run will execute, which a branch on the
  scheduler count can change), while the one compile keeps every core. If you were
  passing `ELIXIR_ERL_OPTIONS="+S …"` to get this effect, drop it — it also throttled
  Mutare's own scan and compile.
- **The derived per-mutant timeout is `baseline × :timeout_multiplier`**, no longer
  scaled by half the worker count: the baseline is now timed under the mutants' scheduler
  trim, so it already measures what a mutant run takes. The scaling remains only for a
  configuration that oversubscribes the CPU (`schedulers: :all`, or explicit counts whose
  product exceeds the machine).

- **Every function with two or more mutation sites keeps its uninstrumented source
  beside the instrumented code, whatever it calls.** A mutant elsewhere runs that copy at
  the original speed. 0.2.1 introduced the copies but admitted only code a classifier
  could vouch for, refusing a function that used a local or `use`-injected macro, a
  `defguard`, `super`, `quote`, a nested module, `__ENV__`/`__STACKTRACE__`, or a name it
  could not prove bound; those functions now get copies too, and a copy's recursion —
  effectful bodies included — stays inside the copy. A copy that fails to compile is
  attributed to its function by poison recovery and dropped in a rebuild, costing no
  mutant and no id; the live display reports it as `kept N functions fully instrumented`.
  A macro that counts or registers its own expansions, or code that reflects on its own
  function name, meets copies it was previously shielded from — the metamutant is
  invisible to callers, not to reflection, and the remedy is `skip_lifting` or
  `# mutare:ignore`, as before.

### Added

- **`:lazy_expression`, a position treatment for a callee that may not evaluate an
  argument eagerly.** Mutare treats every call as ordinary in every respect its route does
  not address, including when its arguments run: to deliver a whole-call mutant on a pipe
  stage it evaluates the piped value once, ahead of the stage. A macro that evaluates
  that operand late, conditionally, or never (`value |> lazy(enabled?)`) routes the
  position `:lazy_expression`. The argument is mutated exactly like an `:expression`, and
  is handed to the callee unevaluated in every branch. Accepted in `call_routes:` and
  from `call_routes/0` alike.

- **Whole-suite runs are announced, in every mode but `--quiet`.** A mutant whose line
  the probe saw only from a process no test owns (a spawned process, a `setup`'s
  `on_exit`) runs the whole suite, and so does every covered mutant when the probe itself
  fails or overruns its cap. Both used to be silent — the first even under `--verbose` —
  and a run that stalls on one such mutant read as a hang. The live display now leaves a
  line after the probe (`↺ 14 of 140 covered mutants run the whole suite …`, or
  `⚠ coverage probe exited 1 …` naming the cause), marks each such mutant on its
  in-flight line (`· whole suite`) and, under `--verbose`, on its own line
  (`(whole suite)`); the verbose breakdown counts the shapes apart (`120 narrowed to
  tests · 6 per-file · 14 whole-suite`). `Mutare.Result` records what ran as `selection`
  (`:suite`/`:app`/`:files`/`:tests`), and the JSON report carries it as
  `testSelection`. For hook authors: `{:coverage_done, summary}` now carries
  `tests`/`files`/`suite` counts (not `covered`), the run-all `degrade` reason, `mode`,
  `app_scoped?` and `broad_ids`; `Mutare.Runner.CoverageProbe.run/4` returns
  `{:run_all, degrade}` in place of `:run_all`.

- **A test module using `Mutare.Test`'s live-mutant helpers may be `async: true`.** The
  helpers select on a `:persistent_term` key private to one execution of the ExUnit test
  module — two `:parameterize` instances are apart too — taken before a metamutant is
  transformed or a mutant selected (`Mutare.Test.isolate_selector/0`), so two modules
  selecting at once no longer run each other's mutant as a baseline. A test that
  transforms through `Mutare.Transform` itself calls `isolate_selector/0` first. While
  ExUnit is running, a process no test runs above must be given the key
  (`isolate_selector/1`), or the helper raises rather than share the VM-wide key; outside
  ExUnit the VM-wide key stays in force, as before.

### Fixed

- **A binding made inside a mutated expression reaches the code after it.** An in-place
  selector is a `case`, whose branches trap what they bind, and through 0.3.1 the
  bindings a mutated call's arguments made stayed trapped: `result = div(y = 10, 2);
  {result, y}` under the arithmetic family failed the metamutant compile at the read of
  `y`, on a line no mutant owns, so poison recovery could not attribute it and the run
  aborted (`{:error, :compile_failed, …}`). A `|>` closure trapped the same way
  (`10 |> div(y = 2)`). Such bindings are now returned through a tuple and rebound
  outside the selector, whether they are made by an argument, a callee, a live
  `unquote`, a `quote`'s options, a keyword value under a keyed route, or an interpolated
  keyword key. What a selector exports is decided from the scope, not from the branches:
  a name bound on entry is exported by every branch — one that does not rebind it names
  the incoming value, as the source does — so a mutant dropping a rebinding
  (`p = :before; Enum.count(xs, p = f)` → `Enum.count(xs)`) leaves `p` as the source
  leaves it; a name bound fresh is exported when every live branch binds it, a mutant
  that drops a fresh binding something reads later — a source patch that could not
  compile — is withheld, and one that drops a fresh binding nothing reads is delivered
  with the binding unexported. A name an earlier sibling of the same expression writes —
  the callee or another argument of a call, another element of a tuple or list, the
  other operand — is not exported as incoming either: Elixir lets sibling writes out only
  after the whole expression, the last one winning. The readers respect a routed
  position's declaration: a `:binding_pattern` binds what it names, a `:lazy_expression`
  vouches for nothing, and a configured `:skip` withholds mutation without changing what
  the arguments of the skipped call mean.
- **A withheld candidate no longer shapes the program.** Delivery was planned from every
  candidate before ignore directives, poison `skip_ids` and `emit_ids` withheld some, so
  an ignored or poisoned binding-dropping mutant still trapped a live mutant's binding.
  Delivery is now planned from the candidates that get a branch.
- **Two pipe stages the shared closure would have misordered get their own delivery.**
  The closure a written pipe's stages share is created before its piped operand runs and
  evaluates that operand ahead of the stage. A stage reading, or rebinding, a name the
  operand rebinds (`m = 10; (m = 1) |> div(m)`) saw the value captured at creation, and
  the metamutant failed to compile; a replacement that keeps the operand but calls
  through a receiver expression of its own (`receiver().count(xs)` for `xs |> Enum.count()`,
  from a custom mutator) ran that receiver after the operand, where the source runs it
  before. Both are delivered branch-locally now.
- **A name displaced out of `Kernel` is treated as what it resolves to.** In a module
  that writes `import Kernel, except: […]` beside its own definition — or whose `use`
  does — Mutare still read the name as `Kernel`'s:
  - A displaced `|>` was the pipe. A mutated stage was lifted into a closure that applied
    the custom operator twice, which could change the *unmutated* program (an
    `{:ok, value}`-binding pipe skipped the stage), and the stage was resolved and offered
    to mutators at the piped arity. A displaced `|>` is now an ordinary call to that
    operator: both operands are values, and a `call_routes:` entry on the operator —
    the name-only `{:*, :|>, 2, …}` included, which was ignored on it — takes any
    positional treatments. A pipe-shaped *macro*, which reads its right side as syntax,
    wants `{MyPipe, :|>, 2, [:expression, :interior]}` — the stage's own node withheld,
    its arguments mutated.
  - A displaced `if`/`unless` got the conditional family's mutants inside its arguments,
    and a local `if(value, opts)` gained spurious `true`/`false` mutants; with a
    `:pattern` route, or a `:raw` `do:` body, the metamutant failed to compile.
  - A displaced `defmodule`/`def`/`defp`, operator, `and`/`or`/`in`, `abs`/`div`/`min`
    or sigil got `Kernel`'s instrumentation, lifting, rename or literal mutants: the
    metamutant failed to compile, or a custom `+` was mutated to `-`. A displaced
    `defimpl` got no mutants at all, and `argument_marks:` on a displaced `defmodule`
    were ignored; both hold now.
- **A `super` written as a bare pipe stage compiles.** `n |> super` in an overriding
  function whose clause is lifted failed the metamutant compile (`super must be called
  with the same number of arguments`).
- **A call taking options led by `do:` renders again.** The metamutant is rendered by the
  stdlib formatter, which spells any call whose final keyword list starts with `do:` as a
  do-block; with an ordinary key beside it (`value(do: n, other: 0)`, a function taking
  options) that key was stranded inside the block, and the metamutant did not compile.
  Such a list is now rendered bracketed; a list of block keys alone is the do-block it
  always was.
- **A call nested under the same function keeps its mutants.** Removing the outer call of
  `String.upcase(String.upcase(s))` leaves the program that replacing the inner call with
  `s` would, and overlap resolution took that for a rewrite that made the inner call's
  mutants redundant: its own removal, and its `upcase` → `downcase` rename, which
  duplicates nothing. Only a literal or a module alias is now treated as covered by a
  call rewrite. The piped spelling was never affected.
- **A mutant covered from a deep `setup_all` is narrowed to that module's file.** The
  coverage probe attributes a hit to its test by the `__ex_unit__/2` frame on the stack,
  and the VM reports only the innermost 20 frames; a `setup_all` running deep code (a
  recursive walker over fixtures) had the frame cut off, so every id it covered ran the
  whole suite, silently. Dogfooding found one file whose run took hours for it. When the
  reported frames name no owner and fill the cap, the probe now reads the process's full
  backtrace instead.
- **A survivor's diff and JSON/SARIF range cover exactly the node's text.** A site's
  range was read from Sourceror, which extends some parenthesized nodes over their
  parentheses and not others, so `(a + b) * c` with `a + b` → `a - b` was reported as
  `a - b * c`, a different program from the mutant that ran, and a mutant inside
  `&(&1 > 2)` as the unparseable `&&1 >= 2`; a node ending in a parenthesized operand
  (`0 == (if … end)`) was ranged to inside the `)`, one beginning with a parenthesized
  callee (`(fn x -> … end).(1) |> f()`, `(a).b`) from inside the `(`, so a
  whole-expression replacement read `(nil`; and a `<<…>>` ending a clause body was ranged
  one column too far, over the line break. Each range now stops at the node's own text.
- **A survivor's replacement is parenthesized where its position needs it.** A site
  renders its replacement alone, and patched into the source that text could be a
  different program from the mutant that ran: `!(a == 0) |> f()` with the negation
  removed was reported as `a == 0 |> f()` (that is, `a == (0 |> f())`), the `0.75` of
  `-0.75` → `-0.25` as the unparseable `--0.25`, `identity(!(t = b; b))` with the
  negation removed as the unparseable two-line `identity(t = b\n  b)`, and
  `case 0 + (if … end) do` with `+` → `-` as `case 0 - if … end do`. `mutated_code` now
  carries parentheses in exactly those places — `(a == 0)`, `(-0.25)`, `(t = b; b)` —
  and nowhere else: a statement, a call argument and `x == -1` read as before.

## [0.3.1] - 2026-09-19

### Fixed

- Whole-call mutants on a pipe stage preserve a syntax-valued left operand. Routed
  declarations, patterns, keyword fragments and interpolations reach the macro directly,
  instead of being evaluated through a closure. This lets adapters mutate stages such as
  `(p in Post) |> from(order_by: …)` without poisoning the single build. Mutations inside
  the left operand remain reachable without duplicating their selectors.
- A generated interpolation on a pipe's left keeps its precedence when rendered, including
  when only the left operand carries mutations.

## [0.3.0] - 2026-09-19

### Added

- **`--verify-invariants` (`verify_invariants:`) checks each transformed file
  before the run relies on it.** Mutare reads the metamutant back and emits the
  file a second time. It aborts with `Mutare.InvariantError` when a
  recorded mutant has no branch that runs while it alone is active, when a
  mutant has no coverage record, when generated code names an id that no mutant
  records, when a mutant renders identically to its original code, or when the
  second pass differs. These problems would otherwise distort the report
  silently. They come from custom mutators, hosts, and extensions (for example,
  a host splice that overwrites selectors core has already placed). The checks
  add roughly a sixth to scan time and are off by default.
- `Mutare.Manifest` lists every generated mention of a mutant id (`:mentions`).
- **A routed call written as a pipe stage is shown the pipe's left side.**
  `Mutare.CallRouting.Call` gains `pipe_left` — `:unpiped`, or `{:piped, left}`
  with the left side as written. The piped position is the call's effective
  first argument, and adapters used to route it without seeing it; a
  `route_arguments/2` classifier can now route it by shape (`Post |> from(…)`
  held back from the `alias` family, `build(x) |> from(…)` left mutable), and a
  host or mutator can read a declaration written there. It is the same value
  in `route_arguments/2`, in `host/2`, and from
  `Mutare.Calls.resolved_routed_call/1`. It is read-only, so the piped position
  still cannot be routed `:hosted`.
- `Mutare.CallRouting.Call`'s `new/5` builds a call value from its independent
  facts and derives `arguments`, `pipe_mode`, and `effective_arity`.

### Changed

- **Breaking: a hand-built `%Mutare.CallRouting.Call{}` must name `pipe_left`.** The key
  is enforced, so a test that builds the struct literally stops compiling; build
  it with `Call.new/5` instead. Matching on the struct is unaffected.
- **`Mutare.Test`'s source helpers run the invariant checks by default.**
  `diffs/3`, `diffs_for/4`, `metamutant_source/3`,
  `assert_metamutant_compiles/3`, and `compile_metamutant/3` raise
  `Mutare.InvariantError` for a mutator that breaks the metamutant; pass
  `verify_invariants: false` to opt out.
- **Hosts that target the same fragment share one selector.** Inside a function
  body, a later `Mutare.Mutator.MacroHost`'s mutants join the earlier host's
  selector instead of nesting a second selector around it, and one coverage
  record names every id. Each mutant keeps its own host's `wrap`, the first
  host's wrapped original stays the fallback, and every host's `splice` still
  runs in order — a later one now receives the combined selector. Where no
  active-id binding is in scope (a default argument, a function of a module
  defined at runtime) the selectors nest as before.
- **A lifted function's guard mutants share one clause.** Where a clause's
  mutants change only its guard, they become `when` alternatives of a single
  generated clause instead of each copying the clause body. On fixtures of
  large-bodied clauses with several guard mutants this cut the generated source
  by up to 4× and the compile's CPU time by up to half. Mutants and their results
  are unchanged.

### Fixed

- **A `with`/`for`/`try` clause with alternative guards no longer crashes the
  metamutant compile.** Mutating a guard such as `x when x > 10 when x < 0`
  produced a nested `when` that the compiler's type checker rejected with no
  file or line, so poison recovery could not drop the mutant and the whole run
  aborted.

## [0.2.1] - 2026-09-17

### Fixed

- **Mutant locations are correct again under Sourceror 1.12.3.** Sourceror used to
  size a bare `true`/`false`/`nil` one column too wide, and Mutare subtracted that
  phantom column to compensate. Sourceror 1.12.3 fixed the over-count upstream, so
  the subtraction began cutting a real character instead: a survivor whose range
  ends at one of those three rendered its diff a character short (`trim: tru`,
  closing paren left behind), and the JSON/SARIF reporters emitted the short
  `endColumn`. The compensation is gone, and `sourceror` is now floored at
  `~> 1.12.3` so there is one upstream behaviour rather than two. Mutation
  behaviour was never affected — a metamutant is built from the AST, never the
  range — and reports on Sourceror 1.12.2 and earlier were correct as they stood.

### Changed

- **Mutant runs execute far more of the target at its original speed.** A function
  holding two or more mutation sites now keeps its own source beside the instrumented
  code, and a mutant elsewhere runs that source. This previously reached only lifted
  functions of eight or more variants written in a narrow subset of Elixir; it now covers
  functions that stay in place and ordinary code — local bindings, sibling calls, closures,
  comprehensions, bitstrings and interpolation, structs, `raise`, `Logger` — about 89–97%
  of generated mutants in the projects measured, up from under 10%. Benchmark kernels that
  previously missed it run at 0.11–0.76× their former time while another mutant is active.
  The one metamutant compile costs about 8% more CPU and 17% more BEAM size.
- **Cheaper entry into every instrumented function.** The active file is stored and
  compared as an atom instead of a path string, and the id projection tells the compiler
  it holds an integer. `Mutare.Selector.put/1` and `active/0` are unchanged; manual
  selection in a generated sandbox still uses `MUTARE_MUTANT_NAMESPACE` and
  `MUTARE_ACTIVE_MUTANT`.

## [0.2.0] - 2026-09-14

### Changed

- **Breaking: score API moved from `Mutare.Report` to `Mutare.Score`:** `score/1`,
  `percent/1`, `passes_gate?/2`, `gate_failures/2`, `harness_error_rate/1`, and
  `harness_errors_exceed?/2`.
- **Breaking: `Mutare.Sandbox.prepare/3` now returns `{sandbox, materialized}`.**
  Seed-reuse outcomes and declined inference overrides are returned as data;
  the runner delivers their progress events.
- **Breaking: live-report text helpers moved to `Mutare.Report.Live.Lines`.**
  Callers of the rendering and time-formatting functions previously on
  `Mutare.Report.Live` should use the new module.
- **Breaking for manual sandbox selection: runtime mutant IDs are now local
  to each file.** Manual selection in a generated sandbox needs both
  `MUTARE_MUTANT_NAMESPACE` (the root-relative file) and `MUTARE_ACTIVE_MUTANT`
  (its local ID). Changing another file's candidate count no longer changes an
  otherwise unchanged metamutant, allowing retained builds to survive unrelated
  changes. Reports still use globally unique IDs; standalone transforms retain
  integer-only selection.

- **Focused runs and ignore directives produce smaller builds.** `--line`,
  `--since`, and `--max-mutants` now limit generated branches as well as execution,
  and ignore directives suppress branches before compilation. IDs, ignore
  diagnostics, and mutant-cap accounting are preserved. Files with no emitted
  mutants keep their original bytes, allowing their compiled modules to be reused.
- **Smaller metamutants and less processing overhead.** Clause mutations share
  code in eligible `case`, anonymous-function, `receive`, and `try/rescue`
  constructs, and exclusion guards compress consecutive IDs. Scanning and poison
  recovery avoid redundant parsing; coverage recording caches hits per file and
  writes a more compact dump.
- **Custom string-pattern mutations follow the built-in redundancy rule.** When
  one mutator offers both empty and non-empty string replacements for an exact
  pattern, Mutare drops the empty replacement.

### Added

- **Guard mutations in more clause positions:** `with` and `for` generators,
  `with` and `try` `else` clauses, `try` `catch` clauses, and `for … reduce:`
  bodies. These are supported inside functions where the runtime selector is
  bound; module-level and default-argument positions remain excluded.

### Fixed

- **Mutations activate before project evaluation, runtime configuration, and
  application startup.** Timeouts and owner-death watchers also start before
  target project code, containing mutations that hang during startup. Closures
  and workers created before test helpers load retain the correct selection and
  can record coverage when they run after recording begins; execution confined
  to startup is still not recorded as coverage.
- **Mutations that prevent startup count as kills.** Failures during project
  evaluation, runtime configuration, or `Application.start/2` use the startup
  retry budget before being scored as killed. Errors, exits, and throws retain
  the evidence needed for this classification even when deep stacktraces lose
  the project or configuration frames. Infrastructure failures remain harness
  errors.
- **An empty coverage result no longer manufactures survivors.** A successful
  probe that records no hits marks the selected mutants `:no_coverage`, including
  runs focused entirely on untested code. Missing or malformed capture data
  still falls back to running the suite.
- **Signature inference stays disabled in sandbox Mix projects on Elixir 1.20.**
  The override now reaches effective compiler options, including umbrella
  children and custom configuration paths, and overrides an explicit
  `infer_signatures: true` to prevent pathological metamutant compile times.
  Other compiler options are preserved. If a project cannot be safely rewritten,
  `--verbose` reports the file and reason, and its seeded compiler cache is left
  consistent with the options it actually uses.
- **Generated operators respect Mutare's semantics under restricted or replaced
  `Kernel` imports.** Selectors, guards, and coverage code no longer resolve
  operators through the target's imports. Coverage short-circuits also work on
  Elixir 1.21 development builds, where `:erlang.andalso` is guard-only.
- **Protocol implementations receive lifted mutations.** Functions in
  module-level `defimpl` blocks now receive guard, head-pattern, and clause
  mutations, with `:skip_lifting` resolving to the implementation module.
- **Immediately invoked anonymous functions are mutated.** Mutare now analyzes
  the callee in `callee.(args)`, including the guards, patterns, and bodies of
  `(fn … end).(args)`.
- **Binding conditions preserve custom and return-value mutations.** Custom
  `condition_replacements` callbacks now receive `if`/`unless` conditions whose
  bindings must escape into the body, even with `IfCondition` disabled. Rewriting
  those conditions also preserves per-branch return mutations and the exclusion
  of unit-returning tails.
- **Bitstring generators no longer produce invalid value mutations.** The
  generator wrapper in `for <<… <- binary>>` is treated as syntax, avoiding
  spurious compile-poison recovery.
- **Macro poison recovery associates each expansion with its own file.** Nested
  expansion stacks no longer cross-match macro names and unrelated call sites;
  findings without a corresponding mutant are discarded instead of crashing
  recovery.
- **Configuration rejects inconsistent extension and routing declarations.**
  Mutator modules cannot be registered as non-mutating extensions merely by
  omitting `@behaviour`; declarative routes reject the internal `{:hosted, hosts}`
  form; and `:partition_env` cannot overwrite `ERL_COMPILER_OPTIONS` or other
  environment variables managed by Mutare.
- **The sandbox ownership-marker writer no longer follows symlinks.**
- **Self-hosted fixture coverage no longer overwrites the outer probe's state or
  dump.**

### Security

- Updated locked Igniter and Mint dependencies to 0.8.4 and 1.10.0 respectively
  to address advisories reported by `mix hex.audit`.

## [0.1.2] - 2026-09-07

### Fixed

- **The kept sandbox preserves empty directories.** The incremental
  materialisation that the default kept sandbox uses mirrored files and
  symlinks only, so a directory with nothing in it never reached the sandbox —
  and a shallow git checkout under `deps/` keeps `.git/refs/heads` and
  `.git/refs/tags` empty. git then no longer recognised the checkout and Mix
  reported every git dependency as a lock mismatch before the metamutant could
  compile; a freshly generated Phoenix 1.8 app (`heroicons`, `daisyui`) could
  not run Mutare at all.
- **Rendering no longer consults the target project's `.formatter.exs`.**
  Sourceror reads `locals_without_parens` from it through `Mix.Tasks.Format` on
  every render — evaluating its `import_deps` and plugins inside Mutare's own
  process — and Mix could refuse the lookup mid-scan ("Unknown dependency
  `:ecto_sql` given to `:import_deps`"). Every render now pins the option
  (`Mutare.AST.render_opts/1`); a parsed call keeps the spelling its metadata
  records, and a node built without metadata renders with parentheses.
- **`mix igniter.install mutare` fetches the companion packages it adds.** The
  companions are chosen from the project's own deps at run time, and Igniter
  writes a dep added that way to `mix.exs` without fetching it — so the
  generated `.mutare.exs` named modules of packages that were never fetched or
  locked. The installer now applies the `mix.exs` change and runs `deps.get`
  before writing `.mutare.exs`.

## [0.1.1] - 2026-09-07

### Fixed

- **Unit-return classification exempts behaviour callbacks.** A function that is a
  callback of one of its module's declared behaviours (direct `@behaviour` or
  `use`-injected, read through the behaviour's `behaviour_info/1` when it is
  loadable), or whose first clause carries an `@impl` other than `@impl false`, is
  never classified unit-returning, however its body reads. Its caller is the
  behaviour's runtime, which the source never shows and which may treat a lone
  `:ok` as one contract outcome among several — `Oban.Worker.perform/1`'s `:ok`
  is one of six. 0.1.0 silenced the `:ok` return mutants of every such callback,
  including `mutare_oban`'s worker-return family.

## [0.1.0] - 2026-09-07

Initial release.

### Added

- **Compile-once metamutant.** Source under `lib/` is rewritten into a single
  program that embeds every mutant behind a `:persistent_term` runtime switch,
  compiled once; the suite then runs once per mutant by flipping
  `MUTARE_ACTIVE_MUTANT` — no per-mutant recompilation.
- **A broad built-in mutator set** (all on by default): arithmetic/operator and
  operand swaps, relational and logical swaps, strict-equality relaxation,
  literals of every kind (integer/float/string/charlist/atom/sigil/regex/
  bitstring/date-time), collection/string/map/keyword call rewrites, pattern and
  clause restructurings, guard/default/call drops, and more. See `Mutare.Mutators`.
- **Unit-return classification** — a function (or anonymous function) whose every
  return path is literally `:ok` or `nil` returns no data, so its tails draw no
  return-value constant and no `:ok → :error` swap. Syntactic, and one-sided: it
  can miss a unit function, never silence a data-returning one.
- **Coverage-guided test selection** — coverage is self-recorded by the metamutant
  at runtime and keyed by mutant id; each mutant runs only the test cases that
  cover it (`--per-file` widens that to the covering test *files*, for stateful
  `async: false` suites; `--full` runs the whole suite every time). Uncovered
  mutants are skipped and excluded from the score.
- **Parallel workers with per-mutant timeouts** — mutants run `:workers` at a
  time, each capped by a wall-clock deadline; a mutation that hangs halts itself
  and counts as a kill (no process-tree killing).
- **Compile-poison recovery** — a mutant that won't compile is identified from the
  compile error, dropped (reported as *poisoned*, excluded from the score), and
  the build retried, for a bounded number of rounds; only a compile error that
  can't be attributed to any mutant (or that outlasts the bound) aborts the run,
  with a copy-pasteable `:skip` snippet.
- **`# mutare:ignore` directive** — suppress a known-equivalent mutant per line,
  per span (`-start`/`-end`), or per file (`-file`), with an optional free-text
  reason and an optional `[family]` / `[family:label]` filter; ineffective
  directives are surfaced (`--strict-ignores` escalates).
- **Reporters** — human (default, survivor diffs + score), plus machine-readable
  `json` (Stryker / mutation-testing-elements schema), `html` (interactive
  viewer), and `sarif` (GitHub code scanning) via `--report FORMAT[:PATH]`
  (repeatable) or `:reporters`.
- **Live progress** on stderr; the detailed report and score are printed to stdout.
- **CI integration** — `--since <ref>` to scope to the lines changed against a
  git ref, `--min-score` to gate, `--line` to target lines, and a kept sandbox
  (the default) so the
  compiled build carries across runs; `--sandbox <path>` pins it at a CI cache,
  `--no-keep-sandbox` opts back into a throwaway copy.
- **Umbrella-aware** — target one app, several, or the whole workspace.
- **Extension surface** — `Mutare.Mutator` (custom mutators), independent
  `Mutare.CallRouting` and `Mutare.UseExpansion` capabilities, `:extensions` for
  non-mutating integrations, declarative `:call_routes` configuration
  (user-tier treatments only; the adapter-grade treatments must come from a
  module implementing `Mutare.CallRouting`), the `Mutare.AST` node
  constructors that discharge Sourceror's emission invariants for plugins, and
  the `Mutare.Calls` call-resolution readers (`resolved_call_to/3`,
  `module_key/1`) so plugins match calls without building core's key
  representation, and a declarative environment guard (`required_modules/0`,
  on mutators and extensions): the modules a DSL plugin routes are checked
  loadable once at startup, aborting with `Mutare.EnvironmentError` instead of
  silently registering routes against nothing on an external-source run.
- **`mix igniter.install mutare`** installer that detects frameworks and wires up
  the matching companion packages and `.mutare.exs`.
- **Call routes** (`call_routes:` / `--skip-call Module.fun/arity`) — leave a
  call alone: `:skip` makes a whole call an inert leaf (functions, macros, and
  the construct special forms alike — `Kernel.if/2` or `case` included; a piped receiver and
  the enclosing function's return-value mutants are unaffected), `:raw` leaves
  an argument as written, `:interior` mutates an argument's contents but never
  its own node, and a keyed refinement (`[:expression, timeout: :raw]`) reaches
  one option of a literal keyword argument. The forms Mutare analyzes
  structurally (`if`, `case`, the boolean operators, …) take `:skip` only, and
  definitions (`def`, `defmodule`, …) and literal syntax (`{}`, `%{}`, `=`, …)
  take no route. Routes match qualified,
  aliased, imported, and piped forms, and an entry that matches no call in a
  full scan is warned about.
- **Argument marks** (`argument_marks:`) — extend the built-in timeout table (or
  any label a mutator declares) to your own functions, with the mutators'
  value-aware reaction: `{MyApp.Http, :get, 2, [{:keyword, :recv_timeout}], :timeout}`.

[Unreleased]: https://github.com/foxbenjaminfox/mutare/compare/v0.4.0...HEAD
[0.4.0]: https://github.com/foxbenjaminfox/mutare/compare/v0.3.1...v0.4.0
[0.3.1]: https://github.com/foxbenjaminfox/mutare/compare/v0.3.0...v0.3.1
[0.3.0]: https://github.com/foxbenjaminfox/mutare/compare/v0.2.1...v0.3.0
[0.2.1]: https://github.com/foxbenjaminfox/mutare/compare/v0.2.0...v0.2.1
[0.2.0]: https://github.com/foxbenjaminfox/mutare/compare/v0.1.2...v0.2.0
[0.1.2]: https://github.com/foxbenjaminfox/mutare/compare/v0.1.1...v0.1.2
[0.1.1]: https://github.com/foxbenjaminfox/mutare/compare/v0.1.0...v0.1.1
[0.1.0]: https://github.com/foxbenjaminfox/mutare/releases/tag/v0.1.0
