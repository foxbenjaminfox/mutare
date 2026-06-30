defmodule Mutare.Test.NotedMutator do
  @moduledoc """
  A reference mutator exercising the **note channel** of the standard `c:Mutare.Mutator.mutate/1`
  API — the per-mutant advisory previously only a selector host could attach, now available to
  any node-level mutator.

  Each element a `mutate/1` (or `mutate/2`) return list may be one of `t:Mutare.Mutator.mutation/0`:
  a **bare node** (no note), a **`%Mutare.Mutator.Mutation{}`** (a node + an advisory the report
  surfaces on that mutant's `Mutare.Site`), or an `Mutare.AST.literal(nil)` node. A top-level bare
  `nil` is rejected rather than treated as a drop sentinel. This mutator targets the integer literal
  `42` and returns all three useful forms at once:

    * a noted `0` (via `Mutare.Mutator.Mutation.new/2`) — its Site carries the note;
    * a literal `nil` replacement — produces a real Site; and
    * a bare `1` — its Site's note is `nil`.

  So a test can assert the note rides through to the Site, that unnoted mutants have none, and that
  literal `nil` does not disappear.
  """
  @behaviour Mutare.Mutator

  alias Mutare.AST
  alias Mutare.Mutator.Mutation

  @impl Mutare.Mutator
  def name, do: :noted

  @impl Mutare.Mutator
  def mutate({:__block__, _meta, [42]}) do
    [
      Mutation.new(AST.literal(0), "off-by-one suspected"),
      AST.literal(nil),
      AST.literal(1)
    ]
  end

  def mutate(_node), do: :skip
end
