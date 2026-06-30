defmodule Mutare.Transform.Calls do
  @moduledoc """
  Call-resolution helpers for custom mutators and macro integrations.

  `resolved_call/1` normalizes qualified, aliased, imported, and Erlang-module calls to
  `{module, function, arguments, rebuild}`. Use `rebuild` to preserve the source's written call
  form when that is compile-safe; bare imported calls may be requalified when the replacement
  changes name or arity. It operates on nodes passed to a mutator by Mutare's transform.

  This reads the `alias`/`import` stamps the transform places on the AST before
  mutators run, so it is only meaningful on a node handed to a mutator by the transform (a
  `mutate/1` argument) — exactly where a call-matching mutator needs it.

  `resolved_macro_call/1` is the **known-macro** twin: the same normalization and rebuild policy
  for the node core hands a router's `c:Mutare.MacroRouting.macro_routing/2` or a host's
  `c:Mutare.Mutator.MacroHost.host/2` callback, so those recognise their macro across the
  bare/qualified/aliased forms `Resolve`
  accepts instead of pattern-matching the raw head.

  `macro_treatment/1` reads *how a node's macro is registered* — the resolved per-argument routing
  the merged registry (built-ins + every mutator's/extension's `macro_routes/0` + the declarative `:macro_routes`
  option) assigned it. A hosting mutator walking a `:hosted` fragment uses it to ask whether a
  **nested** macro routes a given argument `:skip` (leave it opaque) or otherwise specially, rather
  than re-deriving the registry itself.

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

  @typedoc """
  A resolved module: an Elixir-module path (`[:Enum]`, `[:String]`) or an Erlang-module atom
  (`:binary`, `:string`). A mutator keys its table on whichever shape the function lives in.
  Defined once in `Mutare.Transform.Aliases` (the module-key operations' owner).
  """
  @type module_key :: Aliases.module_key()

  @doc """
  Returns `{module, function, arguments, rebuild}` for a resolved standard-library
  call, or `nil`.

  `module` is an Elixir alias path such as `[:String]` or an Erlang module atom.
  `rebuild.(new_function, new_arguments)` preserves the call's written qualifier when safe.
  Remote calls keep their written qualifier or alias. Bare imported calls stay bare for
  value-only replacements, but may be requalified when the replacement changes name or arity.

      iex> node = Sourceror.parse_string!("String.upcase(s)")
      iex> {module, function, arguments, rebuild} =
      ...>   Mutare.Transform.Calls.resolved_call(node)
      iex> {module, function}
      {[:String], :upcase}
      iex> Sourceror.to_string(rebuild.(:downcase, arguments))
      "String.downcase(s)"

      iex> erlang = Sourceror.parse_string!(":binary.first(b)")
      iex> {module, function, _arguments, _rebuild} =
      ...>   Mutare.Transform.Calls.resolved_call(erlang)
      iex> {module, function}
      {:binary, :first}

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

  @doc """
  Returns `{module, name, visible_arguments, rebuild}` for a registered macro call,
  or `nil`.

  This is the helper a router or host (`c:Mutare.MacroRouting.macro_routing/2`,
  `c:Mutare.Mutator.MacroHost.host/2`) should use instead of pattern-matching the node head. Core hands
  those callbacks the *visible call node*, which — depending on how the source wrote it — is a
  **bare** `where(q, …)`, a **qualified** `Ecto.Query.where(q, …)`, or an **aliased**
  `Q.where(q, …)`. A callback that guards on a bare atom head silently fails to recognise the
  qualified/aliased forms (and routes every argument as `:expression`, poisoning a DSL fragment
  or mutating it with core's families). Normalising through this reader makes the written form
  transparent: a single `{[:Ecto, :Query], macro, args, _}` match covers all three.

  `visible_arguments` excludes the left side of a pipe. The rebuild function
  preserves the written form when safe, including remote qualifiers and aliases. Bare imported
  or registry-fallback macro calls may be requalified when the replacement changes name or arity.

  Macro identity comes from the route-resolution metadata attached by the transform,
  so this function also supports registered macros that cannot be resolved through
  runtime module reflection.

      def macro_routing(node, _context) do
        case Mutare.Transform.Calls.resolved_macro_call(node) do
          {[:Ecto, :Query], name, arguments, _rebuild} ->
            route(name, arguments)

          _ ->
            []
        end
      end
  """
  @spec resolved_macro_call(Macro.t()) ::
          {module_key() | nil, atom(), [Macro.t()], (atom(), [Macro.t()] -> Macro.t())} | nil
  def resolved_macro_call({head, meta, args}) when is_list(meta) and is_list(args) do
    # Stay **total**: the identity stamp is only ever placed (by `Mutare.Transform.Resolve`) on a
    # remote `Mod.fun`/`:mod.fun` or a bare `fun` head, the two shapes `macro_rebuild/4` handles —
    # so a node carrying the stamp on any *other* head (e.g. a `recv.()` anonymous-call head) is an
    # impossible state Mutare never produces. Rather than commit to a partial `macro_rebuild` that
    # would raise on it, degrade to `nil` (the documented "not a recognised known-macro call"), so a
    # caller handing in an arbitrary node can never crash here.
    with {module, name} <- macro_identity(meta),
         rebuild when is_function(rebuild, 2) <- macro_rebuild(head, meta, module, args) do
      {module, name, args, rebuild}
    else
      _ -> nil
    end
  end

  def resolved_macro_call(_node), do: nil

  @doc """
  Returns the resolved treatment for each visible argument of a registered macro
  call, or `nil`.

  Treatments come from the fully merged macro-routing registry and include any
  shape-aware classification already performed for the call. The result may contain
  static treatments, `:hosted`, or nested keyword routing.

  For a piped call, the left side of the pipe is not included. A call that has no
  registered macro route returns `nil`.
  """
  @spec macro_treatment(Macro.t()) :: [Mutare.MacroRouting.routing_treatment()] | nil
  def macro_treatment({_head, meta, _args}) when is_list(meta) do
    case Meta.macro_routing(meta) do
      routing when is_list(routing) -> Enum.map(routing, &author_treatment/1)
      _ -> nil
    end
  end

  def macro_treatment(_node), do: nil

  # Map the resolved routing back to the author-facing treatment vocabulary
  # (`Mutare.MacroRouting.routing_treatment/0`): `Resolve` rewrites each `:hosted` to the
  # internal `{:hosted, host_module}` (stamping the delivering mutator) and recurses through
  # `{:keyword, …}`, so undo that here — a mutator reading `macro_treatment/1` sees the `:hosted`
  # word it wrote, not Mutare's stamp shape.
  defp author_treatment({:hosted, _host}), do: :hosted

  defp author_treatment({:keyword, treatments}),
    do: {:keyword, Enum.map(treatments, &author_treatment/1)}

  defp author_treatment(treatment), do: treatment

  # The resolved `{module_key, name}` identity from a node's own meta, or `nil` when absent —
  # i.e. when the node was never matched against the macro registry.
  defp macro_identity(meta) do
    case Meta.macro_call(meta) do
      {_module, _name} = identity -> identity
      _ -> nil
    end
  end

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
  #     `@macro_call_key` stamp, threaded in as `module`).
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
  # makes `resolved_macro_call/1` degrade to `nil` instead of raising a `FunctionClauseError`.
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
