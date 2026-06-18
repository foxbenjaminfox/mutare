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
  #   * `Candidate.Guard`   — a `when`-guard operator swap, delivered by lifting
  #     (a `case` can't live in a guard) (was `:guard` / `:lifted` / `:replace`).
  #   * `Candidate.Pattern` — a head-pattern literal swap, delivered by lifting (a
  #     selector `case` is illegal in a pattern). Mechanically a twin of `Guard` —
  #     both tag a node in the shared clause group and replace it in the one gated
  #     mutant clause — but a distinct kind: a different position (the clause *head*,
  #     not its `when`) and a different mutator family (only literal-valued mutations
  #     are pattern-legal).
  #   * `Candidate.PatternStructure` — a whole-head pattern restructuring (a variable
  #     swap, or a duplicate-variable wildcarding), delivered by lifting. Like `Pattern`
  #     it lives in a clause head, but the rewrite spans sibling positions / repeated
  #     variables that a single `meta[:mutare_tag]` can't capture, so it is applied by
  #     whole-clause replacement by index (like `Drop`). Structural (the
  #     `PatternSwap`/`PatternWildcard` families own the logic via `pattern_mutations/2`).
  #   * `Candidate.CasePattern` — the *same* swap/wildcard families applied to a `case`
  #     *clause* pattern, but delivered **in place**: a `case` isn't liftable, so the whole
  #     `case` is wrapped in a selector whose mutant branch is a copy with one clause's
  #     pattern restructured. The diff stays focused on the pattern (`original`/`mutated`),
  #     while the selector branch carries the whole mutated `case` (`replacement`).
  #   * `Candidate.MatchPattern` — the same swap/wildcard families on the LHS of a runtime
  #     `=` match *in statement position*. A selector can't wrap the match (its bindings
  #     would stop escaping), so the bound variables are re-exported through a tuple and
  #     rebound outside: `{vars} = case rhs do <pat> -> {vars} end`, the pattern hosted in
  #     a selector. Delivered in place; recorded as an `:in_place` `Mutare.Site`.
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
  # pattern's *literals* are mutated by lifting (`Candidate.Pattern`), the same way
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

  defmodule Guard do
    @moduledoc false

    # A `when`-guard operator swap, delivered by lifting. It carries `tag` — a
    # unique `meta[:mutare_tag]` marking the target node inside the *shared* tagged
    # clause group held once on the `Mutare.Transform.FunctionPlan` — plus the
    # `clause_index` it lives in. `FunctionPlan.mutated_clause/2` reconstructs *just
    # that one clause* by replacing the tagged node with `mutated`; emission emits it
    # as a single dispatcher clause gated `when mutare_active === <id>`.

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

  defmodule Pattern do
    @moduledoc false

    # A head-pattern literal swap, delivered by lifting. Structurally identical to
    # `Guard` (it carries a `tag` into the shared tagged clause group held on the
    # `Mutare.Transform.FunctionPlan`, plus its `clause_index` and the replacement
    # node), but it lives in a clause *head* rather than a `when` guard. Because a
    # selector `case` is illegal in a pattern, a literal in a head (`def f(1, %{0 =>
    # k})`) can only be mutated by lifting — exactly the guard mechanism.
    # `FunctionPlan.mutated_clause/2` materializes the mutant clause by replacing the
    # tagged literal with `mutated`. Only mutations whose replacement is itself a
    # literal are admitted, so the gated mutant clause is always a legal pattern.

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
    # (`f(x, x)` → `f(_, x)`). Like `Pattern` it lives in a clause head; unlike `Pattern`
    # (a single tagged literal node) the rewrite spans/replaces sub-patterns that may have
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

    # A `case` *clause-pattern* restructuring (variable swap / duplicate→wildcard),
    # delivered **in place**. A `case` can't be lifted (it isn't a function clause group)
    # and a selector can't live inside a pattern, so the mutant is delivered by wrapping
    # the *whole* `case` in an in-place selector whose mutant branch is a copy of the case
    # with one clause's pattern restructured — sound because a `case` clause's bindings are
    # local to its body and never escape. `replacement` is that whole mutated `case` (the
    # selector branch); `original`/`mutated` are the clause *pattern* before/after (the
    # focused one-line diff), and `range` locates that pattern. `mutator` is the structural
    # family (`PatternSwap`/`PatternWildcard`). Recorded as an `:in_place` `Mutare.Site`.

    @type t :: %__MODULE__{
            mutator: module(),
            original: Macro.t(),
            mutated: Macro.t(),
            replacement: Macro.t(),
            range: Sourceror.Range.t()
          }

    defstruct [:mutator, :original, :mutated, :replacement, :range]
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
          | Guard.t()
          | Pattern.t()
          | PatternStructure.t()
          | CasePattern.t()
          | MatchPattern.t()
          | Drop.t()
          | Return.t()
end
