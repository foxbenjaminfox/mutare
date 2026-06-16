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
  #     both tag a node in the shared clause group and replace it in a `__mut` copy
  #     — but a distinct kind: a different position (the clause *head*, not its
  #     `when`) and a different mutator family (only literal-valued mutations are
  #     pattern-legal).
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

    @type t :: %__MODULE__{
            mutator: module(),
            original: Macro.t(),
            mutated: Macro.t(),
            range: map()
          }

    defstruct [:mutator, :original, :mutated, :range]
  end

  defmodule Guard do
    @moduledoc false

    # A `when`-guard operator swap, delivered by lifting. Rather than carry a full
    # copy of the clause group with this one guard swapped, it carries only `tag`
    # — a unique `meta[:mutare_tag]` marking the target node inside the *shared*
    # tagged clause group held once on the `Mutare.Transform.FunctionPlan`.
    # `FunctionPlan.mutated_clauses/2` reconstructs the mutated group by replacing
    # the tagged node with `mutated`, so emission never re-finds the node and the
    # group is stored once per function, not once per guard mutant.

    @type t :: %__MODULE__{
            tag: non_neg_integer(),
            mutator: module(),
            original: Macro.t(),
            mutated: Macro.t(),
            range: map()
          }

    defstruct [:tag, :mutator, :original, :mutated, :range]
  end

  defmodule Pattern do
    @moduledoc false

    # A head-pattern literal swap, delivered by lifting. Structurally identical to
    # `Guard` (it carries a `tag` into the shared tagged clause group held on the
    # `Mutare.Transform.FunctionPlan`, plus the replacement node), but it lives in
    # a clause *head* rather than a `when` guard. Because a selector `case` is
    # illegal in a pattern, a literal in a head (`def f(1, %{0 => k})`) can only be
    # mutated by duplicating the whole clause group — exactly the guard mechanism.
    # `FunctionPlan.mutated_clauses/2` materializes the mutant copy by replacing the
    # tagged literal with `mutated`. Only mutations whose replacement is itself a
    # literal are admitted, so the `__mut` copy is always a legal pattern.

    @type t :: %__MODULE__{
            tag: non_neg_integer(),
            mutator: module(),
            original: Macro.t(),
            mutated: Macro.t(),
            range: map()
          }

    defstruct [:tag, :mutator, :original, :mutated, :range]
  end

  defmodule PatternStructure do
    @moduledoc false

    # A whole-head *pattern restructuring* of one clause, delivered by lifting — a
    # variable swap (`{x, y}` → `{y, x}`) or a duplicate-variable wildcarding
    # (`f(x, x)` → `f(_, x)`). Like `Pattern` it lives in a clause head and is delivered
    # by duplicating the clause group; unlike `Pattern` (a single tagged literal node) the
    # rewrite spans/replaces sub-patterns that may have no taggable metadata (a 2-tuple,
    # a list), so it is applied by **whole-clause replacement by index** — the same
    # mechanism as `Drop`. `clause_index` says which clause to rebuild;
    # `Mutare.Transform.FunctionPlan.mutated_clauses/2` swaps in `mutated_args` as that
    # clause's head pattern args. `original`/`mutated` are the clause's head *call* node
    # before/after (always rangeable, so the report renders a clean one-line diff), and
    # `mutator` is the structural family that produced it (`PatternSwap`/`PatternWildcard`).

    @type t :: %__MODULE__{
            clause_index: non_neg_integer(),
            mutator: module(),
            mutated_args: [Macro.t()],
            original: Macro.t(),
            mutated: Macro.t(),
            range: map()
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
            range: map()
          }

    defstruct [:mutator, :original, :mutated, :replacement, :range]
  end

  defmodule Drop do
    @moduledoc false

    # A whole function clause removed, delivered by lifting. There is no mutated
    # node — `clause_index` says which clause `FunctionPlan.mutated_clauses/2`
    # deletes; `original` is the clause itself (for the diff) and `range` locates it.

    @type t :: %__MODULE__{
            clause_index: non_neg_integer(),
            original: Macro.t(),
            range: map()
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
            range: map()
          }

    defstruct [:original, :mutated, :range]
  end

  @type t ::
          InPlace.t()
          | Guard.t()
          | Pattern.t()
          | PatternStructure.t()
          | CasePattern.t()
          | Drop.t()
          | Return.t()
end
