defmodule Mutare.Test.NotedMutator do
  @moduledoc """
  A reference mutator exercising the **note channel** of the standard `c:Mutare.Mutator.mutate/1`
  API — the per-mutant advisory previously only a selector host could attach, now available to
  any node-level mutator.

  Each element a `mutate/1` (or `mutate/2`) return list may be one of `t:Mutare.Mutator.mutation/0`:
  a **bare node** (no note), a **`%Mutare.Mutator.Mutation{}`** (a node + an advisory the report
  surfaces on that mutant's `Mutare.Site`), or **`nil`** (a dropped slot, filtered out). This
  mutator targets the integer literal `42` and returns all three forms at once:

    * a noted `0` (via `Mutare.Mutator.Mutation.new/2`) — its Site carries the note;
    * a `nil` slot — produces no Site at all; and
    * a bare `1` — its Site's note is `nil`.

  So a test can assert the note rides through to the Site, that a bare mutant has none, and that
  the `nil` slot is dropped (exactly two sites for the one literal).
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
      nil,
      AST.literal(1)
    ]
  end

  def mutate(_node), do: :skip
end
