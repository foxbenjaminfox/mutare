defmodule Mutare.Transform.Calls do
  @moduledoc false

  # `Mutare.Calls` is the published facade re-exporting the author-facing readers —
  # their docs (and doctests) live there. This module is the implementation, free to
  # grow internal readers the facade doesn't commit to.
  #
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
  #     importable too). For a selective import (`:qualify`), value-only replacements stay bare;
  #     renamed or re-aritied siblings become qualified `Mod.fun(...)` calls because the sibling
  #     may not be in scope.
  #
  # `module` is the resolved key — an Elixir path (`[:String]`, `[:Enum]`) or an Erlang atom
  # (`:binary`, `:string`). A family matches it against its swap table and calls
  # `rebuild.(new_fun, new_args)` without ever inspecting the rebuilt shape, so the
  # direct/aliased/imported distinction is transparent to it. The only call shape this does
  # *not* resolve is a bare `Kernel` call (`abs`, `min`) — those families key on effective
  # arity in their own clauses.

  alias Mutare.Transform.{Aliases, Imports, Meta}

  # A resolved module: an Elixir-module path (`[:Enum]`, `[:String]`) or an Erlang-module atom
  # (`:binary`, `:string`). Defined once in `Mutare.Transform.Aliases` (the module-key
  # operations' owner); re-exported through `Mutare.Calls` for authors.
  @type module_key :: Aliases.module_key()

  # Returns `{module, function, arguments, rebuild}` for a resolved standard-library
  # call, or `nil`. See `Mutare.Calls.resolved_call/1` for the contract.
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
  # wrapped or plain), which `Aliases` never stamps; the atom *is* the module key. The
  # `__aliases__` (Elixir) shape was handled by the clause above, so `Aliases.resolve_node/2`
  # (env-free — a direct remote carries no alias) only ever sees the bare/wrapped-atom shapes
  # here, returning the atom (or `nil` for a non-module receiver).
  def resolved_call({{:., dot_meta, [mod, fun]}, call_meta, args})
      when is_atom(fun) and is_list(args) do
    case Aliases.resolve_node(mod, %{}) do
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
        rebuild = fn new_fun, new_args ->
          {new_fun, rewitness_bare_rebuild(meta, module, args, new_fun, new_args), new_args}
        end

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

  # The resolved-call key for a concrete module atom. See `Mutare.Calls.module_key/1`
  # for the contract; the encoding lives with the key operations in `Aliases`.
  @spec module_key(module()) :: module_key()
  defdelegate module_key(module), to: Aliases, as: :from_module

  @kernel_key Aliases.from_module(Kernel)

  @doc """
  Whether `node` is a call to `Kernel`'s macro or function of that name — the reading every
  bare-`Kernel` reader needs, in one place.

  An *unresolved* bare call is `Kernel`'s unless the resolver stamped it displaced
  (`import Kernel, except: [if: 2]`, with the replacement out of reach); a *resolved* one names
  the module it came from, which may still be `Kernel` (an explicit `Kernel.def`, or an
  `import Kernel, only: …`). `false` for a node that is not a call at all.

  Callers ask this wherever a bare name is about to be read as the `Kernel` construct it looks
  like — a return-path `if`/`unless` (`Mutare.Transform.Analyze.Returns`), a scope-boundary
  `defmodule` (`Mutare.Transform.ModulePlan.scope_boundary?/1`).
  """
  @spec kernel_call?(Macro.t()) :: boolean()
  def kernel_call?({_form, meta, _args} = node) when is_list(meta) do
    case resolved_call(node) do
      nil -> not Imports.kernel_displaced?(meta)
      {@kernel_key, _fun, _args, _rebuild} -> true
      _other_module -> false
    end
  end

  def kernel_call?(_node), do: false

  # Match a resolved call against a target module and function name(s). See
  # `Mutare.Calls.resolved_call_to/3` for the contract.
  @spec resolved_call_to(Macro.t(), module() | module_key(), atom() | [atom()] | :any) ::
          {:ok, atom(), [Macro.t()], (atom(), [Macro.t()] -> Macro.t())} | :error
  def resolved_call_to(node, module, functions \\ :any) do
    target = target_key(module)

    case resolved_call(node) do
      {^target, fun, args, rebuild} ->
        if function_match?(fun, functions), do: {:ok, fun, args, rebuild}, else: :error

      _unresolved_or_other_module ->
        :error
    end
  end

  # An already-encoded key (a segment path) passes through; a module atom is encoded.
  defp target_key(module) when is_list(module), do: module
  defp target_key(module) when is_atom(module), do: Aliases.from_module(module)

  defp function_match?(_fun, :any), do: true
  defp function_match?(fun, functions) when is_list(functions), do: fun in functions
  defp function_match?(fun, function) when is_atom(function), do: fun == function

  defp rewitness_bare_rebuild(meta, module, old_args, new_fun, new_args) do
    case Imports.import_witness(meta) do
      {_module, _fun, old_arity} ->
        new_arity = old_arity + length(new_args) - length(old_args)

        if new_arity >= 0,
          do: Imports.put_import_witness(meta, {module, new_fun, new_arity}),
          else: meta

      nil ->
        meta
    end
  end

  # Return the stable call value for a node stamped by the known-macro resolver, or `nil` for
  # any other node. See `Mutare.Calls.resolved_routed_call/1` for the contract.
  @spec resolved_routed_call(Macro.t()) :: Mutare.CallRouting.Call.t() | nil
  def resolved_routed_call({head, meta, args} = node) when is_list(meta) and is_list(args) do
    # Stay **total**: the identity stamp is only ever placed (by `Mutare.Transform.Resolve`) on a
    # remote `Mod.fun`/`:mod.fun` or a bare `fun` head, the two shapes `macro_rebuild/4` handles —
    # so a node carrying the stamp on any *other* head (e.g. a `recv.()` anonymous-call head) is an
    # impossible state Mutare never produces. Rather than commit to a partial `macro_rebuild` that
    # would raise on it, degrade to `nil` (the documented "not a recognised known-macro call"), so a
    # caller handing in an arbitrary node can never crash here.
    with {module_key, name, pipe_mode} <- macro_identity(meta),
         rebuild when is_function(rebuild, 2) <- macro_rebuild(head, meta, module_key, args) do
      %Mutare.CallRouting.Call{
        node: node,
        module: natural_module(module_key),
        name: name,
        arguments: args,
        pipe_mode: pipe_mode,
        effective_arity: Mutare.Mutator.effective_arity(args, pipe_mode),
        rebuild: rebuild
      }
    else
      _ -> nil
    end
  end

  def resolved_routed_call(_node), do: nil

  # Returns the resolved treatment for each visible argument of a routed call, `:skip` for a
  # call routed as an inert leaf, or `nil` for an unrouted node. See
  # `Mutare.Calls.routed_treatments/1` for the contract.
  #
  # The stamp is mapped back to the author-facing vocabulary (`Mutare.CallRouting.Spec.author_position/1`):
  # `Resolve` rewrites each `:hosted` to the internal `{:hosted, host_module}` (stamping the
  # delivering mutator), normalizes a keyed refinement to `{:keyed, …}`, and recurses through
  # `{:keyword, …}` — so a mutator reading this sees the words it wrote, not Mutare's stamp shape.
  @spec routed_treatments(Macro.t()) :: [Mutare.CallRouting.routing_treatment()] | :skip | nil
  def routed_treatments({_head, meta, _args}) when is_list(meta) do
    case Meta.routing(meta) do
      :skip ->
        :skip

      routing when is_list(routing) ->
        Enum.map(routing, &Mutare.CallRouting.Spec.author_position/1)

      _ ->
        nil
    end
  end

  def routed_treatments(_node), do: nil

  # The resolved `{module_key, name, pipe_mode}` identity from a node's own meta, or `nil` when absent —
  # i.e. when the node was never matched against the macro registry.
  defp macro_identity(meta) do
    case Meta.routed_call(meta) do
      {_module, _name, pipe_mode} = identity when pipe_mode in [:piped, :unpiped] -> identity
      _ -> nil
    end
  end

  defp natural_module(nil), do: nil
  defp natural_module(module) when is_list(module), do: Module.concat(module)
  defp natural_module(module) when is_atom(module), do: module

  # Re-emit a swap in the call's *written* form. The macro stamp is only ever placed on a remote
  # `Mod.fun`/`:mod.fun` head or a bare `fun` head. A remote head reuses its written receiver/meta
  # verbatim — qualified keeps its module path, aliased keeps its alias. (`module` is the resolved
  # identity, unused for a remote: the written receiver already names the module.)
  defp macro_rebuild({:., dot_meta, [recv, _fun]}, call_meta, _module, _args) do
    fn new_name, new_args -> {{:., dot_meta, [recv, new_name]}, call_meta, new_args} end
  end

  # A bare imported/Kernel macro mirrors `resolved_call/1`'s bare rebuild — comparing the proposed
  # name to the **written head** `fun`, exactly as that twin compares `new_fun == fun`. The three
  # sources of a bare macro call differ in whether a *renamed* (or re-aritied) sibling is safe to
  # leave bare:
  #
  #   * `:bare` — a **sole whole import** with an unmanipulated `Kernel` (`Imports.rebuild_kind/3`
  #     guarantees it): the only other in-scope provider is `Kernel`, so the renamed sibling is
  #     unambiguously bare-callable to the same module. Stays **bare** even on a rename.
  #   * `:qualify` — a **selective or overlapping** import: the new name may not be imported, or a
  #     second import could make a bare sibling ambiguous / point it elsewhere. Requalify a
  #     renamed/re-aritied sibling with the alias-proof module.
  #   * `nil` (no `:mutare_import` stamp) — a `Kernel` macro (`match?`, auto-imported) **or** a
  #     **registry-fallback** whole import Mutare couldn't reflect on
  #     (`Resolve.registered_macro_module/3`). Neither carries the sole-whole-import guarantee
  #     `:bare` rests on: a renamed/re-aritied sibling may be displaced
  #     (`import Kernel, except: [destructure: 2]`) or shadowed by an overlapping provider, so a
  #     bare emit could fail to compile. Requalify it with the resolved **identity** module (the
  #     `@route_call_key` stamp, threaded in as `module`).
  #
  # A **value-only** swap (same name *and* arity) keeps the bare form in every case — it resolves
  # exactly as the (compiling) original did. A `nil` *identity module* (a name-only `{:*, name}`
  # match the resolver never pinned to a module) has nothing to qualify against, so it too stays
  # bare — the best available, the name-only hatch's inherent limit.
  defp macro_rebuild(fun, meta, module, args) when is_atom(fun) do
    case Imports.resolved_import(meta) do
      {import_module, :qualify} -> bare_macro_rebuild(import_module, meta, fun, args)
      {_import_module, :bare} -> fn new_name, new_args -> {new_name, meta, new_args} end
      nil -> bare_macro_rebuild(module, meta, fun, args)
    end
  end

  # An unexpected head shape (never produced by `Mutare.Transform.Resolve`): no rebuild — the `nil`
  # makes `resolved_routed_call/1` degrade to `nil` instead of raising a `FunctionClauseError`.
  defp macro_rebuild(_head, _meta, _module, _args), do: nil

  # The bare rebuild closure: a value-only swap (same name *and* arity as the written head `fun`)
  # stays bare; a renamed/re-aritied sibling requalifies with `module` (alias-proof), unless
  # `module` is `nil` (a name-only match) where bare is the only option.
  defp bare_macro_rebuild(module, meta, fun, args) do
    fn new_name, new_args ->
      if (new_name == fun and length(new_args) == length(args)) or is_nil(module) do
        {new_name, meta, new_args}
      else
        {{:., [], [qualifier(module), new_name]}, meta, new_args}
      end
    end
  end

  # Build the qualifier node for a `:qualify` rebuild — naming the resolved module in a form
  # that **bypasses lexical aliases**, since the import captured a specific module but a later
  # `alias` may rebind that name at the call site (`import Enum, only: [reject: 2]; alias
  # String, as: Enum` must still call the real `Enum.filter`, not `String.filter`). For an
  # Elixir module the `Elixir.`-prefixed `__aliases__` is the alias-proof escape hatch
  # (`Elixir.Enum.fun(...)`); an Erlang atom (`:binary.fun(...)`) is never alias-expanded.
  defp qualifier(module) when is_list(module), do: {:__aliases__, [], [:"Elixir" | module]}
  defp qualifier(module) when is_atom(module), do: {:__block__, [], [module]}
end
