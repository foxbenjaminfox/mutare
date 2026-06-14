defmodule Mutare.Transform.Candidate do
  @moduledoc false

  # One mutation candidate: the typed, pre-id description of a single mutant,
  # produced by the analyzer and consumed by emission. It replaces the old
  # untyped `%{type: …}` maps *and* the in-place call shape, so there is one
  # vocabulary for "what to mutate, where, and how it is delivered".
  #
  # `context` is the source of truth; `kind`/`operation` are its consequences:
  #
  #   * `:runtime_body`  → `:in_place`, `:replace`  — a body expression
  #   * `:guard`         → `:lifted`,   `:replace`  — a `when`-guard operator
  #   * `:clause_drop`   → `:lifted`,   `:delete`   — a whole clause removed
  #
  # The excluded contexts — `:pattern`, `:compile_time` (module-attribute
  # values), `:capture_arity` (the `/` in `&fun/arity`) — never become
  # candidates; the analyzer skips them outright (see `Mutare.Transform`'s
  # `skip_node?/1`).
  #
  # `:guard` candidates carry `mutated_clauses` — the whole clause group with
  # this one guard swapped, materialised at analysis time so emission never has
  # to re-find the node. `:clause_drop` carries only `clause_index`.

  @type context :: :runtime_body | :guard | :clause_drop

  @type t :: %__MODULE__{
          context: context(),
          kind: :in_place | :lifted,
          operation: :replace | :delete,
          mutator: module() | nil,
          original: Macro.t(),
          mutated: Macro.t() | nil,
          range: map(),
          clause_index: non_neg_integer() | nil,
          mutated_clauses: [Macro.t()] | nil
        }

  defstruct [
    :context,
    :kind,
    :operation,
    :mutator,
    :original,
    :mutated,
    :range,
    :clause_index,
    :mutated_clauses
  ]
end
