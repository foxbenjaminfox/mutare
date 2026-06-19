defmodule Mutare.Transform.Candidate do
  @moduledoc false

  # The typed, pre-id description of a single mutant: what to mutate and where.
  # Produced by the analyzer / planner and consumed by emission.
  #
  # There is no single `%Candidate{}` struct any more. The old one carried
  # `context` *and* its two consequences (`kind`, `operation`) as separate
  # fields, so the type admitted nonsense states — a `:clause_drop` that claimed
  # to be `:in_place` and `:replace`, say — that only discipline kept out. The
  # three legal shapes are now three structs, one per valid combination, so the
  # illegal ones can't be built:
  #
  #   * `Candidate.InPlace` — a body operator swap, delivered by an in-place
  #     selector `case` (was `:runtime_body` / `:in_place` / `:replace`).
  #   * `Candidate.Lifted`  — a single tagged-node replacement in a lifted clause,
  #     delivered by a dispatcher clause gated `when mutare_active === <id>` (a `case`
  #     can't live in a guard, and a selector is illegal in a pattern). Covers both a
  #     `when`-guard operator swap and a head-pattern literal swap — delivered
  #     identically (tag + replace one node), so one struct, the legality difference
  #     enforced at discovery (was `:guard`/`:lifted` and a separate head-literal kind).
  #   * `Candidate.PatternStructure` — a whole-head pattern restructuring (a variable
  #     swap, or a duplicate-variable wildcarding), delivered by lifting. Like `Pattern`
  #     it lives in a clause head, but the rewrite spans sibling positions / repeated
  #     variables that a single `meta[:mutare_tag]` can't capture, so it is applied by
  #     whole-clause replacement by index (like `Drop`). Structural (the
  #     `PatternSwap`/`PatternWildcard` families own the logic via `pattern_mutations/2`).
  #   * `Candidate.CaseClause` — a `case` *clause* pattern/guard mutation (swap/wildcard,
  #     a pattern literal, or a guard operator), delivered **in place** by the
  #     *tuple-the-scrutinee* rewrite (the per-clause C+M analogue of head lifting): the
  #     `case` becomes `case {<active>, <subject>} do …` and each mutant adds one gated
  #     clause before its original. The diff stays focused on the pattern/guard.
  #   * `Candidate.CasePattern` — the same kinds applied to a `receive`/`fn` clause
  #     (neither has a scrutinee to tuple), delivered **in place** by the
  #     *whole-construct selector*: the whole construct is wrapped in a selector whose
  #     mutant branch is a copy with one clause's pattern/guard changed (`replacement`).
  #     The diff stays focused on the pattern/guard (`original`/`mutated`).
  #   * `Candidate.MatchPattern` — the same swap/wildcard families on the LHS of a runtime
  #     `=` match *in statement position*. A selector can't wrap the match (its bindings
  #     would stop escaping), so the bound variables are re-exported through a tuple and
  #     rebound outside: `{vars} = case rhs do <pat> -> {vars} end`, the pattern hosted in
  #     a selector. Delivered in place; recorded as an `:in_place` `Mutare.Site`.
  #   * `Candidate.MacroPattern` — the same families on the **pattern arg of a binding-
  #     escaping known macro** (`destructure([x, y], v)`, declared `:binding_pattern`) in a
  #     value-discarded position. The `MatchPattern` mechanism with the inner `case rhs do
  #     pat -> {vars} end` generalized to `macro(<pat>, …); {vars}` — the macro does the
  #     binding, the tuple re-export carries the escaping vars out. Delivered in place.
  #   * `Candidate.Return`  — a function clause's *tail expression* replaced with a
  #     constant (`nil`/`0`/`""`/`[]`), delivered by an in-place selector `case`
  #     (the tail is a body position). Structural, like `Drop`: it targets a
  #     position only the transform knows (the clause's return), not a node a
  #     `mutate/1` mutator could match — but it is *delivered* in place, not lifted.
  #
  # `kind`/`operation` no longer live on the candidate — they're implied by the
  # struct, and recovered at emission when the matching `Mutare.Site` is built.
  # Placement (in-place vs lifted) stays positional: the analyzer picks the
  # variant from where the node sits, the mutator never declares it.
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
    # analyzer tags it (it alone knows the call context); emission drops it when this
    # candidate's own mutator was configured `{Module, call_option_keys: false}` (read
    # from its `Mutare.Mutator.Spec.opts` in `Transform.gate_candidates/1`), so the key
    # stays raw while its value still mutates. Default `false` — every other candidate is
    # a normal mutation, never gated.

    @type t :: %__MODULE__{
            mutator: module(),
            original: Macro.t(),
            mutated: Macro.t(),
            range: Sourceror.Range.t(),
            call_option_key?: boolean()
          }

    defstruct [:mutator, :original, :mutated, :range, call_option_key?: false]
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
    # clause group; `clause_index` is the clause it lives in.

    @type t :: %__MODULE__{
            tag: non_neg_integer(),
            clause_index: non_neg_integer(),
            mutator: module(),
            original: Macro.t(),
            mutated: Macro.t(),
            range: Sourceror.Range.t()
          }

    defstruct [:tag, :clause_index, :mutator, :original, :mutated, :range]
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
            mutator: module(),
            mutated_args: [Macro.t()],
            original: Macro.t(),
            mutated: Macro.t(),
            range: Sourceror.Range.t()
          }

    defstruct [:clause_index, :mutator, :mutated_args, :original, :mutated, :range]
  end

  defmodule CasePattern do
    @moduledoc false

    # A `receive`/`fn` *clause-pattern/guard* mutation (variable swap, duplicate→wildcard,
    # a pattern literal, or a guard operator), delivered **in place** by the
    # **whole-construct selector**. `receive` matches the process mailbox and `fn` matches
    # call arguments, so neither has a scrutinee expression to tuple (the way `case` does —
    # see `CaseClause`); the mutant is instead delivered by wrapping the *whole* construct
    # in an in-place selector whose mutant branch is a copy of the construct with one
    # clause's pattern (or guard) changed — sound because these clause bindings are local
    # to a clause body and never escape. `replacement` is that whole mutated construct (the
    # selector branch); `original`/`mutated` are the clause *pattern*/literal/guard-operator
    # before/after (the focused one-line diff), and `range` locates it. `mutator` is the
    # family (`PatternSwap`/`PatternWildcard`, a literal family, or a guard family). Recorded
    # as an `:in_place` `Mutare.Site`. (Each mutant is a *full* copy of the construct — C×M —
    # acceptable for `receive`/`fn`, which are rare and small; `case` uses the per-clause
    # `CaseClause` instead.)

    @type t :: %__MODULE__{
            mutator: module(),
            original: Macro.t(),
            mutated: Macro.t(),
            replacement: Macro.t(),
            range: Sourceror.Range.t()
          }

    defstruct [:mutator, :original, :mutated, :replacement, :range]
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
    # aside when the mutant is active (`Mutare.Transform.emit_case_pattern_site/3`).
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
            mutator: module(),
            mutant_pattern: Macro.t(),
            mutant_guard: Macro.t() | nil,
            raw_body: Macro.t(),
            original: Macro.t(),
            mutated: Macro.t(),
            range: Sourceror.Range.t()
          }

    defstruct [
      :clause_index,
      :mutator,
      :mutant_pattern,
      :mutant_guard,
      :raw_body,
      :original,
      :mutated,
      :range
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
    # pattern's `bound_var_names`, so every branch and the outer match agree on it);
    # `raw_rhs` is the un-emitted matched expression the mutant branch matches (the
    # baseline branch uses the *emitted* rhs, so nested mutations there still fire). Only
    # mutations that preserve the bound-variable set are admitted (swaps always do;
    # wildcards are forced to *thin* mode by passing the bound set as `used_outside`), so
    # the export stays consistent across branches. Recorded as an `:in_place` `Mutare.Site`.

    @type t :: %__MODULE__{
            mutator: module(),
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

    @type t :: %__MODULE__{
            mutator: module(),
            original: Macro.t(),
            mutated: Macro.t(),
            export: Macro.t(),
            mutant_expr: Macro.t(),
            range: Sourceror.Range.t()
          }

    defstruct [:mutator, :original, :mutated, :export, :mutant_expr, :range]
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

  defmodule Return do
    @moduledoc false

    # A function clause's tail expression replaced with a constant, delivered by
    # the in-place selector (the tail is a body position, so a `case` is legal
    # there). Shaped exactly like `InPlace` for emission — `mutated` is the
    # replacement constant, `original` the raw tail, `range` locates it — but it
    # is a distinct kind because there is no node-level `mutator`: the candidate
    # is discovered *structurally* (the transform names the tail) and the
    # constant carries no operator, so the recorded `Mutare.Site` has a
    # `:return_value` mutator and `nil` ops (`Site.return_value/5`).

    @type t :: %__MODULE__{
            original: Macro.t(),
            mutated: Macro.t(),
            range: Sourceror.Range.t()
          }

    defstruct [:original, :mutated, :range]
  end

  @type t ::
          InPlace.t()
          | Lifted.t()
          | PatternStructure.t()
          | CasePattern.t()
          | RescueDrop.t()
          | CaseClause.t()
          | MatchPattern.t()
          | MacroPattern.t()
          | Drop.t()
          | Return.t()
end
