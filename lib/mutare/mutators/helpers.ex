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
end
