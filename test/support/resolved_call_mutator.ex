defmodule Mutare.Test.AliasCallMutator do
  @moduledoc """
  A custom **call-matching** mutator that uses the public `Mutare.Calls.resolved_call/1`
  helper to match `String.reverse/1` and swap it to `String.upcase/1` — *regardless of how the
  call was written*. Because it resolves rather than pattern-matching the raw node, it fires on the
  direct `String.reverse(s)`, an aliased `S.reverse(s)`, and a bare imported `reverse(s)` alike, and
  `rebuild` re-emits the swap in the written form. Exercises the resolution helper being exposed to
  third-party mutators.
  """
  @behaviour Mutare.Mutator

  alias Mutare.Calls

  @impl Mutare.Mutator
  def name, do: :alias_call

  @impl Mutare.Mutator
  def mutate(node) do
    case Calls.resolved_call(node) do
      {[:String], :reverse, [arg], rebuild} -> [rebuild.(:upcase, [arg])]
      _other -> :skip
    end
  end
end
