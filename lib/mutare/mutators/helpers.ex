defmodule Mutare.Mutators.Helpers do
  @moduledoc false

  # Shared building blocks for the built-in mutator families. Not a mutator itself
  # (no `@behaviour`, not in the `Mutare.Mutators` registry) — just the logic several
  # families would otherwise copy.

  alias Mutare.Transform.Calls

  @doc """
  Rename a resolved call by looking its `{module, fun}` up in a swap `table`.

  The single shape behind the "swap-table" families (`Collection`, `Integer`,
  `MapKeyword`, `Numeric`'s qualified arm): resolve the call through
  `Mutare.Transform.Calls` (so a direct, aliased, or bare-imported form all match),
  look up `{module, fun}`, and rebuild the call with the new function name. The
  table value is the new function name, or a **list** of names (several siblings →
  several mutants). `rebuild` reuses the call's written module node, so the swap
  stays within the module (an aliased `S.upcase` mutates to `S.downcase`, not
  `String.downcase`).

  Returns `:skip` when the node isn't a resolved call, or its `{module, fun}` isn't
  in the table.
  """
  @spec swap_call(Macro.t(), %{optional({Calls.module_key(), atom()}) => atom() | [atom()]}) ::
          [Macro.t()] | :skip
  def swap_call(node, table) do
    with {module, fun, args, rebuild} <- Calls.resolved_call(node),
         {:ok, new_funs} <- Map.fetch(table, {module, fun}) do
      new_funs |> List.wrap() |> Enum.map(&rebuild.(&1, args))
    else
      _ -> :skip
    end
  end

  @doc """
  Remove a *transparent transform* call — pipe-aware.

  The "call removal" counterpart of `swap_call/2`: resolve `node` through
  `Mutare.Transform.Calls` (so a direct, aliased, or bare-imported form all match)
  and, when its `{module, fun}` is in the `removable` set, drop the call via
  `removed_call/2`. Returns `:skip` when the node isn't a resolved call, or its
  `{module, fun}` isn't removable.

  The `removable` set holds `{module_key, function}` pairs — arity-agnostic, like
  `Mutare.Mutators.CallRemoval`'s `@removable` — where `module_key` is a resolved
  alias path (`[:String]`) or a bare Erlang atom (`:string`).
  """
  @spec remove_call(Macro.t(), Mutare.Mutator.pipe_mode(), MapSet.t({Calls.module_key(), atom()})) ::
          [Macro.t()] | :skip
  def remove_call(node, pipe_mode, removable) do
    with {module, fun, args, _rebuild} <- Calls.resolved_call(node),
         true <- MapSet.member?(removable, {module, fun}) do
      removed_call(pipe_mode, args)
    else
      _ -> :skip
    end
  end

  @doc """
  The pipe-aware removal itself, decoupled from how the call was matched.

  A call removal can't simply *vanish* a node: a pipe stage carries one fewer argument
  than the source reads (the input is the `|>` left side, not in the call), so the
  removal differs by context:

    * **non-piped** → the first argument (`Enum.sort(x)` → `x`), the cleanest diff;
    * **piped** → `Elixir.Function.identity()`, so `x |> Enum.sort()` becomes
      `x |> Elixir.Function.identity()` ≡ `x`. A pipe stage can't be made to disappear
      inside a selector, and `Function.identity/1` is the minimal, compile-safe no-op
      that rides the existing `hoist_pipe` path unchanged. It is emitted through the
      **absolute** `Elixir.Function` alias (led by `:Elixir`, which alias resolution
      never rewrites) so a target-module `alias Foo, as: Function` can't redirect the
      generated no-op.

  Public so a mutator that matches a call by some means `Calls.resolved_call/1` doesn't
  cover (e.g. a bare `Kernel` call, keyed on effective arity) can reuse the
  identity-vs-first-argument mechanic after deciding the call is removable. Returns
  `:skip` for the degenerate non-piped, zero-argument call (nothing to return).
  """
  @spec removed_call(Mutare.Mutator.pipe_mode(), [Macro.t()]) :: [Macro.t()] | :skip
  def removed_call(:piped, _args), do: [identity_call()]
  def removed_call(:unpiped, []), do: :skip
  def removed_call(:unpiped, [first | _]), do: [first]

  defp identity_call do
    {{:., [], [{:__aliases__, [], [:"Elixir", :Function]}, :identity]}, [], []}
  end
end
