# Mutare

Mutare is a mutation testing system for Elixir, that mutates the source you actually write, and compiles **once**.

Mutation testing measures whether your test suite actually constrains the behavior of your code: it deliberately breaks your source code one small change at a time, and each time your tests nevertheless still pass it has located a gap in your test suite.

Other Elixir mutation testing libraries, such as [Muex](https://github.com/Oeditus/muex), compile your code once per mutant, which can be quite slow, even with incremental recompilation. Mutation testing is never fast, but mutare aims to be the fastest Elixir mutation library with its compile-once approach. Mutare compiles a **metamutant**, a version of your program embedding all possible mutants behind runtime switches, and then selects the active mutant per test run via an environment variable.

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

A mutator package extends the `:mutators` list; a non-mutating **extension** like `mutare_gettext` (which teaches mutare a library's compile-time vocabulary so the built-in mutators can deal with it) joins the `:extensions` list. The Ecto repo is detected automatically (pass `--repo MyApp.Repo` to override). If you already have a `.mutare.exs`, it is left untouched and the recommended keys are printed for you to merge in.

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

1. **Transform.** Every in-scope source file is rewritten into a *metamutant* that embeds all of its mutants. Mutare transforms the code you write, before macro expansion—so any macros that don't accept arbitrary expressions will probably need to be marked `:skip` in your config.
2. **Compile once.** The metamutant compiles a single time. The source code doesn't change between runs, so there is no per-mutant recompilation.
3. **Run the suite per mutant.** A baseline test run must pass; a coverage probe then maps each mutant to the test files that exercise it. Each mutant runs in a fresh `mix test` OS process with `MUTARE_ACTIVE_MUTANT` set, `:workers` at a time, each capped by a wall-clock timeout.
4. **Report.** Surviving mutants are listed in an abbreviated format as the run progresses, and you get a full report, with diffs and a mutation score, at the end. You can also enable JSON, HTML, or SARIF format output.

## Features

- **Compile once, run N times** — no per-mutant recompilation.
- **Coverage-guided selection** — each mutant runs only the test files that cover it; uncovered mutants are skipped and excluded from the score (`--full` opts out).
- **Parallel workers + timeouts** — mutants run concurrently, each capped; a mutation that hangs (a loop turned infinite) halts itself after the deadline and counts as a kill.
- **Compile-poison recovery** — a mutant that wouldn't compile is identified from
  the compile error, dropped (reported as *poisoned*), and the build retried, to try and avoid a bad mutant spoiling the whole run—but ideally this shouldn't be necessary, and it usually isn't.
- **A very broad built-in mutator set** — arithmetic/operator swaps, relational and logical swaps, literals of every kind, collection/string/map call rewrites, pattern and clause restructurings, and more. See [`Mutare.Mutators`](https://hexdocs.pm/mutare/Mutare.Mutators.html), and write your own — the [Extending Mutare](https://hexdocs.pm/mutare/extending.html) guide walks through custom mutators and library extensions.
- **Umbrella-aware** — target one app, several, or the whole workspace.
- **CI-friendly** — `--since <ref>` to scope to changed files, score/coverage/infra gates, machine-readable reports, and `--keep-sandbox` to cache the compiled sandbox across runs.

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

A filter accepts any built-in family name (the full list is [`Mutare.Mutators.families/0`](https://hexdocs.pm/mutare/Mutare.Mutators.html#families/0)
— `arithmetic`, `relational`, `literal`, `collection`, …), plus `clause_drop` and any custom mutator's `name/0`. Filtering fails safe: an unknown name (a typo) or an empty `[]` matches nothing, so the mutant runs rather than being silently hidden.

Qualify a family with `:label` to suppress just one *kind* of its mutants. Here `x < 0` and `x <= 0` are equivalent — the boundary `0` returns `0` down either branch — so that one mutant can never be killed; suppress it while every other relational mutant (`>`, `>=`, `==`, …) keeps running:

```elixir
def floor_zero(x), do: if(x < 0, do: 0, else: x)  # mutare:ignore[relational:<=] 0 ≤ 0 returns 0 here
```

Each family names its own labels — `relational` → `> >= < <= == != === !==`, `literal` → `zero succ pred negate`, `return_value` → `empty sentinel` — and `mix mutare --list-mutators` prints every built-in family's labels. A qualified label that a known family doesn't declare is a hard error with a "did you mean", so a typo can't slip through as a silent no-op. The full grammar is in [`Mutare.Ignore`](https://hexdocs.pm/mutare/Mutare.Ignore.html).

## Usage

```
mix mutare                          # mutate everything under lib/
mix mutare --only lib/billing       # scope to a path
mix mutare --since master           # only files changed vs a git ref (CI)
mix mutare --mutators relational    # choose mutator families
mix mutare --min-score 70           # fail (CI) below a score
mix mutare --max-no-coverage 0      # fail (CI) on uncovered mutants
mix mutare --fail-on-poisoned       # fail (CI) on compile-poisoned mutants
mix mutare --fail-on-harness-error  # fail (CI) on infrastructure verdict gaps
mix mutare --full                   # whole suite per mutant (no test selection)
mix mutare --workers 4              # run N mutants concurrently
mix mutare --timeout 30000          # per-mutant wall-clock cap, in ms
mix mutare --report json:mutare.json   # machine-readable report to a file
```

Optional `.mutare.exs`:

```elixir
[
  paths: ["lib"],
  exclude: ["lib/generated/**"],
  # which mutators run (see "Choosing which mutators run" below). Built-in family
  # atoms and/or your own modules; the `:builtins` token means "all built-ins", so
  # `[:builtins, MyApp.Mutators.AccessPolicy]` extends the defaults rather than replacing.
  mutators: [:builtins, MyApp.Mutators.AccessPolicy],
  # mark a macro's arguments as off-limits for mutation, by module/name/arity
  # (see "Skipping macro arguments" below). `:skip` = every argument; a list
  # skips only the marked positions (`:expression` = mutate as normal).
  macro_routes: [
    {Ecto.Query, :from, :skip},
    {MyApp.Schema, :field, 2, [:expression, :skip]}
  ],
  # fail the run (non-zero exit) if the mutation score drops below this;
  # the same CI gate as `--min-score`, which overrides this when given
  min_score: 70,
  # separate CI gates for mutants Mutare could not test meaningfully
  max_no_coverage: 0,
  fail_on_poisoned: true,
  fail_on_harness_error: true,
  workers: System.schedulers_online(),
  # per-mutant cap = baseline × timeout_multiplier, unless an absolute
  # `timeout:` (ms) is set — both also available as --workers / --timeout
  timeout_multiplier: 3.0,
  # harden against flaky tests: baseline suite disagreement aborts; one-off kills
  # from residual mutant-timing flakes are demoted unless every run kills
  baseline_runs: 2,
  kill_runs: 2,
  test_selection: :coverage,
  # emit several reports at once (a bare atom goes to stdout)
  reporters: [:human, {:json, "mutare.json"}, {:sarif, "mutare.sarif"}]
]
```

These are the common keys; `mix help mutare` documents the full set — sandbox / build-cache reuse (`sandbox`, `keep_sandbox`), baseline re-runs (`baseline_runs`), unanimous-kill reruns (`kill_runs`), harness-error retry/abort guards (`harness_retries`, `max_harness_error_rate`), run caps (`max_mutants`, `max_survivors`), CI gates (`min_score`, `max_no_coverage`, `fail_on_poisoned`, `fail_on_harness_error`, `strict_ignores`), `quiet`, and `expand_uses` — each also a CLI flag.

### Live progress

While a run is in flight, Mutare shows live progress on **stderr**: the current phase (compiling once, baseline, coverage probe), then a permanent line for each surviving mutant the moment it's found (plus timeouts and harness errors), and — in a terminal — a status block at the bottom with a spinner, the mutant currently under test, and a counter with an ETA. The detailed survivor diffs and the score still print to **stdout** at the end, so `mix mutare > report.txt` captures the report while you watch progress on the terminal.

### Machine-readable output

By default Mutare prints the human report to the console (stdout). `--report FORMAT[:PATH]` selects a report format and optional output file, and the flag is repeatable: `--report json:mutare.json --report sarif:mutare.sarif`.

- **`json`** — the [mutation-testing-elements](https://github.com/stryker-mutator/mutation-testing-elements) / Stryker **report schema**. A standardized, versioned document covering every mutant (not just survivors), ready for the Stryker dashboard and other tooling.
- **`html`** — that same JSON embedded in a single HTML file that loads the official interactive report viewer from a pinned CDN bundle, with a file tree, inline mutant annotations on the source, and the score.
- **`sarif`** — surviving mutants as SARIF 2.1.0 findings, so GitHub code scanning shows each one as an inline annotation on the pull-request diff.

When every machine format is written to a file, the human report still prints to the console; when any report takes stdout (no `:PATH`), the human report is suppressed to avoid a collision.

### Skipping macro arguments

Some macros take arguments that aren't ordinary runtime code — a query DSL body, a pattern, a schema definition. Mutating inside them is pointless at best and can break the single compile at worst (a selector spliced into `Ecto.Query.from`'s body, say). When Mutare can't tell a macro call from a normal function call, list the macro under `macro_routes:` in `.mutare.exs` and its arguments are left **raw** — no custom mutator required:

```elixir
macro_routes: [
  # every argument of `from/_` (any arity) is left untouched
  {Ecto.Query, :from, :skip},
  # only the 2nd argument of `field/2` is skipped; the 1st mutates as normal
  {MyApp.Schema, :field, 2, [:expression, :skip]}
]
```

An entry is `{Module, :name, arity, treatment}`, or `{Module, :name, treatment}` to match **any arity**. The `treatment` is either a single atom applied to every argument or a per-position list:

- `:skip` — leave the argument raw (no descent, no mutation).
- `:expression` — mutate it as normal runtime code (the default).
- `:pattern` — treat it as a match pattern (descend, but don't mutate the pattern
  itself); for the rare macro that takes one (like `match?/2`).
- `:binding_pattern` — like `:pattern`, for a macro whose bindings escape into the caller.

A per-position list is padded with `:expression`, so `[:expression, :skip]` means "mutate the first argument, skip the second, mutate the rest". The macro is matched however it's written — directly, aliased, or imported (bare).

That vocabulary is the whole escape hatch most projects need — and the whole vocabulary
`.mutare.exs` accepts: it only tells Mutare an argument isn't ordinary runtime code. Further
treatments (and shape-dependent routing) exist for **library adapters**: an extension implementing
`Mutare.MacroRouting` describes a DSL's argument shapes once, and independent host mutators
implementing `Mutare.Mutator.MacroHost` deliver mutations *inside* its fragments. Those treatments
assert facts about the DSL that Mutare cannot check, so they can only come from adapter code that
takes responsibility for them — a `macro_routes:` config entry using one is rejected. If you find
yourself wanting one, you're writing an adapter: start from the
[Extending Mutare](https://hexdocs.pm/mutare/extending.html) guide.

#### Wildcards: a whole module, or a name in any module

The glob atom `:*` matches anything in the module, name, or arity slot:

```elixir
macro_routes: [
  # whole module — leave every macro in this DSL untouched
  {MyApp.Sql, :*, :skip},
  # …but override one of them (a more specific line always wins)
  {MyApp.Sql, :select, 2, [:expression, :skip]},

  # name-only escape hatch — a macro of this name in ANY module
  {:*, :sigil_X, :skip}
]
```

A **whole-module** entry (`:*` in the name slot) routes every macro in the module; a more specific entry on another line overrides it per macro. The **name-only** escape hatch (`:*` in the module slot) matches a macro by name regardless of which module exports it — use it only when Mutare can't resolve the macro's module; it's consulted last and never shadows a more precise treatment.

### Choosing which mutators run

The `:mutators` list (in `.mutare.exs`, or `--mutators` on the CLI) is a list of mutators, each optionally with its configuration.

```elixir
# 1. The canonical form — a mutator and its config:
mutators: [{Mutare.Mutators.Arithmetic, []}, {MyApp.Mutators.AccessPolicy, []}]

# 2. Drop the config when it's empty — bare module or family atom:
mutators: [:arithmetic, MyApp.Mutators.AccessPolicy]
#          ^ a built-in family atom expands to its module with default config.
#            (Atoms name built-ins; external mutators are named by their module.)

# 3. Omit :mutators entirely → every built-in family, default config, no externals.
```

To work *from* the defaults rather than listing everything, use the **`:builtins`** group token. Whether it appears decides extend vs. replace:

```elixir
mutators: [:builtins, MyApp.Mutators.AccessPolicy]   # EXTEND  — all built-ins + your own
mutators: [MyApp.Mutators.AccessPolicy]              # REPLACE — only your own

mutators: [{:builtins, except: [:arithmetic, :relational]}]   # all built-ins but these
```

To **reconfigure** a built-in — exclude it, then re-add it configured as you choose:

```elixir
mutators: [
  {:builtins, except: [:convention]},                 # all built-ins but the stock one…
  {Mutare.Mutators.ConventionAtom, pairs: [[:active, :inactive]]}   # …re-added, configured
]
```

On the CLI, `--mutators` takes a CSV of those atoms (`--mutators builtins,relational`);
`except:` and custom modules are `.mutare.exs`-only.

### Custom mutators

A custom mutator is useful when your application has a meaningful alternative that a general-purpose tool cannot know about. Suppose editing requires stricter permission than viewing: replacing `Permissions.can_edit?/2` with `Permissions.can_view?/2` checks whether the tests prevent a view-only user from editing.

A mutator implements `Mutare.Mutator`: `name/0` supplies the report name, while `mutate/1` returns either `:skip` or a list of replacement AST nodes. `resolved_call/1` recognizes the call even when `MyApp.Permissions` is aliased, and its `rebuild` function preserves the form used by the source:

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
