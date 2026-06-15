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
  #   * `Candidate.Drop`    — a whole clause removed, delivered by lifting (was
  #     `:clause_drop` / `:lifted` / `:delete`).
  #
  # `kind`/`operation` no longer live on the candidate — they're implied by the
  # struct, and recovered at emission when the matching `Mutare.Site` is built.
  # Placement (in-place vs lifted) stays positional: the analyzer picks the
  # variant from where the node sits, the mutator never declares it.
  #
  # The excluded positions — `:pattern`, `:compile_time` (module-attribute values
  # and macro bodies), `:spec` (a bitstring type specifier), `:capture_arity`
  # (the `/` in `&fun/arity`) — never become candidates at all; the analyzer
  # classifies them positively and skips them (see `Mutare.Transform`'s `analyze/3`).

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

  @type t :: InPlace.t() | Guard.t() | Drop.t()
end
