# Mutare

Mutare is a mutation testing system for Elixir, that mutates the source you actually write, and compiles once.

Mutation testing measures whether your test suite actually constrains the behavior of your code: it deliberately breaks your source code one small change at a time, and each time your tests nevertheless still pass it has located a gap in your test suite.

Other Elixir mutation testing libraries, such as [Muex](https://github.com/Oeditus/muex), compile your code once per mutant, which can be quite slow, even with incremental recompilation. Mutation testing is never fast, but mutare aims to be the fastest Elixir mutation library with its compile-once approach. Mutare compiles a metamutant, a version of your program embedding all possible mutants behind runtime switches, and then selects the active mutant per test run via an environment variable.

## Installation

The easiest way to install mutare is the [igniter](https://hexdocs.pm/igniter) installer, which adds mutare to your `:dev`/`:test` deps and auto-configures framework integrations:

```
mix igniter.install mutare
```

It inspects your dependencies and, for each framework it finds, adds the matching companion package and wires it into a generated `.mutare.exs`:

| Detected dependency                               | Package added              | Wired into                                                             |
| ------------------------------------------------- | -------------------------- | ---------------------------------------------------------------------- |
| `:plug` / `:bandit` / `:plug_cowboy` / `:phoenix` | `mutare_plug`              | `:mutators` — `Mutare.Plug.all/0`                                      |
| `:phoenix`                                        | `mutare_phoenix`           | `:mutators` — `Mutare.Phoenix.all/0`; `:extensions` — `Mutare.Phoenix` |
| `:phoenix_live_view`                              | `mutare_phoenix_live_view` | `:mutators` — `Mutare.Phoenix.LiveView.all/0`                          |
| `:ecto_sql` / `:phoenix_ecto` / `:ecto`           | `mutare_ecto`              | `:mutators` — `{Mutare.Ecto, repo: YourRepo}`                          |
| `:oban` / `:oban_pro`                             | `mutare_oban`              | `:mutators` — `Mutare.Oban.all/0`                                      |
| `:decimal`                                        | `mutare_decimal`           | `:mutators` — `Mutare.Decimal.all/0`                                   |
| `:swoosh` / `:phoenix_swoosh`                     | `mutare_swoosh`            | `:mutators` — `Mutare.Swoosh.all/0`                                    |
| `:phoenix_swoosh`                                 | `mutare_phoenix_swoosh`    | `:mutators` — `Mutare.Phoenix.Swoosh.all/0`                            |
| `:gettext`                                        | `mutare_gettext`           | `:extensions` — `Mutare.Gettext`                                       |


A mutator package extends the `:mutators` list; a non-mutating extension like `mutare_gettext` (which teaches mutare a library's compile-time vocabulary so the built-in mutators can deal with it) joins the `:extensions` list; `mutare_phoenix` does both, since its front module also routes Phoenix's compile-time macros. The Ecto repo is detected automatically (pass `--repo MyApp.Repo` to override). If you already have a `.mutare.exs`, it is left untouched and the recommended keys are printed for you to merge in.

You can install igniter globally, with `mix archive.install hex igniter_new`, or add it to your project's `mix.exs`:

```elixir
{:igniter, "~> 0.8", only: [:dev]},
```


Or add mutare by hand — though if you're using any macro-heavy libraries, like `ecto` or `gettext`, you'll need to add the relevant mutator or extension too.

```elixir
# mix.exs
{:mutare, "~> 0.1", only: [:dev, :test], runtime: false}
# Optionally, also:
# {:mutare_ecto, "~> 0.1", only: [:dev, :test], runtime: false}
# {:mutare_decimal, "~> 0.1", only: [:dev, :test], runtime: false}
# {:mutare_gettext, "~> 0.1", only: [:dev, :test], runtime: false}
# {:mutare_plug, "~> 0.1", only: [:dev, :test], runtime: false}
# {:mutare_phoenix, "~> 0.1", only: [:dev, :test], runtime: false}
# {:mutare_phoenix_live_view, "~> 0.1", only: [:dev, :test], runtime: false}
# {:mutare_swoosh, "~> 0.1", only: [:dev, :test], runtime: false}
# {:mutare_phoenix_swoosh, "~> 0.1", only: [:dev, :test], runtime: false}
```

Then run `mix mutare`.

## How it works

1. Transform. Every in-scope source file is rewritten into a *metamutant* that embeds all of its mutants. Mutare transforms the code you write, before macro expansion—so any macros that don't accept arbitrary expressions will probably need their arguments routed `:raw` in your config (see "Routing calls" below).
2. Compile once. The metamutant compiles a single time. The source code doesn't change between runs, so there is no per-mutant recompilation.
3. Run the suite per mutant. A baseline test run must pass; a coverage probe then maps each mutant to the test files that exercise it. Each mutant runs in a fresh `mix test` OS process, `:workers` at a time, each capped by a wall-clock timeout. The process learns which mutant to activate from `MUTARE_MUTANT_NAMESPACE` (its file) and `MUTARE_ACTIVE_MUTANT` (its id within that file).
4. Report. Surviving mutants are listed in an abbreviated format as the run progresses, and you get a full report, with diffs and a mutation score, at the end. You can also enable JSON, HTML, or SARIF format output.

One observable difference is worth knowing: a suite that is green under plain `mix test` can fail during Mutare's baseline run when a test asserts exact `FunctionClauseError` fields or stacktrace frames, because Mutare's function *lifting* renames those internals. See "Troubleshooting baseline-only failures" in the [`mix mutare` task docs](https://hexdocs.pm/mutare/Mix.Tasks.Mutare.html) (`mix help mutare`) for the mechanics and the `skip_lifting` escape hatch.

## Features

- Compile once, run N times — no per-mutant recompilation.
- Coverage-guided selection — each mutant runs only the individual test *cases* that cover it (`--per-file` widens this to whole covering files for stateful `async: false` suites; `--full` runs the whole suite per mutant); uncovered mutants are skipped and excluded from the score.
- Parallel workers + timeouts — mutants run concurrently, each capped; a mutation that hangs (a loop turned infinite) halts itself after the deadline and counts as a kill. A timed-out run is first confirmed with an uncontended re-run, so a merely-slow mutant is never falsely recorded as killed.
- Compile-poison recovery — a mutant that wouldn't compile is identified from the compile error, dropped (reported as *poisoned*), and the build retried, to try and avoid a bad mutant spoiling the whole run—but ideally this shouldn't be necessary, and it usually isn't.
- A very broad built-in mutator set — arithmetic/operator swaps, relational and logical swaps, literals of every kind, collection/string/map call rewrites, pattern and clause restructurings, and more. See [`Mutare.Mutators`](https://hexdocs.pm/mutare/Mutare.Mutators.html), and write your own — the [Extending Mutare](https://hexdocs.pm/mutare/extending.html) guide walks through custom mutators and library extensions.
- Umbrella-aware — target one app, several, or the whole workspace.
- CI-friendly — `--since <ref>` to scope to changed lines, score/coverage/infra gates, machine-readable reports, and a kept sandbox (on by default; `--sandbox <path>` to point it at a CI cache) so a re-run recompiles only what changed.

Suppress a known-equivalent mutant with a comment — a trailing comment marks its line as ignored, and a standalone comment applies to the next line. Ignored mutants are excluded from the score and their generated code is omitted from the metamutant. They retain their report entries and positions within `--max-mutants`.

```elixir
def discounted(amount, percent), do: amount - amount * percent / 100  # mutare:ignore
```

You may add a free-text reason; it is also possible to narrow the directive to specific mutator families with a `[...]` filter listing the families to suppress.

```elixir
# mutare:ignore nothing on the next line will be mutated
def passthrough(x), do: x + 0

def parity(n), do: rem(n, 2) == 0  # mutare:ignore[arithmetic] only `rem` will be skipped
```

A filter accepts any built-in family name (the full list is [`Mutare.Mutators.families/0`](https://hexdocs.pm/mutare/Mutare.Mutators.html#families/0) — `arithmetic`, `relational`, `integer`, `collection`, …) or any custom mutator's `name/0`. Filtering fails safe: an unknown name (a typo) or an empty `[]` matches nothing, so the mutant runs rather than being silently hidden.

Qualify a family with `:label` to suppress just one *kind* of its mutants. Here `x < 0` and `x <= 0` are equivalent — the boundary `0` returns `0` down either branch — so that one mutant can never be killed; suppress it while every other relational mutant (`>`, `>=`, `==`, …) keeps running:

```elixir
def floor_zero(x), do: if(x < 0, do: 0, else: x)  # mutare:ignore[relational:<=] 0 ≤ 0 returns 0 here
```

Each family names its own labels — `relational` → `> >= < <= == != === !==`, `integer` → `zero succ pred`, `return_value` → `empty sentinel` — and `mix mutare --list-mutators` prints every built-in family's labels. A qualified label that a known family doesn't declare is a hard error with a "did you mean", so a typo can't slip through as a silent no-op.

For spans that aren't worth annotating line by line — a literal lookup table, a generated module — suppress a region with `# mutare:ignore-start` … `# mutare:ignore-end` (both take the same filter and reason, carried on the `-start`), or a whole file with `# mutare:ignore-file`:

```elixir
# mutare:ignore-start spot-checked; the round-trip property test covers the whole table
def encode(?A), do: ?B
def encode(?B), do: ?C
def encode(?C), do: ?D
# mutare:ignore-end
```

The full grammar is in [`Mutare.Ignore`](https://hexdocs.pm/mutare/Mutare.Ignore.html).

## Usage

```
mix mutare                             # mutate everything under lib/
mix mutare --only lib/billing          # scope to one path
mix mutare --since master              # only lines changed vs a git ref
mix mutare --mutators relational       # run one built-in family
mix mutare --skip-lifting MyApp.Mod.fun/2
                                       # keep one function in-place; no guard,
                                       #   head-pattern, or clause-drop mutants
mix mutare --min-score 70              # fail below a mutation score
mix mutare --max-no-coverage 0         # fail on uncovered mutants
mix mutare --fail-on-poisoned          # fail on compile-poisoned mutants
mix mutare --fail-on-harness-error     # fail on infrastructure verdict gaps
mix mutare --per-file                  # run whole covering files, not per-test-case
mix mutare --full                      # run the whole suite per mutant
mix mutare --workers 4                 # run N mutants concurrently
mix mutare --timeout 30000             # per-mutant wall-clock cap, in ms
mix mutare --max-heap-mb 4096          # per-process heap cap: a mutant that
                                       #   allocates without bound dies as a
                                       #   test failure, not a host OOM
mix mutare --report json:mutare.json   # write a machine-readable report
```

Most projects can start without configuration. Add `.mutare.exs` when you want to scope the run, tune CI gates, teach Mutare about a project macro, or add an application-specific mutator:

```elixir
[
  paths: ["lib"],
  exclude: ["lib/generated/**"],

  # Extend the built-in mutators with one of your own.
  mutators: [:builtins, MyApp.Mutators.AccessPolicy],

  # Leave DSL-only macro arguments as written, or skip a call outright.
  call_routes: [
    {Ecto.Query, :from, :raw},
    {MyApp.Schema, :field, 2, [:expression, :raw]},
    {Mixpanel, :track, 3, :skip}
  ],

  # Extend the built-in timeout table to your own functions.
  argument_marks: [{MyApp.Http, :get, 2, [{:keyword, :recv_timeout}], :timeout}],

  # Keep a compatibility-sensitive function in-place.
  skip_lifting: [{MyApp.Legacy, :parse, 1}],

  # CI gates.
  min_score: 70,
  max_no_coverage: 0,
  fail_on_poisoned: true,
  fail_on_harness_error: true,

  workers: 4,
  timeout_multiplier: 3.0,

  # Harden against flaky tests.
  baseline_runs: 2,
  baseline_retries: 1,
  kill_runs: 2,
  test_selection: :tests,

  # Emit several reports at once.
  reporters: [:human, {:json, "mutare.json"}, {:sarif, "mutare.sarif"}]
]
```

These are the common keys. `mix help mutare` documents the full option set, including sandbox reuse, run caps, retry guards, strict ignore handling, and the matching CLI flags.

### Live progress

While a run is in flight, Mutare writes progress to stderr: the current phase, each survivor as soon as it appears, timeouts, harness errors, and — in a terminal — a live status block with the active mutant and an ETA. The final report still prints to stdout, so `mix mutare > report.txt` captures the report while progress stays visible in the terminal.

### Machine-readable output

By default Mutare prints the human report to stdout. `--report FORMAT[:PATH]` selects another format, and the flag is repeatable:

```
mix mutare --report json:mutare.json --report sarif:mutare.sarif
```

- `json` — the [mutation-testing-elements](https://github.com/stryker-mutator/mutation-testing-elements) / Stryker report schema, covering every mutant.
- `html` — the same JSON embedded in a single interactive HTML report.
- `sarif` — surviving mutants as SARIF 2.1.0 findings for GitHub code scanning.

When every machine format is written to a file, the human report still prints to the console; when any report takes stdout (no `:PATH`), the human report is suppressed to avoid a collision. Only one report may take stdout, and no two may share a path — a second document on the same destination would corrupt or overwrite the first, so `--report json --report sarif` is rejected rather than run.

### Routing calls: skipping calls and arguments

Two kinds of call want leaving alone. Some are **not worth testing** — an analytics emitter, a logger, a metrics call — and every mutant inside them is noise. Some macros take **arguments that are not ordinary runtime code** — a query DSL body, a pattern, a schema definition — and mutating inside those is noise too, and sometimes breaks the single metamutant compile.

Both are `call_routes:` entries. An entry names a call by module, function, and arity (macros and functions alike; Mutare matches it however it is written — directly, aliased, imported, or piped) and says how to treat it:

```elixir
call_routes: [
  # skip the whole call: nothing inside it is mutated, and the call itself is never rewritten
  {Mixpanel, :track, 3, :skip},

  # every argument of `from/_` is left as written
  {Ecto.Query, :from, :raw},

  # only the 2nd argument of `field/2` is left as written; the 1st mutates as normal
  {MyApp.Schema, :field, 2, [:expression, :raw]},

  # the assigns map itself is never collapsed to `%{}` (a crash, not a signal), but the values
  # inside it still mutate
  {Phoenix.Controller, :render, 3, [:expression, :expression, :interior]},

  # one option of a literal keyword argument: `recv_timeout:` is left alone, `pool:` still mutates
  {MyApp.Http, :get, 2, [:expression, [recv_timeout: :raw]]}
]
```

An entry is `{Module, :name, arity, treatment}`, or `{Module, :name, treatment}` to match any arity. The treatment is either `:skip` for the whole call, one word for every argument, or a per-position list:

- `:skip` — the whole call is an inert leaf. A value piped *into* the call is not part of it and still mutates, and a skipped call in tail position still gets the enclosing function's return-value mutants (those test the function, not the call). `mix mutare --skip-call Mixpanel.track/3` is the same thing from the command line. `:skip` applies to whatever the name resolves to — `Kernel.if/2` or a special form (`{Kernel.SpecialForms, :case, :skip}`) included. The forms Mutare analyzes structurally (`if`, `case`, the boolean operators, …) accept `:skip` and nothing else, and definitions (`def`, `defmodule`, `use`, …) cannot be routed, and neither can literal or pattern syntax (`{}`, `%{}`, `<<>>`, `=`, …); `# mutare:ignore` is the tool for a definition, `--mutators` or `# mutare:ignore[<family>]` for a literal family.
- `:raw` — leave the argument exactly as written (no descent, no mutation).
- `:interior` — mutate what is *inside* the argument, but never the argument's own node.
- `:expression` — mutate it as normal runtime code (the default).
- `:pattern` — descend as a match pattern, without mutating the pattern itself.
- `:binding_pattern` — like `:pattern`, for macros whose bindings escape into the caller.
- `[leading, key: treatment, …]` — a *keyed refinement* for an argument written as a literal keyword list: the argument follows `leading` (default `:expression`), except that each named key's value follows its own treatment. Refinements nest (`[retry: [max_retries: :raw]]`).

A per-position list is padded with `:expression`, so `[:expression, :raw]` means "mutate the first argument, leave the second as written, mutate the rest". `:skip` is only ever the whole treatment; inside a list, write `:raw`.

Two wildcards cover the awkward cases, and more specific entries win:

```elixir
call_routes: [
  # whole module
  {Sentry, :*, :skip},

  # one macro name, wherever it comes from
  {:*, :sigil_X, :raw},

  # more specific entries win: everything in MyApp.Sql is skipped except select/2
  {MyApp.Sql, :*, :skip},
  {MyApp.Sql, :select, 2, [:expression, :raw]}
]
```

That is the whole vocabulary `.mutare.exs` accepts. Richer DSL support belongs in a library adapter: use an extension for shape-aware routing, and host mutators for mutations inside DSL fragments. The [Extending Mutare](https://hexdocs.pm/mutare/extending.html) guide covers that path.

A route that matches no call anywhere in a full scan is reported as a warning, so a typo'd module or a wrong arity never sits silently inert.

#### Argument marks: extending the timeout table

Routes are blunt on purpose: `:raw` holds a position back from every mutator whatever its value. The built-in timeout handling is finer than that. A duration position (`Process.sleep/1`, `GenServer.call/3`'s third argument, `Task.async_stream`'s `timeout:` option, …) is *marked* `:timeout`, and each mutator decides what the mark means: the integer family declines any integer there, the atom family declines only `:infinity`, and every other family proceeds — so a computed duration like `base * 2` still mutates its `2`.

`argument_marks:` extends those tables to your own functions, in the exact shape the mutators declare them:

```elixir
argument_marks: [
  {MyApp.Cache, :put, 3, [2], :timeout},                       # a positional argument
  {MyApp.Http, :get, 2, [{:keyword, :recv_timeout}], :timeout} # a trailing-option value
]
```

An entry is `{Module, :function, arity, positions, label}`; `positions` lists effective argument indices (a piped receiver is index 0) and `{:keyword, key}` option keys. The label must be one some enabled mutator understands — `:timeout` is built in, and a companion package documents its own — so a typo fails at startup. Reach for a route when a position should simply not mutate; reach for a mark when the reaction should depend on the value.

### Choosing which mutators run

By default, every built-in mutator family runs. The `:mutators` option is only needed when you want to narrow that set, configure one family, or add a custom mutator.

```elixir
# A mutator plus config:
mutators: [{Mutare.Mutators.Arithmetic, []}, {MyApp.Mutators.AccessPolicy, []}]

# Empty config can be omitted. Built-in family atoms expand to their modules.
mutators: [:arithmetic, MyApp.Mutators.AccessPolicy]
```

Use `:builtins` when you want to start from the default set:

```elixir
mutators: [:builtins, MyApp.Mutators.AccessPolicy]   # EXTEND  — all built-ins + your own
mutators: [MyApp.Mutators.AccessPolicy]              # REPLACE — only your own

mutators: [{:builtins, except: [:arithmetic, :relational]}]   # all built-ins except these
```

To reconfigure a built-in, exclude the stock version and add the configured module explicitly:

```elixir
mutators: [
  {:builtins, except: [:convention]},
  {Mutare.Mutators.ConventionAtom, pairs: [[:active, :inactive]]}
]
```

On the CLI, `--mutators` takes a CSV of built-in family atoms (`--mutators builtins,relational`). `except:` and custom modules are `.mutare.exs`-only.

### Custom mutators

A custom mutator is useful when your application has a meaningful alternative that a general-purpose tool cannot know. Suppose editing requires stricter permission than viewing: replacing `Permissions.can_edit?/2` with `Permissions.can_view?/2` checks whether the tests prevent a view-only user from editing.

A mutator implements `Mutare.Mutator`: `name/0` supplies the report name, and `mutate/1` returns either `:skip` or a list of replacement AST nodes. `resolved_call/1` recognizes the call even when `MyApp.Permissions` is aliased, and its `rebuild` function preserves the form used by the source:

```elixir
defmodule MyApp.Mutators.AccessPolicy do
  @behaviour Mutare.Mutator

  alias Mutare.Calls

  @impl true
  def name, do: :access_policy

  @impl true
  def mutate(node) do
    case Calls.resolved_call(node) do
      {[:MyApp, :Permissions], :can_edit?, [actor, record], rebuild} ->
        [rebuild.(:can_view?, [actor, record])]

      _ ->
        :skip
    end
  end
end
```

This assumes both permission functions exist with the same arity, keeping the generated mutant compile-safe. Enable it with `mutators: [:builtins, MyApp.Mutators.AccessPolicy]`.

Example output:

```
mutare: 3 mutants across 1 file(s)
compiling metamutant once, baseline first…

.S.

lib/calc.ex:3  [relational, in-place]  SURVIVED
-  def gte?(a, b), do: a >= b
+  def gte?(a, b), do: a > b

mutation score: 66.7%  (2 killed, 1 survived, 3 total)
```

That survivor says: nothing in the suite distinguishes `>` from `>=` at the boundary — a missing boundary test.

## Development

```
mix test                                      # full suite (~3 min; subprocess + property soaks)
mix test --exclude runner --exclude property  # fast loop (~4s)
mix format
mix compile --warnings-as-errors              # the project is kept warnings-clean
mix docs                                      # generate the HexDocs locally
```

## License

[MIT](LICENSE) © Benjamin Fox
