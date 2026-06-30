defmodule Mutare.Mutators.GenServer do
  @moduledoc """
  Changes a `GenServer` callback return into another valid OTP return tuple. It runs
  only in modules that use or declare the `GenServer` behaviour.

  The mutator covers return values from `handle_call/3`, `handle_cast/2`,
  `handle_info/2`, and `handle_continue/2`:

      handle_call/3
        {:reply, reply, new_state}                     ->  {:noreply, new_state}
        {:reply, reply, new_state, action}             ->  {:noreply, new_state, action}
        {:noreply, new_state}                          ->  {:stop, :normal, new_state}
        {:noreply, new_state, action}                  ->  {:stop, :normal, new_state}
        {:stop, reason, new_state}                     ->  {:noreply, new_state}
        {:stop, reason, reply, new_state}              ->  {:reply, reply, new_state}

      handle_cast/2, handle_info/2, handle_continue/2
        {:noreply, new_state}                          ->  {:stop, :normal, new_state}
        {:noreply, new_state, action}                  ->  {:stop, :normal, new_state}
        {:stop, reason, new_state}                     ->  {:noreply, new_state}

  Here `action` is a timeout, `:hibernate`, or `{:continue, term()}`. Each mutation
  preserves the original state, reply, and action where the new tuple accepts them.

  Other tuple shapes do not match. This excludes `init/1` returns, `:ignore`,
  two-element `{:stop, reason}` tuples, and returns from callbacks such as
  `terminate/2` and `code_change/3`. Actions and stop reasons are not mutated.
  """

  @behaviour Mutare.Mutator
  @behaviour Mutare.Mutator.Structural

  alias Mutare.AST

  @impl Mutare.Mutator
  def name, do: :genserver

  @doc """
  Offer the alternative GenServer return for `tail`, but only inside a module that
  implements `GenServer` (read from `context.behaviours`). The behaviour-aware
  variant of `c:Mutare.Mutator.Structural.return_replacements/1`.
  """
  @impl Mutare.Mutator.Structural
  def return_replacements(tail, %{behaviours: behaviours}) do
    if MapSet.member?(behaviours, GenServer), do: mutate_return(tail), else: []
  end

  # A single-statement block — Sourceror wraps a bare 2-tuple literal (`{:noreply,
  # state}`) this way to anchor its metadata, and an inline `do:` body the same —
  # so unwrap and recurse; the tuple inside is what we recognise.
  defp mutate_return({:__block__, _meta, [inner]}), do: mutate_return(inner)

  # A 3- or 4-element tuple carries its own metadata (`{:{}, meta, [tag | rest]}`).
  defp mutate_return({:{}, _meta, [tag | rest]}) when is_list(rest),
    do: returns_for(tag_name(tag), rest)

  # A bare 2-tuple `{tag, new_state}` (post-unwrap).
  defp mutate_return({tag, state}), do: returns_for(tag_name(tag), [state])

  defp mutate_return(_tail), do: []

  # The one alternative valid return per (tag, arity). The element layout is the
  # callback contract: `:reply`/`:stop`-4 carry a reply, `:stop` carries a reason.
  defp returns_for(:reply, [_reply, state]), do: [retuple(:noreply, [state])]
  defp returns_for(:reply, [_reply, state, action]), do: [retuple(:noreply, [state, action])]
  defp returns_for(:noreply, [state]), do: [retuple(:stop, [AST.literal(:normal), state])]

  defp returns_for(:noreply, [state, _action]),
    do: [retuple(:stop, [AST.literal(:normal), state])]

  defp returns_for(:stop, [_reason, state]), do: [retuple(:noreply, [state])]
  defp returns_for(:stop, [_reason, reply, state]), do: [retuple(:reply, [reply, state])]
  defp returns_for(_tag, _elements), do: []

  # Build `{:tag, ...values}` as a Sourceror tuple node. The explicit `{:{}, [], …}`
  # form renders as a literal tuple for any arity (a 2-element arg list renders
  # `{a, b}`), so it serves the 2-, 3-, and 4-tuple results uniformly.
  defp retuple(tag, values), do: {:{}, [], [AST.literal(tag) | values]}

  # The atom of a control tag, read through `AST.literal_value/1` (Sourceror wraps an atom literal
  # in a block; a bare atom passes too), or `nil` for a non-atom node.
  defp tag_name(node) do
    case AST.literal_value(node) do
      {:ok, atom} when is_atom(atom) -> atom
      _ -> nil
    end
  end
end
