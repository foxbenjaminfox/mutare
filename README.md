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

| Detected dependency                     | Package added              | Wired into                                    |
| --------------------------------------- | -------------------------- | --------------------------------------------- |
| `:phoenix`                              | `mutare_phoenix`           | `:mutators` — `Mutare.Phoenix.all/0`          |
| `:phoenix_live_view`                    | `mutare_phoenix_live_view` | `:mutators` — `Mutare.Phoenix.LiveView.all/0` |
| `:ecto_sql` / `:phoenix_ecto` / `:ecto` | `mutare_ecto`              | `:mutators` — `{Mutare.Ecto, repo: YourRepo}` |
| `:oban` / `:oban_pro`                   | `mutare_oban`              | `:mutators` — `Mutare.Oban.all/0`             |
| `:decimal`                              | `mutare_decimal`           | `:mutators` — `Mutare.Decimal.all/0`          |
| `:gettext`                              | `mutare_gettext`           | `:extensions` — `Mutare.Gettext`              |

A mutator package extends the `:mutators` list; a non-mutating extension like `mutare_gettext` (which teaches mutare a library's compile-time vocabulary so the built-in mutators can deal with it) joins the `:extensions` list. The Ecto repo is detected automatically (pass `--repo MyApp.Repo` to override). If you already have a `.mutare.exs`, it is left untouched and the recommended keys are printed for you to merge in.

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
# {:mutare_phoenix, "~> 0.1", only: [:dev, :test], runtime: false}
# {:mutare_phoenix_live_view, "~> 0.1", only: [:dev, :test], runtime: false}
```

Then run `mix mutare`.

## How it works

1. Transform. Every in-scope source file is rewritten into a *metamutant* that embeds all of its mutants. Mutare transforms the code you write, before macro expansion—so any macros that don't accept arbitrary expressions will probably need to be marked `:skip` in your config.
2. Compile once. The metamutant compiles a single time. The source code doesn't change between runs, so there is no per-mutant recompilation.
3. Run the suite per mutant. A baseline test run must pass; a coverage probe then maps each mutant to the test files that exercise it. Each mutant runs in a fresh `mix test` OS process with `MUTARE_ACTIVE_MUTANT` set, `:workers` at a time, each capped by a wall-clock timeout.
4. Report. Surviving mutants are listed in an abbreviated format as the run progresses, and you get a full report, with diffs and a mutation score, at the end. You can also enable JSON, HTML, or SARIF format output.

## Features

- Compile once, run N times — no per-mutant recompilation.
- Coverage-guided selection — each mutant runs only the test files that cover it; uncovered mutants are skipped and excluded from the score (`--full` opts out).
- Parallel workers + timeouts — mutants run concurrently, each capped; a mutation that hangs (a loop turned infinite) halts itself after the deadline and counts as a kill.
- Compile-poison recovery — a mutant that wouldn't compile is identified from the compile error, dropped (reported as *poisoned*), and the build retried, to try and avoid a bad mutant spoiling the whole run—but ideally this shouldn't be necessary, and it usually isn't.
- A very broad built-in mutator set — arithmetic/operator swaps, relational and logical swaps, literals of every kind, collection/string/map call rewrites, pattern and clause restructurings, and more. See [`Mutare.Mutators`](https://hexdocs.pm/mutare/Mutare.Mutators.html), and write your own — the [Extending Mutare](https://hexdocs.pm/mutare/extending.html) guide walks through custom mutators and library extensions.
- Umbrella-aware — target one app, several, or the whole workspace.
- CI-friendly — `--since <ref>` to scope to changed files, score/coverage/infra gates, machine-readable reports, and `--keep-sandbox` to cache the compiled sandbox across runs.

Suppress a known-equivalent mutant with a comment — a trailing comment marks its line as ignored, and a standalone comment applies to the next line. Ignored mutants are excluded from the score.

```elixir
def discounted(amount, percent), do: amount - amount * percent / 100  # mutare:ignore
```

You may add a free-text reason; it is also possible to narrow the directive to specific mutator families with a `[...]` filter listing the families to suppress.

```elixir
# mutare:ignore nothing on the next line will be mutated
def passthrough(x), do: x + 0

def parity(n), do: rem(n, 2) == 0  # mutare:ignore[arithmetic] only `rem` will be skipped
```

A filter accepts any built-in family name (the full list is [`Mutare.Mutators.families/0`](https://hexdocs.pm/mutare/Mutare.Mutators.html#families/0) — `arithmetic`, `relational`, `literal`, `collection`, …), plus `clause_drop` and any custom mutator's `name/0`. Filtering fails safe: an unknown name (a typo) or an empty `[]` matches nothing, so the mutant runs rather than being silently hidden.

Qualify a family with `:label` to suppress just one *kind* of its mutants. Here `x < 0` and `x <= 0` are equivalent — the boundary `0` returns `0` down either branch — so that one mutant can never be killed; suppress it while every other relational mutant (`>`, `>=`, `==`, …) keeps running:

```elixir
def floor_zero(x), do: if(x < 0, do: 0, else: x)  # mutare:ignore[relational:<=] 0 ≤ 0 returns 0 here
```

Each family names its own labels — `relational` → `> >= < <= == != === !==`, `literal` → `zero succ pred negate`, `return_value` → `empty sentinel` — and `mix mutare --list-mutators` prints every built-in family's labels. A qualified label that a known family doesn't declare is a hard error with a "did you mean", so a typo can't slip through as a silent no-op. The full grammar is in [`Mutare.Ignore`](https://hexdocs.pm/mutare/Mutare.Ignore.html).

## Usage

```
mix mutare                             # mutate everything under lib/
mix mutare --only lib/billing          # scope to one path
mix mutare --since master              # only files changed vs a git ref
mix mutare --mutators relational       # run one built-in family
mix mutare --min-score 70              # fail below a mutation score
mix mutare --max-no-coverage 0         # fail on uncovered mutants
mix mutare --fail-on-poisoned          # fail on compile-poisoned mutants
mix mutare --fail-on-harness-error     # fail on infrastructure verdict gaps
mix mutare --full                      # run the whole suite per mutant
mix mutare --workers 4                 # run N mutants concurrently
mix mutare --timeout 30000             # per-mutant wall-clock cap, in ms
mix mutare --report json:mutare.json   # write a machine-readable report
```

Most projects can start without configuration. Add `.mutare.exs` when you want to scope the run, tune CI gates, teach Mutare about a project macro, or add an application-specific mutator:

```elixir
[
  paths: ["lib"],
  exclude: ["lib/generated/**"],

  # Extend the built-in mutators with one of your own.
  mutators: [:builtins, MyApp.Mutators.AccessPolicy],

  # Leave DSL-only macro arguments untouched.
  macro_routes: [
    {Ecto.Query, :from, :skip},
    {MyApp.Schema, :field, 2, [:expression, :skip]}
  ],

  # CI gates.
  min_score: 70,
  max_no_coverage: 0,
  fail_on_poisoned: true,
  fail_on_harness_error: true,

  workers: System.schedulers_online(),
  timeout_multiplier: 3.0,

  # Harden against flaky tests.
  baseline_runs: 2,
  kill_runs: 2,
  test_selection: :coverage,

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

When every machine format is written to a file, the human report still prints to the console; when any report takes stdout (no `:PATH`), the human report is suppressed to avoid a collision.

### Skipping macro arguments

Some macros take arguments that are not ordinary runtime code: a query DSL body, a pattern, a schema definition. Mutating inside those arguments is usually noise, and sometimes it breaks the single metamutant compile.

When Mutare needs project-specific help, list the macro under `macro_routes:` and mark the non-runtime arguments as raw:

```elixir
macro_routes: [
  # every argument of `from/_` is left untouched
  {Ecto.Query, :from, :skip},

  # only the 2nd argument of `field/2` is skipped; the 1st mutates as normal
  {MyApp.Schema, :field, 2, [:expression, :skip]}
]
```

An entry is `{Module, :name, arity, treatment}`, or `{Module, :name, treatment}` to match any arity. A treatment is either one atom for every argument or a per-position list:

- `:skip` — leave the argument raw (no descent, no mutation).
- `:expression` — mutate it as normal runtime code (the default).
- `:pattern` — descend as a match pattern, without mutating the pattern itself.
- `:binding_pattern` — like `:pattern`, for macros whose bindings escape into the caller.

A per-position list is padded with `:expression`, so `[:expression, :skip]` means “mutate the first argument, skip the second, mutate the rest”. Mutare matches the macro however it is written: directly, aliased, or imported.

Two wildcards cover the awkward cases:

```elixir
macro_routes: [
  # whole module
  {MyApp.Sql, :*, :skip},

  # one macro name, wherever it comes from
  {:*, :sigil_X, :skip},

  # more specific entries win
  {MyApp.Sql, :select, 2, [:expression, :skip]}
]
```

That is the whole vocabulary `.mutare.exs` accepts. Richer DSL support belongs in a library adapter: use an extension for shape-aware routing, and host mutators for mutations inside DSL fragments. The [Extending Mutare](https://hexdocs.pm/mutare/extending.html) guide covers that path.

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
