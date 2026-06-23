defmodule Mutare.Mutators.GenServer do
  @moduledoc """
  Mutates the **return value of a GenServer callback** — `handle_call/3`,
  `handle_cast/2`, `handle_info/2` (and `handle_continue/2`, which shares their
  shapes) — into a *different but still valid* OTP return tuple. The first
  behaviour-gated built-in: it fires **only inside a module that implements
  `GenServer`** (`use GenServer`, or a direct `@behaviour GenServer`), so it is inert
  everywhere else.

  Unlike `Mutare.Mutators.ReturnValue` — which replaces a clause tail with a
  *sentinel* (so the server gets a malformed return and merely crashes, an
  uninformative kill) — this swaps the **control tag** for another the callback
  is *allowed* to return, so the mutant runs as a well-formed GenServer that
  behaves differently. A surviving mutant therefore pinpoints a precise gap:
  *no test checks this callback's reply / liveness / continuation semantics.*

  ## What it knows about (the full `@callback` return surface)

  Recognised by `{tag, arity}`, so every documented form is accounted for — even
  the ones left unmutated:

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

  where `action` is `timeout() | :hibernate | {:continue, term()}`. The shape is
  unambiguous from the tag and arity alone — `:reply` appears only in
  `handle_call`, so the transform never needs to know which callback it is in,
  and a `{:ok, _}` (an `init/1` return), an `:ignore`, a `{:stop, reason}`
  two-tuple, or any non-OTP tuple simply does not match.

  ## The mutations, and why each is meaningful

    * **`:reply` → `:noreply`** (drop the synchronous reply). The headline
      `handle_call` mutation: the caller's `GenServer.call` now blocks until
      timeout instead of receiving `reply`. Any test that asserts the call's
      result kills it; a survivor means the return value is unchecked.
    * **`:noreply` → `:stop` (`:normal`)** — the server *terminates* where it
      meant to keep running. A test that does more than one interaction (or
      checks the process stays alive) kills it.
    * **`:stop` → `:noreply`** — the server *keeps running* where it meant to
      stop. A test asserting termination (a `:DOWN`, `Process.alive?/1`) kills it.
    * **`{:stop, reason, reply, s}` → `{:reply, reply, s}`** — stops-with-reply
      becomes reply-and-continue (keeps the reply, drops the shutdown).

  Each reuses the original `new_state` / `reply` operand AST and injects only the
  literal control atoms (`:noreply` / `:stop` / `:reply` / `:normal`), so every
  mutant is a **valid GenServer return that compiles** — the single metamutant
  build is never at risk. Exactly one alternative is offered per recognised tail
  (the clearest behaviour change), keeping the mutant set tight.

  ## Deliberately left alone

    * The `action` element (`timeout`/`:hibernate`/`{:continue, _}`) is reused or
      dropped, never rewritten — a `:hibernate`↔drop is a perf-only no-op
      (equivalent mutant), and a `{:continue, _}` target is mutated by other
      families if it is code.
    * The `:stop` `reason` is reused (or dropped when the tag changes), not
      swapped — a reason swap is rarely observable.
    * `init/1`, `terminate/2`, `code_change/3`, `format_status/*` returns aren't
      these tagged tuples, so they are out of scope by construction.
  """

  @behaviour Mutare.Mutator

  alias Mutare.AST

  @impl true
  def name, do: :genserver

  # Every decision needs the enclosing module's behaviours, so this mutator works
  # purely through the structural return hook — never node-locally.
  @impl true
  def mutate(_node), do: :skip

  @doc """
  Offer the alternative GenServer return for `tail`, but only inside a module that
  implements `GenServer` (read from `context.behaviours`). The behaviour-aware
  variant of `c:Mutare.Mutator.return_replacements/1`.
  """
  @impl true
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

  # The atom of a control tag — Sourceror wraps an atom literal in a block.
  defp tag_name({:__block__, _meta, [atom]}) when is_atom(atom), do: atom
  defp tag_name(atom) when is_atom(atom), do: atom
  defp tag_name(_other), do: nil
end
