defmodule Mutare.Transform.Calls do
  @moduledoc false
  # The single reader every call-matching mutator family uses to recognise a stdlib call
  # and rebuild a swap of it — the one home for the call AST shape and the alias/import
  # resolution step they would otherwise each repeat.
  #
  # `resolved_call/1` recognises three shapes and returns a uniform
  # `{module, fun, args, rebuild}` (or `nil`):
  #
  #   * an **Elixir remote** call `Mod.fun(args)` — resolved through the lexical `alias` env
  #     (`Mutare.Transform.Aliases`); `rebuild` reuses the *written* alias node, so renaming
  #     `S.filter` to `S.reject` keeps the `S.` the source wrote (minimal diff, swap stays
  #     within the module).
  #   * an **Erlang remote** call `:binary.fun(args)` — the module is a bare atom; `rebuild`
  #     reuses it. (An *aliased* atom module `alias :binary, as: B; B.fun` is the Elixir-remote
  #     shape above, resolving to the atom via the `:mutare_alias` stamp.)
  #   * a **bare** call `fun(args)` carrying an `import` stamp (`Mutare.Transform.Imports`) —
  #     `rebuild` produces a **bare** call for a whole-module import (`:bare` — the sibling is
  #     importable too) or a **qualified** `Mod.fun(...)` call for a selective import
  #     (`:qualify` — the sibling may not be in scope, so qualifying keeps it compile-safe).
  #
  # `module` is the resolved key — an Elixir path (`[:String]`, `[:Enum]`) or an Erlang atom
  # (`:binary`, `:string`). A family matches it against its swap table and calls
  # `rebuild.(new_fun, new_args)` without ever inspecting the rebuilt shape, so the
  # direct/aliased/imported distinction is transparent to it. The only call shape this does
  # *not* resolve is a bare `Kernel` call (`abs`, `min`) — those families key on effective
  # arity in their own clauses.

  alias Mutare.Transform.{Aliases, Imports}

  @typedoc """
  A resolved module: an Elixir-module path (`[:Enum]`, `[:String]`) or an Erlang-module atom
  (`:binary`, `:string`). A mutator keys its table on whichever shape the function lives in.
  """
  @type module_key :: [atom()] | atom()

  @doc """
  Deconstruct a recognised stdlib call into `{module, fun, args, rebuild}`, or `nil`.
  """
  @spec resolved_call(Macro.t()) ::
          {module_key(), atom(), [Macro.t()], (atom(), [Macro.t()] -> Macro.t())} | nil

  # An Elixir remote call `Mod.fun(args)` — alias-resolved, rebuilt reusing the written node.
  # `Mod` resolves to an Elixir path, or to an Erlang atom when it is an aliased atom module
  # (`alias :binary, as: B; B.split(...)`), via the `:mutare_alias` stamp.
  def resolved_call(
        {{:., dot_meta, [{:__aliases__, alias_meta, mod} = aliases, fun]}, call_meta, args}
      )
      when is_list(args) do
    rebuild = fn new_fun, new_args ->
      {{:., dot_meta, [aliases, new_fun]}, call_meta, new_args}
    end

    {Aliases.resolved_module(alias_meta, mod), fun, args, rebuild}
  end

  # A direct Erlang remote call `:binary.fun(args)` — the module is a bare atom (Sourceror-
  # wrapped or plain), which `Aliases` never stamps; the atom *is* the module key.
  def resolved_call({{:., dot_meta, [mod, fun]}, call_meta, args})
      when is_atom(fun) and is_list(args) do
    case erlang_module(mod) do
      nil ->
        nil

      atom ->
        rebuild = fn new_fun, new_args ->
          {{:., dot_meta, [mod, new_fun]}, call_meta, new_args}
        end

        {atom, fun, args, rebuild}
    end
  end

  # A bare call `fun(args)` stamped with the module it was imported from (Elixir or Erlang).
  def resolved_call({fun, meta, args}) when is_atom(fun) and is_list(args) do
    case Imports.resolved_import(meta) do
      {module, :bare} ->
        rebuild = fn new_fun, new_args -> {new_fun, meta, new_args} end
        {module, fun, args, rebuild}

      {module, :qualify} ->
        rebuild = fn new_fun, new_args ->
          {{:., [], [qualifier(module), new_fun]}, meta, new_args}
        end

        {module, fun, args, rebuild}

      nil ->
        nil
    end
  end

  def resolved_call(_node), do: nil

  # The module node of a *direct* Erlang remote: a Sourceror-wrapped atom or a bare atom. An
  # `{:__aliases__, …}` (Elixir, handled above) or any non-atom receiver is not one.
  defp erlang_module({:__block__, _meta, [atom]}) when is_atom(atom), do: atom
  defp erlang_module(atom) when is_atom(atom), do: atom
  defp erlang_module(_mod), do: nil

  # Build the qualifier node for a `:qualify` rebuild: an `__aliases__` for an Elixir path,
  # a wrapped atom for an Erlang module (so it renders `:binary.fun(...)`).
  defp qualifier(module) when is_list(module), do: {:__aliases__, [], module}
  defp qualifier(module) when is_atom(module), do: {:__block__, [], [module]}
end
