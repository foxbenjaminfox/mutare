defmodule Mutare.Transform.Calls do
  @moduledoc """
  Resolve a call node to the module it actually targets — the helper a **call-matching
  mutator** uses so it matches aliased, imported, and Erlang-atom forms, not just the
  written `Mod.fun(...)`.

  Every built-in call family (Collection, StringCall, ModeSwap, Numeric, …) reads
  `resolved_call/1`; a **custom** mutator should too. Without it, a mutator matching a raw
  `{:., _, [{:__aliases__, _, [:String]}, :upcase]}` node misses `alias String, as: S;
  S.upcase(x)` and `import String; upcase(x)` — `resolved_call/1` resolves all three to the
  same `{[:String], :upcase, args, rebuild}`, and `rebuild` re-emits the swap in the form the
  source wrote (bare/qualified/aliased preserved, so the diff stays minimal).

  This reads the `alias`/`import` stamps `Mutare.Transform.Resolve` places on the AST before
  mutators run, so it is only meaningful on a node handed to a mutator by the transform (a
  `mutate/1` argument) — exactly where a call-matching mutator needs it.

  ## Example

      defmodule MyApp.Mutators.Upcase do
        @behaviour Mutare.Mutator
        def name, do: :upcase_swap

        def mutate(node) do
          case Mutare.Transform.Calls.resolved_call(node) do
            {[:String], :upcase, [arg], rebuild} -> [rebuild.(:downcase, [arg])]
            _ -> :skip
          end
        end
      end

  """

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

  `module` is the resolved key — an Elixir path (`[:String]`) or an Erlang atom
  (`:binary`); `rebuild.(new_fun, new_args)` re-emits a swap in the *written* form
  (so a swap keeps the source's `Mod.`/alias and stays a minimal diff).

      iex> node = Sourceror.parse_string!("String.upcase(s)")
      iex> {module, fun, args, rebuild} = Mutare.Transform.Calls.resolved_call(node)
      iex> {module, fun}
      {[:String], :upcase}
      iex> Sourceror.to_string(rebuild.(:downcase, args))
      "String.downcase(s)"

      iex> erlang = Sourceror.parse_string!(":binary.first(b)")
      iex> {module, fun, _args, _rebuild} = Mutare.Transform.Calls.resolved_call(erlang)
      iex> {module, fun}
      {:binary, :first}

      iex> # a bare local call resolves to nothing
      iex> Mutare.Transform.Calls.resolved_call(Sourceror.parse_string!("foo(x)"))
      nil
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
          # Requalification disambiguates a *renamed* (or re-aritied) sibling — a new
          # `name/arity` that a bare call might resolve to the wrong module, or not at all
          # (see `Mutare.Transform.Imports`). A **value-only** mutation keeps the same name
          # *and* arity, so the bare call resolves exactly as the (compiling) original did:
          # leave it bare. That keeps such a mutant minimal (`truncate(dt, :second)` →
          # `truncate(dt, :millisecond)`, not the requalified whole call) — which also lets
          # `Mutare.Transform.Overlap` see a single-node diff and recognise that the swap
          # covers just the argument (so the redundant `AtomLiteral` leaf is pruned).
          if new_fun == fun and length(new_args) == length(args) do
            {new_fun, meta, new_args}
          else
            {{:., [], [qualifier(module), new_fun]}, meta, new_args}
          end
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

  # Build the qualifier node for a `:qualify` rebuild — naming the resolved module in a form
  # that **bypasses lexical aliases**, since the import captured a specific module but a later
  # `alias` may rebind that name at the call site (`import Enum, only: [reject: 2]; alias
  # String, as: Enum` must still call the real `Enum.filter`, not `String.filter`). For an
  # Elixir module the `Elixir.`-prefixed `__aliases__` is the alias-proof escape hatch
  # (`Elixir.Enum.fun(...)`); an Erlang atom (`:binary.fun(...)`) is never alias-expanded.
  defp qualifier(module) when is_list(module), do: {:__aliases__, [], [:"Elixir" | module]}
  defp qualifier(module) when is_atom(module), do: {:__block__, [], [module]}
end
