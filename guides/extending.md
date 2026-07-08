# Extending Mutare

Mutare has two extension points, matching two keys in `.mutare.exs`:

- **`:mutators`** — modules that *produce mutations*. A custom mutator adds new
  kinds of mutants alongside (or instead of) the built-in families.
- **`:extensions`** — non-mutating modules that *teach Mutare a library's
  compile-time vocabulary*, so the built-in mutators can work in and around its
  macros. Extensions never appear in reports.

This guide helps you pick the piece you need and points to the module docs that
carry the full contract. Every kind listed here has a small working example
under `test/support/` in the Mutare repository.

## Which piece do you want?

| You want to… | Implement | Read next |
| --- | --- | --- |
| Swap one AST node for another (`and` → `or`) | `Mutare.Mutator` with `mutate/1` | `Mutare.Mutator` |
| Make a mutator configurable, pipe-aware, or gated on the module's `@behaviour`s | `mutate/2` | `Mutare.Mutator` |
| Mutate a *position*: a clause's return value, an `if` condition, a head pattern | `Mutare.Mutator.Structural` | `Mutare.Mutator.Structural` |
| Match calls to a specific library or stdlib function | `mutate/1,2` + `Mutare.Calls.resolved_call_to/3` | `Mutare.Calls` |
| Keep a macro's arguments from being mutated at all | no code — `macro_routes:` in `.mutare.exs` | the README's macro section |
| Describe how a DSL's macro arguments should be treated | `Mutare.MacroRouting` | `Mutare.MacroRouting` |
| Emit mutations *inside* a DSL fragment (an Ecto `where`, say) | `Mutare.Mutator.MacroHost` | `Mutare.Mutator.MacroHost` |
| Handle a `use` whose injected imports/behaviours Mutare can't recover | `Mutare.UseExpansion` | `Mutare.UseExpansion` |

The first four are mutators and go under `:mutators`. The last three are
extension capabilities: implemented by a *non-mutating* module, they go under
`:extensions` (a mutator may also implement `Mutare.MacroRouting` and
`Mutare.Mutator.MacroHost` itself — then the one `:mutators` entry enables
everything).

## Writing a mutator

A mutator is a module implementing `Mutare.Mutator`: `name/0` (the family name
shown in reports) plus at least one mutation-producing callback. The simplest
producer is `mutate/1` — match the nodes you care about, return replacements,
`:skip` everything else:

```elixir
defmodule MyApp.Mutators.AndOr do
  @behaviour Mutare.Mutator

  @impl true
  def name, do: :and_or

  @impl true
  def mutate({:and, meta, [left, right]}), do: [{:or, meta, [left, right]}]
  def mutate({:or, meta, [left, right]}), do: [{:and, meta, [left, right]}]
  def mutate(_node), do: :skip
end
```

Enable it in `.mutare.exs` — `:builtins` keeps the default families alongside
yours:

```elixir
[mutators: [:builtins, MyApp.Mutators.AndOr]]
```

Three rules keep you out of trouble; the *why* is in the `Mutare.Mutator` docs:

1. **Every replacement must compile.** All mutants are compiled together into
   one program, so one bad replacement sinks the whole run. Reuse the original
   operands wherever you can.
2. **Never decide placement.** You return replacement nodes; Mutare decides
   whether they're delivered in place or by lifting the enclosing function.
3. **Build literals with `Mutare.AST.literal/1`**, not by hand — a hand-built
   literal can silently render as the original source.

### Emitting AST

Sourceror nodes carry rendering metadata with sharp edges, and every one of
them is core's problem, not yours. Each invariant has a `Mutare.AST` helper
that discharges it — reach for the helper instead of re-deriving the rule:

| Invariant | Helper |
| --- | --- |
| Fresh literals need clean, derived meta, or the renderer re-emits the old source text | `Mutare.AST.literal/1` |
| Numeric literals woven into parsed source need a `:token`, or rendering raises | `Mutare.AST.literal/1` |
| Keyword keys need `format: :keyword` to render as `key:` rather than `{:key, …}` | `Mutare.AST.keyword_key/1` |
| Re-declared variables must drop source meta but keep their hygiene context | `Mutare.AST.clean_var/1` |
| Emitted module references must be alias-proof (`Elixir.`-prefixed) | `Mutare.AST.absolute_alias/1`, `absolute_call/3`, `remote_call/3` |

If you find yourself building a raw `{:__block__, meta, [value]}` tuple in a
mutator, one of these is missing from your toolkit — or from `Mutare.AST`, in
which case that's a bug report.

### Context: configuration, pipes, and behaviours

Implement `mutate/2` instead of `mutate/1` when the mutation depends on
context. (If both are exported, Mutare calls only `mutate/2` — compose them
yourself by calling `mutate/1` from it.) The second argument carries:

- `:opts` — per-instance options, when the mutator is registered as
  `{MyApp.Mutators.MagicNumber, swaps: %{200 => 500}}`. The reserved `:as`
  option renames the family, so one module can run twice under two names.
- `:pipe_mode` — whether the call sits on the right of a `|>` (its first
  argument is then implicit; helpers `Mutare.Mutator.effective_arity/2` and
  `visible_index/2` do the arithmetic).
- `:behaviours` — the enclosing module's `@behaviour` set, for mutators that
  should only fire in, say, a `GenServer`.

### Structural positions

Some targets are positions, not nodes: a function clause's return value, an
`if`/`unless`/`cond` condition, a head or destructuring pattern. For those,
declare `Mutare.Mutator.Structural` alongside `Mutare.Mutator` and implement
the matching callback — `return_replacements/1`, `condition_replacements/1`,
or `pattern_mutations/2` (each also has a context-taking arity). No `mutate/1`
needed.

### Matching library calls

Don't pattern-match qualified call AST directly — users write `Enum.sort/1` as
`Enum.sort`, `E.sort` under an alias, or bare `sort` under an import. Use
`Mutare.Calls.resolved_call_to/3` to match a specific module (and optionally
function names): it takes the real module atom — you never build the resolved
key yourself — and returns `{:ok, function, arguments, rebuild}`, where
`rebuild` re-emits your replacement in whatever form the source used. The
lower-level `Mutare.Calls.resolved_call/1` returns the raw resolved tuple for
table-driven matching across many modules, and `Mutare.Calls.module_key/1`
encodes a module atom into its key shape when you need to build such a table.

### Polish: ignore variants and option keys

Two optional callbacks refine how users interact with your mutator:

- `variants/0` (with `Mutare.Mutator.Mutation.tagged/2` or `variant/2`) gives
  your mutations labels, so `# mutare:ignore[boolean:or]` can suppress one kind
  without silencing the family. See `Mutare.Mutator` and `Mutare.Ignore`.
- `mutate_call_option_keys?/1` lets a key-mutating family opt out of rewriting
  trailing call options like the `timeout:` in `foo(x, timeout: 5)`.

### Reporting a whole-node rewrite at its clause

A macro-aware mutator that rebuilds and returns a whole registered call from
`mutate/1,2` — say it rewrites an entire multi-line `from(...)` query but only
changed one `where:` clause — would otherwise report every mutant at the call's
line, so `# mutare:ignore` (line-keyed) could only suppress the whole call at
once. Wrap the return in a `Mutare.Mutator.Mutation` with an `:attribution` to
point the report at the clause you actually changed:

```elixir
# a value flip, reported (and ignorable) at the order_by: line:
Mutation.new(rebuilt_call, attribution: Mutation.at(order_by_value, flipped_value))

# a clause drop, reported at the dropped clause's line:
Mutation.new(rebuilt_call, attribution: Mutation.at_drop(dropped_clause))
```

The metamutant is still built from the returned node; attribution only moves the
site's location and diff onto the named clause. Point it at a node *inside* the
rewrite — core drops (with a warning) an attribution whose clause isn't rangeable
or escapes the returned node's span. See `Mutare.Mutator.Mutation`.

### Testing your mutator

`import Mutare.Test` in an ExUnit case. It tests at three levels: the
replacements for one node (`node_mutations/3`), what the full transform
produces (`diffs/3`, `metamutant_source/3`), and — the real proof — compiling
a metamutant and checking that activating your mutant changes runtime
behaviour (`compile_metamutant/3` + `observe_mutant/3`). Each source-driven
helper forwards a trailing keyword list to `Mutare.transform_string/2`, so a
suite can thread `:extensions` or `:macro_routes` through them. To test that
your mutator composes with macro routing an *independent* library ships, use
the bundled `Mutare.Test.Fixtures.RoutingExtension` rather than authoring a
no-op routing provider.

## Writing an extension

An extension is a module implementing `Mutare.MacroRouting`,
`Mutare.UseExpansion`, or both, listed under `:extensions`:

```elixir
[extensions: [Mutare.Gettext]]
```

It produces no mutations, has no `name/0`, and never appears in a report. Its
job is to describe a library so Mutare's ordinary mutators behave correctly
around that library's macros. (Mutators that implement these capabilities
belong under `:mutators`, not `:extensions`.)

### Macro routing

A macro can put an argument somewhere Mutare's normal treatment of runtime
code would be wrong — a query DSL body, a pattern, a schema field. If all you
need is "leave this macro's arguments alone", the `macro_routes:` key in
`.mutare.exs` does that declaratively with no code (see the README). Implement
`Mutare.MacroRouting` when you're building a reusable adapter for a library:

```elixir
@impl Mutare.MacroRouting
def macro_routes do
  [
    {Ecto.Query, :from, 2, [:expression, :skip]},
    {Ecto.Query, :where, :any, :routing}
  ]
end
```

Each argument gets a *treatment*: `:expression` (mutate normally), `:skip`
(leave raw), `:pattern`/`:binding_pattern` (treat as a pattern),
`:interpolated` (the value is interpolable data — reuse core's mutations on
it, delivered through `^` interpolation), `{:keyword, ...}` (route
keyword *values*, keep keys raw), or `:hosted` (hand the position to a host
mutator — below). The `:routing` sentinel defers to
`route_arguments/2` when the right treatment depends on the call's shape —
`where(q, category: "Foo")` is data, `where(q, [u], u.x == u.y)` is a DSL
fragment.

The first four treatments are also the end-user vocabulary of the declarative
`macro_routes:` config key. The other three are adapter-grade: routing a
position `:interpolated`, `{:keyword, ...}`, or `:hosted` asserts facts about the
DSL that Mutare cannot check, and a wrong assertion has real consequences.
`:interpolated` delivers mutations through `^`: a bare scalar gets a `^`-pinned
selector, and a value the source already pins is descended as plain Elixir. It
is sound only where the DSL genuinely accepts `^` interpolation, and only for
bare values that are scalar (a bare compound is rejected at transform time with
an error rather than left to poison the build — but a DSL that rejects `^`
outright still breaks the single compile, costing a poison-recovery rebuild
that drops those mutants).
`{:keyword, ...}` asserts the argument is a keyword list whose keys are DSL
vocabulary, never data — the treatment list must name exactly one treatment
per pair (a mismatch is an error at transform time), and a non-keyword
argument is left raw with no mutants: silently for a static route (another
call shape may be a legal form of the macro), with a printed warning when a
`:routing` classifier misrouted it (the classifier saw the concrete argument,
so the mismatch is its bug). `:hosted` is a delivery contract, not a hint: it leaves the position
raw and requires an enabled mutator subscribed via `Mutare.Mutator.MacroHost`,
and the run aborts at scan time if none is. That is why these treatments can
only come from here — an adapter written and tested against the library it
describes. A declarative `macro_routes:` entry in `.mutare.exs` that uses one
is rejected with an error; put the route in a module implementing
`Mutare.MacroRouting` instead (a one-module extension is enough). The full
treatment semantics, precedence rules, and the committed compatibility surface
for adapters are in the `Mutare.MacroRouting` docs.

### Hosting mutations inside a DSL

Routing says what core may touch; a **macro host** goes further and emits
mutations *inside* fragments core must leave raw, in whatever form that DSL
accepts. A host is a mutator (it produces mutations, so it's a `:mutators`
entry) implementing `Mutare.Mutator.MacroHost`: `hosted_macros/0` names the
macros it can mutate, and `host/2` receives each resolved call and returns
targets — original fragment, mutants, and a splice function. Routing and
hosting are deliberately separate: one library adapter can describe the DSL
under `:extensions` while several independent host mutators contribute
mutants inside it.

### `use` expansion

Mutare expands `use` calls to learn what they inject — the imports and aliases
that make call resolution work, and the behaviours that behaviour-gated
mutators check. Some `__using__` macros can't be expanded from the outside;
`Mutare.UseExpansion` lets an extension supply the answer directly:

```elixir
@impl Mutare.UseExpansion
def expand_use(Gettext, _args, _context) do
  Mutare.UseExpansion.expand([quote(do: import(Gettext.Macros))])
end

def expand_use(_used, _args, _context), do: :decline
```

Handlers are tried in `:extensions` order; the first non-`:decline` result
wins. A library integration commonly pairs this with `Mutare.MacroRouting` in
one module — recover the injected import so the macro calls resolve, then
route them.
