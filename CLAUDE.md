# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository.

## What this is

Mutare is a **mutation testing tool for Elixir**, built on one bet: **compile once**.
It rewrites a target project's source into a single *metamutant* program that embeds every
mutant behind a `:persistent_term` runtime switch, compiles it once, then runs the suite once
per mutant by flipping `MUTANT_UNDER_TEST`. Read `PHILOSOPHY.md`
(how the project thinks) and `NOTES.md` (the implementation logbook — deferred work, sharp
edges, and the *why* behind non-obvious decisions) before substantial changes; they are
unusually load-bearing and will save you re-deriving things.

## Commands

```
mix test                                        # full suite (subprocess + property soaks included)
mix test --exclude runner --exclude property    # fast loop: skips subprocesses and the property soak
mix test --only property                        # just the transform property soak
mix test test/mutare/transform_test.exs          # a single file
mix test test/mutare/transform_test.exs:42       # a single test (by line)
mix format
mix compile --warnings-as-errors      # CI-style; the project is kept warnings-clean
mix mutare examples/auth              # run the tool against a bundled demo project
mix run script.exs                    # ad-hoc exploration in the lib context (uses MIX_ENV=dev)
```

Tests tagged `@moduletag :runner` (e.g. `runner_test`, `coverage_test`, `mix_task_test`,
`timeout_test`, `poison_test`, `ignore_test`) shell out to real `mix test` subprocesses; tests
tagged `@moduletag :property` (`transform_property_test`, `transform_compile_property_test`,
`transform_baseline_property_test`) are PropCheck soaks that render / compile / run a stream of
generated modules. Both are slow — exclude them while iterating
(`--exclude runner --exclude property`), but run the full suite before committing. `mix run` uses
the `:dev` env, where `test/support/*.ex` fixtures are **not** compiled; those (custom mutator
fixtures) only exist under `MIX_ENV=test`.

## Architecture

The pipeline, in dependency order. A change usually touches one stage; understanding the
contract between them is the whole game.

- **`Mutare.Transform`** — the heart. `source → {metamutant_source, [%Site{}], next_id}`. An
  explicit staged pipeline (analyze → classify → **plan** → assign → emit → render) over a small
  IR, not a walk-everything-then-subtract blacklist. Context is classified *positively* and
  routed; mutators run **once**. The IR splits *vocabulary* (plan structs, owning discovery) from
  *emission* (id assignment, site recording, AST building — kept in `Transform`):
  - **`Transform.Resolve`** — the lexical name-resolution **pre-pass**: one walk over the
    parsed AST that threads a single scoped env and stamps every call with the module it
    refers to, so the call-matching families recognise it. It is the *driver*; the rules live
    in two vocabulary modules (`Aliases`, `Imports`). `alias` and `import` share one scope and
    **interleave** — `import Foo.B; alias A.B; import B` imports two different modules — so they
    must be folded *together*, in source order: one left-to-right fold per statement sequence
    extends both envs (`Aliases.register` + `Imports.register`, the latter resolving its module
    through the alias env in force) and walks each statement under its predecessors' env. Nested
    scopes inherit; a child's additions don't leak. (One walk, not two passes — a second pass
    would rebuild the same alias env to resolve imports.) The same pass also consults the
    **known-macro registry** (`Mutare.Macros`): when a resolved `{module, name, arity}` matches,
    it stamps the call's `meta[:mutare_macro]` with the per-argument routing the analyzer reads
    (`match?`/`destructure`/a registered DSL macro — see `Mutare.Macros` below). For a **piped**
    stage (`x |> macro(...)`) the match uses the *effective* arity (visible + 1) and the piped value's
    treatment (effective position 0, the `|>` LHS) rides on a second `meta[:mutare_macro_piped]` stamp
    so the LHS can reach back to it — see the `:|>` clause below.
  - **`Transform.Aliases`** — the `alias` *vocabulary* (env-building, resolution, stamping,
    reading). `Resolve` folds a scoped alias env (`register/2`) and at each remote call stamps
    the *call-module* `__aliases__` node with the module it resolves to (`stamp_module/2` →
    `meta[:mutare_alias]`, only when it differs from the written path). `resolved_module/2` is
    the reader that recognises an aliased `S.upcase` as `String.upcase` — while the mutator
    still rebuilds from the node's own (aliased) `__aliases__`, so the diff keeps `S.` and the
    swap stays within the module. It also fixes a latent shadow bug: `alias MyApp.Enum` resolves
    `Enum.filter` to the *local* module, so a family no longer wrongly fires on it. `use`-injected
    aliases are invisible without macro expansion.
  - **`Transform.Imports`** — the `import` *vocabulary* (the bare-call counterpart). `Resolve`
    folds the import env (`register/4`) and stamps each *bare-call* node (`stamp/6` →
    `meta[:mutare_import] = {module, :bare | :qualify}`), so a bare `reject(xs, f)` after
    `import Enum` is mutated like `Enum.reject`. Soundness rests on the compiler: any *compiling*
    bare call is unambiguous (import+local same name/arity, dual whole-imports, and Kernel
    shadowing via plain import all error), so resolution needs only a module — not a definition.
    It is strictly **per-arity**, so exported arities are learned by **runtime reflection**
    (`function_exported?`/`macro_exported?`; precise for stdlib, the only modules the families
    target, and conservatively skipped for un-loadable modules). The stamp's `:bare`/`:qualify`
    kind drives the rebuild diff: only a **sole whole import** (with `Kernel` unmanipulated)
    keeps the mutant bare (the swap's sibling is then unambiguously bare-callable to the same
    module); a selective import, *or* a whole import that isn't the only one in scope, qualifies
    it with an **alias-proof** `Elixir.`-prefixed module (`Elixir.Enum.filter(...)`). Qualifying
    fixes two real bugs — a later `alias` rebinding the name can't redirect the call
    (`import Enum, only: [reject: 2]; alias String, as: Enum`), and a second overlapping import
    can't make a bare sibling ambiguous (`import Stream, except: [filter: 2]; import Enum` — bare
    `reject` would be both). The
    **only** way to displace a `Kernel` function is `import Kernel, except:/only:` — tracked as a
    `Kernel` selector, stamping `meta[:mutare_kernel_displaced]` so the bare-`Kernel` families
    (`Numeric`/`CallRemoval`) skip a displaced call. **Erlang atom modules** resolve the same way
    (`import :binary`; `alias :binary, as: B`) — the module key is the atom (`:binary`), reflected
    on identically — so a bare/aliased atom-module call resolves like an Elixir one. Out of scope:
    operator displacement (`import Kernel, except: [+: 2]`); a *non-`use`* macro-injected import is
    invisible (a `use`-injected one is surfaced by `Transform.Uses`, below).
  - **`Transform.Uses`** — the `use`-expansion **pre-pass** (runs before `Resolve`, feeding it).
    Idiomatic Phoenix/Ecto hides directives behind `use`: `use MyAppWeb, :controller` injects a
    bundle, `use Ecto.Schema` injects `import Ecto.Schema` (the `schema`/`field` DSL macros as
    *bare* calls). `annotate/2` walks tracking the enclosing module and, at each **module-level**
    `use` with **static-literal** args, expands it **in-process** (sound because `mix mutare` runs
    with the target's deps on the code path; the Mix task best-effort-compiles the current project
    so first-party `use`s load) and stamps the `import`/`alias`/`require …, as:` it injects onto
    `meta[:mutare_use_directives]` — which `Resolve.register/2` folds in, as if written inline at the
    `use`. Two mechanics: `Macro.expand_once` the inner `Mod.__using__(opts)` call (plain `expand`
    over-expands a nested `use`), and **normalize** each harvested (standard-quoted, bare-atom)
    directive back to Sourceror form (`Sourceror.parse_string!(Macro.to_string(d))`) so the existing
    `Aliases`/`Imports` clauses + live reflection handle it unchanged. The split is in `Harvest`:
    `target/2` alias-resolves the `use`'s module (no opts gate); a **plugin** override (each plugin's
    `c:Mutare.Plugin.expand_use/3`, dispatched by `Plugin.expand_use/4` over the `:plugins` specs threaded
    as `annotate/2`'s 2nd arg) is consulted **first** with a `context` carrying the caller `:module` + the
    plugin's `:opts` and, if it doesn't `:decline`, returns a `Mutare.Plugin.Expansion` whose directives
    are folded directly
    (bypassing `__using__` entirely — neither the static-literal opts gate nor `Code.ensure_loaded?`);
    else `in_process/5` expands as before. The handlers thread all the way through the recursion
    (`in_process → expand_and_collect → collect`), so a `use` **nested** inside an expanded `__using__`
    body is plugin-consulted too — the idiomatic Phoenix `use MyAppWeb, :html` whose body itself does
    `use Gettext, …`, *not* only a directly-written top-level `use`. This is the **positive fix for
    Gettext**: `use Gettext,
    backend: …` injects `import Gettext.Macros` but registers its backend by mutating the caller, so
    in-process expansion *raises* and harvests nothing (and `backend:` isn't a static literal) — a
    plugin returns the `import` so the bare `gettext`/`ngettext` calls resolve and route (see NOTES
    "Plugin `use`-expansion override"). Degrades to a no-op (never
    raises) for a non-loadable/aliased/dynamic-arg `use` or a raising `__using__`; a **declining**
    plugin simply falls through to in-process expansion. But a **misbehaving** plugin — a
    contract-violating return (neither `%Expansion{}` nor `:decline`) **or** a raising/throwing
    `expand_use/3` — raises `Mutare.Plugin.ContractError` *loudly* (a misconfiguration, surfaced like
    a bad `:plugins` entry, not silently dropped: a plugin *bug* fails the run, while a *target*'s
    un-expandable `use` still degrades). The stamp is stripped before render and `use` is already
    non-mutating. `:expand_uses`
    (default on, `--no-expand-uses`) toggles the whole pass — *including* plugin overrides. This is
    the *positive* fix for the Ecto-build-failure /
    missed-controller-mutants pains; see NOTES "`use` expansion". It *also* harvests each
    `@behaviour Foo` the `__using__` body injects (`use GenServer` → `@behaviour GenServer`)
    onto `meta[:mutare_use_behaviours]` (resolved module atoms, read by `Transform.Behaviours`).
  - **`Transform.Behaviours`** — the `@behaviour`-gathering **pre-pass** (runs after `Uses`,
    before `Resolve`). Walks module scopes folding an alias env (reusing `Aliases`), and per
    `defmodule` computes the **behaviour set** — direct `@behaviour Foo` (alias-resolved, so
    `alias X, as: B; @behaviour B` records `X`; Erlang atoms like `@behaviour :gen_statem` kept
    as-is) ∪ `use`-injected behaviours (`Uses.injected_behaviours/1`) — stamping a `MapSet` on
    `meta[:mutare_behaviours]`. `Transform` reads it per module (save/restore, behaviours don't
    inherit) and folds it onto each mutator `Spec` (`enrich_mutators/2`), so a behaviour-aware
    custom mutator gets it via the context map's `:behaviours` key in `mutate/2` and the
    structural callbacks (`return_replacements/2`/`condition_replacements/2`/`pattern_mutations/3`)
    — a GenServer-only mutator, etc. Only canonical `@behaviour` (Elixir rejects `@behavior`);
    `defimpl` bodies see the empty set; `--no-expand-uses` keeps direct behaviours, drops
    use-injected. See NOTES "Behaviour detection".
  - **`Transform.Calls`** — the single `resolved_call/1` reader **every** call-matching family
    (Collection/StringCall/MapKeyword/CollectionArity/ModeSwap/CallRemoval/DefaultDrop/Numeric/
    Integer/Math) uses. It recognises three shapes — an Elixir remote `Mod.fun(args)` (alias-
    resolved), an Erlang remote `:binary.fun(args)`, and a bare import-stamped call — returning a
    uniform `{module, fun, args, rebuild}` where `module` is an Elixir path (`[:Enum]`) or an
    Erlang atom (`:binary`), and `rebuild` keeps the written form (bare/qualified per import kind,
    alias preserved). So a family matches its swap table and calls `rebuild.(new_fun, new_args)`
    without caring whether the call was direct, aliased, or imported, Elixir or Erlang. The lone
    shape it doesn't resolve is a bare `Kernel` call (`abs`/`min`), keyed on effective arity in the
    bare-`Kernel` families' own clauses.
  - **`Transform.Analyze.Captures`** — mutates a `&Mod.fun/N` **reference** capture (a call
    *value*: `&Mod.fun/N ≡ fn a… -> Mod.fun(a…) end`), so the same call families that match a
    written call match the capture. It does **not** re-list their swap tables: it *probes* them —
    synthesize the equivalent N-ary call `Mod.fun(v1…vN)`, offer it through the ordinary
    `Mutator.mutations/3` path, and **re-capture** each mutant (a rename's `Mod'.fun'(v1…vN)` →
    `&Mod'.fun'/N`; a removal's first-arg return → `&Function.identity/1` (N=1) or the arity-N
    projection `fn a, _… -> a end` (N>1); arity-changing / non-recapturable output dropped). So a
    custom CallRemoval-style mutator gets captures for free, and the recapture filter self-selects
    the renames+removals cohort with no allow/deny list. The synth call is a transient probe — the
    emitted selector keeps the **verbatim** capture as its baseline branch (a real external fun, so
    `==`/map-key identity is preserved at mutant 0), each mutant a re-built capture (never an
    eta-expanded `fn`). Remote (`&Mod.fun/N`, alias-resolved) and Erlang (`&:mod.fun/N`) only; a
    bare/local capture (`&reject/2`, `&local/1`) is deferred (no import stamp on a capture ref).
    See NOTES "Capture mutation".
  - **`Transform.ModulePlan`** — a statement sequence classified into items: `{:lift, FunctionPlan}`,
    `{:in_place, clauses}`, `{:statement, node}`. `build/3` does the run-chunking + non-consecutive
    detection; `Transform.emit_module_plan/2` walks the items.
  - **`Transform.FunctionPlan`** — one liftable clause group: signature, clauses, a single shared
    *tagged* clause group, and its typed lifted candidates (guard swaps, head-pattern literal
    swaps, head-pattern **structure** rewrites, **guard removals**, clause drops). `mutated_clause/2`
    reconstructs the
    *single* clause a candidate mutates (plus its index), on demand — emission gates it by id, so a
    mutant touching one clause never copies the rest (the **per-clause** lifting; see "Adding a
    mutator" / NOTES "lifting blowup"). `build_lifted/2` threads one tag counter through guards and
    head-pattern literals, so a `def f(0) when …` lifts both kinds together;
    `build_pattern_structures/2` is a separate (untagged, index-based) pass for the structural
    rewrites, and `build_guard_drops/2` another for guard removals (a clause whose guard the tagger
    finds *inert* — no other family touches it — has its whole `when` stripped, `Candidate.GuardDrop`).
  - **`Transform.{ClauseAST,GuardBuild,LiftedEmit,CaseClauseEmit,ImportWitness}`** — the **pure**
    helpers `Transform`'s stateful emission core calls, so `transform.ex` holds the `Ctx`-threading,
    not the node-building. **`ClauseAST`** is the one home for the `def`/`defp` clause shape and the
    primitives that navigate it (head/args/guards/`when`/`put_*`/`bodiless_header?`/`drop_clause_guard`),
    shared by `Transform` and `FunctionPlan` (the fragile clause-shape invariant matched once).
    **`GuardBuild`** builds the dispatch guards (the `<var> === <id>` gate, the `!==` exclusion,
    `and`-into-`when` distribution, list-combine), shared by the lifted and `case` paths; ids render via
    `AST.literal/1` (clean-meta, formatter-safe). **`LiftedEmit`** is the assembly half of
    `emit_function_plan/2` — the dispatcher + interleaved gated base clauses (`build_dispatcher`,
    `build_base_clauses`, `clause_defaults`, `base_name`, plus the `super`/default plumbing), all
    `Ctx`-free. **`CaseClauseEmit`** is the assembly half of `emit_case_pattern_site/3` — the
    tuple-the-scrutinee `case` clause builders (`mutant_clause`/`original_clause`/`unmatched_clause`/
    `exhaustive_clauses?`). **`ImportWitness`** builds and splices the dead-code import witness
    (`for_candidate`/`wrap`/`prepend`) read off the `Mutare.Transform.Imports` stamp.
  - **`Transform.Tag`** — the shared *replace-by-tag* discovery primitives (`guard_targets/3`,
    `pattern_literal_targets/3`, `replace_tag/3`): walk a guard / pattern, tag every mutatable node
    with a unique `meta[:mutare_tag]`, return the tagged copy + a `{tag, original, [{mutator,
    mutated}]}` per target; a caller materialises one mutant by `replace_tag`. Used by **both**
    `FunctionPlan` (lifted def-clause guards/literals) and `Analyze` (the `case`/`receive`/`fn`
    clause-pattern/guard discovery). The walks keep a remote call's *form* opaque and a bitstring
    spec / keyword-or-map *key* unoffered (the subtleties live here once).
  - **`Transform.Candidate.{InPlace,Lifted,PatternStructure,CaseClause,CasePattern,MatchPattern,MacroPattern,GuardDrop,RescueDrop,Hosted,Return,Drop}`** —
    typed
    candidate variants (one struct per legal kind), replacing the old single struct that redundantly
    stored `context`/`kind`/`operation` and admitted illegal combinations. `Lifted` (a `when`-guard
    operator swap **or** a head-pattern literal swap) tags a node in the shared clause group and
    replaces it in the one gated mutant clause — one struct for both, since the mechanism is identical
    (the head-literal kind is restricted to the literal families).
    `PatternStructure` (a variable swap or duplicate→wildcard in a `def`/`defp` head) spans sibling
    positions / repeated variables that a single tag can't capture, so it is applied by **whole-clause
    replacement by index** (like `Drop`), carrying the mutated head args. `CaseClause` is a `case`
    *clause* pattern/guard mutation (swap/wildcard, a pattern literal, **or** a guard operator),
    delivered **in place** by the **tuple-the-scrutinee** rewrite — the per-clause (C+M) analogue of
    head lifting: the `case` becomes `case {<active>, <subject>} do …` and each mutant adds one gated
    clause before its original (carries the mutant clause's pattern/guard + the clause's raw body).
    `CasePattern` is the same kinds on a `receive`/`fn` clause (neither has a scrutinee to tuple),
    delivered **in place** by the **whole-construct selector** — the whole construct wrapped in a
    selector whose mutant branch is a copy (`replacement`) with one clause's pattern/guard changed
    (C×M, fine for these rare/small constructs). `MatchPattern` is the swap/wildcard families on the
    LHS of a runtime **`=` match in a value-discarded position** (a non-final block statement, a `for`
    qualifier, or a `with` clause): a selector can't wrap the match (its bindings, unlike a `case`
    clause's, *escape* to the enclosing scope), so the bound variables are re-exported through a tuple
    and rebound outside — `{vars} = case rhs do <pat> -> {vars} end`, the pattern hosted in a selector
    (`emit_match_site/3`); the diff still shows just the LHS pattern.
    `MacroPattern` is the same families on the **pattern arg of a binding-escaping known macro**
    (`destructure([x, y], v)`, declared `:binding_pattern`) in a value-discarded statement/`with`
    clause — the `MatchPattern` mechanism generalized from a `=` to running the macro itself inside
    each selector branch (`{x, y} = case <sel> do <id> -> destructure(<mut>, v); {x, y} … end`,
    `emit_macro_pattern_site/3`); both the direct and piped (`[x, y] |> destructure(v)`) forms route.
    `GuardDrop` is a **lifted** `def`/`defp` guard removal (the tag-less twin of `Lifted`/`Drop`:
    `mutated_clause/2` strips the clause's whole `when`); `case`/`receive`/`fn` guard removals need
    no new variant — they're a `CaseClause` with a `nil` mutant guard / a `CasePattern` whose
    `replacement` is the guard-stripped construct. The matching `Site` constructor is chosen by
    pattern-matching the variant at emit
    (`Lifted`/`PatternStructure`/`GuardDrop` → `Site.lifted_replace/6`;
    `InPlace`/`Return`/`CaseClause`/`CasePattern`/`MatchPattern`/`MacroPattern`
    → `Site.in_place/6` family — guard removals reuse it with `original` the `{:when, …}` head and
    `mutated` the bare head, so the diff drops just the ` when g`). The `case` tuple-the-scrutinee
    rewrite has its own emit
    (`emit_case_pattern_site/3`, reusing the lifting gates `exclusion_guard`/`and_into_guard`); for
    the others the selector branch is chosen by `branch_node/1`. The structural discovery primitives
    shared by the def-head, `case`, `receive`/`fn`, and `=`-match paths live in
    `Transform.PatternStructure` (`mutators/1`, `used_names/1`, `bound_var_names/1`, `node_mutations/3`).
    `Candidate.Hosted` is the **selector-host** delivery for a `:hosted` macro argument (a fragment
    inside a compile-time DSL — `Ecto.from`/`where`): the registering mutator's `host/2` supplies
    `{logical original, [logical mutants]}` + `wrap`/`splice`, and core builds the id-gated selector,
    records one `Site.in_place/6` per mutant (the diff is the fragment swap, the `wrap`/`splice`
    scaffolding invisible), and weaves it in via the target's `splice` — a third emit
    (`emit_hosted_site/3`, under the `:mutare_hosted` meta key) alongside `:mutare`/`:mutare_case`. It
    owns *none* of the mutation logic (the fragment has foreign — SQL — semantics core can't vouch
    for); see NOTES "the selector host".
  - **analyze + classify (`analyze/3`)** is a single context-threaded recursive descent: it
    *names the context* of each position as it descends (routing is positional — the spec side of
    a `::` goes one way, the value side another, which a flat `Macro.traverse` accumulator can't
    express) and attaches a typed `Candidate.InPlace` to each mutatable node's *own metadata*
    (`meta[:mutare]`) — which is why there's no fragile `{line, column}` node identity and no
    double mutator invocation. Three contexts are threaded: `:runtime` → in-place (`:guard`/
    `:clause_drop`, and a **`def`/`defp` head-pattern literal**, are produced by the separate lift
    path), `:pattern` (don't mutate *in place*, but keep descending so default-arg values and
    `size()` args are still reached), and `:scaffold` — a module-level `for`/`if`/`unless`/… that
    *defines* functions via compile-time metaprogramming (entered by `transform_statement/2` when
    `metaprogrammed_def?/1` finds a nested `def`). Like `:pattern` it never mutates in place (a
    module body runs **once**, at compile time, with mutant 0 — so a selector on the `for` generator
    / `if` condition / unquoted head pattern could never activate, only adding inert no-coverage
    noise), but the one runtime escape it reaches is a generated `def`/`defp` **body** (the def
    clause flips it back to `:runtime`); `body_context/1` propagates `:scaffold` through nested
    scaffolds and `case`/`cond`/… arms. The *mixed* case (a function with both a normal head and
    metaprogrammed heads, e.g. plug's `code/1`) falls out for free — the top head goes in-place via
    `metaprogrammed_def_names`, the `for` heads via `:scaffold`, both bodies mutating independently
    (no lifting ⇒ no dispatcher ⇒ no shadowing). Pattern routing covers
    not just `def` heads and `=`/`<<>>` but every match position: a `<-` generator LHS, the
    LHS of a `case`/`fn`/`receive`/`with`/`for`/`try` `->` clause (generic `->` clause), and the
    pattern argument of a **known macro** (`match?`/`destructure`, or a user-registered one) —
    routed in the generic runtime clause off the `meta[:mutare_macro]` stamp, so a literal there
    isn't mutated in place (splicing a `case` into a pattern), with
    **`cond` excepted** (its `->` LHS is a runtime condition, kept mutatable — `analyze_cond_block/3`).
    The runtime `if`/`unless` clause and `analyze_cond_clause` route their **condition** through
    `analyze_condition/2`, which appends the IfCondition `true`/`false` pair (`attach_if_condition/3`
    — only when live, i.e. `:runtime`, never `:scaffold`), so the same selector hosts both that and
    any operator swap already on the condition node. But a binding made *in* the condition
    (`(name = lookup()) != nil -> use(name)`) **escapes** into the clause body, and the in-place
    selector is a `case` — wrapping the condition would scope `name` to a branch, leaving the body's
    reference unbound (a hard compile error, *independent of the active mutant*: every branch,
    including the unmutated catch-all, binds inside the `case`). So `analyze_condition/2` runs
    `prune_binding_ancestors/1` over the analyzed condition, stripping the in-place candidate from
    every node that is a *proper ancestor* of an escaping `=` (the nodes whose selector would trap
    it) while a binding-free sibling sub-expression still mutates and the body mutates normally; and
    IfCondition (which wraps the *whole* condition) is skipped when any binding escapes within it.
    Binding-isolating forms (`fn`/`for`/`with`/`try`/`quote`) stop the taint — a `=` scoped inside a
    closure never reaches the body, so the surrounding condition still mutates. (IfCondition's own
    `condition_replacements/1` already declines a *top-level* `=`; the prune is the cross-mutator
    generalization for a binding nested under an operator/call, where Conditional/Relational would
    otherwise wrap it.)
    Pruning is `cond`'s only option (its clauses short-circuit in order, so a clause's binding can't be
    lifted out without changing *when* it runs), but an `if`/`unless` condition is evaluated **once and
    unconditionally**, so the if/unless clause instead **hoists** a hoistable binding (`hoist_if?/2` +
    `hoist_if/6`): the `if` becomes a `__block__` that lifts the binding into a preceding statement and
    lets the now-binding-free condition carry the IfCondition decision without trapping anything —
    `if (name = f()) != nil do use(name) …` → `name = f(); if (sel: true/false/name != nil) do
    use(name) …` (a refutable `{:ok, v} = f()` binds the match value to a temp first, `mutare_cond =
    f(); {:ok, v} = mutare_cond; if … mutare_cond …`, keeping `MatchError` semantics; the temp is a
    `Names.hoist_placeholder/0` until emit substitutes the salted `cond_var`). The decision `Site`
    references the **original** condition (range and code), so the diff stays faithful
    (`(name = f()) != nil` → `true`). Scope (each a soundness/fidelity guard, the rest staying on the
    prune path): only when *every* escaping binding is on the unconditional **spine** (not under a
    short-circuit `and`/`or`/`&&`/`||` right operand, nor inside a nested `case`/`cond`/`if`), no
    binding reordered past a side-effecting sibling (`spine_reorders?/1` — a binding hoists to before
    the whole `if`, so an impure expression evaluated *before* it, `check(s) == (x = f())`, would be
    reordered *after* it, diverging the baseline; the common shapes evaluate their binding first and
    are fine), at most
    one **refutable** spine binding (bare-variable ones reuse their own name; a refutable one needs the
    lone temp), and IfCondition enabled (it owns the delivered decision). Only the decision is
    recovered — an operator swap on a binding-ancestor node (`Relational` on the `!=`) stays pruned (its
    mutant would still embed the binding); the hoisted EXPR mutates in its lifted statement, and safe
    siblings and the body mutate as always. The `__block__` renders, compiles, and leaks the binding
    exactly like the original `if` in every position (statement, expression RHS, call argument).
    A `case`/`receive`/`fn` clause's pattern (and guard) stays unmutated *in place* in the ordinary
    descent but is **additionally** offered — to the structural pattern families (swap/wildcard), the
    literal families, and (for the guard) the guard families — by dedicated analyze clauses. For a
    **`case`** the clause is mutated **per clause** via *tuple-the-scrutinee*: `case_clause_candidates`
    attaches `Candidate.CaseClause`s under the `meta[:mutare_case]` key (literals/guards via
    `Transform.Tag`, structure via `PatternStructure`), and `emit_case_pattern_site/3` rewrites the
    `case` to `case {<active>, <subject>} do …`. For **`receive`/`fn`** (no scrutinee to tuple) the
    whole construct is wrapped in a selector — `attach_clause_pattern_candidates/4` (parameterized by
    the construct's clause list + a rebuild closure) attaches a `Candidate.CasePattern` whose mutant
    branch is a full copy with one clause's pattern/guard changed. (The `<-` generator/clause LHS and
    `with`/`try` `else` clause patterns are still deferred — routed to `:pattern`, unmutated.)
    A **value-discarded `=` match** is *also* offered those families on its LHS via
    `analyze_statement/2` (→ `attach_match_pattern_candidates/4`, attaching a `Candidate.MatchPattern`),
    routed from three positions: a runtime block's **non-final statements** (`analyze`'s `:__block__`
    clause), a **`for` qualifier** (`analyze_for_arg/2`), and a **`with` clause** (the `:with` clause).
    In all three the match's value is discarded (only its bindings matter, and they escape to later
    statements/clauses), so re-exporting the bindings through a tuple is value-transparent. A *trailing*
    block match (the block's value) is left a plain `=`; so is a `<-` generator/clause LHS (deferred).
    A **binding-escaping known macro** call (`destructure([x, y], v)`, declared `:binding_pattern`)
    gets the *same* treatment on its pattern arg (`Candidate.MacroPattern` — the `=` mechanism with the
    macro run inside each branch), but only in the **block-statement** and **`with`-clause** positions:
    a `for` qualifier is excluded (`analyze_match_statement/2` routes only `=` there) because a bare
    macro call as a qualifier is a *filter* (truthiness selects iterations) — rewriting it to a binding
    would silently drop the filter. The directly-written and **piped** (`[x, y] |> destructure(v)`, the
    LHS is effective arg 0) forms both route (`binding_pattern_macro/1`).
    A dedicated **`:|>` clause** routes a pipe's RHS through `analyze_pipe_stage/2`, which offers the
    stage to mutators with `%{pipe_mode: :piped}` (everywhere else defaults to `%{pipe_mode: :unpiped}`): a pipe
    stage's node carries one fewer arg than the source reads (the piped value is the `|>` LHS, not in
    the call), so an arity-changing mutator (CollectionArity, via the optional `mutate/2` callback)
    needs the flag to recover the *effective* arity. The mutated stage is a plain `Candidate.InPlace`,
    so the existing selector + `hoist_pipe` path delivers it unchanged. The `|>` **LHS** is normally
    ordinary runtime, but when the RHS is a **known macro** the piped value is that macro's effective
    argument 0 and reaches back to position 0's treatment (`analyze_piped_value/3`, off a separate
    `meta[:mutare_macro_piped]` stamp `Resolve` records for a non-`:expression` head): `1 |> match?(1)`
    pipes its LHS into match?'s **pattern** position, and a `:skip` macro may accept a LHS that is
    neither a valid expression nor a valid pattern — so the LHS goes through the *same*
    `route_macro_arg/3` as a visible arg (treated exactly as if written as the macro's first argument),
    never wrapping a pattern/opaque value in a selector (which would poison).
    Orthogonally, a **data** keyword/map key *is* mutatable: the 2-tuple pair clause skips only a
    **block key** (`do:`/`else:`/`rescue:`/`catch:`/`after:`, `block_key?/1` on `@block_keys`) — a
    selector spliced into a `do:` key is malformed and wouldn't render — but a `%{a: 1}` / `[a: 1]`
    keyword-shorthand key descends like its arrow/tuple twin (`%{:a => 1}` / `[{:a, 1}]`), which
    always mutated; syntax sugar no longer hides it. Sourceror re-renders the spliced selector as an
    arrow (`%{(sel) => v}`) or tuple (`[{(sel), v}]`) automatically, so the `format: :keyword` marker
    on the original key is harmless. The two **compile-constrained** key positions are excluded
    positively by their own clauses, *before* the pair clause: a `%Struct{…}` field key
    (`analyze_struct_field/3`, covering the `%S{m | f: v}` update form too — a wrong field name is a
    compile error) and a `for` special-form option key (`into:`/`uniq:`/`reduce:`, in
    `analyze_for_arg/2` — `unsupported option … given to for`). Other unknown DSL keyword options
    (e.g. an Ecto `field …, default: x` inside a macro `do` block) are left to the **poison backstop**
    if the macro rejects a mutated key — consistent with how the unknown is handled everywhere.
    The key of a keyword list passed as a *call's final argument* (`foo(x, timeout: 5)` →
    `timeout:`, the trailing-keyword sugar) is a **per-mutator opt-out**: `recurse_runtime/2` knows
    the call context, so it tags those key candidates `call_option_key?` (via `CallOptions.mark/1`,
    `call_form?/1` distinguishing a real call from a `%{}`/tuple by `@non_call_forms`). A mutator
    configured `{Module, call_option_keys: false}` (the `Mutare.Mutator.Spec` opts mechanism)
    suppresses *its own* tagged candidates: `Transform.gate_candidates/1` reads each candidate's own
    `Spec.opts` and drops it — *before* id assignment, so it leaves no id/site (ids stay contiguous;
    the mutator list is constant within a run, so poison rebuilds stay stable). On by default (mutate);
    the value still mutates regardless, and a *standalone* `%{a: 1}` / `[a: 1]` literal is unaffected
    (not a call argument). Per-mutator: `{Mutare.Mutators.AtomLiteral, call_option_keys: false}` stops
    atom keys, while another family's keys (an integer key → `Literal`) are untouched.
    Similarly a `%Struct{…}`'s inner `%{}` is descended for its field *values* but the `%{}` wrapper
    itself is not offered, so MapLiteral can't empty a struct (which would drop required fields). A
    module alias is mutatable only as a *value*: the module side of a remote call (`Foo.bar()`) sits
    in the call's `{:., …}` *form* position, which the descent treats as opaque (so it is never
    reached — same as `:erlang.foo()`), and `defimpl`/`defprotocol`/`defdelegate` module references
    are pruned (a `defimpl` body still mutates) — so AliasLiteral hits `apply(Foo, …)` but not a
    call/struct/impl name. The rest are recognised
    and pruned by dedicated clauses: `:compile_time` (module-attribute values like `@x 1 + 2`,
    `defmacro`/`defmacrop` bodies, `quote` blocks, **and** `import`/`alias`/`require`/`use`
    directives whose args must be compile-time literals — frozen at compile/expansion time, so a
    selector there is inert, or in a directive arg like `import …, only: [f: 1]` / a quoted
    pattern outright illegal), `:spec` (a bitstring type
    specifier — separators/`unit()`/type atoms excluded, but
    `size(expr)` args recursed; `analyze_spec/3`), and `:capture_arity` (the `/` in `&fun/arity`
    is an arity separator, not division — never mutated; the *reference* `&Mod.fun/N` it sits in
    is offered to the call families by `Transform.Analyze.Captures`, below). A `<<…>>` node is itself offered in a runtime body (so
    BitstringLiteral can collapse it to `<<>>`) while its segments still descend; a **sigil**
    (`~r`/`~D`/`~w`/custom, `sigil?/1`) is offered as a whole, then descended *surgically*
    (`descend_sigil/2`): its content `<<>>` **segments** are analyzed — so an interpolated
    expression `~r/a#{b}c/` still mutates `b` — but the content `<<>>` **wrapper** is never offered
    (collapsing it, or splicing a selector into sigil content, would be illegal).
  - **assign + emit (`emit/2`)** is a bottom-up `Macro.postwalk` so ids are assigned in
    post-order DFS; the id counter advances even for `:skip_ids` (poison recovery relies on it).
  - **redundant-leaf overlap (`Transform.Overlap`)** runs once at the top of `emit/2`,
    *before* id assignment (so a dropped candidate leaves no id/site and ids stay contiguous —
    the cross-node sibling of the per-node `gate_candidates/1` self-opt-out, which it deliberately
    stays separate from). It drops a leaf mutation a call-rewriting mutator already covers
    (AtomLiteral on a ModeSwap unit/key), **derived from the mutation itself**: a candidate's
    *footprint* is the minimal changed subtree between its `original` and `mutated` (a
    meta-insensitive lockstep diff); one whose footprint is a proper descendant of its host (a
    call rewrite touching one descendant) is *covering*, and any non-covering candidate whose host
    node *is* a covering footprint is pruned. "Same node" is matched by a stable per-node identity
    token `meta[:mutare_nid]` — stamped on every metadata-bearing node by `Transform.Resolve`'s
    pre-pass (`stamp_nids/1`, a DFS counter), *before* `analyze` annotates, so a leaf candidate's
    host and the call rewrite's footprint subtree (drawn from the same `original`) carry the
    matching nid; `Resolve.nid/1` reads it. Injective by construction (distinct nodes → distinct
    nids), node-granular (so an excluded `shift` key like `microsecond:` keeps its leaf mutant,
    consistently), zero-API (it replaced the old `owned_args/2` callback + `:owned` context, which
    drifted from `mutate/2` and could only speak in argument *positions* — see NOTES "Overlap
    resolution"). Scoped to `Candidate.InPlace`; ModeSwap is never lifted, so no other candidate
    kind is touched. A footprint is covering only for a genuine **single-node substitution**: the
    changed subtree must carry a nid (a *proper, nid-bearing descendant*) — and **bare atoms and
    lists carry no metadata, so no nid**, which is exactly why operator swaps / function renames
    (changed node a bare `:+`/`fun` atom), arity drops, and operand permutations (changed subtree
    the argument *list*) are all non-covering for free, with no special cases. This nid-identity
    *replaced* an earlier `Sourceror`-range proxy that needed a three-rule denylist
    (rangeable / proper-sub-range / non-list) plus two unproven Sourceror invariants, because
    `get_range/1` is **not injective** (`[a, b]` ≡ `a - b`; `[0]` ≡ `0`) — see NOTES "node
    identity, not range" for why a range collision risked a *false prune* (a silently missing
    mutant). Net: ModeSwap is the only covering mutator that drops anything (the direct
    `String.equivalent?/2` → `==` rewrite is covering-but-inert — its `.`-node nid matches no
    candidate), so the prune runs only on subtrees with a mode/unit swap or that rewrite.
  - **in-place selector** for body expressions: wrap the operator in a tail-position
    `case <subject> do <id> -> mutated; <var> -> <record>; original end`. The `<subject>` is the
    **hoisted active-id read** (`Transform.selector_subject/1`): when `mutare_active` is already bound
    in scope (`Ctx.active_bound`) the subject is the bare variable — read once per function activation
    and reused — else the self-contained `:persistent_term.get(:mutare_active, 0)`. It is bound in two
    places, set by the head/body-split clause emitter (`emit_clause/3`): a **lifted base clause** (the
    dispatcher threads it as the first parameter, in scope in the whole body) and a **non-lifted
    function's `:do` block** (a once-per-call prologue `mutare_active = :persistent_term.get(...)`,
    added only when the block splices a hoisted selector — else it would warn unused). A head's
    **default values** keep the inline read (they run in a generated head clause `f() → f(<default>)`,
    out of any binding's scope — lifted defaults also ride onto the dispatcher head, the same
    out-of-scope spot), as do a non-lifted clause's `rescue`/`catch`/`else`/`after` blocks (siblings of
    `:do`, not inside its prologue's scope), module-level / `:scaffold` selectors (no function-emit
    hook; baseline-only), and a selector inside a **runtime `defmodule`** in a function body — a new
    module scope whose inner `def` can't see the outer binding (`emit/2` tracks `Ctx.module_depth` as
    a `Macro.traverse` descends a `defmodule`/`defimpl`/`defprotocol`, gating the hoisted form on
    depth 0; `references_var?/2` likewise prunes those subtrees so the outer prologue isn't added for
    a reference that lives in the nested module). The head/body split preserves id ordering, so Sites/coverage/poison ids are
    unchanged. The active id is process-constant (`:persistent_term`, write-once per run), so the
    hoisted read is semantically identical and a win on compile *and* runtime — see NOTES "Hoist the
    per-site active-id read". One
    illegal spot for that `case`: the RHS of a pipe (`x |> case … end` parses but won't compile —
    `|>` can't pipe into a `case`), so when the mutated node is a **pipe stage** emission lifts the
    selector out of the pipe into a **one-shot closure on the piped value** (`hoist_pipe/2`, run on
    the parent `|>` in the same postwalk *and* on `emit_site`'s default for a tail pipe that also
    carries a ReturnValue): `lhs |> (fn <piped_var> -> case … (each branch pipes `<piped_var>`) …
    end).()`. The piped value is computed **once** (it stays the pipe's LHS) and bound to the closure
    param, so a chain of mutated stages renders **linear** in depth — distributing `lhs` into every
    branch (the earlier form) copied the whole upstream chain per branch and blew up as
    ≈`(mutants+1)^depth`. `<piped_var>` is salted per file (`Ctx.piped_var`, like `active_var`) so a
    stage arg of the same name isn't captured; `(fn … end).()` is itself a valid pipe LHS, so chains
    nest. The Site keeps the bare stage, so the diff is unchanged.
  - **function lifting + dispatcher** for `when` guards, **head-pattern literals**, **head-pattern
    structure rewrites** (variable swap / duplicate→wildcard), and clause structure (a `case` can't
    live in a guard or a pattern): the clause group becomes **one** private function `__mutare_…_g<n>`
    that takes the active id as an extra first arg (`mutare_active` — per-file, collision-free; see the
    invariants below), and the public `f/arity` becomes a dispatcher that reads the id and tail-calls
    it. Each source clause is emitted **once** (gated
    `when mutare_active !== <id>` for the mutants that override/drop it, carrying the in-place body
    selectors); each mutant is a **single** clause gated `when mutare_active === <id> …`, placed
    before the original — so a mutant touching one clause never copies the others (`C+M` clauses, not
    `C×M`; the per-clause lifting, NOTES "lifting blowup"). The dispatcher body carries the coverage
    record (it used to live in the old dispatcher `case`'s catch-all). Guard *and* head-literal
    targets are tagged via `meta[:mutare_tag]` on a single shared clause group held by the
    `FunctionPlan`; `FunctionPlan.mutated_clause/2` materializes the one affected clause (+ index) on
    demand. A head pattern admits **only literal-valued mutations** for the literal families
    (`tag_pattern_targets/3` offers a node to the mutators iff it is a scalar literal and keeps a
    mutation iff its replacement is too — so the mutant clause is always a legal pattern; specs and
    keyword/map *keys* are skipped). Invariants the lifting relies on: a lifted clause keeps its
    **source `meta`** (so Sourceror doesn't assign stale lines to the `[]`-meta selector ids in its
    body); every generated integer id is clean-meta `{:__block__, [], [n]}` (a bare int gets a `:line`
    but no `:token` and crashes the formatter); and the dispatch variable is **per-file collision-free**
    — `generated_names/1` salts `mutare_active` → `mutare_active_0`, … (and the `__mutare_` prefix) away
    from any identifier the source uses, since a source variable named `mutare_active` in a lifted
    function would otherwise be silently captured by the gated head (`def f(mutare_active, mutare_active)`
    is a legal equality match — wrong dispatch, no error). `Mutare.Coverage.Recorder` owns the canonical
    name + the `catch_all_pattern/1`·`record_ast/2` builders that take it.
    Both sides of a `%{1 => 2}` map pattern mutate. The **structure** rewrites (`PatternSwap`,
    `PatternWildcard`) are pattern-legal by construction and applied by whole-clause replacement, not
    tagging. **Default args** (`def f(a, b \\ 1, c, d \\ 2)`) are lifted too: the `\\` defaults ride
    on the public dispatcher (the only place a `\\` is legal — so the function's whole arity range
    still resolves), whose body forwards the *resolved* args to the base at full arity; the base
    clauses strip `\\` to bare patterns (`clause_parts`). A default *value* stays a runtime in-place
    position (its selector lifted off the emitted clause by `clause_defaults/1`, firing only on the
    defaulted call path); a default cannot reference another arg (isolated scope), so renaming the
    dispatcher's args to `mutare_arg_i` never breaks it. A bodiless **header** (`def f(a, b \\ 1)`
    before the real clauses) supplies the dispatcher's defaults but is not a base clause
    (`bodiless_header?/1` skips it). Head literals under a `\\` lift (`tag_pattern_targets/3` descends
    the `\\`'s pattern, keeps the default raw); pattern structures strip-then-reattach the `\\`. Only
    operator-named and non-consecutive/metaprogrammed groups still fall back to in-place (see NOTES
    "Default arguments are lifted").
    **`super`** is legal only inside the overriding function, so a `super` in a lifted body would not
    compile in the relocated base `defp`. `Mutare.Transform.Super` keeps the rewrite local: when a
    lifted clause *body* calls `super` (`Super.in_clauses?/1`), the dispatcher — which keeps the
    original name and *is* the override, where `super` is legal even in a closure — binds
    `mutare_super = fn a1, …, aN -> super(a1, …, aN) end` (one fixed-arity closure: `super`'s only
    legal arity is the full param count, the signature arity, defaults included) and threads it to the
    base as its second arg; each `super(args)` becomes `mutare_super.(args)` (`Super.rewrite/2`). Off
    unless a body actually calls `super`, so the common path is unchanged. A base clause with no
    `super` of its own still takes the shared param but names it `_mutare_super` (no unused warning);
    `mutare_super` is salted per-file like `mutare_active` (`Names.salted/2`); a `super` inside `quote`
    is quoted *data* and left untouched (the body reads as super-free, lifts without a closure),
    mirroring the analyzer's `:compile_time` quote handling. In-place (non-lifted) functions keep their
    name, so their `super` needs nothing (see NOTES "`super` in a lifted body").
- **`Mutare.Schema`** — runs `Transform` across discovered files, threading **globally-unique,
  stable** mutant ids. `from_files/4` is a **two-phase parallel build**, because the ids baked into
  each metamutant's selectors mean concurrent files can't thread `next_id` sequentially: **(1)
  count** — `Transform.count_string/2` per file in parallel (the same analyze → plan → emit pipeline
  but skipping the dominant final render), so each file's mutant count is known *id-free*; **(2)
  render** — prefix-sum the counts to hand each sited file its `:start_id` up front, then
  `Transform.transform_string/2` each file in parallel. The count is **drift-proof** — it comes from
  the *same* id-claiming path (`SelectorEmit.claim_item/4`) emission uses, so it equals a render's
  `next_id - start_id`; `render_one/5` re-checks and crashes loudly on any drift (cross-file id
  stability depends on it). Both passes run in **throwaway workers** (`Task.async_stream`, concurrency
  `System.schedulers_online/0` — independent of the runner's `:workers`), so each file's heavy
  short-lived ASTs die with its worker instead of inflating the scan's loop heap (the heap-isolation
  the old single-`Task.async`/`await` gave, now *plus* parallelism — see NOTES "Scan is
  transform-bound"). The let-it-crash contract is preserved per worker: an unparseable source is a
  skipped file (`:skipped`), any other exception is captured + **re-raised faithfully** in the parent
  (original type + trace, not an opaque `Task` exit). `:on_scan` fires once per file, in input order,
  with the running mutant tally (discovered in the count pass). Honors `:paths`/`:exclude`,
  `:only_files` (for `--since`), `:only_lines`
  (for `--line`: keep only the sites on the named `file:line`s, *and* prune discovery to those
  files so the one compile stays small — a narrow rerun; applied inside `from_files/4` like
  `:max_mutants`, so a poison rebuild reapplies it), `:max_mutants` (cap to the first N sites), and
  `:skip_ids`
  (for poison recovery — the id counter advances even for skipped ids, so ids stay stable across
  rebuilds; this stability is relied upon; the count pass is `:skip_ids`-independent, since a skipped
  id still advances the counter). Per mutated file it stores the **rendered metamutant
  source** (`:metamutants`); the `Mutare.Manifest` is *not* precomputed — it is built lazily by
  Poison only on a failed compile (rare).
- **`Mutare.Manifest`** — the per-file, per-mutant map of *where each mutant lives in its
  rendered metamutant*: the full **generated line ranges** (selector clause bodies, lifted mutant
  clauses gated `when mutare_active === <id>`, the **tupled-`case` mutant clauses** `{mutare_active,
  <pat>} when mutare_active === <id>` — whole-clause, since the mutated pattern/guard lives in the
  head — and a whole-`case` fallback) that **Poison** maps a compile error back to a mutant id with.
  Built **lazily** by `Poison` from the stored metamutant, via the fast `Code.string_to_quoted!`
  parse (not `Sourceror.parse_string!` — same token metadata `get_range/1` reads, far faster on a big
  file). `Mutare.Metamutant` owns the selector-subject AST and the `subject?/2` / `pattern_subject?/2`
  recognizers this walk uses (the latter spots a tuple-the-scrutinee `case`). Because the active-id
  read is **hoisted** (a body selector's subject is the bare `mutare_active` variable, not the inline
  `:persistent_term.get`), the recognizers are **var-aware**: `Manifest.active_var/1` recovers the
  per-file (possibly salted) dispatch name once — off the first generated `<var> = :persistent_term.get`
  binding (a dispatcher's or a non-lifted `:do`-block prologue's) or a tupled-`case` `{<var>, <pat>}`
  pattern — and threads it into **both** the subject recognizers and the gate matcher (`gate_id/2`), so a
  hoisted selector is recognised and a user `case` never is (the dispatch name is salted away from every
  source identifier, so it can't equal a user scrutinee). (Coverage no longer
  lives here — the metamutant self-records it at runtime, keyed by mutant id, so there is no
  `{module, line}` location to precompute.)
- **`Mutare.Sandbox`** — workspace materialization. Copies the target project to a temp dir and
  overwrites the metamutant sources. Injects a **dependency-free bootstrap** into `test_helper.exs`:
  reads `MUTANT_UNDER_TEST` into `:persistent_term`, plus a portable timeout watcher that
  `System.halt/1`s the run itself after the cap (no killing an OS process tree). Also writes the
  dependency-free `MutareCov` coverage helper (`lib/mutare_cov.ex`) and appends the coverage
  bootstrap *after* `ExUnit.start/0` (it registers an `after_suite` dump) — both inert unless the
  probe sets `MUTARE_COVERAGE` (see `Mutare.Coverage.Recorder`). Two materialisation modes:
  **fresh** (default — wipe & re-copy a throwaway dir, recompile cold) and **kept**
  (`:keep_sandbox`/`--keep-sandbox` — preserve the sandbox *and its `_build`* between runs and
  re-materialise via `sync/3`: rewrite a file only when its bytes change so unchanged files keep
  their mtime and mix's incremental compiler reuses `_build`; prune what's gone; never touch
  `@excluded` dirs). For CI build caching; see `NOTES.md` for the cache pattern. Either mode then
  **seeds the dependencies' compiled `_build`** (`Sandbox.Seed.dep_build/2`): `@excluded` keeps `_build`
  out of the copy, so a fresh sandbox would otherwise recompile *every* test-env dep cold each run
  (the deps are byte-identical to what the user already built — pure waste, often dominating the
  one `mix compile`). It copies each `deps/`-named dir's `_build/test/lib/<dep>` (deps only —
  *never* the mutated app, whose own beam must recompile from the metamutant, not silently win),
  idempotently (skips deps already present, so a kept `_build` is untouched) and best-effort (a
  dev-only or never-test-compiled dep is simply absent). See `NOTES.md` "Seed the deps' `_build`".
  When a run rewrites only some files it *also* seeds the **mutated app's own** `_build`
  (`Sandbox.Seed.app_build/4`), so the one compile rebuilds only the metamutant file(s) — not the whole
  (possibly huge) app — the first-run experience when someone aims Mutare at a single module. The
  app build can't be seeded as-is for two reasons: mix gates app-source staleness on a manifest
  that embeds the **absolute project root** (transplanted, every source looks stale → cold compile),
  and seeding an app's *original* beam could silently win over the metamutant (a no-op that scores
  everything killed). So it (1) **relocates the manifest** — rewrites the recorded root (the bare
  root *and* root-prefixed paths) to the sandbox via a structure-agnostic walk over the public
  `binary_to_term` form (never the manifest's private layout), `File.write!` restamping it "now" so
  unchanged copies aren't stale — and (2) **deletes each metamutant's beam** (identified by
  `:beam_lib`'s recorded `compile_info[:source]`), the structural no-op guard: a beamless module
  *must* recompile from the only source present, the metamutant. **Fail-safe by construction:** the
  seed is kept only if *every* metamutant's beam was found and deleted (else `teardown/1` reverts to
  today's cold compile), so a bug here loses the speed-up, never the score. **Gated on the outcome,
  not the flag** (`worth_seeding?/2`): seed when the metamutant files are a small fraction
  (≤ `@seed_app_build_max_fraction`) of the app's compiled modules, read from `metamutants` vs a
  cheap beam-name listing — so `--only`/`--line`/`--since`/a `paths:` narrowing (and a sparse-site
  full run) are all covered with no scoping mechanism to forget, and a run touching most of the app
  is declined (copy + scan would outweigh the saving). Idempotent like the dep seed, beams left
  un-rewritten (real stacktraces, no staleness impact). **`--no-seed-app-build`**
  (`:seed_app_build` false, default true) opts out wholesale — forcing a cold compile — as a
  diagnostic A/B for the no-op surface or for a paranoid CI. See `NOTES.md` "Seed the
  mutated app's `_build`".
- **`Mutare.Sandbox.Command`** — the *run side* of the **exit-code contract** and the one entry
  point that runs a mutant and hands back a typed `Mutare.Sandbox.Command.Result`. (What was once
  one god-module is now four by responsibility: this decodes, `Command.Invocation` runs,
  `Command.Output` parses output, `Mutare.Sandbox.CompilerOptions` carries the compile-speed env —
  the three below.) `timed_test/4` builds the kill-detection argv (`test_argv/1`), runs it via
  `Command.Invocation.timed_mix/5`, and decodes the result via `outcome/2`: `0`→`:passed`,
  `failure_exit/0`→`:failed`, `timeout_exit/0`→`:timeout`, anything else→`:harness_error` (the total
  *exit-code* decoder is `outcome/1`). `outcome/2` refines the otherwise-`:harness_error` case with
  the run's *output* (via the `Command.Output` discriminators) — the *only* place the contract reads
  output to form a *verdict* — recovering two **detected**-mutant cases: (1) a mutation that breaks
  the **test suite's** own compilation (it ran at the test modules' compile time — exit `1` with a
  `.exs`-under-`test/` compile-error banner, `Output.suite_compile_error?/1`) is `:suite_compile_error`
  (justified because the lib compiles **once**, so a fresh per-mutant compile error can only be a
  re-evaluated test script the mutation broke); (2) a mutation that mints **unbounded atoms** crashes
  the BEAM when the atom table fills (the VM-abort banner `Output.atom_exhausted?/1`) — a
  resource-divergence like a timeout (the VM dies before the in-process watcher can self-halt
  cleanly), so `:atom_exhausted`. The runner counts **both** as kills; a real infra/lib compile error
  / missing dep / other crash stays `:harness_error` (fail safe). A **third** refinement,
  `:boot_failure` (`Output.boot_failure?/1` — the sandbox node died **during boot** with its own
  diagnostic erased by a secondary `:standard_error` failure, requiring *both* the `terminating during
  boot` and `standard_error` markers), does **not** change the verdict — it stays a harness error out
  of the score — but *names a known-transient contention cause* (kills take precedence in the `cond`),
  so `Mutare.Runner` messages it actionably (the real cause is unrecoverable from output) and retries
  it harder from a dedicated budget. It never reaches `Result.status`/the reporters. This module is
  also the single home for what mix's *exit codes* mean: `success?/1` is the one reading of "exit `0`
  means success" (the metamutant compile, `Baseline`, `CoverageProbe` all call it instead of matching
  a literal `0`), and `timeout_exit/0` is the code a timeout signals (read by both `outcome/1` and the
  watcher `Command.Invocation` renders). The pivot is `--exit-status failure_exit/0`, forced onto
  every mutant `mix test`: a clean ExUnit failure (a kill) exits with that distinctive code, while a
  compile error / missing dep / broken helper exits `1` — so a harness error is no longer
  indistinguishable from a kill.
- **`Mutare.Sandbox.Command.Invocation`** — *how a run is invoked*: `mix/4` and `timed_mix/5` spawn a
  fresh `mix` OS process with `MIX_ENV=test`/`MUTANT_UNDER_TEST` set (`mix_env/0` is the single home
  for the `"test"` env, shared by `Mutare.Sandbox` and `Mutare.Transform.Uses`). Owns the *environment*
  a run gets — including the self-hosting isolation vars and `reserved_env_names/0` (the authoritative
  reserved set `Mutare.Options` rejects a colliding `:partition_env` against) — and the **run side of
  the timeout sub-contract**: the env var the cap travels in (`timeout_env/0`) and the dependency-free
  `watcher_ast/0` the `Mutare.Sandbox` bootstrap renders (it `System.halt/1`s the run itself with
  `Command.timeout_exit/0`, so there is no process tree to kill). The *decode* side of the timeout
  (the exit code → `:timeout`) stays in `Command`.
- **`Mutare.Sandbox.Command.Output`** — every pattern that reads `mix`'s human-readable output, in one
  home because they all break together if mix changes its format (though each is read for a *different*
  job, deliberately **not** merged): the verdict-refinement discriminators `outcome/2` consults
  (`suite_compile_error?/1`, `atom_exhausted?/1`, `boot_failure?/1`), the mix-output **patterns**
  `compile_error_banner/0`, `source_location_regex/0` (read by `Mutare.Poison` for `file:line`s) +
  `diagnostic_severity/1` (so `Poison` scans only non-warning blocks), and `test_location_regex/0`
  (read by `Mutare.Runner.Baseline` to name flaky tests), plus `output_tail/2` (the shared "tail the
  output"). All pure, so each discriminator is unit-testable without spawning `mix`.
- **`Mutare.Sandbox.CompilerOptions`** — the env that tunes the **one** metamutant compile for speed:
  `compiler_env/0` (an `ERL_COMPILER_OPTIONS` disabling the SSA alias-analysis pass via
  `erl_compiler_options/1`, merging with any inherited value), applied by `Mutare.Runner` to that
  single `mix compile` only — a per-mutant `mix test` never recompiles the lib, so it carries nothing.
- **`Mutare.Runner`** — the orchestrator. Compiles the sandbox **once** (recovering from
  compile-poisoning, see below), runs the baseline green then a coverage probe, then runs
  `:workers` mutants concurrently via `Task.async_stream`, each a fresh `mix test` OS process.
  Per-mutant wall-clock cap; a timeout is a kill (`:timeout`). Maps each run's typed
  `Command.outcome` onto a result status — notably `:harness_error` (an infra failure that never
  reached a verdict) stays out of the score, never charged as a kill. Two knobs guard against
  flaky/broken infra: `:harness_retries` (default 2; re-run a harness-erroring mutant before
  recording it) and `:max_harness_error_rate` (abort `{:error, :too_many_harness_errors, …}` when
  persistent harness errors exceed that fraction of the mutants that *ran*). The one *named*
  harness-error cause, `:boot_failure` (a sandbox node dying during boot under startup contention),
  gets its **own** retry budget (`@boot_failure_retries`, independent of `:harness_retries`, with a
  jittered backoff so retries don't re-collide) plus a *specific* actionable warning naming the
  contention levers (`--workers`/`--partition-db`; not `--harness-retries`, which the dedicated
  budget bypasses) instead of pointing at output that can't
  help; `status_for(:boot_failure)` still maps to `:harness_error`, so the score is unchanged.
  `:max_survivors` (`--max-survivors`) is the lone **runner-loop** cap — distinct from `:max_mutants`
  (a `Schema` cap on candidate *sites*): every mutant is still compiled in, but the per-mutant loop
  **halts once N `:survived` results are found** (`collect_until_survivors/2` over the already-ordered
  `Task.async_stream`, so the stop is the Nth survivor *in source order*, deterministic; survivors
  only — no-coverage/kills/excluded don't count). An early stop flags the run `stopped_early`, which
  **skips the harness-error abort guard** (aborting would discard the survivors the user asked for;
  the Mix task likewise skips `--min-score`). Returns
  `%{schema, results, sandbox, baseline_ms, stopped_early}`. Optional **per-worker partitioning**
  (`:partition_env`, off by default; `--partition-db`/`--partition-env`) hands each concurrent run
  a distinct partition id under a named env var (default `MIX_TEST_PARTITION`) for DB isolation —
  the ids come from a bounded, recycled checkout/checkin pool (`Mutare.Runner.Partitions`) sized to
  `:workers` (so two live runs never share one, `rem(index, workers)` being unsafe — tasks don't
  finish in index order), the compile/baseline/probe taking a fixed partition (the compile too,
  since it evaluates the target's config — a partitioned default-less `System.fetch_env!` would
  otherwise raise); delivered through the existing `Command` `:env` plumbing, inert when unset.
- **`Mutare.Runner.Baseline`** — a whole-suite `mix test` (no `--cover`) at the baseline mutant:
  the authoritative green check (a red suite aborts with `:baseline_failed`) and the source of
  `baseline_ms` (a *single* run's wall-clock — the per-mutant timeout cap is scaled from it). With
  `:baseline_runs` > 1 it runs the suite up to N times (short-circuiting on disagreement) to catch
  a **flaky** suite: all green → proceed (`baseline_ms` = the slowest green run); all red →
  `:baseline_failed`; mixed → `:baseline_flaky` (abort, naming the disagreeing tests — a flaky test
  manufactures false kills). The all-green/all-red/mixed decision is the pure, tested
  `Baseline.classify/1`.
- **`Mutare.Runner.CoverageProbe`** — coverage-driven test selection, run after the baseline. A
  **single** instrumented `mix test` at baseline (`MUTARE_COVERAGE=1`), then it reads the dump.
  Per mutant: never ran → `:no_coverage`; ran in an **unlabeled process** (`on_exit`/a bare spawn/
  a `setup_all` whose work ran off-stack in a `Task`) → whole suite, *not* `:no_coverage` — this
  **dominates** attribution, since an id covered via an unlabeled process *and* directly touched by
  some test would otherwise trust the partial attribution, run too narrow a set, and miss the
  killing file (a false survivor); else covered with attributed files → those files. Two coverage
  shapes are *exempted* from the unlabeled bucket and attribute normally (tighter selection):
  `Task` coverage (`Recorder` recovers the spawning test's label from the caller chain) and
  `setup_all` coverage (recovered to its own module's file via the `__ex_unit__/2` stacktrace frame
  — sound for the module-scoped `setup_all` *context*, but not for a `setup_all` with cross-module
  global side effects, which `:full` mode still covers; see `Recorder`). Returns a bare `selection`
  (`:run_all | {:selective, %{id => outcome}}`) and **can't fail**: an unreadable/empty dump
  degrades to `:run_all`. Split from the baseline on purpose — folding the two conflated a green
  check that never ran the suite together with a `baseline_ms` summed over N per-file process
  boots (an inflated cap). See `NOTES.md`.
- **`Mutare.Coverage.Recorder`** — the **generated** side of coverage capture (owns the contract
  the metamutant and the bootstrap share): `record_ast/1` (spliced into every selector catch-all),
  `helper_source/0` (the `MutareCov` module `Sandbox` writes in), and `bootstrap_ast/0`. The
  catch-all records the site's mutant ids into shared ETS *synchronously, in the test process*,
  gated `mutare_active == 0 and :persistent_term.get(:mutare_track, false) and MutareCov.hit(ids)`
  — inert on per-mutant runs (short-circuits on the id compare) and outside the probe. `hit/1`
  routes each id by the recording process's label, in three tiers (`label/0`): its own
  `{module, name}` test label; else a spawning test's, recovered from the `$callers`/`$ancestors`
  chain (a `Task`); else a `setup_all`'s owning module, recovered from the `{module, __ex_unit__, 2}`
  frame on its own stacktrace (`stacktrace_label/0` — `setup_all` runs in an unlabeled, caller-less
  process but inside the module's `__ex_unit__/2` dispatch). Any of these → per-file attribution.
  No recoverable label (`on_exit`/a bare spawn/a `setup_all` whose work ran off-stack in a `Task`)
  → the `unlabeled` table (whole-suite, read by `CoverageProbe`). The `setup_all` recovery is sound
  for the module-scoped `setup_all` *context* (the common case) but not for cross-module global side
  effects — the same cross-file-dependency limitation `:coverage` already has for ordinary
  attribution (`:full` is the escape hatch). The `ids`
  list is spliced as `__block__`-wrapped integers (`ids_literal/1`), never a bare list: a bare
  integer list is indistinguishable from a charlist in quoted form, so the renderer would emit
  `~c"…"` for printable ids — and ids like `\`/newline then produce un-re-parseable source.
- **`Mutare.Coverage`** — reads back the probe's dump: `%{aggregate, by_file, unlabeled}`, all keyed
  by **mutant id**. `aggregate` (process-agnostic: any process that ran the line) is the no-coverage
  signal; `by_file` (labeled test processes, `Task`s attributed via their caller chain, plus
  `setup_all`s attributed via the `__ex_unit__/2` stacktrace frame) drives per-file selection;
  `unlabeled` (ids hit in a process with no recoverable test label — `on_exit`/a bare spawn/a
  `setup_all` whose work ran off-stack in a `Task`) forces a whole-suite run, dominating `by_file`.
  No `:cover`, no
  coverdata, no metamutant↔original line mapping. Why self-record, not `:cover`: cover's table is
  global (`{module, line}`, no per-process partition), so per-test attribution in one run needs an
  async-formatter snapshot that **races** test execution and loses fast `async: false` modules'
  coverage; recording in the metamutant captures it in-process, accumulate-only (no reset).
- **`Mutare.Poison`** — on a failed metamutant compile, maps the error's `file:line` to the
  offending mutant id(s) via the manifest's **generated line ranges** (`Manifest.ids_at_line/2`,
  narrowest range wins). This catches poison anywhere a mutant's code lives — a multiline body, a
  lifted private `defp`, or (as a coarse fallback) the surrounding `case` — not just a selector
  clause's start line. The runner drops the implicated ids via `:skip_ids` and rebuilds, bounded.
  Zero cost when nothing poisons. One **escalation** lives in the runner
  (`Runner.escalate_block_poison/3`): when an implicated id sits inside an *unknown module-level
  block macro* (`custom_dsl do … end`, whose body is mutated on the "unquoted into a function"
  guess), the *whole* block's ids may be skipped at once — a DSL that rejects the injected selector
  `case` does so for every mutation in the block, so dropping one at a time would just re-hit the
  next (and could exhaust the attempt budget). But that's only one of two failure modes: a DSL
  rejecting the selector **wholesale** (drop one → the next fails) vs. *one* mutant's broken
  replacement (a custom mutator emitting uncompilable code — drop it → the rest compile). The two
  are distinguished by **recurrence**, the only signal that exists (whether an unknown DSL rejects a
  given selector is known only at compile time): escalation is **evidence-based** — the *first*
  poison in a block drops just the implicated id(s) and marks the block *struck*; only a *second,
  distinct* poison in an already-struck block drops every mutant in it. So a wholesale block pays
  one extra rebuild but an id-specific failure no longer drags its innocent
  (compile-safe-by-construction) siblings to `:poisoned`. Whole-block drop is the runtime-stable
  equivalent of marking the macro `:skip` (the body renders raw, its mutants are `:poisoned`)
  without breaking id stability (the body is still *analyzed*, so ids stay put across rebuilds — a
  true `:skip` would stop analyzing and shift every later id). The block macro is identified
  **per-invocation** by `Site.block_macro` (`{name, nid}`, the statement node's injective `nid` — so
  `guarded :guard do …` poisoning doesn't suppress a sibling `guarded :body do …`), tagged by
  `Transform.emit_block_macro/2` only on *unknown* macros (`Analyze.unknown_block_macro_name/1`) — a
  *registered* macro the user chose to mutate is never auto-skipped. See NOTES "Unknown block macros".
  The one poison class recovery structurally **can't** isolate — a macro that requires a
  compile-time **literal** argument (`Size.megabytes(5)`): the spliced selector `case` makes the
  macro raise while *expanding*, and the compiler reports the macro **call** line, not the selector
  inside it (different lines), so `Poison.ids/2` maps `[]` and the run aborts. Instead of only
  re-emitting the raw error, **`Mutare.Poison.Hint`** (pure) scans the captured output for
  `expanding macro: Mod.fun/arity` frames and renders a copy-pasteable `.mutare.exs` `:skip` snippet
  (`{Mod, :fun, :skip}`) naming the **innermost** culprit of each stacktrace (a nested
  `if Size.megabytes(5)` prints `Size.megabytes` *then* the enclosing `Kernel.if` — only the inner
  macro's arg was mutated, so advising `{Kernel, :if, :skip}` would wrongly hide every `if`);
  `Mix.Tasks.Mutare`'s `:compile_failed` formatter leads with it, then the raw error. `:skip` (stop descending into the macro's args) is the only fix —
  `# mutare:ignore` is applied *after* rendering, so it can't prevent the splice. See NOTES
  "Remediation hint for an unrecoverable macro-literal poison".
- **`Mutare.Report`** — diffs each *surviving* mutant against the **original** source via
  `Sourceror.patch_string` (clean one-line diffs), and computes the score:
  `killed / (total − no_coverage − ignored − poisoned − harness_error)`. This is the default
  *human* reporter, rendered **after** the run completes.
- **`Mutare.Report.Live`** — the **live** human progress (a `GenServer`), the interactive
  counterpart to `Mutare.Report`'s after-the-fact diffs. cargo-mutants-style: it shows what the
  runner is *currently doing* (the phase, then the in-flight mutant), leaves a permanent line
  behind for each survivor / timeout / harness-error as it happens, and — on a tty — paints a
  live status block (spinner + activity + a counter with an ETA) at the bottom, driven by an
  internal tick timer so it animates while the foreground blocks in `Task.async_stream`. All
  output goes to **stderr** (so a machine report on stdout is never corrupted); animation is
  gated on `detect_ansi/0` (a real stderr tty + `IO.ANSI.enabled?`), degrading to plain
  scrollback (phase notes + leave-behind lines, no cursor codes) for pipes/CI. **Colour** is a
  *separate* gate (`color_enabled?/0`, the only colour being the leave-behind label): the
  `NO_COLOR` convention (any non-empty value) drops the label colour while keeping the live block
  — `IO.ANSI.enabled?` doesn't check `NO_COLOR`, so this does. The Mix task owns
  it: unless **`--quiet`** (`:quiet`) — which suppresses the reporter *entirely* (no `Live`, no
  stderr progress; the final + machine reports are untouched) — it starts the server, wires the
  run's four live hooks to it (`:reporter` → `report/2`,
  `:on_phase` → `phase/2`, `:on_start` → `started/2`, and — during the pre-run scan —
  `:on_scan` → `scanned/2`), and calls `finish/1` to tear the block
  down **before** the final `Mutare.Report` prints. Because the rendering is pure
  (`status_block/2`, `leave_behind/1`, `humanize_secs/1`, `eta_secs/3`, `truncate/2`) and the
  state a plain map, the visible output is unit-tested without a terminal or a clock.
- **`Mutare.Report.{Json,Html,Sarif}`** — the **machine** reporters, pure renderers paralleling
  `Mutare.Report` (`(results, sources, opts) → String.t()`; all IO stays in the Mix task). **Json**
  emits the standardized *mutation-testing-elements / Stryker* report schema (every mutant, keyed
  by file; `Result.status` maps 7-for-7 onto the schema's `MutantStatus` — the one place the two
  vocabularies meet). **Html** embeds that JSON into the `mutation-test-report-app` web component
  (no bespoke renderer; neutralises `</` so embedded source can't close the inline `<script>`).
  **Sarif** emits survivors-only as SARIF 2.1.0 findings for GitHub code scanning (reuses
  `Site.describe/1` as the message). Encoding is the stdlib `JSON` module — hence the `elixir`
  floor is `~> 1.18`. Selected via the `:reporters` option (below).
- **`Mutare.Mutator`** (+ the `Mutare.Mutator.Structural` / `Mutare.Mutator.MacroAware` capability
  behaviours) + **`Mutare.Mutators.*`** — the public extension surface, **split by capability** so
  the core behaviour is the 90% case rather than a bag of twelve optional callbacks. **`Mutare.Mutator`**
  is `name/0` + a node-level producer (`mutate/1`, the pipe-aware/configurable `mutate/2`, and the
  `empty_collection?/1` in-RHS classifier — a mutator implements `name/0` plus at least one producer);
  **`Mutare.Mutator.Structural`** carries the position-routed hooks
  (`return_replacements`/`condition_replacements`/`pattern_mutations`, each with a behaviour-aware
  `+1` arity); **`Mutare.Mutator.MacroAware`** carries DSL targeting (`macros/0`, `macro_routing/1`,
  `host/2`). A mutator declares `Mutare.Mutator` plus whichever capability behaviours it needs.
  Dispatch is **unchanged** — `Mutare.Mutator.Dispatch` still discovers every hook by
  `function_exported?`, so the split is documentation/ergonomics, not new plumbing (the same
  capability-named-peer move as `Mutare.Plugin`'s vocabulary/judgment carve-out; see NOTES "Mutator
  capability behaviours"). The built-in families are **all on by default**. The `Mutare.Mutators` `@registry` is the source of truth for *which* families
  exist; each family's exact swap table, exclusions, and rationale live in its own `@moduledoc`.
  Don't re-enumerate those here — a hand-maintained catalogue drifts (that's how a new family goes
  undocumented), the moduledocs don't. What a reader needs from *this* file is the handful of
  cross-cutting facts a single moduledoc can't show: the categories core routes differently, and
  the cross-family ownership rules.

  **Categories** (how core treats a family):
  - **In-place operator/value swaps** (`mutate/1`, reused operands, compile-safe by construction):
    Arithmetic, OperandSwap, Bitwise, Relational, StrictEquality, Logical, List, Conditional.
    Guard-legal ops (`-`/`/`/`div`/`rem`/bitwise, `Integer.is_even`, the equality ops…) reach
    `when` guards via lifting.
  - **Literal swaps** (a literal → empty/sentinel/shifted value, in place): Literal (ints/bools),
    StringLiteral, FloatLiteral, AtomLiteral, ConventionAtom, CharlistLiteral, WordListLiteral,
    MapLiteral, TupleLiteral, BitstringLiteral, RegexLiteral, DateTimeLiteral, AliasLiteral. Each
    participates in `def`-head lifting only where its node is a *scalar* literal.
  - **Bitstring-spec swap** (BitstringSpec): the lone *spec-position* family — swaps a `<<…>>`
    segment's Unicode encoding (`utf8 ↔ utf16 ↔ utf32`) and byte order (`big ↔ little`, utf16/32
    only; `native` excluded as host-dependent). Routed exactly like BitstringLiteral — an ordinary
    `mutate/1` handed the whole `<<…>>` node by the runtime-body `offer/3`, returning *complete*
    bitstring copies — so the in-place selector (constructor) and lifted clause-guard replacement
    both deliver it with no new plumbing. Never-equivalent + compile-safe by construction (the three
    encodings share one validity domain). Never-equivalence rests on a **literal-value equivalence
    filter**: for a literal value (an integer codepoint *or* a binary string) it encodes the original
    and each variant and drops any whose bytes match — catching a byte-palindromic value (`<<0::utf16>>`,
    `<<"\0"::utf16>>` are `<<0, 0>>` either way) on the byte-order axis *and* an empty value
    (`<<""::utf16>>` is `<<>>` under every width) on the encoding axis; a *variable* value is kept
    (killable by some input). It re-parses the rendered literal with the standard parser first, since
    Sourceror keeps a string's escapes un-decoded (`"\0"` → `"\\0"`) — else the compared bytes would be
    wrong and an equivalent mutant would survive as a phantom (a false *keep*, not a false drop: the
    un-decoded `"\\0"` carries a backslash, never byte-palindromic, so it only ever *under*-drops). The deprecated `utf16-big()` paren form is read as an explicit order, not
    appended-to into a conflicting `utf16-big()-little`. **Constructor-only**: a `<<>>` in a *pattern* isn't offered
    (the non-scalar node fails the head-lift filter, and no selector wraps a pattern), so it catches
    encoders, not decoders. See NOTES "Unicode encoding/byte-order specifiers".
  - **Call-matching** (resolve the call through `Mutare.Transform.Calls`, so direct / aliased /
    imported, Elixir or Erlang-atom forms all match): Collection, StringCall, StringByte, MapKeyword,
    MapSet, PeriodBoundary, Numeric, Math, Integer — arity-blind renames; CollectionArity, DefaultDrop, ModeSwap,
    CallRemoval — arity-changing / option-value / removal, **pipe-aware** via the optional `mutate/2`
    (a `|>` stage hides one arg, so effective arity needs the flag). A *bare* `Kernel` call
    (`abs`/`min`/`max`/`div`/`binary_slice`…) has no module to prove it's the `Kernel` one, so those
    are gated on **effective arity** instead. Generated cross-module names are emitted absolute
    (`Elixir.Kernel.==`, `Elixir.Function.identity`) so no alias/import can redirect them.
  - **Structural** (no `mutate/1`; the real logic is a callback core discovers *by export*
    and applies at the positions it routes — so a *custom* mutator at that position participates
    too): ReturnValue (`return_replacements/1`, a clause's return tail — **and each branch tail of a
    `case`/`cond`/`if`/`unless`/`with`/`try`/`receive` in tail position**, descended by
    `Transform.Analyze.Returns`; the def-level `rescue`/`catch`/`else` and a `try` expression share one
    clause walk; an **anonymous function**'s every `fn` clause body tail is a return path too, via the
    same per-clause walk — `annotate_fn_returns/3`), IfCondition
    (`condition_replacements/1`, an `if`/`unless`/`cond` condition), PatternSwap + PatternWildcard
    (`pattern_mutations/2`, head / `case` / `receive` / `fn` / `=`-match patterns), and RescueType +
    GuardDrop — the two **transform-managed** families (`Mutare.Mutators.transform_managed/0`):
    `try`/guard rebuilds that don't fit a `(node) → [replacement]` callback, so their logic lives in
    `Transform` (discovered by module identity via `Spec.find/2`) and the modules carry only `name/0`,
    deliberately *not* implementing `Mutare.Mutator` (RescueType's `drops/1` is a plain helper, not a
    producing callback). The unregistered `clause_drop` is the one structural built-in that *isn't*
    a toggleable family.
  - **Behaviour-gated** (the first built-in to read `context.behaviours`): GenServer
    (`return_replacements/2`, gated on `@behaviour GenServer`) swaps a `handle_call`/`cast`/`info`/
    `continue` return tuple for another *valid* OTP return (`:reply`→`:noreply`, `:noreply`↔`:stop`,
    …) — a higher-signal complement to ReturnValue's sentinel (a well-formed mutant, not a crash).
    Inert in non-GenServer modules. See its `@moduledoc` for the full swap table.
  - **Configurable** (`{module, opts}` in `:mutators`; `opts` reach `mutate/2` as `context.opts`,
    the reserved `:as` key renames the recorded family): ConventionAtom (extra `:pairs`) and any
    user mutator. See `Mutare.Mutator.Spec`.

  **Cross-family rules that bite** (ownership splits / equivalent-sibling suppression — *not* visible
  from one moduledoc, so they live here):
  - `AtomLiteral` excludes `true`/`false`/`nil` (Literal/Conditional own them) and the convention
    atoms (`ConventionAtom` owns them via `members()`); `Conditional` skips boolean-operator
    conditions (IfCondition / the operator families own those).
  - `OperandSwap` excludes commutative operators (guaranteed no-ops) and comparison operators (an
    operand swap there *is* Relational's direction flip); the non-commutative date/time/version/MapSet
    *calls* it does swap are the ones no other family flips.
  - `Relational` leaves an `in`/equality op directly under `not`/`!` unmutated (that's Logical's
    strip); a collection-emptying mutant on the **RHS of `in`** (`x in []` ≡ `false`) is suppressed
    as equivalent to Conditional — recognised by `Mutare.AST.empty_collection_literal?/1` or a
    mutator's `empty_collection?/1` callback.
  - `StrictEquality` relaxes `===`→`==` / `!==`→`!=` (one direction; `Relational` owns the
    *polarity* flip `===`→`!==`). The two are orthogonal, so both fire on a bare `a === b`. Under a
    negation they diverge: Relational's flip is suppressed (`not (a !== b)` ≡ `a === b` ≡ Logical's
    strip), but the relaxation is **kept** (`not (a == b)` ≢ `a === b` — a strictness change isn't a
    polarity complement). So the equality-under-`not` suppression is a **per-mutation** filter
    (`drop_negation_redundant_candidates/2` in `Analyze`, `offer_negation_survivors/4` in `Tag`)
    that drops only the complement + Conditional's `true`/`false`, not the whole inner node.
  - `MapSet` owns the *commutative* `union`↔`intersection`; the *non-commutative* `difference`/`subset?`
    are `OperandSwap`'s. `div`↔`rem` is Arithmetic's, not Numeric's.
  - When a call rewrite (ModeSwap) and a leaf mutant (AtomLiteral on the same swapped key) overlap,
    the diff-derived `Transform.Overlap` pass drops the redundant leaf (see "redundant-leaf overlap").

  Delivery mechanics (lifting, tuple-the-scrutinee, whole-construct selectors, the `=`-match
  tuple-re-export) are the `Transform` bullet's concern, not the mutator's — placement is positional.
  A user narrows the set by listing a subset under `:mutators`.
- **`Mutare.Mutators`** — the **single ordered registry** of built-in families and the one place
  mutator lists are resolved/validated. `all/0` is the default set (every registered module — an
  unset `:mutators`/`:all`); `families/0` is every registered atom; `resolve/1` maps any entry —
  a family atom, a custom module, a `{family|module, opts}` **configured pair**, the **`:builtins`
  group token** (synonym `:all`; bare or `{:builtins, except: [families]}`, expanded in place to
  the registry's families before per-entry resolution — so including it *extends* the defaults and
  omitting it *replaces* them, and `except:` drops named built-ins, the reconfigure-a-built-in path
  being exclude-then-re-add-configured), or an already-resolved `%Spec{}` (idempotent) — to
  validated **`Mutare.Mutator.Spec`** structs. A registered entry resolves either because it
  implements `Mutare.Mutator` (a producing callback — most families) *or* because it is
  **transform-managed** (`transform_managed/0` — `GuardDrop`/`RescueType`, `name/0`-only, logic in
  `Transform`); `to_module!/1` accepts both, and a test pins that every registered module is one or
  the other.
  `Transform` (its default), `Config` (the CLI/`.mutare.exs` path), and `Options` (the direct
  `Mutare.run/2` API) all derive from it — so a family registered here is part of `:all` and
  resolvable/validated everywhere, with no second list to drift.
- **`Mutare.Mutator.Spec`** — the resolved unit of "a mutator to run":
  `%Spec{module, name, opts, behaviours}`.
  Every mutator runs as a `Spec` (a bare built-in is one with empty `opts` and `module.name()`); a
  `{module, opts}` entry carries per-instance `opts`, delivered to the **context-taking callback**
  `mutate/2` via the context map's `:opts` key — so a *configurable* mutator
  reads its parameters there (and therefore implements `mutate/2`, since `mutate/1` has no context).
  `behaviours` is **not** user config — it is the enclosing module's `@behaviour` set, folded onto
  the spec **per module** by `Transform.enrich_mutators/2` and delivered under the context's
  `:behaviours` key (the same spec→context path `opts` rides), so a behaviour-targeted mutator gates
  on it. The base specs carry the empty default; only the per-module re-bind populates it.
  The reserved `:as` key in `opts` overrides the recorded `name`, so the **same module can run
  twice under distinct names** — load-bearing because the recorded name is what reports show and
  what the `# mutare:ignore[...]` filter matches, so two configs must be distinguishable. The
  `Spec` (not the bare module) is what `Mutator.mutations/3` tags each mutation with and what
  threads through the candidates into `Site` (which records `spec.name`); `Spec.find/2` is how the
  structural families (`ReturnValue`/`IfCondition`) check enablement by module. `Transform`
  normalizes its `:mutators` opt through `resolve/1` at the boundary, so every internal consumer
  sees specs regardless of whether the caller passed atoms, modules, or specs.
- **`Mutare.Macros`** + **`Mutare.Macro.Spec`** — the **known-macro registry**: macros whose
  arguments the transform routes specially instead of mutating as ordinary runtime values. A
  `Macro.Spec` (`%{module, name, arity, args, host}`, module a `Calls`-style key) declares a per-argument
  treatment — `:expression` (mutate, default), `:pattern` (a match context with **local** bindings —
  `match?`), `:binding_pattern` (a match context whose bindings **escape** into the enclosing scope —
  `destructure`; routed like `:pattern`, but *additionally* earns structural swap/wildcard mutants in
  a value-discarded position, delivered by `Candidate.MacroPattern`), `:skip` (leave raw — an
  opaque DSL body, e.g. `Ecto.Query.from`), or **`:hosted`** (leave raw for *core*, but deliver
  mutations through the registering mutator's **selector host** — the deep `Ecto.from`/`where` case;
  see "Adding a mutator" and NOTES "the selector host"). `args` is a uniform atom, a per-position
  list, or the **`:routing`** sentinel — a *shape-aware classifier* deferring per-position routing to
  the mutator's `macro_routing(call_node)` (a treatment that depends on the call shape:
  `where(q, category: "x")` is data, `where(q, [u], u.x == u.y)` is `:hosted`). `host` (the mutator
  delivering `:hosted`/answering `:routing`) is **not** user-written: `from_mutators/1` stamps it to
  the registering mutator, so a declarative `:macros` entry can't ask for `:hosted`/`:routing`
  (`build/3` raises — `Spec.host_required?/1`). Specs come from **four** merged sources, folded
  **built-ins → mutator `macros/0` → plugin `macros/0` → declarative `:macros`** (later wins): built-ins (`Kernel.match?/2`
  arg 0 `:pattern`, `Kernel.destructure/2` arg 0 `:binding_pattern`), an optional **`macros/0`**
  callback on any enabled `Mutare.Mutator` — so a library ships its custom mutator *and* its macro
  registration in one module (the user adds one `:mutators` entry; core stays DSL-agnostic) — the
  same `macros/0` on any enabled **`Mutare.Plugin`** (`from_plugins/1`, the non-mutating-extension
  counterpart; see the `Mutare.Plugin` bullet) — and the declarative **`:macros`** option **last**, so
  an explicit config entry is the **final authority** for a key (it wins over a mutator's or a plugin's
  `macros/0`; a plugin wins a tie over a mutator; all three override the built-ins). A user can thus
  pin a macro's routing from `.mutare.exs` even against an installed plugin — at the cost of being able
  to override a mutator's correctness-critical routing (`{Ecto.Query, :from, :skip}`), a deliberate
  opt-in the poison backstop still guards. `build/3`
  merges them into a lookup `Resolve` stamps from; resolution of `:macros`/`macros/0` is
  **reflection-free** (syntactic module keys via `Module.split`/`Macro.classify_atom`), so a
  `{Ecto.Query, …}` entry validates without `Ecto` loaded. Identity at the call site uses the
  existing alias/import/displacement resolution (a bare `match?` is `Kernel.match?` only when it
  resolves to Kernel — a local shadow is a compile error), so bare/qualified/aliased forms all route.
  The glob atom **`:*`** (`Spec.wildcard/0`) wildcards a slot: `{module, :*, t}` registers a **whole
  module** (every macro in it), `{:*, name, t}` a **name-only escape hatch** (that name in *any*
  module — the fallback for when module resolution can't see the macro, e.g. a `use`-injected import;
  in the arity slot `:*` is a synonym for `:any`). `lookup/4` is **most-specific-wins** —
  `{module, name, arity}` > `{module, name, :any}` > `{module, :*, :any}` > `{:*, name, arity}` >
  `{:*, name, :any}` — so a specific entry overrides a whole-module one (per-macro override), the
  name-only hatch is consulted last (never shadowing a module-matched or built-in treatment), and a
  name-only entry fires even when the resolved `module_key` is `nil` (an unresolvable bare call —
  exactly its purpose; no `Resolve` change, the cascade does it). `Spec.new/4` rejects the two
  nonsensical combos (both module *and* name `:*`; a name-`:*` entry pinned to a real arity, which the
  cascade would never reach). `:*` is a *practically* collision-free sentinel (`*` *can* name a
  macro/module — it's `Kernel.*/2`, and `defmodule :*` / a metaprogrammed `def unquote(:*)` compile —
  but nothing registers the operator as a known macro), so it needs no escaping.
  `:skip` is also "owned only by a custom mutator": core skips the args, but the whole node is still
  offered to every mutator, so the registering mutator fires. The stamp is honoured on **both**
  routing paths: the generic runtime clause *and* the **module-level macro-block** path
  (`analyze_module_macro_block/2`, e.g. `schema do … end`), which otherwise analyzes a block body as
  runtime (a DSL may unquote it into a function) and would mutate an opaque `:skip` body. `Mutare.Options`
  validates `:macros`; `Mutare.Schema` forwards it; `Transform` builds the registry and passes it to
  `Resolve.annotate/2`.
- **`Mutare.Plugin`** — the **compile-time vocabulary** extension point: a module that teaches Mutare
  how to *resolve and route* the constructs the built-in mutators encounter, and **never participates
  in the run, verdict, or score**. The charter is *vocabulary vs. judgment* — in: macro routing,
  `use`-expansion, block-macro treatment, opaque-literal declarations; out: anything that reads a run
  or weighs a mutant (coverage, equivalent-survivor exoneration, scoring, reporting — a future
  *runtime* extension point would be a capability-named peer, not a `Plugin.*` member). Being
  third-party is *incidental* (the built-in `Kernel.match?`/`destructure` routings are the same
  vocabulary, first-party). A plugin produces no mutations and has
  no `name/0`; it only contributes **registrations** through two optional callbacks (a module is a
  usable plugin if loaded and exporting either), which split by **what they do**, and that split sets
  *how multiple plugins combine and whether the callback sees config*:
  - **`macros/0`** (a *registration*) — known-macro argument routing, **merged** into the registry
    across all plugins exactly like a mutator's (`Macros.from_plugins/1`). A static declaration of
    library facts, so it is **opts-independent** (takes no context).
  - **`expand_use/3`** (a *decision/override*) — a `use`-expansion override
    (`expand_use(used_module, args, context) -> Mutare.Plugin.Expansion.t() | :decline`,
    `Expansion` a struct of `directives` + `behaviours` built by `Plugin.expand/2`), consulted by
    `Transform.Uses.Harvest` before in-process expansion (and at every **nested** `use` too, so a
    `use` injected by another `use`'s `__using__` body — Phoenix's `use MyAppWeb, :html` → `use Gettext`
    — is overridden, not only a top-level one). Dispatch (`Plugin.expand_use/4`) is
    **first-non-`:decline`-wins** over the ordered `:plugins` (an **empty** `%Expansion{}` still wins
    — "handle, inject nothing" — so falling through requires `:decline`; a handler can never hijack
    another's result). A **misbehaving** handler is loud, not isolated: a **contract** violation (a
    return that is neither `%Expansion{}` nor `:decline`, or a non-list `Plugin.expand/2` call) **or**
    a raising/throwing `expand_use/3` is wrapped/raised as `Mutare.Plugin.ContractError` (`safe_expand/4`)
    and rides *through* `Harvest`'s never-raise boundary — which exists to absorb the *target*'s
    un-expandable `use`s, not a plugin's bugs — surfaced like a bad `:plugins` entry rather than
    silently dropped. Because a
    decision *is* behavior, it is **opts-aware** and **context-carrying**: its `context` map carries the
    caller `:module` (parity with `__CALLER__.module`, which in-process expansion already threads) and
    the plugin's per-instance `:opts`. The map is the extension point — new keys add without an arity
    bump; the **struct** return is the same future-proofing for the result (a new field ≠ a breaking
    tuple widening).
  The rule worth holding: **registrations merge & ignore opts; decisions first-win & read opts** — the
  same shape as a mutator (`opts` reach `mutate/2`, never `macros/0`). The built-in mutators do the
  mutating; the plugin makes their work *land* (the calls resolve, the right arguments are offered).
  Listed under **`:plugins`** as a bare module or a `{module, opts}` pair, resolved to
  **`Mutare.Plugin.Spec`** (`%{module, opts}`, the plugin counterpart of `Mutare.Mutator.Spec`;
  validated by `Options` via `Plugin.validate!/1` → `plugin?/1` — *reflection-based*, since a plugin
  module **is** on the Mutare process path, unlike a `:macros` entry which is only named; forwarded by
  `Schema`, threaded by `Transform` — the plugin *specs* into both `Macros.build/3` (which reads each
  spec's `.module`; registration is opts-independent) and `Uses.annotate/2` (so `opts` reach
  `expand_use/3`)). `Macros.from_plugins/1` rejects a plugin `macros/0` declaring a `:hosted`/`:routing`
  treatment — a plugin produces no mutations, so it cannot host one. The
  motivating case is **Gettext** (its raising, caller-mutating `__using__` defeats in-process
  expansion); a `mutare_gettext` package ships `expand_use/3` (returning `import Gettext.Macros`) +
  `macros/0` (routing each macro's msgid positions `:skip`, the bindings/count `:expression`), and an
  Igniter installer writes the one `:plugins` entry. See "Adding a plugin" and NOTES "Plugin
  `use`-expansion override".
- **`Mutare.Options`** / **`Mutare.Options.Registry`** / **`Mutare.Run.Context`** — the split
  between *configuration* and *runtime wiring*. **`Mutare.Options`** is the validated user-config
  struct, but it owns no option *knowledge*: every option's default, CLI passthrough switch shape,
  `--show-config` visibility + formatter, and validator live in one place — **`Mutare.Options.Registry`**
  (an ordered `specs/0` list) — so adding a typical option is a *single* registry entry instead of
  the four synchronized edits (`options.ex` default+validator, the Mix task `@switches`, `Config`'s
  passthrough fold, `info.ex`'s `--show-config` row) that drifted before (that drift is how
  `--show-config` silently omitted `partition_env`/`seed_app_build`/`quiet`/`only_files`/`only_lines`;
  `display_rows/1` now lists *every* visible option). `Options` derives its `defstruct`/`@keys`/`new/1`
  from `Registry.defaults/0`/`specs/0`; `Config` and the Mix task derive their switch lists from
  `Registry.cli_switches/0`/`passthrough_keys/0`; the registry is `Options`'s **compile-time**
  dependency, so it must not reference the `%Options{}` struct (the reporters validator reads
  `Options.formats/0` at *runtime*, and `display_rows/1` takes a plain map — both deliberately avoid a
  compile cycle). **`Mutare.Run.Context`** carries the things that are *not* config — the resolved
  `Mutare.Project` and the four live-progress hooks (`reporter`/`on_phase`/`on_start`/`on_scan`) —
  bundled with the validated `options`. `new/1` is a **wrap-at-boundary** normalizer mirroring
  `Options.new/1`: a keyword list has its wiring keys split off (validated here) from its config keys
  (routed to `Options.new/1`), so an existing `Schema.build(root, project: p, mutators: m)` call keeps
  working unchanged. `Mutare.Schema`/`Mutare.Sandbox`/`Mutare.Runner` thread the context, reading
  config from `ctx.options` and wiring from the context's own fields (`Context.hook/2` is the no-op
  default; `Context.ensure_project/2` resolves a project from `root` when the direct API leaves it
  unset). Note `Mutare.Runner.RunCtx` (per-mutant invariants) is a *different* struct.
- **`Mutare.Config`** / **`Mutare.Changes`** / **`Mix.Tasks.Mutare`** — `.mutare.exs` + CLI flag
  resolution, `git diff` for `--since`, and the CLI entry point. The Mix task's `@switches` is
  composed `Registry.cli_switches() ++ Config.cli_switches() ++ <project/scope + inspect flags>`, so
  each flag's parse shape sits with its meaning — the passthroughs in the registry, the
  *exceptional/translated* flags (`--only`/`--line`/`--exclude`/`--mutators`/`--full`/`--partition-*`/
  `--format`/`--output`) in `Config.cli_switches/0` (whose translations stay in `Config.merge/2`).
  `Config.parse_line_spec/1` parses a
  repeatable `--line FILE:LINE` (split on the last colon, integer line) into `:only_lines` — a narrow
  rerun scoped to one `file:line`'s mutants, the `FILE:LINE` mirroring `Report.header/1`'s prefix.
  Output formats resolve here too:
  `--format`/`--output` (CLI) and `reporters:` (`.mutare.exs`) become the `Mutare.Options`
  `:reporters` list (`[{format, path | nil}]`, `nil` = stdout). `Config.resolve_reporters/2` owns
  the **collision rule** — `--format` *with* `--output` keeps the human report on the console and
  writes the machine format to the file; `--format` *alone* takes stdout and drops the human
  report. Note `:reporters` (output formats; `Options` validates the format set) is distinct from
  the four **live-progress hooks** the task wires to `Mutare.Report.Live`: `:reporter` (per
  completed `Result`), `:on_phase` (the run's phase as it advances `:compiling` → `:baseline` →
  `:coverage_probe` → `{:running, total}`), `:on_start` (each `Site` as its run begins), and
  `:on_scan` (pre-run scan progress). All
  four are 1-arity, optional (`nil` = no-op), and live on `Mutare.Run.Context` (not `Options` —
  they're wiring, not config); `Mutare.Runner` fires the first three and `Mutare.Schema` fires
  `:on_scan`, but neither knows anything of the display.
  **`--quiet`** (`:quiet`, a plain boolean threaded like `keep_sandbox`/`strict_ignores`) is the
  master off-switch for that display: when set, the task leaves all four hooks unset and never
  starts `Live`, so the run is silent on stderr (for CI / piped use); the final and machine
  reports are unaffected, and it's inert in the direct `Mutare.run/2` API (which never starts
  `Live`). **`--max-survivors N`** (`:max_survivors`, threaded like `:max_mutants`) is enforced in
  `Mutare.Runner` (a runner-loop cap, *not* a `Schema` site cap); when it fires (`run.stopped_early`)
  the task **skips the `--min-score` gate** and prints a partial-run note to **stderr** (so a machine
  report on stdout stays clean), since the score is over a tested prefix. There is **no** top-level
  option for call-option-key
  gating — it is per-mutator config (`{Module, call_option_keys: false}`), carried on the mutator's
  `Mutare.Mutator.Spec` and read by `Transform.gate_candidates/1` (above), so it needs no Options
  field, CLI flag, or `Schema`/`Ctx` plumbing.

### Cross-cutting things that bite

- **The selection contract is split across modules and baked into generated code.** The
  `:persistent_term` key (`:mutare_active`) and the selector env var (`MUTANT_UNDER_TEST`) are
  defined in `Mutare.Selector`; the timeout env var in `Mutare.Sandbox.Command.Invocation` and its
  exit code in `Mutare.Sandbox.Command`; the
  coverage-capture contract (the `MUTARE_COVERAGE` env var, the `:mutare_track` flag, the ETS table
  names, the `MutareCov` helper, the dump file) in `Mutare.Coverage.Recorder`. They are *emitted
  into generated code* — the selectors and coverage record into the metamutant by `Mutare.Transform`,
  the reader/timeout watcher/coverage bootstrap+helper into the bootstrap by `Mutare.Sandbox`. Keep
  them in sync — change one in isolation and the metamutant stops responding. **The selection key is
  resolved at *runtime* by `Selector.key/0`** — `default_key/0` (`:mutare_active`) unless the
  `MUTARE_SELECTOR_KEY` override (`Selector.override_env/0`) names another. `Sandbox.Command.Invocation`
  sets that override (to `Selector.suite_key/0`) on every sandbox `mix`, so when Mutare dogfoods *itself*
  the suite-under-test selects on a private slot and its own `Selector.put/1` can't clobber the
  harness's active mutant (the self-hosting false-survivor fix; see NOTES "Self-hosting"). The real
  metamutant's sites + bootstrap bake `default_key/0` as literals in the harness process (override
  unset), so this is invisible on a normal target.
- **Two renderers, on purpose.** The metamutant is a build artifact (AST rewrite via
  `Sourceror.to_string`, only needs to compile); the report patches the original source. Don't
  try to make one serve both. Normally throwaway, but `--keep-sandbox` optionally caches the
  compiled sandbox across runs (still a build artifact — the *report* never reads it).
- **Two line spaces, decoupled.** Poison maps a compile error in metamutant-line space (via
  `Manifest`); the report works in original-line space. They never need to be related — don't
  reintroduce a mapping between them. (Coverage uses neither: it keys by mutant id.)
- **Compile-safety is layered.** Built-in mutators are compile-safe by construction (operator
  swaps reuse operands); dangerous/inert positions (guards, module-attribute values, the `/` in
  `&fun/arity` captures) are excluded *positively* by the context classifier (`skip_node?/1`),
  not by a blacklist; the poison pre-filter is the backstop for the unknown (e.g. custom
  mutators). A mutation that won't compile would sink the whole single build.

## Adding a mutator

Implement `Mutare.Mutator`: `name/0` (required) plus a way to produce mutations — a *node-level*
`mutate/1` (returning `:skip` or a list of mutations that reuse the original operands), **or**
one of the structural/pipe-aware/macro callbacks below. The structural and macro callbacks live on
the **companion behaviours** `Mutare.Mutator.Structural` / `Mutare.Mutator.MacroAware`, declared
*alongside* `Mutare.Mutator` (`@behaviour Mutare.Mutator` plus `@behaviour Mutare.Mutator.Structural`,
etc.) — the split keeps the core contract small; dispatch still finds every hook by export. `mutate/1`
is **optional**: a structural or pipe-only mutator omits it entirely (a module needs `name/0` and at
least one producing callback to count as a mutator). Each list element is a `t:Mutare.Mutator.mutation/0` — a bare node, `nil` (a
dropped slot), or a `%Mutare.Mutator.Mutation{node:, note:}` to attach a **per-mutant advisory** the
report surfaces on a survivor (e.g. "off-by-one suspected"); `Mutation.new(node, note)` builds it.
The note (the same channel a selector host's `:mutants` use) rides through to the `Mutare.Site` from
every position a `mutate` result lands — in-place, lifted, or in a clause. A bare `%{node:, note:}`
*map* is **rejected** — the struct is required (a quoted map literal is itself a valid mutation
node). Register a built-in by adding a `family: Module` entry to
`Mutare.Mutators`'s ordered `@registry` — the only edit, since the default set (`:all`),
`families/0` and resolution all follow from it (everything registered is on by default). Users
list custom modules directly under `:mutators` in `.mutare.exs`. Do **not** decide in-place vs
lifted — placement is positional. `test/support/boolean_mutator.ex` is a working example;
`test/support/noted_mutator.ex` shows the note channel.

Build literal replacements with **`Mutare.AST.literal/1`**, not by hand. It encodes the
Sourceror **clean-meta** rule: a literal parses as `{:__block__, meta, [value]}` and renders
from a `:token`/`delimiter` cached in `meta`, so reusing the original meta re-renders the
*original* text even after you change the value (a silent equivalent no-op), and a bare
`{:__block__, [], ["x"]}` for a string renders as the charlist `~c"x"`. `Mutare.AST.literal/1`
gets both right; `Mutare.AST.sentinel_string/0`·`sentinel_atom/0`·`sentinel_alias/0` give the
survivor marker the built-ins use; and `Mutare.AST` also carries node predicates
(`nil_literal?/1`, `key_atom/1`, `empty_collection_literal?/1`). To skip emitting a mutant on a
node `Conditional` already forces `true`/`false`, reuse `Mutare.Mutators.Conditional.boolean_op?/1`
(as `ReturnValue`/`IfCondition` do).

For a *structural head-pattern* mutator (restructuring a whole `def`/`defp` head — variable
swaps, wildcards), you declare `Mutare.Mutator.Structural`, omit `mutate/1`, and implement its
`pattern_mutations(head_args, used_outside)` callback (returning mutated arg lists);
`Mutare.Transform.FunctionPlan` discovers it by export and delivers each by lifting. You must
return only pattern-legal, compile-safe arg lists (`PatternSwap`/`PatternWildcard` are the
built-in examples).

For a *structural in-place* mutator at a position core routes — a `def`/`defp` clause **return
tail** or an `if`/`unless`/`cond` **condition** — you declare `Mutare.Mutator.Structural`, omit
`mutate/1`, and implement its `return_replacements(tail)` or `condition_replacements(condition)`
callback (each returning replacement
nodes). `Transform` discovers implementers by export (`Mutare.Mutator.Dispatch.implementing/3`) and asks
*all* of them at each routed position, recording each under its own name — so these are no longer
hardcoded to the built-in `ReturnValue`/`IfCondition`. `test/support/structural_mutator.ex` is a
working example. (The third structural built-in, `RescueType`, stays special — its `try`-rebuild
logic doesn't fit a `(node) → [replacement]` callback.)

For a *behaviour-targeted* mutator (firing only inside modules implementing a given
`@behaviour` — a GenServer return-tuple mutator, etc.), read the enclosing module's behaviour
set from the **context's `:behaviours` key** (a `MapSet` of module atoms, gathered by
`Transform.Behaviours` from direct `@behaviour` *and* `use`-injected ones). It is present in
`mutate/2`'s context (`%{behaviours: bs, …}`) and — via the **behaviour-aware structural
arities** `return_replacements/2`, `condition_replacements/2`, `pattern_mutations/3` (a
`%{behaviours: bs}` context appended; implement the `+1`-arity instead of the base, `Transform`
prefers it when exported) — in the structural positions too. No registration/plumbing: the
behaviours ride on each `Mutare.Mutator.Spec` (folded per module by `Transform.enrich_mutators/2`)
exactly like `opts`. `test/support/behaviour_mutator.ex` is a working example (a GenServer
`{:reply, …}` → `{:noreply, …}` swap via `mutate/2`, plus a `return_replacements/2` arm).

For a *call-matching* mutator (one targeting a stdlib/remote call), resolve the node with
`Mutare.Transform.Calls.resolved_call/1` rather than pattern-matching the raw `Mod.fun(...)`: it
returns `{module, fun, args, rebuild}` resolved through `alias`/`import`/Erlang-atom forms (or
`nil`), and `rebuild.(new_fun, new_args)` re-emits the swap in the written form. This is how the
built-in families match aliased/imported calls; a custom mutator gets the same reach.
`test/support/resolved_call_mutator.ex` is a working example. Such a mutator also fires on a
`&Mod.fun/N` **capture** of the same function for free — `Transform.Analyze.Captures` probes the
call families with a synthesized call and re-captures a rename (`Mod'.fun'` → `&Mod'.fun'/N`) or a
first-arg removal (→ `&Function.identity/1`); you write nothing capture-specific.

For an *arity-changing call* mutator (dropping a refining argument, collapsing to a coarser call),
you omit `mutate/1` and implement the optional callback
`mutate(node, %{pipe_mode: :piped | :unpiped})` — `Transform` invokes it at each runtime
call position with whether the node is a `|>` RHS, so you can compute the *effective* arity
(`Mutare.Mutator.effective_arity(args, context.pipe_mode)` — `length(args)`, plus one when `:piped`).
You must
only ever *remove* args or rename to a function that exists at the lower arity (stay compile-safe);
`CollectionArity` is the built-in example.

For a *configurable* mutator, the user gives `{Module, opts}` (not a bare module) under
`:mutators`. The `opts` arrive in the **context** of `mutate/2` as
`context.opts` — so a configurable mutator implements `mutate/2` and reads its parameters there
(`mutate/1` has no context to carry them). A reserved `:as` key in `opts` renames the recorded
family (so the same module can run twice under distinct names) and is stripped before `opts`
reaches the mutator. `Mutare.Mutators.resolve/1` turns each entry into a `Mutare.Mutator.Spec`;
`test/support/configurable_mutator.ex` is a working example. Note `pattern_mutations/2` does **not**
receive `opts` (structural head-pattern mutators aren't configurable yet — out of scope).

For a *macro-aware* mutator (one that targets a macro whose arguments must be routed specially —
a pattern, or an opaque DSL body), you declare `Mutare.Mutator.MacroAware` and implement its
`macros/0` callback returning
`{module, name, arity, treatment}` / `{module, name, treatment}` entries (treatment
`:expression`/`:pattern`/`:binding_pattern`/`:skip`; `:binding_pattern` is a pattern arg whose
bindings *escape* the macro — a `destructure`-like macro — earning structural swap/wildcard mutants
in a value-discarded position, no custom mutator needed). Listing the mutator in `:mutators`
auto-registers them in the known-macro registry (`Mutare.Macros`), so a library ships its mutator
and its macro routing in one
module. The motivating case is Ecto: register `{Ecto.Query, :from, :any, :skip}` so core leaves the
query DSL untouched, while `mutate/1` rewrites the query. The whole macro node is still offered to
the mutator (`:skip` only stops core descending into the args). The no-mutator case (just route an
argument as a pattern / leave a DSL opaque) is the declarative top-level `:macros` option.
`test/support/macro_mutator.ex` is a working example.

For a *selector-hosting* mutator (one that mutates *inside* a compile-time DSL fragment — the deep
`Ecto.from`/`where` case, where a bare selector `case` would poison the build and the fragment has
*foreign* semantics core can't vouch for), you declare `Mutare.Mutator.MacroAware`, register the
macro with a **`:hosted`** treatment (or a shape-dependent **`:routing`** classifier, implementing
`macro_routing(call_node)`) and implement
`host(macro_node, context)`. Per call core hands the **whole macro node** to `host/2`, which returns
a list of *targets*, each a map: `:original` (the logical fragment) + `:mutants` (the library's *own*
semantics catalog — **never** core's mutators, which would mis-suppress under three-valued logic) +
`:splice` (a `(macro_node, case_node) -> macro_node` weaving the woven selector in, `^`-pinned for
Ecto) + optional `:wrap` (each branch → `dynamic([u], _)`; default identity) + `:range`. Core keeps
the four cross-cutting contracts — it builds the id-gated selector `case`, assigns ids, records one
`:in_place` `Site` per mutant (the diff is the fragment swap, the scaffolding invisible), emits the
coverage catch-all, and splices. You only ever hand core `wrap`/`splice` + the logical pair, never
ids/selectors. `test/support/host_mutator.ex` (`Mutare.Test.{HostDSL,HostMutator}`) is a working
example; see NOTES "the selector host" and `Transform.emit_hosted_site/3`.

For a *collection-emptying* mutator (one whose mutation collapses a collection to an empty
one), implement the optional callback `empty_collection?(mutated_node) :: boolean()` so its
empty result earns the **in-RHS redundancy drop** (`x in <empty>` ≡ `false` ≡ Conditional, see
the equivalent-sibling suppression under emit/assign). Core recognises the *standard* empties
(`[]`/`%{}`/`~w()`/`~c""`, via `Mutare.AST.empty_collection_literal?/1`) for any mutator; the
callback is for a *non-standard* shape — a custom sigil (`~SET[]`) or a builder (`MapSet.new([])`).
No registration/plumbing: every mutation is tagged with its producing `Mutare.Mutator.Spec`, so
`Mutare.Mutator.empty_collection?/2` simply asks the producing module at drop time (discovered by
`function_exported?/2`), ORing it with the shape-based recogniser. `test/support/collection_mutator.ex`
is a working example.

## Adding a plugin

A **`Mutare.Plugin`** is the vehicle for a *non-mutating* extension — one that makes Mutare
understand a library's compile-time vocabulary so the **built-in** mutators land correctly, without
itself producing mutations. (Contrast a mutator, which has `name/0` and a mutation producer; a plugin
has neither and never shows up in a report.) Implement `@behaviour Mutare.Plugin` and either or both
optional callbacks, then list the module under `:plugins` (in `.mutare.exs` or `Mutare.run/2`) as a
bare module or a `{module, opts}` pair. The two callbacks split by kind — a **registration** (merges
across plugins, opts-independent) vs a **decision** (first-non-`:decline`-wins, opts-aware,
context-carrying):

- **`macros/0`** (registration) — same entries as a mutator's `c:Mutare.Mutator.MacroAware.macros/0`
  (`{module, name, arity, treatment}`); they **merge** into the known-macro registry. Use a *per-position*
  list to mutate the runtime arguments while skipping the compile-time-literal ones
  (`{Gettext.Macros, :ngettext, 4, [:skip, :skip, :expression, :expression]}` — mutate the count and
  the bindings, never the msgids). It is a static library fact, so it receives **no** opts/context —
  a plugin needing config reads it in `expand_use/3`.
- **`expand_use(used_module, args, context)`** (decision) — override `use`-expansion for a `use` Mutare
  can't expand in-process. Return a **`Mutare.Plugin.Expansion`** (build it with
  `Mutare.Plugin.expand(directives, behaviours \\ [])`, the directives standard-quoted, e.g. from
  `quote`) to inject the `import`/`alias`/`require` the `use` would, or `:decline` to fall through. The
  struct return (not a tuple) versions gracefully — a future field gets a default, no breaking widen.
  `used_module` is alias-resolved; `args` is the raw argument list after the module; `context` is a map
  carrying the caller `:module` and the plugin's `:opts` (from a `{module, opts}` entry), and may gain
  keys without an arity bump. Consulted **before** in-process expansion (so a raising/caller-mutating
  `__using__` is irrelevant). `:decline` is the *only* opt-out: a handler that **raises/throws** or
  returns a non-`%Expansion{}`/non-`:decline` value is a misconfigured plugin and surfaces **loudly**
  as `Mutare.Plugin.ContractError` (it aborts the run), never silently coerced to `:decline`.

The two are complementary: `expand_use/3` makes the bare DSL calls *resolve* (real `import` →
resolution → routing fires), and `macros/0` then routes their arguments. `test/support/plugin_fixtures.ex`
(`Mutare.Test.{GettextLike,GettextLikeMacros,GettextLikePlugin}`, plus `ContextPlugin` for the
opts/context path) is a working example modelling Gettext end to end; see NOTES "Plugin `use`-expansion
override". Shipping such an extension as its own package (`mutare_gettext`) means a user adds *one*
dependency and *one* `:plugins` entry — or an Igniter installer writes the entry on detecting the
library, so it is zero manual config.

## Result statuses

`:killed` / `:survived` (the product is the survivor diffs, not the headline score), plus four
that are excluded from the denominator: `:no_coverage` (no test runs the line), `:ignored`
(`# mutare:ignore` — see below), `:poisoned` (dropped — wouldn't compile), and `:harness_error` (the mutant
run never reached a verdict — a compile error, missing dep, or filesystem race — so it measures
nothing about the mutation; classified by `Mutare.Sandbox.Command`'s exit-code contract, **not**
charged as a kill). `:timeout` and `:atom_exhausted` (the mutation minted unbounded atoms and
crashed the BEAM — a resource-divergence like a timeout) both count as kills.

Every **per-status** fact lives once in the **`Mutare.Result.Status`** descriptor registry — an
ordered list of one descriptor map per status carrying its classification (`kill?`/`scored?`/
`ran?`), its Stryker/JSON name, its `summary/1` and live-counter labels, and its
`Mutare.Report.Live` leave-behind styling. The consumers *derive* from it instead of re-listing the
vocabulary: `Mutare.Result.kill?/scored?/ran?` build their constant lists from the descriptor flags
(keeping the `in`-list contract — a non-status atom answers, never raises), `Mutare.Report.summary/1`
iterates `Status.all/0` in render order, `Mutare.Report.Json` reads each descriptor's schema name
(`fetch!/1`, loud on an unregistered status like the old `Map.fetch!`), and `Mutare.Report.Live`
folds `@leave_behind`/the counter extras out of the same rows. Rows are validated against the schema
at compile time (an unknown/missing key fails the build), and `Mutare.Result.StatusTest` pins
`Status.names/0` to the `@type status` union (read straight from the compiled typespec) — so adding a
status is two edits (a row plus the type) and the five formerly-drifting lists can't diverge
silently. Note the distinct *input* vocabulary `Mutare.Sandbox.Command.outcome` → `Result.status`
(`Mutare.Runner.status_for/1`) is many-to-one (`:boot_failure`/`:suite_compile_error` collapse onto
one status), so it stays a hand-written mapping, not part of the per-status registry.

### The `# mutare:ignore` directive (`Mutare.Ignore`)

Parsed from Sourceror's comment metadata (not a raw-text scan), so a literal string that *reads*
like the directive is never mistaken for one. Trailing ⇒ own line, standalone ⇒ next line
(`previous_eol_count` decides). The grammar after the keyword has two optional, ordered parts:

```
# mutare:ignore                              suppress every mutant on the line
# mutare:ignore <free text>                  suppress all; the text is recorded as the reason
# mutare:ignore[arithmetic, relational]      suppress only those mutator families
# mutare:ignore[literal] off-by-one is fine  filter + reason together
```

The `[...]` **filter** matches a site's `mutator` name (the families in `Mutare.Mutators`, plus
`clause_drop` and any custom `name/0`); without brackets, *all* mutators match. Filtering fails
**safe** — an unknown name or empty `[]` matches nothing, so the mutant runs rather than hides,
and bracket-less trailing words are always prose, never an accidental filter. The matched
directive's reason rides onto the `Site` (`ignore_reason`) and `Mutare.Report` lists each ignored
mutant with it. `Mutare.Ignore.directives_from_ast/1` returns `%{line => [%Ignore.Directive{}]}`;
`Transform` applies it per `{line, mutator}`, not per line.

Failing safe is **silent**, so `Mutare.Ignore.ineffective/2` surfaces the directives that
suppressed *nothing* — every one no recorded site admits (a typo'd family, an empty `[]`, a
standalone line whose `line + 1` has no mutant, or a family that produced no mutant there).
`Mutare.Schema` computes them per file (`ineffective_ignores`, the substring-prefiltered re-parse
done on the **full** site set before any `--line`/`--max-mutants` trim, so a scoped run can't
manufacture a false positive); the Mix task **warns** on each to stderr at scan time, and
`--strict-ignores` (`:strict_ignores`, mirroring the `--min-score` `gate/2`) escalates them to a
non-zero abort. Detection is relative to the active run — a family disabled by `--mutators`
produces no site, so a directive naming only it is reported.
