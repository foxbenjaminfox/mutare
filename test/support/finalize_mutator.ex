defmodule Mutare.Test.FinalizeMutator do
  @moduledoc """
  A reference family-rich mutator, used in tests to exercise `c:Mutare.Mutator.finalize/2`
  as the one tag → filter → enrich funnel across both delivery paths: producers stay pure —
  every mutant is returned as `Mutare.Mutator.Mutation.tagged(node, [family])` — and
  `finalize/2` (which Mutare guarantees runs on every produced mutation) drops mutations of
  disabled families and attaches the family's report note.

  Two families over integer literals: `:zero` (n → 0) and `:one` (n → 1).
  """
  @behaviour Mutare.Mutator

  use Mutare.Mutator.Families,
    plugin: "Mutare.Test.FinalizeMutator",
    all: [:zero, :one]

  alias Mutare.Mutator.Mutation

  @impl Mutare.Mutator
  def name, do: :finalized

  @impl Mutare.Mutator
  def init(opts), do: parse_families!(Keyword.get(opts, :families, :default))

  @impl Mutare.Mutator
  def variants, do: all_families()

  # Pure production: tag each mutant with its family at construction; no filtering, no notes.
  @impl Mutare.Mutator
  def mutate({:__block__, _meta, [n]}, _context) when is_integer(n) and n > 1 do
    [
      Mutation.tagged(Mutare.AST.literal(0), [:zero]),
      Mutation.tagged(Mutare.AST.literal(1), [:one])
    ]
  end

  def mutate(_node, _context), do: :skip

  # The funnel, defined once: the leading variant label is the family — drop it when
  # disabled, otherwise attach the family's report note.
  @impl Mutare.Mutator
  def finalize(%Mutation{variant: [family | _]} = mutation, %{config: enabled}) do
    if family_enabled?(enabled, family),
      do: %{mutation | note: "#{family} boundary"},
      else: :skip
  end
end
