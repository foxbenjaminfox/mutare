defmodule Mutare.Test.ConfigurableMutator do
  @moduledoc """
  A reference *configurable* custom mutator, used in tests to exercise the public
  `{module, opts}` options-threading path.

  It rewrites an integer literal to a replacement supplied via its configuration,
  read from `context.opts` in `mutate/2` (a node-local mutator with no options
  does nothing). Mirrors the configurable example in the `Mutare.Mutator` docs.
  """
  @behaviour Mutare.Mutator

  @impl Mutare.Mutator
  def name, do: :configurable

  @impl Mutare.Mutator
  def mutate({:__block__, _meta, [n]}, %{opts: opts}) when is_integer(n) do
    case Keyword.get(opts, :replacement) do
      nil -> :skip
      # Clean meta so the new value renders (not the original token).
      value -> [{:__block__, [], [value]}]
    end
  end

  def mutate(_node, _context), do: :skip
end
