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

  @type t :: InPlace.t() | Guard.t() | Pattern.t() | Drop.t() | Return.t()
end
