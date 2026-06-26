defmodule Mutare.Transform.Behaviours do
  @moduledoc false
  # The `@behaviour`-gathering pre-pass — a fourth lexical pre-pass alongside `Aliases`,
  # `Imports`, and `Uses`. It computes, **per module**, the set of behaviour modules the
  # module implements and stamps it on the `defmodule`/`defprotocol` node's meta under
  # `:mutare_behaviours`, so `Mutare.Transform` can fold it onto each mutator `Spec` and
  # deliver it to a behaviour-aware custom mutator's `mutate/2` / structural callbacks
  # (via the context map's `:behaviours` key).
  #
  # A module's behaviours come from two places, unioned:
  #
  #   * **direct** `@behaviour Foo` statements in the body — resolved through the lexical
  #     alias env in force (so `alias MyApp.Server, as: S; @behaviour S` records
  #     `MyApp.Server`, not `S`), reusing `Aliases.register/2` + `Aliases.resolve_path/2`;
  #   * **`use`-injected** behaviours — `use GenServer` injects `@behaviour GenServer` in
  #     its `__using__` body, harvested by `Mutare.Transform.Uses` and read back off each
  #     `use` node's `:mutare_use_behaviours` stamp (present only when `:expand_uses` ran
  #     and the used module was loadable — the same degradation class `Uses` documents).
  #
  # Only the canonical `@behaviour` is recognised — Elixir rejects `@behavior` outright.
  #
  # ## Why a dedicated walk (not folded into `Uses` or `Resolve`)
  #
  # `Uses` already tracks modules + an alias env, but it runs only under `:expand_uses`;
  # direct `@behaviour` must be gathered regardless. `Resolve` always runs but deliberately
  # doesn't track module scopes. So this is its own small walk: descend module scopes,
  # fold the alias env left-to-right (so a top-level `alias` reaches a later `defmodule`'s
  # `@behaviour`, exactly as `Uses` folds its `use` targets), and stamp each module.
  #
  # ## Scope
  #
  # `defmodule`/`defprotocol` are stamped (a `defprotocol` has no mutatable body, so its
  # stamp is harmless but kept for uniformity). A `defimpl` is *descended* (its body and
  # nested modules still resolve) but not itself stamped — it is its own module and rarely
  # behaviour-bearing; its body therefore sees an empty behaviour set. Behaviours never
  # *inherit* into nested modules (each module declares its own), which falls out of
  # stamping each `defmodule` from its own body only.

  alias Mutare.Transform.{Aliases, MetaKeys, Uses}

  @behaviours_key MetaKeys.behaviours_key()

  @doc """
  Stamp each `defmodule`/`defprotocol` node's meta with `:mutare_behaviours` — the `MapSet`
  of behaviour modules it implements (direct + `use`-injected). Runs on the
  `Uses`-annotated tree (so the injected behaviours are visible) and before
  `Resolve.annotate/2` (which preserves the stamp when it prepends nids).
  """
  @spec annotate(Macro.t()) :: Macro.t()
  def annotate(ast), do: walk(ast, %{})

  @doc """
  The behaviour `MapSet` stamped on a module node's meta, or the empty set for any other
  node. The reader half of the `:mutare_behaviours` contract.
  """
  @spec behaviours(keyword() | term()) :: MapSet.t(module())
  def behaviours(meta) when is_list(meta), do: Keyword.get(meta, @behaviours_key, MapSet.new())
  def behaviours(_meta), do: MapSet.new()

  # --- the walk --------------------------------------------------------------

  # A module scope: compute its behaviour set from its own body, stamp it, then descend the
  # body (so nested modules are stamped too) under the alias env in force. The set is
  # computed from the body's *direct* statements only — a nested module's `@behaviour`
  # belongs to it, not the parent — so no behaviour leaks across the boundary.
  defp walk({form, meta, [mod_ast, [{do_key, body}]]}, aliases)
       when form in [:defmodule, :defprotocol] do
    set = module_behaviours(body, aliases)
    # Descend the body (for nested modules), folding aliases where it is a block.
    body = walk(body, aliases)
    meta = if MapSet.size(set) == 0, do: meta, else: [{@behaviours_key, set} | meta]
    {form, meta, [mod_ast, [{do_key, body}]]}
  end

  # A statement sequence (the file top level, a module body, or any block): fold the alias
  # env left-to-right so a `defmodule` after a top-level/preceding `alias` resolves its
  # `@behaviour` through it, and descend each statement to reach nested modules.
  defp walk({:__block__, meta, stmts}, aliases) when is_list(stmts) do
    {walked, _aliases} =
      Enum.map_reduce(stmts, aliases, fn stmt, aliases ->
        {walk(stmt, aliases), Aliases.register(stmt, aliases)}
      end)

    {:__block__, meta, walked}
  end

  defp walk({form, meta, args}, aliases) when is_list(args),
    do: {form, meta, Enum.map(args, &walk(&1, aliases))}

  defp walk({left, right}, aliases), do: {walk(left, aliases), walk(right, aliases)}
  defp walk(list, aliases) when is_list(list), do: Enum.map(list, &walk(&1, aliases))
  defp walk(other, _aliases), do: other

  # --- per-module behaviour set ----------------------------------------------

  # The behaviour set of one module body: fold its direct statements left-to-right (so an
  # `@behaviour` resolves through the aliases declared above it), accumulating direct
  # `@behaviour` modules (alias-resolved) and `use`-injected ones. Starts from the enclosing
  # `outer_aliases` so a file-top alias is in scope.
  defp module_behaviours(body, outer_aliases) do
    {set, _aliases} =
      body
      |> body_statements()
      |> Enum.reduce({MapSet.new(), outer_aliases}, fn stmt, {set, aliases} ->
        set = set |> add_direct(stmt, aliases) |> add_injected(stmt)
        {set, Aliases.register(stmt, aliases)}
      end)

    set
  end

  defp body_statements({:__block__, _meta, stmts}) when is_list(stmts), do: stmts
  defp body_statements(single), do: [single]

  # A direct `@behaviour Foo` statement: resolve the module through the alias env in force
  # and add it. Anything else leaves the set untouched.
  defp add_direct(set, {:@, _meta, [{:behaviour, _bmeta, [mod_ast]}]}, aliases) do
    case Aliases.resolve_node(mod_ast, aliases) do
      nil -> set
      mod -> MapSet.put(set, mod)
    end
  end

  defp add_direct(set, _stmt, _aliases), do: set

  # A `use` statement: union in whatever behaviours `Uses` harvested from its `__using__`
  # body (empty unless `:expand_uses` ran and the module was loadable).
  defp add_injected(set, {:use, meta, _args}) when is_list(meta),
    do: Enum.into(Uses.injected_behaviours(meta), set)

  defp add_injected(set, _stmt), do: set
end
