defmodule Mutare.Test.AssignMutator do
  @moduledoc """
  A **probe** mutator for the invariant that a bare `=` node is *never offered* to mutators.

  It matches a `=` node (a whole-match mutation) **and**, as a liveness control, a bare `probe()`
  call (a node that *is* offered). In a transform it earns a site on the `probe()` call but none
  on the `=` — proving the `=`'s absence is because the node isn't offered, not because the
  mutator is inert or disabled.

  This is the asymmetry with the *macro* path: a macro node is offered (`analyze_known_macro` →
  `offer`), so a `macro_routes/0` mutator can mutate the whole call and the transform must re-home that
  mutation into the tuple-export selector (`Transform.Analyze.rehome_call_mutations/2`). A `=`
  has no such entry point. If a `=` site ever appears here, that has changed and a whole-`=`
  mutation of a value-discarded binding match would need the same re-home.
  """
  @behaviour Mutare.Mutator

  @impl Mutare.Mutator
  def name, do: :assign_probe

  @impl Mutare.Mutator
  # Whole-`=` mutation — only ever reached if a `=` node is offered to mutators.
  def mutate({:=, meta, [lhs, _rhs]}), do: [{:=, meta, [lhs, [9, 9]]}]

  # Liveness control: a bare call *is* offered, so a site here proves the mutator runs.
  def mutate({:probe, meta, args}) when is_list(args), do: [{:probe, meta, [:fired | args]}]

  def mutate(_node), do: :skip
end
