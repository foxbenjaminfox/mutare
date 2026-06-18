defmodule Mutare.Transform.Calls do
  @moduledoc false
  # The single reader every call-matching mutator family uses to recognise a stdlib call
  # and rebuild a swap of it — the one home for the call AST shape and the alias/import
  # resolution step they would otherwise each repeat.
  #
  # `resolved_call/1` recognises two shapes and returns a uniform
  # `{module, fun, args, rebuild}` (or `nil`):
  #
  #   * a **remote** call `Mod.fun(args)` — resolved through the lexical `alias` env
  #     (`Mutare.Transform.Aliases`); `rebuild` reuses the *written* alias node and the
  #     original `.`/call metadata, so renaming `S.filter` to `S.reject` keeps the `S.`
  #     the source wrote (minimal diff, swap stays within the module).
  #   * a **bare** call `fun(args)` carrying an `import` stamp
  #     (`Mutare.Transform.Imports`) — `rebuild` produces a **bare** call for a
  #     whole-module import (`:bare` — the sibling is importable too, so the mutant stays
  #     bare) or a **qualified** `Mod.fun(...)` call for a selective import (`:qualify` —
  #     the sibling may not be in scope, so qualifying keeps it compile-safe).
  #
  # `module` is the resolved module path (`[:String]`, `[:Enum]`). A family matches it
  # against its swap table and calls `rebuild.(new_fun, new_args)` without ever inspecting
  # the rebuilt shape, so bare-vs-qualified is transparent to it. Families with extra
  # shapes (`:string`/`Kernel`/bare-Kernel) keep their own clauses and use this for the
  # Elixir alias/import case.

  alias Mutare.Transform.{Aliases, Imports}

  @doc """
  Deconstruct a recognised stdlib call into `{module, fun, args, rebuild}`, or `nil`.
  """
  @spec resolved_call(Macro.t()) ::
          {[atom()], atom(), [Macro.t()], (atom(), [Macro.t()] -> Macro.t())} | nil

  # A remote call `Mod.fun(args)` — alias-resolved, rebuilt reusing the written node.
  def resolved_call(
        {{:., dot_meta, [{:__aliases__, alias_meta, mod} = aliases, fun]}, call_meta, args}
      )
      when is_list(args) do
    rebuild = fn new_fun, new_args ->
      {{:., dot_meta, [aliases, new_fun]}, call_meta, new_args}
    end

    {Aliases.resolved_module(alias_meta, mod), fun, args, rebuild}
  end

  # A bare call `fun(args)` stamped with the module it was imported from.
  def resolved_call({fun, meta, args}) when is_atom(fun) and is_list(args) do
    case Imports.resolved_import(meta) do
      {module, :bare} ->
        rebuild = fn new_fun, new_args -> {new_fun, meta, new_args} end
        {module, fun, args, rebuild}

      {module, :qualify} ->
        rebuild = fn new_fun, new_args ->
          {{:., [], [{:__aliases__, [], module}, new_fun]}, meta, new_args}
        end

        {module, fun, args, rebuild}

      nil ->
        nil
    end
  end

  def resolved_call(_node), do: nil
end
