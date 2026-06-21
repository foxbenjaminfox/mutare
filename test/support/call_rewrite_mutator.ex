defmodule Mutare.Test.CallRewriteMutator do
  @moduledoc """
  A reference *call-rewriting* custom mutator, used in tests to exercise the
  cross-mutator overlap pass (`Mutare.Transform.Overlap`) for a mutator that is
  **not** a built-in.

  It rewrites a two-argument remote call `_.scale(x, :small)` by substituting just
  the mode atom `:small` → `:big`, reusing every other operand verbatim — the same
  minimal "original with one descendant replaced" shape `Mutare.Mutators.ModeSwap`
  produces. Because the change is a single metadata-bearing descendant, Overlap
  derives a *covering* footprint on that node (matched by `meta[:mutare_nid]`) and
  prunes a redundant leaf mutant (`AtomLiteral` turning `:small` into `:mutare`) on
  the same node — with no callback or registration: "any future minimal-rewrite
  call mutator gets it for free."

  Reusing `dot`/`cm`/`arg` keeps their `:mutare_nid` stamps intact, so the diff
  isolates exactly the swapped atom (see the `Mutare.Mutator` "Adding a mutator"
  notes on reusing operands).
  """
  @behaviour Mutare.Mutator

  @impl Mutare.Mutator
  def name, do: :call_rewrite

  @impl Mutare.Mutator
  def mutate({{:., _, [_, :scale]} = dot, cm, [arg, {:__block__, _, [:small]}]}) do
    # Clean meta on the replacement atom so it renders (not the original token).
    [{dot, cm, [arg, {:__block__, [], [:big]}]}]
  end

  def mutate(_node), do: :skip
end
