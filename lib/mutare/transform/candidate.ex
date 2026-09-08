defmodule Mutare.Transform.Candidate do
  @moduledoc false

  # The typed, pre-id description of a single mutant: what to mutate and where.
  # Produced by the analyzer / planner and consumed by emission.
  #
  # There is no single `%Candidate{}` struct: each legal *shape* of a mutant is its own struct.
  # The old single struct carried `context` *and* its two consequences (`kind`, `operation`) as
  # separate fields, so the type admitted nonsense states — a `:clause_drop` that claimed to be
  # `:in_place` and `:replace`, say — that only discipline kept out. One struct per valid
  # combination makes the illegal ones unbuildable. `kind`/`operation` aren't fields: they're
  # implied by *which* struct it is, and recovered at emission when the matching `Mutare.Site` is
  # built. Placement (in-place vs lifted) stays positional — the analyzer picks the variant from
  # where the node sits; the mutator never declares it. The candidate-design rule: **no
  # discriminant field — the struct *is* the shape** (a `kind` enum would just let the impossible
  # states back in).
  #
  # Each variant's own `@moduledoc` (below) documents what it represents and how it is delivered.
  # The variant → {`Mutare.Site` constructor, node-local emit route, selector branch} mapping is
  # *not* spread across the structs: it lives in one table, `Mutare.Transform.Candidate.Delivery`,
  # so the three facets can't drift apart and adding a variant is one row there. There is
  # deliberately no enumerated catalogue in this comment — that list is exactly what drifted (it
  # said "three legal shapes" while the structs had grown past a dozen); the structs below and the
  # `Delivery` table are the catalogue.
  #
  # The excluded positions — `:compile_time` (module-attribute values and macro
  # bodies), `:spec` (a bitstring type specifier), `:capture_arity` (the `/` in
  # `&fun/arity`) — never become candidates at all; the analyzer classifies them
  # positively and skips them (see `Mutare.Transform`'s `analyze/3`). `:pattern` is
  # excluded *in place* (a `case` is illegal in a pattern), but a `def`/`defp` head
  # pattern's *literals* are mutated by lifting (`Candidate.Lifted`), the same way
  # guards are.

  defmodule InPlace do
    @moduledoc false

    # A body-expression operator swap. Rides in the mutated node's own
    # `meta[:mutare]` so emission finds "this exact node" without a fragile
    # `{line, column}` identity. `original` is the raw (un-annotated) node — what
    # the report renders — and `mutated` the replacement the mutator produced.
    #
    # `call_option_key?` flags an in-place candidate that mutates the *key* of a keyword
    # list passed as a call's final argument (`foo(x, timeout: 5)` → `timeout:`). The
    # analyzer tags it (it alone knows the call context); emission asks the candidate's
    # own mutator through `c:Mutare.Mutator.mutate_call_option_keys?/1` whether to keep it.
    # This lets a context-free atom family suppress noisy option-name changes without
    # imposing the same policy on call-aware rewrites. Default `false` — every other
    # candidate is a normal mutation, never gated.
    #
    # `pin?` flags an in-place candidate whose selector `case` must be **`^`-pinned** —
    # the value sits in a compile-time DSL position that accepts an interpolated value but
    # not a bare `case` (an Ecto keyword-shorthand value, `where(q, category: "Foo")`,
    # where Ecto rejects a raw `case` but accepts `^(case …)`). Set by the `:interpolated`
    # argument treatment (`Mutare.Transform.Analyze.route_macro_arg/3`, adapter-grade);
    # emission wraps the built selector in `^`. Default `false` — pinning is illegal outside
    # such a context (a bare `^` is a compile error), so only a deliberate route sets it.
    #
    # `note` carries the optional per-mutant advisory the producing mutator attached (a
    # `%Mutare.Mutator.Mutation{}` return from `mutate/1`/`mutate/2`); it rides through to the
    # `Mutare.Site` for the report. Default `nil` — an ordinary mutation has no note.
    #
    # `variant` carries the `# mutare:ignore` label(s) a value family tagged at production time
    # (the `%Mutare.Mutator.Mutation{}`'s `variant`); it rides through to `Mutare.Site`, where it
    # takes precedence over the `c:Mutare.Mutator.variant/2` derivation. Default `nil` — an operator
    # family (or an untagged mutation) leaves the label to be derived from the node.
    #
    # `attribution` is the optional report-location override (a `%Mutare.Mutator.Mutation.Attribution{}`
    # from `Mutare.Mutator.Mutation.at/2` / `at_drop/1`), carried when a `mutate/2` returned a
    # **whole-node rewrite** whose textual footprint is one inner clause (the motivating case:
    # `mutare_ecto` rebuilding a whole `from(...)` but changing only its `order_by:`). It decouples
    # the site's *location + diff* (the clause the plugin names) from the *selector* (which still
    # splices `original`/`mutated`, the whole node, to build the metamutant): `Candidate.Delivery`
    # reads it and records a clause-level replace or delete `Mutare.Site` instead of one pinned to
    # the offered node. Validated at attach time (`Attach.build_candidates/2` drops a clause that is
    # unrangeable or escapes the node's span). `attribution_range` is the already-normalized range
    # validated there; delivery uses it instead of recomputing from `attribution.original`, because
    # Sourceror can over-count a clause ending in bare `true`/`false`/`nil` by the following
    # delimiter. Defaults `nil` — an ordinary mutation is reported at the offered node, exactly as
    # before.

    @type t :: %__MODULE__{
            mutator: Mutare.Mutator.Spec.t(),
            original: Macro.t(),
            mutated: Macro.t(),
            range: Sourceror.Range.t(),
            call_option_key?: boolean(),
            pin?: boolean(),
            note: String.t() | nil,
            variant: Mutare.Mutator.Mutation.variant(),
            attribution: Mutare.Mutator.Mutation.Attribution.t() | nil,
            attribution_range: Sourceror.Range.t() | nil
          }

    defstruct [
      :mutator,
      :original,
      :mutated,
      :range,
      call_option_key?: false,
      pin?: false,
      note: nil,
      variant: nil,
      attribution: nil,
      attribution_range: nil
    ]
  end

  defmodule Lifted do
    @moduledoc false

    # A single tagged-node replacement inside one *lifted* clause, delivered by a
    # dispatcher clause gated `when mutare_active === <id>`. Two discovery positions
    # share this one representation because they are delivered *identically* — tag a
    # node in the *shared* tagged clause group held once on the
    # `Mutare.Transform.FunctionPlan`, then in the one gated mutant clause replace that
    # node with `mutated` (`FunctionPlan.mutated_clause/2` reconstructs *just that one
    # clause*):
    #
    #   * a `when`-**guard** operator swap (a `case` can't live in a guard), and
    #   * a **head-pattern literal** swap (a selector `case` is illegal in a pattern,
    #     so a literal in a head — `def f(1, %{0 => k})` — can only be lifted).
    #
    # They differ only in *where* the tagged node sits (the `when` vs the head args)
    # and which families reach it (head literals admit only literal-valued mutations,
    # so the gated clause is always a legal pattern) — both enforced at *discovery*
    # (`build_guards` vs `build_pattern_literals`, the distinct `Tag` walks), not by
    # the candidate. Nothing downstream tells them apart: emission records both as the
    # same `:lifted` replacement `Mutare.Site`, the mutator family (an operator family
    # vs a literal family) being the only visible difference. This keeps to the
    # candidate-design rule — no discriminant field; the struct *is* the shape.
    #
    # `tag` is the unique `meta[:mutare_tag]` marking the target inside the tagged
    # clause group; `clause_index` is the clause it lives in. `note` carries the producing
    # mutator's optional per-mutant advisory (a `%Mutare.Mutator.Mutation{}` return) through
    # to the `Mutare.Site`; `nil` for an ordinary mutation. `variant` carries the production-time
    # `# mutare:ignore` label(s) (a value family's tagged head literal), `nil` when derived.

    @type t :: %__MODULE__{
            tag: non_neg_integer(),
            clause_index: non_neg_integer(),
            mutator: Mutare.Mutator.Spec.t(),
            original: Macro.t(),
            mutated: Macro.t(),
            range: Sourceror.Range.t(),
            note: String.t() | nil,
            variant: Mutare.Mutator.Mutation.variant()
          }

    defstruct [
      :tag,
      :clause_index,
      :mutator,
      :original,
      :mutated,
      :range,
      note: nil,
      variant: nil
    ]
  end

  defmodule PatternStructure do
    @moduledoc false

    # A whole-head *pattern restructuring* of one clause, delivered by lifting — a
    # variable swap (`{x, y}` → `{y, x}`) or a duplicate-variable wildcarding
    # (`f(x, x)` → `f(_, x)`). Like a `Lifted` head literal it lives in a clause head;
    # unlike one (a single tagged node) the rewrite spans/replaces sub-patterns that may have
    # no taggable metadata (a 2-tuple, a list), so it is applied by **whole-clause
    # rebuild by index** — the same mechanism as `Drop`. `clause_index` says which clause
    # to rebuild; `Mutare.Transform.FunctionPlan.mutated_clause/2` swaps in `mutated_args`
    # as that clause's head pattern args. `original`/`mutated` are the clause's head *call* node
    # before/after (always rangeable, so the report renders a clean one-line diff), and
    # `mutator` is the structural family that produced it (`PatternSwap`/`PatternWildcard`).

    @type t :: %__MODULE__{
            clause_index: non_neg_integer(),
            mutator: Mutare.Mutator.Spec.t(),
            mutated_args: [Macro.t()],
            original: Macro.t(),
            mutated: Macro.t(),
            range: Sourceror.Range.t()
          }

    defstruct [:clause_index, :mutator, :mutated_args, :original, :mutated, :range]
  end

  defmodule CasePattern do
    @moduledoc false

    # A rescue type-list narrowing, delivered by a whole-try selector. `replacement`
    # is the complete try with one rescue clause changed; `original`/`mutated`/`range`
    # describe just that type-list edit for the in-place Site. The historical name
    # predates per-clause delivery: cases, fns and receives now have their own variants.

    @type t :: %__MODULE__{
            mutator: Mutare.Mutator.Spec.t(),
            original: Macro.t(),
            mutated: Macro.t(),
            replacement: Macro.t(),
            range: Sourceror.Range.t(),
            note: String.t() | nil,
            variant: Mutare.Mutator.Mutation.variant()
          }

    defstruct [:mutator, :original, :mutated, :replacement, :range, note: nil, variant: nil]
  end

  defmodule FnClause do
    @moduledoc false

    # One anonymous-function clause with its pattern/guard mutated and its body raw.
    # FnClauseEmit interleaves it before its original, guarded by the selector captured
    # at closure creation. The report still describes just original → mutated, in place.
    # `raw_fn` shares the original immutable AST (no clause-list rebuilding per candidate).
    # Only emission in a scope without a bound selector uses it to rebuild a whole-function
    # fallback: introducing a capture there would change the bindings visible to macros.
    @type t :: %__MODULE__{
            clause_index: non_neg_integer(),
            mutant_clause: Macro.t(),
            raw_fn: Macro.t(),
            mutator: Mutare.Mutator.Spec.t(),
            original: Macro.t(),
            mutated: Macro.t(),
            range: Sourceror.Range.t(),
            note: String.t() | nil,
            variant: Mutare.Mutator.Mutation.variant()
          }

    defstruct [
      :clause_index,
      :mutant_clause,
      :raw_fn,
      :mutator,
      :original,
      :mutated,
      :range,
      note: nil,
      variant: nil
    ]
  end

  defmodule ReceiveClause do
    @moduledoc false

    # One receive clause with a mutated pattern/guard and a raw body. ReceiveClauseEmit
    # interleaves it before its original, leaving mailbox scanning and the after block
    # on one native receive. `raw_receive` shares the normalized source AST; only live
    # fallback mutants rebuild the whole receive when no selector binding is in scope.
    # The diff, note, variant and in-place Site retain the original focused mutation.
    @type t :: %__MODULE__{
            clause_index: non_neg_integer(),
            mutant_clause: Macro.t(),
            raw_receive: Macro.t(),
            mutator: Mutare.Mutator.Spec.t(),
            original: Macro.t(),
            mutated: Macro.t(),
            range: Sourceror.Range.t(),
            note: String.t() | nil,
            variant: Mutare.Mutator.Mutation.variant()
          }

    defstruct [
      :clause_index,
      :mutant_clause,
      :raw_receive,
      :mutator,
      :original,
      :mutated,
      :range,
      note: nil,
      variant: nil
    ]
  end

  defmodule RescueDrop do
    @moduledoc false

    # A whole `rescue` *clause* removed from an explicit `try`, delivered **in place** by the
    # **whole-construct selector** (like `CasePattern`). The structural twin of the type-list
    # narrowing `Mutare.Mutators.RescueType` already does for a single `var in [A, B]` clause —
    # for the idiomatic multi-branch shape (`rescue e in A -> …; e in B -> …`), where each branch
    # catches a single type, there is no list to narrow, so the equivalent "is this exception's
    # handling relied on?" question is asked by dropping one whole branch. Only offered when ≥2
    # rescue clauses are present (a `try` cannot have an empty `rescue`), so the result always
    # compiles; sound for the same reason as `CasePattern` — a rescue binding is body-local.
    #
    # `replacement` is the whole `try` rebuilt with this clause removed (the selector branch);
    # `dropped` is the removed clause (for the focused `:delete` diff) and `range` locates it.
    # `mutator` is the `RescueType` spec (the family owns both narrowing and dropping). Recorded
    # as an `:in_place`, `:delete` `Mutare.Site` (`Site.in_place_drop/5`).

    @type t :: %__MODULE__{
            mutator: Mutare.Mutator.Spec.t(),
            dropped: Macro.t(),
            replacement: Macro.t(),
            range: Sourceror.Range.t()
          }

    defstruct [:mutator, :dropped, :replacement, :range]
  end

  defmodule CaseClause do
    @moduledoc false

    # A `case` *clause-pattern/guard* mutation (variable swap, duplicate→wildcard, a
    # pattern literal, or a guard operator), delivered **in place** by the **tuple-the-
    # scrutinee** rewrite — the per-clause (C+M) analogue of function-head lifting. Unlike
    # `receive`/`fn`, a `case` *has* a scrutinee, so the whole `case` is rewritten to
    # `case {<active>, <subject>} do …` and each mutant adds **one** clause (`{<active>,
    # <mutant_pattern>} when <active> === <id> [and <mutant_guard>] -> <raw_body>`) placed
    # before its original — so a mutant touching one clause never copies the other N-1
    # (C+M, not C×M). The original it overrides is gated `when <active> !== <id>` to step
    # aside when the mutant is active (`Mutare.Transform.CaseClauseEmit.emit/3`).
    #
    # `clause_index` is the source clause this targets (for grouping the originals'
    # exclusion gates). `mutant_pattern`/`mutant_guard` are the mutant clause's pattern and
    # guard: a literal/structure mutation carries the *mutated* pattern + the clause's
    # *original* guard (or `nil`); a guard mutation carries the *original* pattern + the
    # *mutated* guard. `raw_body` is the clause's un-emitted body (no nested in-place
    # selectors — only one mutant is ever active). `original`/`mutated`/`range` are the
    # pattern/literal/guard-operator before/after, for the focused one-line diff; `mutator`
    # is the family. Recorded as an `:in_place` `Mutare.Site`.

    @type t :: %__MODULE__{
            clause_index: non_neg_integer(),
            mutator: Mutare.Mutator.Spec.t(),
            mutant_pattern: Macro.t(),
            mutant_guard: Macro.t() | nil,
            raw_body: Macro.t(),
            original: Macro.t(),
            mutated: Macro.t(),
            range: Sourceror.Range.t(),
            note: String.t() | nil,
            variant: Mutare.Mutator.Mutation.variant()
          }

    defstruct [
      :clause_index,
      :mutator,
      :mutant_pattern,
      :mutant_guard,
      :raw_body,
      :original,
      :mutated,
      :range,
      note: nil,
      variant: nil
    ]
  end

  defmodule MatchPattern do
    @moduledoc false

    # The *same* swap/wildcard families applied to the LHS pattern of a **runtime `=`
    # match in statement position** (a non-final statement of a body block, where the
    # match's value is discarded). A selector `case` can't live in a pattern and a `=`
    # isn't a liftable clause group — but, unlike a `case` clause, an `=`'s bindings
    # *escape* to the enclosing scope, so wrapping the whole match in a selector would
    # lose them. The fix re-exports the bound variables through a tuple and rebinds them
    # outside (the user's `<pat> = e` → `{vars} = case e do <pat> -> {vars} end` trick):
    #
    #     {x, y} =
    #       case <sel> do
    #         <id> -> case <raw_rhs> do {y, x} -> {x, y} end   # mutant: swapped binding
    #         mutare_active -> <record>; case <rhs> do {x, y} -> {x, y} end   # baseline
    #       end
    #
    # `original`/`mutated` are the LHS pattern before/after (the focused one-line diff)
    # and `range` locates it; `export` is the shared `{vars}` tuple (built once from the
    # pattern's `bound_var_names`, so every branch and the outer match agree on it — plus,
    # for a **chained** match `<pat> = mid = e`, the chain vars `mid` binds, which escape the
    # scrutinee and so must ride the tuple too; see `Analyze.MatchPatterns.export_with_rhs_chain/2`);
    # `raw_rhs` is the un-emitted matched expression the mutant branch matches (the
    # baseline branch uses the *emitted* rhs, so nested mutations there still fire). Only
    # mutations that preserve the bound-variable set are admitted (swaps always do;
    # wildcards are forced to *thin* mode by passing the bound set as `used_outside`), so
    # the export stays consistent across branches. Recorded as an `:in_place` `Mutare.Site`.

    @type t :: %__MODULE__{
            mutator: Mutare.Mutator.Spec.t(),
            original: Macro.t(),
            mutated: Macro.t(),
            export: Macro.t(),
            raw_rhs: Macro.t(),
            range: Sourceror.Range.t()
          }

    defstruct [:mutator, :original, :mutated, :export, :raw_rhs, :range]
  end

  defmodule MacroPattern do
    @moduledoc false

    # The same swap/wildcard families applied to the **pattern argument of a known macro
    # whose bindings escape** (`:binding_pattern` — `Kernel.destructure`, or a
    # user-registered macro), when the call sits in a **value-discarded position** (a
    # non-final block statement or a `with` clause). It is the `MatchPattern` mechanism
    # generalized from a `=` to a macro call: the macro itself does the binding, and those
    # bindings escape to the enclosing scope — so, exactly like `MatchPattern`, wrapping the
    # call in a selector would trap them inside the branch. The fix re-exports the bound
    # variables through a tuple and rebinds them outside, running the macro (with the
    # original or a mutated pattern) inside each selector branch:
    #
    #     {x, y} =
    #       case <sel> do
    #         <id> -> destructure(<mutated_pat>, v); {x, y}        # one per mutant
    #         mutare_active -> <record>; destructure(<pat>, v); {x, y}   # baseline
    #       end
    #
    # `original`/`mutated` are the pattern before/after (the focused one-line diff) and
    # `range` locates it; `export` is the shared `{vars}` tuple (built from the pattern's
    # `bound_var_names`, so every branch and the outer match agree); `mutant_expr` is the
    # *raw* macro call (or `|>` pipe) with the mutated pattern substituted — what the mutant
    # branch runs (the baseline branch runs the *emitted* call so nested mutations in the
    # value arg still fire). Only bound-set-preserving mutations are admitted (swaps always;
    # wildcards forced *thin*), so the export is consistent across branches. Recorded as an
    # `:in_place` `Mutare.Site`, like `MatchPattern`.
    #
    # `note`/`variant` carry the producing mutator's optional per-mutant metadata (a
    # `%Mutare.Mutator.Mutation{}` return). The structural swap/wildcard source never sets either
    # (default `nil`), but the **whole-call re-home** (`Analyze.MatchPatterns.call_mutation_candidate/3`,
    # turning a `mutate`-built `Candidate.InPlace` on a binding-escaping macro call into this kind)
    # carries the InPlace's `note` *and* `variant` through to the `Mutare.Site` — so a tagged
    # whole-call mutation on a `:binding_pattern` macro keeps the label a `[family:label]` directive
    # filters on (without it the re-homed Site would carry `variant: []` and be unsuppressable).

    @type t :: %__MODULE__{
            mutator: Mutare.Mutator.Spec.t(),
            original: Macro.t(),
            mutated: Macro.t(),
            export: Macro.t(),
            mutant_expr: Macro.t(),
            range: Sourceror.Range.t(),
            note: String.t() | nil,
            variant: Mutare.Mutator.Mutation.variant()
          }

    defstruct [
      :mutator,
      :original,
      :mutated,
      :export,
      :mutant_expr,
      :range,
      note: nil,
      variant: nil
    ]
  end

  defmodule Hosted do
    @moduledoc false

    # A mutation of a **`:hosted` macro argument** — a fragment *inside* a compile-time DSL
    # (`Ecto`'s `from`/`where`) where core can neither reach `:persistent_term` with a bare
    # selector (the `case` would poison the single build) nor vouch for the fragment's
    # semantics (SQL's three-valued logic ≠ Elixir's). Core therefore owns none of the
    # mutation logic: the **hosting mutator** (`c:Mutare.Mutator.MacroHost.host/2`) supplies, per macro
    # node, a list of *targets*, each carrying `{logical original, logical mutants}` and two
    # pure transforms — `wrap` (each branch → the woven runtime form, e.g. `dynamic([u], _)`;
    # default identity) and `splice` (where the woven `case` goes in a copy of the macro node,
    # `^`-pinned for Ecto). One `Hosted` candidate *is* one such target.
    #
    # Core keeps the four cross-cutting contracts: it builds the id-gated selector `case` from
    # its own `subject_ast` + `<id> ->` clauses (so poison/manifest still recognise it), assigns
    # the ids, records one `:in_place` `Mutare.Site` per logical mutant (the diff is the logical
    # fragment swap — the `dynamic`/`^` scaffolding invisible, exactly as the tuple-export Sites
    # hide theirs), and emits the coverage catch-all (`Mutare.Transform.HostedEmit.emit/5`).
    #
    # `original` is the logical fragment before mutation (rendered in each Site's diff and run by
    # the wrapped catch-all baseline); `mutants` are the logical mutated fragments as
    # `{node, note, variant, producer}` quads (one id + Site each, the optional `note` recorded on
    # the Site for the report; `variant` is *usually* `nil` — a host fragment has foreign semantics
    # and no variant vocabulary, and `Mutare.Mutator.Dispatch.normalize_mutant/1` quads a bare-node
    # mutant with `nil, nil, nil` — but a hosting mutator declaring `variants/0` may tag one via
    # `Mutation.tagged/2`, and that label rides through `HostedEmit` to the Site's `# mutare:ignore`
    # filter; `producer` is the sub-contract attribution — a mutant the host relayed from a core
    # family via `Mutare.Analyze.expression_mutations/3` carries that family's spec, and
    # `HostedEmit` records its Site under it instead of the host); `wrap` maps a logical fragment
    # to its woven branch value; `splice` weaves the assembled `case` into a copy of the (emitted)
    # macro node; `range` locates the fragment for the Site; `mutator` is the hosting
    # `Mutare.Mutator.Spec` (its name on every Site a mutant doesn't re-attribute).

    @type t :: %__MODULE__{
            mutator: Mutare.Mutator.Spec.t(),
            original: Macro.t(),
            mutants: [
              {Macro.t(), String.t() | nil, Mutare.Mutator.Mutation.variant(),
               Mutare.Mutator.Spec.t() | nil}
            ],
            wrap: (Macro.t() -> Macro.t()),
            splice: (Macro.t(), Macro.t() -> Macro.t()),
            range: Sourceror.Range.t()
          }

    defstruct [:mutator, :original, :mutants, :wrap, :splice, :range]
  end

  defmodule Drop do
    @moduledoc false

    # A whole function clause removed, delivered by lifting. There is no mutant
    # clause — `clause_index` says which clause's *original* is gated off (its
    # `FunctionPlan.mutated_clause/2` returns `:drop`) when this id is active;
    # `original` is the clause itself (for the diff) and `range` locates it.

    @type t :: %__MODULE__{
            clause_index: non_neg_integer(),
            original: Macro.t(),
            range: Sourceror.Range.t()
          }

    defstruct [:clause_index, :original, :range]
  end

  defmodule GuardDrop do
    @moduledoc false

    # A `def`/`defp` clause's whole `when` guard removed, broadening it to match
    # unconditionally (`def f(x) when is_binary(x)` → `def f(x)`), delivered by
    # **lifting**. Like `Candidate.Lifted` it mutates one clause's head and records a
    # `:lifted` replacement Site, but it is structurally a whole-clause rebuild (the
    # `when` is stripped, not one tagged node swapped), so it carries the
    # `clause_index` and is materialized by `FunctionPlan.mutated_clause/2` — which
    # returns the clause with its guard dropped (`Mutare.Mutators.GuardDrop`).
    #
    # `original` is the clause's `{:when, …}` head (rendering `f(x) when g`) and
    # `mutated` the bare head call (`f(x)`), so the lifted-replace Site diffs to a
    # clean one-liner dropping just the ` when g`; `range` is the `when` head's range.
    # The `case`/`receive`/`fn` clause guards reuse `Candidate.CaseClause` /
    # `Candidate.ReceiveClause` / `Candidate.FnClause` (a `nil` mutant guard or a
    # guard-stripped clause) —
    # only a `def`/`defp` head needs this lifted shape, the same way only it needs
    # `Candidate.Lifted` and `Candidate.Drop`.

    @type t :: %__MODULE__{
            clause_index: non_neg_integer(),
            mutator: Mutare.Mutator.Spec.t(),
            original: Macro.t(),
            mutated: Macro.t(),
            range: Sourceror.Range.t()
          }

    defstruct [:clause_index, :mutator, :original, :mutated, :range]
  end

  defmodule Return do
    @moduledoc false

    # A function clause's tail expression replaced with a constant, delivered by
    # the in-place selector (the tail is a body position, so a `case` is legal
    # there). Shaped exactly like `InPlace` for emission — `mutated` is the
    # replacement constant, `original` the raw tail, `range` locates it — but it
    # is a distinct kind because it is discovered *structurally* (the transform
    # names the tail) rather than by a node-level match, and the constant carries
    # no operator, so the recorded `Mutare.Site` has `nil` ops
    # (`Site.return_value/6`). `mutator` is the producing spec — `ReturnValue` or a
    # custom mutator implementing `return_replacements/1` — so its name reaches the site.

    @type t :: %__MODULE__{
            mutator: Mutare.Mutator.Spec.t(),
            original: Macro.t(),
            mutated: Macro.t(),
            range: Sourceror.Range.t()
          }

    defstruct [:mutator, :original, :mutated, :range]
  end

  @type t ::
          InPlace.t()
          | Lifted.t()
          | PatternStructure.t()
          | CasePattern.t()
          | FnClause.t()
          | ReceiveClause.t()
          | RescueDrop.t()
          | CaseClause.t()
          | MatchPattern.t()
          | MacroPattern.t()
          | Hosted.t()
          | Drop.t()
          | GuardDrop.t()
          | Return.t()

  @doc """
  Apply `fun` to the **in-place** candidate list a node carries, splicing the transformed list
  back. A **no-op** (the node is returned unchanged) when the node carries no in-place candidates
  — so a caller that only ever *narrows* (`Enum.reject`) or *re-flags* (`Enum.map`) an existing
  list needs no nil/shape handling of its own.

  A thin alias for `Mutare.Transform.Meta.update_candidates/3` pinned to the `:in_place` kind —
  the "transform the candidates attached to this node" mechanic the analyze pass and
  `Mutare.Transform.Overlap` share.
  """
  @spec update_candidates(Macro.t(), ([t()] -> [t()])) :: Macro.t()
  def update_candidates(node, fun),
    do: Mutare.Transform.Meta.update_candidates(node, :in_place, fun)
end
