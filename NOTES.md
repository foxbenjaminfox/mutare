# Implementation notes & deferred work

A running log of decisions made and limitations discovered while building Mutare.
`DESIGN.md` is the vision; this file tracks reality and what's intentionally left
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
in its rendered metamutant*. `Schema` builds one per mutated file (once, from the
rendered source) and stores it under `:manifests`; **`Poison`** reads it instead of
re-parsing the metamutant on every compile error. It carries the **generated line
ranges** of each mutant's code. (It used to also carry a coverage location, but
coverage now self-records by id — see *Test selection* — so the manifest is
Poison-only.)

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
- Ranges only exist *after* rendering, so the manifest re-parses with
  `Sourceror.parse_string!` (for `Sourceror.get_range/1`) — not `Code.string_to_quoted`.
  Sourceror wraps every literal in `{:__block__, _, [literal]}`, so
  `Mutare.Metamutant.subject?/1` was made tolerant of that wrapping (one recognizer,
  both parsers); the integer clause patterns are likewise unwrapped.
- A lifted private copy is attributed to its id by name (`~r/\A__mutare_.*_m(\d+)\z/`);
  `…_orig` and user code never match, so they're left out.
- `Mutare.Metamutant` shrank to just the selector-subject AST contract
  (`subject_ast/0` + `subject?/1`); the metamutant *walk* now lives in `Mutare.Manifest`.

### Sandbox isolation & dependencies `[M4 / open question]`
`Mutare.Sandbox` copies the whole project (excluding `_build`/`.git`, keeping
`deps`) to a temp dir. Consequences:
- **Path deps don't resolve in the copy.** A target using `{:mutare, path: ...}`
  (or any local path dep) breaks in `/tmp`. That's why the examples are driven via
  `mix mutare examples/<name>` (positional root) rather than depending on Mutare.
  Hex deps are fine (they're under the copied `deps/`).
- We don't run `mix deps.get` in the sandbox; relies on the original having
  fetched deps already. Fine for the common case, revisit for robustness.
- The design's open question stands: full source copy vs per-worker
  `MIX_BUILD_PATH` against one shared schema build — measure on a large umbrella.

### Umbrella support `[M5 / in progress]`
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
running every app. The dependency graph is read **authoritatively** from the
compiled `.app` files' runtime `applications` lists (`:file.consult`), which
capture both `in_umbrella` and `path:` siblings, so it can't under-report a sibling
edge the way regex-parsing `mix.exs` could; an unreadable `.app` degrades to no
narrowing (whole umbrella). A killer must execute the mutant's code, and a sibling
only reaches it through a declared dep, so owning-app + dependents is a safe
superset — we never narrow below it. Attributed coverage selections (step 3) are
left untouched.

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
is what keeps poison recovery cheap: the runner rebuilds the *same* sandbox path
repeatedly, and each rebuild is condition 3.

### `--keep-sandbox`: incremental materialisation for CI caching `[done]`
The default sandbox is throwaway: a fresh dir per run, or an owned `--sandbox`
that `reset!/1` wipes (`rm_rf` + `mkdir`) and re-copies. So "compile once" was
**per run** — `_build` is discarded between runs and the metamutant recompiles
cold every time. `--keep-sandbox` (`Options.keep_sandbox`, default `false`) makes
the sandbox *survive* between runs so mix's incremental compiler does almost
nothing on a re-run. The precondition is already true: the metamutant is
deterministic for identical input (stable mutant ids), so an unchanged source
file produces a byte-identical metamutant.

`prepare/3` branches on the flag:
- `claim!/2` skips `reset!` on an owned dir (keeps `_build`/`deps`/sources).
- `default_sandbox/2` returns a **stable** per-project temp dir (a SHA-256 of the
  expanded root) instead of a random one, so `mix mutare --keep-sandbox` alone
  reuses the same path. CI usually pins `--sandbox <cache>` instead.
- `sync/3` re-materialises in place: `put_if_changed/2` rewrites a file **only
  when its bytes differ** (size-check, then compare), so an unchanged file keeps
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

CI pattern: `--sandbox <cache-dir> --keep-sandbox`, and cache `<cache-dir>/_build`
and `<cache-dir>/deps` keyed on `mix.lock`. tar-based caches (e.g. GitHub
`actions/cache`) preserve mtimes, which is what makes the cross-run incremental
compile work. Still out of scope: `mix deps.get` in the sandbox (unchanged), and
the `MIX_BUILD_PATH` worker-isolation question below.

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
- **Guards:** mutated via lifting (M2) — operators in a `when` are swapped in a
  duplicated clause group, since a `case` can't live in a guard. The analyzer
  returns the whole `when` untouched for *in-place*; this is position-independent,
  so `case`/`fn` clause guards are skipped too. (The clause *head's* literals are
  not mutated in place either, but they **are** mutated by the same lift path — see
  "Head-pattern literals are lifted" below.)
- **Module-attribute expressions** (`@x 1 + 2`): **excluded** (context
  `:compile_time`). Such a value is frozen at compile time — `persistent_term`
  reads the default → original — so a selector there could never activate (an
  inert/equivalent mutant). The analyzer prunes the whole `@<name> <value>`
  definition. (A bare attribute *read*, `@x`, has no value list and is not
  skipped.) Pinned by a transform_test.
- **Macro bodies** (`defmacro`/`defmacrop`): **excluded** (also `:compile_time`).
  A macro body runs at expansion time, before `MUTANT_UNDER_TEST` is set at test
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
- **`quote` blocks**: **excluded** (also `:compile_time`). A `quote` *constructs
  AST* — its literals become part of the code the quote generates, which is out of
  scope (PHILOSOPHY: "macro-generated code is a different tool"), exactly like a
  `defmacro` body. And it is a *silent* poison if mutated: a selector `case`
  spliced into a quoted pattern/guard (e.g. `quote do: (case x do "" -> … end)`,
  as in `Selector.bootstrap_ast`) is valid *as a quote* — the metamutant compiles
  — but illegal where the AST is later expanded/`Code.eval_quoted`'d, so the
  pre-filter never sees it and it surfaces as a baseline failure. The analyzer
  prunes the whole `quote`. **Deferred:** `unquote(expr)` args are runtime
  sub-positions (they run when the quote is built) and are currently pruned along
  with the body; mutating them precisely (route `unquote` back to `:runtime`, like
  the `\\` default) is future work — losing them is acceptable per the philosophy
  above, and `bootstrap_ast`'s unquotes are inert (vars/atoms) anyway.
- **Bitstring type specifiers** (the right of `::` in `<<>>`): **excluded**
  (context `:spec`), *except* `size(expr)` args. A `case` is illegal as a bare
  spec / in `unit(...)`, and swapping the `-` separator yields an illegal
  specifier (`integer-big` → `integer+big`) — both compile-poison the single
  build. The analyzer keeps separators / type atoms / `unit()` raw but recurses
  into `size(expr)` args (a `case` *is* legal in `size`), so a body's
  `<<x::size(n*8)>>` still yields a real, killable size mutant; in a pattern the
  size arg is pruned. The value side (left of `::`) mutates normally.
- **Default arg values** (`def f(a \\ b + 1)`): mutated in place; live mutant.
  The head is a pattern, but `\\`'s default runs at call time, so the analyzer
  routes it back to `:runtime`. Note such functions are *not lifted* (defaults
  expand to multiple arities; normalize-then-lift is deferred), so they get no
  guard/clause-drop mutants.
- **Patterns** (clause heads, `=` match LHS): routed to `:pattern` and not
  mutated **in place** (a selector `case` is illegal in a pattern). Built-in
  arithmetic/relational operators can't legally appear in a pattern anyway, so this
  mainly shielded *custom* mutators — until the **atom** mutator (the first built-in
  that matches a bare-atom node) made the gap bite. (A `def`/`defp` *head* pattern's
  literals are nonetheless mutated — by **lifting**, not in place — see "Head-pattern
  literals are lifted" below; `=`-LHS and `case`/`fn`/… clause patterns stay
  unmutated, having no lift path.)
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
  false end`). It looks like an ordinary call, so without a dedicated `analyze`
  clause its pattern arg was routed `:runtime` and a literal/tuple/string there was
  mutated in place — splicing a `case` into a pattern ("case not allowed in
  matches"). Now routed like `=`: arg 1 `:pattern`, arg 2 the surrounding context.
  Only the bare `match?/2` form (how it is always written); a qualified
  `Kernel.match?/2` is left to poison fallback. Found dogfooding `plug` — see
  "Real-world poisons (plug/router)" below.

### Keyword/block keys are labels, never runtime values
The pair routing (`label_key?/1` + the 2-tuple `analyze` clause) is what lets the
atom mutator exist. An atom in a *value* position (`{:ok, x}` tag, a `key: VALUE`)
is mutatable; an atom in a *key* position is a structural label and must never be
offered to a mutator — a selector `case` spliced into a key is malformed and
**crashes `Sourceror.to_string` outright** (not a compile error, so *not*
poison-recoverable; it sinks the whole file's render). Two key shapes, both
`{:__block__, meta, [atom]}`: an **inline** keyword key (`a:`, `timeout:`, an inline
`do:`/`else:`) carries `format: :keyword`; a **block** key (the `do`/`else`/`rescue`/
`catch`/`after` that renders a `do … end`) carries *no* format marker, so it is
recognised by its reserved atom (`@block_keys`). A plain atom literal — a tuple tag
or a `%{:a => …}` arrow key — is neither, so it falls through and stays mutatable.
This was invisible before atom because no prior built-in matched an atom node;
integer/string/operator mutators never touch a `:do` key.

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
    skipped by the mutator (it is StringLiteral's domain, which itself skips
    interpolations); its inner expressions still mutate (the node is descended);
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

### Guard tagger is not bitstring-spec-aware `[deferred]`
`tag_targets/3` (the lifted-guard path) is a context-free `Macro.postwalk` that
runs mutators on every guard node. A multi-specifier bitstring *pattern* inside a
`when` guard could therefore lift a `-`-separator swap that compile-poisons (the
`size()`-arg subcase only produces a legal direct swap — lifting never emits a
`case`). Exotic and poison-backstopped, so left as-is. The clean fix shares the
`analyze_spec/3` spec-exclusion descent between `analyze/3` and `tag_targets/3`.

### Head-pattern literals are lifted `[done]`
A literal in a `def`/`defp` *head* — `def f(1)`, `def f(%{1 => 2})`,
`def f(:go)` — can't be mutated in place (a selector `case` is illegal in a
pattern), so for a long time heads were left untouched (the in-place `:pattern`
routing skips them). Now they are mutated by the **same lift machinery as guards**:
`FunctionPlan.build_pattern_literals/3` tags each mutatable head literal in the
shared tagged clause group (continuing the guard tag counter so tags are unique
group-wide), and each `Candidate.Pattern` materializes a `__mut` copy with that one
literal swapped — `def f(2)`, etc. The `Site` is a `:lifted` replace, identical in
shape to a guard's (`Site.lifted_replace/6`), with the literal mutator's name.

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
- Not lifted ⇒ no head mutants: default-arg functions and operator-named functions
  fall back to in-place (so their head literals are unmutated), same as their
  guard/clause-drop mutants.
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
  literals; and
- a `case`/`receive`/`fn` *clause* pattern — **in place** (`Candidate.CasePattern`), since
  none is a function clause group to lift.

The three in-place constructs share one analyze path (`attach_clause_pattern_candidates/4`)
parameterized by *the clause list* and *a rebuild closure* — the only things that differ
(`case` has a subject + a single `do` block; `receive` has a `do` block plus an optional
`after` whose timeout is **not** a pattern and is skipped; `fn` *is* its clauses, with
multi-argument heads). Each clause's pattern *positions* are iterated, so a single-pattern
`case`/`receive` clause and a multi-arg `fn` clause are handled uniformly; a duplicate
*across* fn arguments (`fn x, x -> …`) is not seen (each position is mutated independently),
only a duplicate *within* one argument (`fn {x, x} -> …`) — a small, rare gap.

`=`-LHS is excluded (a selector `case` around a match would lose its bindings); `with`/
`for`/`try` are deferred. The shared discovery primitives (`mutators/1`, `used_names/1`,
`node_mutations/3`) live in `Transform.PatternStructure`, used by every path.

Several design choices worth remembering:

- **Structural via an optional callback, discovered by export.** `mutate/1` is `:skip`;
  the real entry point is `Mutare.Mutator.pattern_mutations/2` (`@optional_callbacks`),
  taking `(head_args, used_outside)` and returning mutated arg lists. It is discovered by
  `function_exported?(_, :pattern_mutations, 2)` — so no hard-coded list (unlike the
  `ReturnValue in mutators` check), toggling is just list membership, and a custom mutator
  can opt in. The head path (`FunctionPlan.build_pattern_structures/2`) calls it with the
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
  reachable. `branch_node/1` picks `replacement` for a `CasePattern`, `mutated` for every
  other in-place candidate.

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
  `Candidate.Guard`, `Candidate.Drop`), shared by in-place and lifted alike.
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
  building the selector `case` and dispatcher) stays in `Transform` — it shares
  the `Ctx` id-threading discipline across in-place and lifted paths too tightly
  to separate cleanly (`claim_id/4` is the single owner of that dance).

### Transform IR — typed candidate variants + plan structs `[refactor, done]`
The earlier `%Candidate{}` was one struct that stored `context` *and* its two
consequences (`kind`, `operation`) as separate fields, so the type admitted
illegal combinations (a `:clause_drop` claiming to be `:in_place`/`:replace`)
that only discipline kept out — and every **guard** candidate carried a full
copy of the clause group with its one guard pre-swapped (`mutated_clauses`), N
near-identical copies for N guard mutants. Both are fixed:
- **One struct per legal kind.** `Candidate.{InPlace,Guard,Drop}` — the
  `context`/`kind`/`operation` triple is gone; the variant *is* the kind, and the
  matching `Site` constructor is chosen by pattern-matching the struct at emit
  (`in_place_site/3` / `lifted_site/3`). Illegal states can't be built.
- **The clause group is stored once.** `FunctionPlan` holds a single *tagged*
  clause group (every mutatable guard operator marked with a unique
  `meta[:mutare_tag]`, the tag counter threaded across clauses so tags are
  group-unique); each `Candidate.Guard` carries only its `tag` + replacement.
  `FunctionPlan.mutated_clauses/2` reconstructs a copy on demand
  (`replace_tag/3` for a guard, `List.delete_at/2` for a drop). Leftover tags on
  sibling operators are stripped before rendering, so the rendered metamutant is
  identical to the old per-candidate-copy output.
- **`ModulePlan` is the module-planning stage.** `build/3` chunks a statement
  sequence into `{:lift, FunctionPlan}` / `{:in_place, clauses}` / `{:statement,
  node}` items (run chunking, non-consecutive detection + the warning), and owns
  `clause_signature/1`. `Transform.emit_module_plan/2` walks the items in order.

### Function lifting (M2): sharp edges `[various]`
- **Recursion bounces through the dispatcher.** A self-call inside a lifted copy
  hits the public dispatcher and re-dispatches — correct, LCO survives, but ~2×
  the calls. Self-call redirection (point self-calls at the active copy) is
  deferred (DESIGN open question / v2).
- **Error provenance shifts.** `FunctionClauseError` now raises from the lifted
  private fn (`__mutare_f_1_g3_orig`), so its message names that, not `f`.
  Irrelevant to kill/survive; mildly ugly in raw error output.
- **`@doc`/`@spec`/`@impl`** ride on the public dispatcher because we emit it
  *first* in the lifted group (attributes attach to the next def). Private copies
  are `defp` (no docs needed). Not exhaustively tested across attribute shapes.
- **Not lifted (fall back to in-place):** functions with default args,
  operator-named functions (`def a ~> b` — can't be spelled `__mutare_~>_2_…`),
  and functions with non-consecutive clauses (see the dedicated note below).
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
  pointing at the fix (group the clauses). **Deferred:** the cases we *can* lift
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

  `metaprogrammed_def_names/1` collects every name `def`/`defp`'d *inside* a
  non-clause statement (pruning nested `defmodule`/`defimpl`/`defprotocol`, a
  different scope), and `plan_clause_group/4` refuses to lift any clause group
  whose name is in that set — falling back to in-place exactly like the
  non-consecutive case. Keyed by **name only** (not name/arity): a generated
  head's arity can be obscured by metaprogramming, and over-refusing only costs
  guard/clause-drop mutants, never correctness. Not silent —
  `warn_metaprogrammed/2` logs once per blocked signature (it is not
  user-fixable; the generated clauses are intentional). Note the sibling functions
  `reason_atom/1` / `reason_phrase/1` in the same file were *already* safe via the
  non-consecutive path (their two literal clauses straddle the `for`), so this
  closes the remaining hole where the literal clauses happen to be consecutive.
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
  generated functions. The unquoted head pattern (`def code(unquote(atom))`) is
  analyzed `:pattern` and never mutated — correct, since these are not lifted.
  **Crucially**,
  the *mixed* case works for free: when a function has both a normal top-level head
  and metaprogrammed heads (`def code(0), do: 53` beside the `for`), the top head
  falls back to in-place via `metaprogrammed_def_names` and the `for` heads route
  through `:scaffold` — both bodies mutate in place, independently (no dispatcher, so
  no shadowing). Still **out of scope**: mutating inside `unquote(expr)` (compile-time
  splice; deferred, as for `quote`), and lifting any of these
  (head-pattern/guard/clause-drop mutants).
- **Private names** are `<prefix><name>_<arity>_g<group>_{orig,m<id>}`. The
  group counter keeps generated names unique *among themselves*, and `?`/`!`
  (legal only at a name's end) are replaced so they can sit mid-identifier. The
  public dispatcher keeps the real name.
- **The prefix is collision-checked, not a fixed string.** `<prefix>` is
  normally `__mutare_`, but a single clash with a hand-written target definition
  is catastrophic — a duplicate `defp` sinks the *one* metamutant build with a
  cryptic compile error — so `Transform.generated_prefix/1` scans the source's
  own def-like names (`@def_forms`) once per file and shifts to `__mutare_0_`,
  `__mutare_1_`, … (the first stem no existing name is a prefix of) when the
  target already defines a `__mutare_`-prefixed name. Every candidate still
  *starts* with `__mutare_`, so `Manifest`'s `~r/\A__mutare_.*_m(\d+)\z/`
  recogniser keeps working unchanged. Common case (no `__mutare_` names in the
  target): zero change, prefix stays `__mutare_`. The dispatcher's `mutare_argN`
  params are fresh locals in a generated head and can't collide, so they need no
  such treatment. (The selector's `:persistent_term` key is a *separate* global
  collision surface — deliberately left as the fixed `:mutare_active`; see the
  self-hosting note below.)
- **Lifting duplicates whole functions** (K+1 copies for K lifted mutants), so
  code size / single-compile time grows with mutation density on overloaded
  functions — the accepted cost (first-order ⇒ no copy sharing).

### Timeouts — portable self-halt (M4 done) `[refine]`
A mutation can turn a terminating loop infinite. Each mutant run gets a
wall-clock cap (`baseline × :timeout_multiplier`, default 3.0, floored; or an
explicit `:timeout` ms), and a timeout counts as a kill (`:timeout`).

The cap is enforced **portably, with no process-killing**: the injected sandbox
watcher (a quoted AST owned by `Mutare.Sandbox.Command.watcher_ast/0`, rendered
into the bootstrap by `Mutare.Sandbox`) spawns a process that `System.halt(124)`s
after the deadline. The BEAM preempts a looping process, so the watcher always runs (even
on a tight infinite loop — confirmed); if the suite finishes first the watcher
dies with the VM; exit 124 ⇒ timed out. This replaced an earlier Port + `kill`/
`ps` process-group approach (Unix-only, and `Port.close` alone did *not* kill a
hung beam — SIGTERM is trapped). Caveat: a hang that wedges *every* scheduler in
a non-yielding NIF could starve the watcher — not reachable from mutating Elixir
source, so not handled.

False-timeout guard: the cap floor is 10 s. The baseline is measured uncontended
but mutants run under parallel-worker contention, so a tight cap was
false-timing-out slow-but-finite mutants (a non-deterministic false kill, seen in
testing). A true infinite loop overruns any floor, so the generous floor keeps
correctness without missing real hangs. Per-covering-file caps would be tighter
and more precise — a refinement.

### Parallel workers (M4 done) `[refine]`
The per-mutant phase runs `:workers` mutants concurrently (default
`System.schedulers_online/0`) via `Task.async_stream` in the shared sandbox.
Concurrent `mix test` in one sandbox contends on mix's build lock ("Waiting for
lock…") and, since each spawns a full BEAM, oversubscribes CPU — a real but
bounded overhead (4 workers gave ~2.4× in a spike). The design's open question —
per-worker `MIX_BUILD_PATH` vs full source copy — would remove the contention;
deferred. Default workers may be worth lowering from schedulers_online to cut
oversubscription.

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

Deferred: the same shape exists for *any* compile-time-executed code (compile-time
`@attr` expressions, `EEx`/`use`-time calls, custom route DSLs). The discriminator is
general (any test-script compile error), so those are covered too — but if a target
compiled lib modules *lazily* per-run (it doesn't today; the metamutant is built
once), a lib compile error here could be a real kill we conservatively keep as a
harness error. Acceptable while "lib compiles once" holds.

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
`Sandbox` writes into the sandbox). Two keys, accumulate-only, **never reset** →
no race:
- **aggregate** `{id}` — written by any process → process-agnostic no-coverage
  detection.
- **attribution** `{{label, id}}` — `label` is the test process's
  `Process.set_label({case, name})` (proc-dict `:"$process_label"` on OTP 26,
  `:proc_lib.get_label/1` on 27+) → maps to the test *file* → per-file selection.

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
Reconciliation, per id: never ran → `:no_coverage`; ran with attributed files →
`{:run, files}`; ran but **unattributed** (covered only by an unlabeled process —
`setup_all`/`on_exit`/a spawned task) → `{:run, []}` (whole suite), *not*
`:no_coverage`. `:run_all` is the single conservative fallback: a non-zero probe
exit (the dump may be partial — e.g. `max_failures` aborts before later files),
an unreadable dump, or an empty dump (the capture recorded nothing → it likely
failed). The rule throughout: never skip on doubt — run everything rather than
silently drop a mutant from the score's denominator.

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
`dedup`/`shuffle`, `List.flatten`, `String.trim`/`downcase`/… — leaving its first
arg; in a pipe, replace the stage with `Function.identity()`; pipe-aware via
`mutate/2`), **default_drop** (drop a trailing default/fallback — `Map.get`/`pop`/
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
  `Transform` invokes at every runtime call position with `%{piped: boolean}` (a
  dedicated `:|>` analyze clause routes the RHS through `analyze_pipe_stage/2` with
  `piped: true`; everywhere else defaults to `false`). The mutator computes
  `effective_arity = length(args) + if(piped, do: 1, else: 0)` and emits a normal
  `Candidate.InPlace` — so the existing selector + `hoist_pipe` machinery delivers
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
- **`Site.original_op`/`mutated_op` are `:__block__` for literal sites** (they
  come from `elem(node, 0)`), which is fine — reports use the rendered
  `original_code`/`mutated_code` (`1 → 2`), not the op atom; the op fields are
  only used by tests/lookups that key on real operators.

Knock-on test work: the routing-focused `transform_test`/`schema_test`/
`lift_test`/runner fixtures that asserted exact site counts now **pin
`mutators:`** to the operator-swap families (`@probe`) — they test context
routing and lifting mechanics, not the default set, so pinning keeps their
counts stable while positive coverage of the new defaults lives in
`mutators_test` and one dedicated `transform_test`.

### Return-value mutators `[done]`
PIT's largest, highest-yield group, now implemented: replace a function clause's
**return value** (its body's tail expression) with a fixed constant. Very high
signal — it asks directly "does any test pin what this function returns?". On by
default (`:return_value` family).

**Why it's structural, not a `Mutare.Mutator`.** Node-level mutators (`mutate/1`)
rewrite a matched node *wherever it occurs*; a return-value mutation targets the
*tail expression of a clause body*, a position only the transform knows. So the
real work is `Mutare.Mutators.ReturnValue.replacements/1` (a pure tail→constants
function), invoked by `Transform` once per `def`/`defp` `:do`-block tail it finds
(`annotate_returns/3`). The module still implements the behaviour — `name/0` is
`:return_value`, `mutate/1` is `:skip` — purely so it sits in the `Mutare.Mutators`
registry and inherits everything that follows from membership: on-by-default,
named in reports, selectable/validatable via `:mutators`, filterable by
`# mutare:ignore[return_value]`. (Contrast `clause_drop`, the *other* structural
built-in, which is always-on and not in the registry — return-value is registered
because it is high-volume and users will reasonably want to toggle it.)

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
    atom, `if`/`case`/`with` result, …) → `nil` and `:mutare`

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
targeted (`Transform.annotate_returns/3` → `annotate_block_returns/3`): the `:do`
tail via `attach_return/2`, and each clause body tail via `attach_clause_returns/2`.
**`:after` is deliberately excluded** — `try` discards the after block's value, so
its tail is *not* a return path (a mutant there would be unobservable). The after
*body* still mutates in place; only its return-value candidate is withheld.

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

The `Site` each return mutant records (`Site.return_value/5`) has
`mutator: :return_value`, `kind: :in_place`, and `nil` ops (there is no operator),
shaped like the clause-drop site that also carries no op.

### Equivalent mutants `[partial]`
Per DESIGN's "don't emit obviously-equivalent mutations" mitigation, the
arithmetic mutator skips the multiplicative-identity swap on a right operand
(`a * 1`, `a / 1`) — only the right operand, since `1 * a → 1 / a` is a
reciprocal. `div`/`rem` are never identities (`rem(a, 1)` is `0`).

We deliberately do **not** skip `a + 0` / `a - 0`: adding/subtracting a literal
zero is genuinely observable when normalizing `-0.0` (`x + 0.0` clears the sign,
`x - 0.0` keeps it), so that mutant is a real check on whether such code is
tested. (`a * 1` vs `a / 1` is also not strictly equivalent — `/` yields a float
— but that int→float difference is `==`-invisible and rarely intentional, so we
treat it as noise.) See `Mutare.Mutators.Arithmetic`.

`# mutare:ignore` (done) is the manual escape hatch: a trailing comment ignores
its line, a standalone comment the next line; matching mutants are recorded
`:ignored` — not run, kept out of the score's denominator (`killed / (total −
no_coverage − ignored)`), surfaced in the summary. Parsed from Sourceror's
comment metadata (`Mutare.Ignore`), not a raw-text scan — each comment's
`previous_eol_count` (`0` ⇒ trailing, `≥ 1` ⇒ standalone) drives the
classification, and a literal `"# mutare:ignore"` *string* is never mistaken for
a directive (the old text scan accepted it). It still *generates* the (unused)
selector for an ignored mutant, so it does **not** rescue a compile-poisoning
mutant — that's the compile-poisoning pre-filter's job, not ignore's.

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
  hidden. We deliberately *don't* validate filter tokens against the active
  mutator set: custom mutators have arbitrary `name/0` values that `Ignore` (which
  sees only source) can't know, so a warning there would false-positive. If we
  ever want typo-warnings, cross-check in `Transform`, which knows the live set.

Suspected-equivalent auto-reporting is still future work.

### Self-hosting: tests that touch `:mutare_active` `[dogfood artifact, partly mitigated]`
Mutation-testing Mutare *with Mutare* has a trap: several of Mutare's own tests
(`selector_test`, `integration_test`, `lift_test`, `transform_corpus_test`) call
`Selector.put/1` on `:mutare_active` — the very key the runner uses to hold the
active mutant. Since `:persistent_term` is global and the whole suite shares one
BEAM, those tests reset the active mutant mid-run, so any mutant whose only
killing test runs *after* them registers a **false survivor** (confirmed:
`runner.ex` mutants survive in the full suite but die when `runner_test` runs
alone). Normal targets never touch this key, so it's a self-hosting artifact only.

What's in place now (dogfood run, M-ignore work):
- **Sandbox skips `:runner` tests.** `test/test_helper.exs` calls
  `ExUnit.configure(exclude: [:runner])` iff `MUTANT_UNDER_TEST` is set — which is
  true on every per-mutant run (and the baseline) but never on a normal `mix
  test`. Those tests shell out to nested `mix test`; running them per mutant would
  be a fork bomb. (It does *not* fix the collision — the remaining saboteurs above
  aren't `:runner`-tagged.)
- **`Selector.put/1` is `# mutare:ignore`d.** Its only mutants are in the
  active-mutant guard, and the only way to exercise `put/1` is to *call* it, which
  overwrites `:mutare_active` — so under dogfooding the mutant either deactivates
  itself (false survivor) or crashes a setup `put` (false kill). Neither measures
  the mutation. Excluded with a reason; on a normal target the guard is killable.
- **`Selector.bootstrap_ast` / `Command.watcher_ast` no longer break the
  baseline.** Both build a `quote` containing a `case … "" -> …` clause; the
  transform used to mutate the `""` *pattern* inside the quote and wrap it in a
  selector `case`. That compiles fine *as a quote* but is an illegal pattern where
  the AST is later compiled (`selector_test` evals `bootstrap_ast()`), so the
  **baseline run failed and aborted the whole dogfood** — a poison the pre-filter
  can't see (the metamutant itself compiled). Fixed by classifying `quote` as
  compile-time (pruned whole, like `defmacro`); see "Non-body operator positions".

Still open for *clean* whole-suite self-dogfooding: the remaining saboteurs
(`lift_test`/`integration_test`/`transform_corpus_test`) still collide, so
`Transform`-and-friends mutants keyed off them show false survivors. `# mutare:ignore`
is the wrong tool there — those are real, killable mutants, not equivalents. The
proper fix is isolation: run the selector-touching tests in a separate pass, or
make the harness key configurable so the suite-under-test and the harness don't
share `:mutare_active`.

### Surface skipped files more loudly `[soon]`
`Schema`/`safe_transform` skips a file that fails to transform (good — one bad
file shouldn't sink the run) and the task prints `skipped <file>: <reason>` in
its banner. But that's easy to miss, and it's exactly how the two
compile-poisoning bugs below hid. Consider a `--strict` mode that fails on any
skip, and/or making poisoning structural exclusions (below) the norm.

### Live human progress (`Mutare.Report.Live`) `[done]`
The human run used to print a test-runner stream of symbols (`.`/`S`/`T`/…) via a
bare `IO.write` in the Mix task. It's now a cargo-mutants-style live display: phase
notes as the run advances, a permanent line left behind for each survivor (the
product) plus timeouts and harness errors (problems worth surfacing live), and — on
a tty — a bottom status block (spinner + the in-flight mutant + a counter with an
ETA) that animates via an internal tick timer. Design decisions worth remembering:

- **It's a `GenServer`, because the hooks fire concurrently.** `:reporter`/`:on_start`
  are called from many `Task.async_stream` workers at once, so every terminal write
  must funnel through one owner. Reports/starts/phases are `cast`s (workers never
  block on rendering); `finish/1` is a `call`, and since all casts were *sent* (mailbox
  delivery complete) before the stream returned, FIFO guarantees `finish` sees the
  final state and clears the block before the after-the-fact `Mutare.Report` prints.
- **stderr, always; animation, conditionally.** Output goes to stderr so a machine
  report piped to stdout (`--format json > f`) is never corrupted. Animation is gated
  on `detect_ansi/0` = a real **stderr** tty (`:io.columns/1` succeeds) *and*
  `IO.ANSI.enabled?`. We key on stderr (not stdout) deliberately; the cost is that
  redirecting stdout (which flips `IO.ANSI.enabled?` off at boot) drops us to plain
  mode even if stderr is a tty — acceptable (safe, just less fancy). Plain mode =
  phase notes + leave-behind lines as ordinary scrollback, no cursor codes, no spinner
  — exactly what CI logs want.
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
  one activity line), and a permanent "baseline green in Ns" timing note (would need
  threading `baseline_ms` through `:on_phase`).

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
  Fixed by routing `match?/2`'s first arg `:pattern` (see "Non-body operator
  positions" → Patterns). Two of the "7" were *collateral*: poison maps a compile
  error's line → every mutant id whose generated code spans it, so the valid
  `Enum.reject`→`Enum.filter` swaps sharing those lines were dropped too. Handling
  the root cause both removed the 5 real poisons and recovered the 2 valid mutants.
- **Selector as a pipe target (2 of the 7, fixed):** the recovered `reject`→`filter`
  swaps then revealed a second, independent shape — a mutated **pipe stage**.
  `x |> Enum.reject(f)` puts the call right of a `|>`; wrapping it in the selector
  yields `x |> case … end`, which *parses* but fails `Kernel.|>/2` expansion
  ("misplaced operator `->`") — so `Code.string_to_quoted` was not enough to catch
  it (the regression tests `Code.compile_string`). Fixed by hoisting the pipe into
  the selector (`hoist_pipe/1`): each branch becomes `lhs |> <branch>`, leaving a
  standalone `case` that is itself a valid pipe LHS, so chained pipes nest. Two
  spots needed it: the parent `|>` in the emit postwalk (a plain pipe stage), and
  `emit_site`'s catch-all default (a tail pipe that *also* carries a ReturnValue
  candidate, so the `|>` node goes through `emit_site` rather than the postwalk's
  pipe branch). The bare stage stays the Site's recorded node, so diffs are clean.

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
  symmetric second half: `Mutare.Sandbox.Command.watcher_ast/0` is its canonical
  quoted AST, owned next to the timeout env var and exit code, and the sandbox
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
- **`--since <ref>` (done).** `Mutare.Changes.since/2` runs `git diff
  --name-only --relative <ref>` with `root` as cwd, giving root-relative changed
  files (committed + uncommitted); `Schema`'s `:only_files` intersects discovered
  files with that set, so it composes with `--only`/paths. Limits: untracked new
  files aren't reported by `git diff` (commit them); only the changed files
  themselves are mutated, not files that transitively depend on them; `--since`
  assumes `root` is inside the repo.
- **Custom mutators (done).** `Mutare.Mutator` is the public extension point:
  `mutate/1` + `name/0`. `:mutators` in `.mutare.exs` accepts built-in family
  atoms *and* any module implementing the behaviour (validated, with a helpful
  error otherwise). Dropped the old `kind/0` callback — it was vestigial and
  misleading: placement (in-place selector vs lifting into a guard) is decided
  by the node's *position*, not declared by the mutator. Limit: `mutate/1` does
  node-level mutations; structural mutations (clause-drop) remain built-in only,
  not expressible by a custom mutator. CLI `--mutators` CSV is for built-in
  families (short names); custom modules go in `.mutare.exs`.
- **Validated options struct (done).** The shared keyword list that threaded
  through `Config → Schema → Runner → Sandbox` is now `Mutare.Options`, built and
  validated once by `Options.new/1` at each public entry point (idempotent on a
  struct, so the pipeline normalizes once and passes the struct down). Validation
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
  - **Retry** (`:harness_retries`, default `1`). A harness error can be
    *transient* (a filesystem/lock race under parallel workers), so the runner
    re-runs a harness-erroring mutant up to N times before recording it — a fresh
    `mix` boot is its own natural backoff. Only `:harness_error` is retried; a
    real verdict (passed/failed/timeout) never is. Retry lives in the runner's
    `run_mutant/5`, *not* in `Command` — `Command` does one clean run and reports
    its outcome; whether to re-run is an orchestration decision. (So
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
    callback. The collision rule lives in `Config.resolve_reporters/2`: `--format`
    with `--output` writes the machine format to a file *and* keeps the human
    report on the console; `--format` alone takes stdout and drops the human
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
  - **Decision: abort-and-name, not quarantine.** Matches DESIGN's "abort loudly"
    and "mitigate, don't pretend": we refuse to score a flaky suite rather than
    guess which tests to drop. **Deferred** as a follow-up: *quarantine* the flaky
    tests and proceed over the stable subset (needs the exclusion threaded through
    the baseline re-measure, the coverage probe, *and* every per-mutant run — and a
    reduced-suite score is a soundness caveat to surface).
  - **Deferred — Layer 2 (`--runs`/rerun-kills).** A residual flake only visible
    under one mutant's timing escapes a green baseline. The fix: re-run each
    *killed* mutant up to N times and demote to `:survived` if any re-run fails to
    kill (**unanimous-kill** — the honest combine rule; "any-kill" defends the
    wrong direction). Under unanimous-kill only kills need re-running, so the honest
    rule is also the cheap one; it's a near-copy of the `:harness_retries` machinery
    in `run_mutant/5`. Orthogonal to harness retries (that's infra flakiness, this
    is test flakiness). Not built here.
