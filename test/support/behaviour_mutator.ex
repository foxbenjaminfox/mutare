defmodule Mutare.Test.BehaviourMutator do
  @moduledoc """
  A **behaviour-targeted** custom mutator — the worked example for `context.behaviours`. It
  fires *only* inside a module that implements one of its target behaviours (`GenServer` or
  `Mutare.Test.SampleBehaviour`), demonstrating both ways a mutator can read the enclosing
  module's `@behaviour` set:

    * `mutate/2` — swaps a `{:reply, reply, state}` 3-tuple to `{:noreply, state}` (the
      motivating GenServer mutation), gated on `context.behaviours`;
    * `return_replacements/2` — the behaviour-aware structural hook: offers a sentinel
      `:behaviour_marker` return tail, again only in a targeted module.

  The `@behaviour` set reaches both via the context map's `:behaviours` key
  (`Mutare.Transform.Behaviours` gathers it, `Mutare.Transform` folds it onto the spec). In a
  module that implements none of the targets, both callbacks no-op, so no site is recorded.
  """

  @behaviour Mutare.Mutator
  @behaviour Mutare.Mutator.Structural

  alias Mutare.AST

  # The behaviours this mutator cares about. A real `use GenServer` (or a direct
  # `@behaviour GenServer`) and the test-only `Mutare.Test.SampleBehaviour` both qualify.
  @targets [GenServer, Mutare.Test.SampleBehaviour]

  @impl true
  def name, do: :behaviour_aware

  @doc """
  Swap a `{:reply, reply, state}` tuple to `{:noreply, state}`, but only inside a module
  implementing one of `@targets`. Reads the behaviour set from `context.behaviours`.
  """
  @impl true
  def mutate({:{}, meta, [tag, _reply, state]}, %{behaviours: behaviours}) do
    if targeted?(behaviours) and reply_tag?(tag),
      do: [{:{}, meta, [noreply(tag), state]}],
      else: :skip
  end

  def mutate(_node, _context), do: :skip

  @doc """
  Offer a sentinel `:behaviour_marker` return tail, only inside a targeted module — the
  behaviour-aware variant of `c:Mutare.Mutator.Structural.return_replacements/1`.
  """
  @impl true
  def return_replacements(_tail, %{behaviours: behaviours}) do
    if targeted?(behaviours), do: [AST.literal(:behaviour_marker)], else: []
  end

  defp targeted?(behaviours), do: Enum.any?(@targets, &MapSet.member?(behaviours, &1))

  # `:reply` as Sourceror wraps an atom literal in a tuple (`{:__block__, _, [:reply]}`), or
  # a bare atom (generated nodes).
  defp reply_tag?({:__block__, _meta, [:reply]}), do: true
  defp reply_tag?(:reply), do: true
  defp reply_tag?(_tag), do: false

  defp noreply({:__block__, meta, [:reply]}), do: {:__block__, meta, [:noreply]}
  defp noreply(_tag), do: AST.literal(:noreply)
end
