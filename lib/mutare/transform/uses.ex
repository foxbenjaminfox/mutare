defmodule Mutare.Transform.Uses do
  @moduledoc false
  # The `use` *expansion* vocabulary — the third lexical-resolution pre-pass, alongside
  # `Aliases` and `Imports`. Idiomatic Phoenix/Ecto hides `import`/`alias` behind `use`:
  # `use MyAppWeb, :controller` injects a bundle of imports/aliases, and `use Ecto.Schema`
  # injects `import Ecto.Schema` (bringing the `schema`/`field` DSL macros as *bare* calls).
  # Those directives are invisible to `Resolve`, so the calls that depend on them don't
  # resolve — call families miss mutants, and a registered `:skip` DSL routing (keyed on the
  # *resolved* module) is dead, so core descends into the DSL body and poisons the build.
  #
  # This pass makes them visible. `annotate/1` walks the parsed (Sourceror) tree, finds each
  # **module-level** `use` with **static-literal** args, expands it in-process, harvests only
  # the `import`/`alias`/`require …, as:` directives it injects, and stamps them onto the
  # `use` node's meta under `:mutare_use_directives`. `Resolve.register/2` reads them back and
  # folds each into the alias/import env exactly as if written inline at the `use` — so the
  # whole existing resolution + reflection + macro-routing machinery works unchanged.
  #
  # ## Why in-process expansion is sound here (and where it degrades)
  #
  # In the primary deployment (the user adds `{:mutare, …}` as a dep of their app and runs
  # `mix mutare`) the task process has the app's deps (Ecto, Phoenix) on the BEAM code path,
  # so a `use Foo` is expandable in-process: `Code.ensure_loaded?(Foo)` is true and
  # `Foo.__using__/1` can be invoked. `Macro.expand/2` is **one level only** — it yields
  # `require Foo; Foo.__using__(opts)` and stops, because it won't expand a *remote* macro
  # call — so we expand the **inner** `Foo.__using__(opts)` call directly, with `Foo` added to
  # the env's `:requires`. The `__using__` body (a `quote` block) is returned *unexpanded*; we
  # harvest its top-level directives and recurse through nested `use`s (depth- and cycle-capped).
  #
  # Everything degrades to the old behaviour (no stamp) and **never raises** — wrapped in
  # `try`. A `use` is skipped when the module isn't loadable (an external-path target, where
  # the target's deps aren't on this process's path; or an aliased `use Web` we can't resolve
  # to a concrete module statically), when its args aren't static literals (`use Foo, runtime`),
  # or when `__using__` raises (e.g. it reads caller-module attributes — illegal outside an
  # open module). Imports gated behind a runtime `if`/`unless` inside a `__using__` body are
  # not harvested either (we don't evaluate injected conditionals). All are misses, never errors.
  #
  # ## Why directives are normalized to Sourceror form
  #
  # `Macro.expand` returns **standard** quoted AST, where a module is `{:__aliases__, …}` *or*
  # a bare atom (`import unquote(mod)` → `{:import, _, [Ecto.Schema]}`) — a shape `Imports.register`
  # doesn't accept. Each harvested directive is re-rendered through Sourceror
  # (`Sourceror.parse_string!(Macro.to_string(d))`), so it arrives indistinguishable from a
  # textual directive and `Aliases`/`Imports`/`Calls` need no new clauses. Live reflection then
  # resolves `field`/`schema` against the real module and the `:skip` routing fires.
  #
  # ## Why the `use` target is alias-resolved (and the caller env mirrored)
  #
  # `use Foo` may name an *aliased* module (`alias RealUse, as: Foo; use Foo`), in which case the
  # compiler expands `RealUse.__using__`, not `Foo.__using__`. So the walk folds a lexically-scoped
  # alias env (reusing `Aliases.register/2` + `resolve_path/2`, the very rules `Resolve` uses for
  # `import`) and resolves each `use` target through it before expanding — otherwise an unrelated
  # but loadable `Foo` would be expanded and its directives stamped as the wrong module.
  #
  # That same source alias env is also threaded into the expansion **`Macro.Env`** as its
  # `:aliases` (replacing this module's own compile-time aliases), so a `__using__` that consults
  # `__CALLER__.aliases` — picking an import/alias out of the caller's lexical bindings — expands
  # against the real caller env, not Mutare's. `alias Enum, as: U; use AliasAware` makes
  # `__CALLER__.aliases` report `U => Enum`, exactly what the compiler sees, so the fallback
  # directives we harvest are the ones that will actually be in scope when the metamutant compiles
  # — see `expand_using/4`. (Without this, the pre-pass harvested directives against the *wrong*
  # module and rewrote later bare calls accordingly.)

  alias Mutare.AST
  alias Mutare.Transform.Aliases
  alias Mutare.Transform.Uses.EnvMirror
  alias Mutare.Transform.Uses.Harvest

  @directives_key :mutare_use_directives
  @behaviours_key :mutare_use_behaviours

  # The module name of a nested `defmodule` we couldn't resolve to a concrete atom (a non-static
  # head, or a child of an already-unresolved parent). Expansion is *skipped* under it — see
  # `child_module/3` and `stamp/3`.
  @unresolved :__mutare_unresolved__

  @doc """
  Stamp each eligible module-level `use` node's meta with `:mutare_use_directives` — the
  Sourceror-form `import`/`alias`/`require …, as:` directives it injects (flattened across
  nested `use`s). A `use` that can't be expanded is left untouched.

  The whole walk runs with `Mix.env()` mirrored to the sandbox env (`:test`) by
  `Mutare.Transform.Uses.EnvMirror`, so an env-sensitive `__using__` is expanded under the env
  the metamutant will compile in, not the scan env.
  """
  @spec annotate(Macro.t()) :: Macro.t()
  def annotate(ast), do: EnvMirror.with_sandbox_env(fn -> walk_generic(ast, nil, %{}) end)

  @doc """
  The harvested directives stamped on a `use` node's meta, or `[]` for any other node. The
  reader half of the `:mutare_use_directives` contract, mirroring `Imports.resolved_import/1`.
  """
  @spec directives(keyword() | term()) :: [Macro.t()]
  def directives(meta) when is_list(meta), do: Keyword.get(meta, @directives_key, [])
  def directives(_meta), do: []

  @doc """
  The behaviour modules a `use` injects (`@behaviour Foo` in its `__using__` body), harvested
  alongside the directives and stamped under `:mutare_use_behaviours`, or `[]` for any other
  node. Read by `Mutare.Transform.Behaviours` to fold `use`-injected behaviours into a
  module's set.
  """
  @spec injected_behaviours(keyword() | term()) :: [module()]
  def injected_behaviours(meta) when is_list(meta), do: Keyword.get(meta, @behaviours_key, [])
  def injected_behaviours(_meta), do: []

  # --- the module-tracking walk ----------------------------------------------
  #
  # `Resolve` deliberately doesn't track the enclosing module, but expansion needs it (for a
  # faithful `__CALLER__.module`), so `Uses` runs its own small walk. It also threads a
  # lexically-scoped **alias env** (`Aliases.register/2`, folded left-to-right over a module body
  # so a `use` sees only the aliases declared *before* it; nested scopes inherit, a child's
  # additions don't leak) so an aliased `use` target resolves to the real module. The env mirrors
  # **both** explicit aliases *and the implicit alias Elixir auto-introduces for a nested module a
  # body defines* (`register_defined_module/3`): inside `Outer`, `defprotocol P` aliases `P =>
  # Outer.P`, so a later `defimpl P, for: Integer` computes the caller `Outer.P.Integer` (not
  # `P.Integer`) and a `defmodule U …; use U` resolves `U => Outer.U` and stamps. Only a `use`
  # that is a **direct module-body statement** is stamped — a `use` nested in a `def` is data /
  # invalid, never a module-level directive, so it is descended without stamping.

  # `walk_generic/3` is the structural descent for any node *except* a module-body statement
  # sequence: it routes each `defmodule`/`defprotocol`/`defimpl` body to `walk_module_body/3`
  # (which stamps the `use`s), folds the lexical alias env over a plain block, and otherwise
  # just recurses. It never stamps a `use` itself — one it reaches is nested data, not a
  # module-level directive.
  defp walk_generic({:defmodule, meta, [mod_ast, [{do_key, body}]]} = node, module, env) do
    child = child_module(mod_ast, module, env)

    {:defmodule, meta,
     [mod_ast, [{do_key, walk_module_body(body, child, body_env(node, module, env))}]]}
  end

  # `defprotocol P do … end` defines module `P` — a module scope (a direct `use` inside it, though
  # rare, is a real directive), named exactly like a `defmodule`.
  defp walk_generic({:defprotocol, meta, [mod_ast, [{do_key, body}]]} = node, module, env) do
    child = child_module(mod_ast, module, env)

    {:defprotocol, meta,
     [mod_ast, [{do_key, walk_module_body(body, child, body_env(node, module, env))}]]}
  end

  # `defimpl P, for: T do … end` opens a module scope named `P.T` (**absolute** — never
  # parent-prefixed, regardless of nesting), where a direct `use` is expanded before the
  # implementation functions. Both `P` and `T` are resolved through the alias env; only a single,
  # statically-resolvable impl module is entered as a stamping scope (`impl_module/3` yields
  # `@unresolved` for a list `for:` or a non-static type, which conservatively skips the stamp).
  defp walk_generic({:defimpl, meta, [proto, opts, [{do_key, body}]]}, _module, env)
       when is_list(opts) do
    impl = impl_module(proto, for_type(opts), env)
    {:defimpl, meta, [proto, opts, [{do_key, walk_module_body(body, impl, env)}]]}
  end

  # `defimpl P do … end` — the `for:` is inferred from context we don't track, so the impl module
  # is unknown; descend without stamping (the conservative choice — a wrong caller is worse).
  defp walk_generic({:defimpl, meta, [proto, [{do_key, body}]]}, _module, env) do
    {:defimpl, meta, [proto, [{do_key, walk_module_body(body, @unresolved, env)}]]}
  end

  # A `quote` block is quoted *data*: a `defmodule … do use Foo end` inside it is only realised
  # if/when the quote is later expanded in some caller's context — it is not a module-level
  # directive of *this* program. Descending would invoke `Foo.__using__` during the scan in the
  # wrong caller context (and could harvest invalid directives), so we stop at quoted contexts.
  defp walk_generic({:quote, _meta, _args} = node, _module, _env), do: node

  # A non-module-body block — the **file top level** (a multi-form file parses as a `:__block__`)
  # or a function body. A `use` here is never a module-level directive (descended, not stamped),
  # but an `alias` *does* scope to following siblings — including a sibling `defmodule`'s `use`
  # targets (`alias RealUsing, as: U` then `defmodule M do use U end`, which the compiler expands
  # as `RealUsing.__using__`). So the lexical alias env is folded left-to-right here too (source
  # aliases *and* the implicit alias a `defmodule`/`defprotocol` introduces). (A module body is
  # reached via `walk_module_body/3`, which folds + stamps; this clause never sees one.)
  defp walk_generic({:__block__, meta, stmts}, module, env) do
    {walked, _env} =
      Enum.map_reduce(stmts, env, fn stmt, env ->
        {walk_generic(stmt, module, env), register_lexical(stmt, module, env)}
      end)

    {:__block__, meta, walked}
  end

  defp walk_generic({form, meta, args}, module, env) when is_list(args),
    do: {form, meta, Enum.map(args, &walk_generic(&1, module, env))}

  defp walk_generic({left, right}, module, env),
    do: {walk_generic(left, module, env), walk_generic(right, module, env)}

  defp walk_generic(list, module, env) when is_list(list),
    do: Enum.map(list, &walk_generic(&1, module, env))

  defp walk_generic(other, _module, _env), do: other

  # A **module body** statement sequence (the only place a `use` is a directive): its direct
  # statements are module-level, so the alias env is folded left-to-right (a `use` resolves
  # against the aliases declared above it) and each `use` is stamped (`walk_stmt/3`); everything
  # else is descended via `walk_generic/3` (to reach nested `defmodule`s).
  defp walk_module_body({:__block__, meta, stmts}, module, env) do
    {walked, _env} =
      Enum.map_reduce(stmts, env, fn stmt, env ->
        node = walk_stmt(stmt, module, env)
        {node, advance_env(stmt, node, module, env)}
      end)

    {:__block__, meta, walked}
  end

  defp walk_module_body(stmt, module, env), do: walk_stmt(stmt, module, env)

  defp walk_stmt({:use, _meta, _args} = node, module, env), do: stamp(node, module, env)
  defp walk_stmt(stmt, module, env), do: walk_generic(stmt, module, env)

  # Advance the alias env past a statement: fold the lexical aliases it introduces (source
  # `alias`/`require …, as:` plus the implicit alias a nested `defmodule`/`defprotocol` defines),
  # then any aliases an earlier `use` *injected* (read back off the stamped node). Elixir expands a
  # later `use`/call through an alias an earlier `use` brought into scope (`use InjectAlias; use
  # T`), so without this the later `use` would resolve its target against the wrong (un-injected)
  # env and stay unstamped.
  defp advance_env(stmt, node, module, env) do
    env = register_lexical(stmt, module, env)
    node |> injected_directives() |> Enum.reduce(env, &Aliases.register/2)
  end

  defp injected_directives({:use, meta, _args}) when is_list(meta), do: directives(meta)
  defp injected_directives(_node), do: []

  # Fold the lexical alias(es) a *source* statement introduces into the env: an explicit
  # `alias`/`require …, as:`, **plus the implicit alias Elixir auto-introduces for a nested module
  # it defines** (`register_defined_module/3`). Both scope to following siblings, so the unified
  # fold keeps the env faithful for a later `use`/`defimpl` that refers to a sibling by short name.
  defp register_lexical(stmt, module, env) do
    # `Aliases.register/2` folds the alias a source statement introduces — a plain `alias`, or a
    # `require Mod, as: Name` (the compiler treats it as an alias); a bare `require Mod` passes
    # through. Then add the implicit alias a nested-module definition introduces.
    stmt |> Aliases.register(env) |> then(&register_defined_module(stmt, module, &1))
  end

  # The env a nested module's **own body** is walked under: the parent env *plus the implicit alias
  # the module head introduces*, which the compiler makes available inside the body itself. In
  # `defmodule Outer do defmodule Foo.Bar do use Foo.Baz end end`, `Foo => Outer.Foo` is in scope
  # *inside* `Foo.Bar`, so `use Foo.Baz` resolves to `Outer.Foo.Baz` and an alias-sensitive
  # `__using__` sees it via `__CALLER__.aliases`. (`register_lexical/3` folds the same alias for the
  # module's *following siblings*; this is the in-body half — without it a body-local `use`/call by
  # the head's own short name resolves through an outer/top-level module or not at all.)
  defp body_env(defmodule_node, parent, env),
    do: register_defined_module(defmodule_node, parent, env)

  # Mirror the alias Elixir auto-introduces when a module body **defines** a nested module:
  # `defmodule Outer do defprotocol P …; defimpl P, for: Integer … end` aliases `P => Outer.P`, so
  # the `defimpl`'s caller is `Outer.P.Integer` (not `P.Integer`); `defmodule U …; use U` aliases
  # `U => Outer.U`, so the `use` target resolves and is stamped. The alias binds the **first**
  # written segment to the parent-prefixed first segment (`defmodule Foo.Bar` ⇒ `Foo => Outer.Foo`,
  # *not* `Bar => Outer.Foo.Bar` — verified against the compiler), so it is computed as the
  # `child_module/3` of just that first segment. Stored as a path (the form `Aliases.register/2`
  # uses) so `resolve_path/2` can extend it (`P.Sub` ⇒ `Outer.P.Sub`). Skipped for a dynamic head
  # (`@unresolved`), an absolute `Elixir.`-led head, and an atom-named module (no segment to alias).
  # Only `defmodule`/`defprotocol` define such an alias — `defimpl` defines `P.T` but introduces no
  # convenient short name, so it is not a definer here.
  defp register_defined_module({def_form, _meta, [mod_ast | _]}, module, env)
       when def_form in [:defmodule, :defprotocol] do
    with {:__aliases__, _, [first | _]} when is_atom(first) and first != :"Elixir" <- mod_ast,
         full when full != @unresolved <- child_module({:__aliases__, [], [first]}, module, env),
         path when is_list(path) <- module_path(full) do
      Map.put(env, first, path)
    else
      _ -> env
    end
  end

  defp register_defined_module(_stmt, _module, env), do: env

  # A concrete Elixir module atom → its segment-atom path (`Outer.P` → `[:Outer, :P]`), the value
  # form the alias env stores for an Elixir module. `nil` for an Erlang atom module (`:foo`, from
  # `defmodule :foo`) — an atom has no last segment, so Elixir aliases nothing.
  defp module_path(mod) when is_atom(mod) do
    case Atom.to_string(mod) do
      "Elixir." <> _ -> mod |> Module.split() |> Enum.map(&String.to_atom/1)
      _ -> nil
    end
  end

  # The full module name of a nested `defmodule`, best-effort: Elixir prepends the enclosing
  # module to a nested alias. A non-static head (`__MODULE__.Child`, `unquote(mod)`, a
  # `Module.concat(…)` call) can't be resolved to a concrete module, so it yields `@unresolved`
  # and expansion is **skipped** inside that module (see `stamp/3`) rather than run with the wrong
  # `__CALLER__.module` — a `__using__` that derives imports/aliases from `__CALLER__.module`
  # would otherwise stamp directives for the *parent's* namespace. The sentinel propagates inward
  # (an unresolved parent ⇒ unresolved child). A leading `Elixir` segment (`defmodule Elixir.Bar`)
  # is the **absolute** escape — it defines `Bar`, never `Parent.Elixir.Bar` — so it is not
  # prefixed. A bare-atom head (`defmodule :foo`) is itself a concrete module — atoms aren't
  # namespaced — so it resolves to that atom (Sourceror wraps the literal as `{:__block__, _,
  # [:foo]}`).
  #
  # A **top-level** (no-parent) head is resolved through the alias env — `alias RealParent, as: RP;
  # defmodule RP.Child` defines `RealParent.Child`, so `__CALLER__.module` must be that. A **nested**
  # head is *not* alias-resolved: Elixir prepends the parent to the *literal* segments (`defmodule
  # RP.Child` inside `Outer` is `Outer.RP.Child`, the alias untouched), which the literal-path
  # `Module.concat([parent | path])` already matches.
  defp child_module({:__aliases__, _, path}, parent, env) when is_list(path) do
    cond do
      not Aliases.atoms?(path) -> @unresolved
      match?([:"Elixir" | _], path) -> Module.concat(path)
      parent == @unresolved -> @unresolved
      parent == nil -> path |> Aliases.resolve_path(env) |> Aliases.to_module()
      true -> Module.concat([parent | path])
    end
  end

  defp child_module({:__block__, _, [atom]}, _parent, _env) when is_atom(atom), do: atom
  defp child_module(atom, _parent, _env) when is_atom(atom), do: atom
  defp child_module(_mod_ast, _parent, _env), do: @unresolved

  # The implementation module of a `defimpl P, for: T`: `Module.concat(P, T)` (absolute), both
  # resolved through the alias env. `@unresolved` (⇒ no stamping) unless both are statically a
  # single concrete module — a list `for:`, a missing `for:`, or a non-static type degrades.
  defp impl_module(proto, type, env) do
    proto_mod = Aliases.resolve_node(proto, env)
    type_mod = type && Aliases.resolve_node(type, env)

    if module?(proto_mod) and module?(type_mod),
      do: Module.concat(proto_mod, type_mod),
      else: @unresolved
  end

  # The `for:` value of a `defimpl` opts list, or `nil`.
  defp for_type(opts) do
    Enum.find_value(opts, fn
      {key, value} -> if AST.key_atom(key) == :for, do: value
      _ -> nil
    end)
  end

  # `Aliases.resolve_node/2` returns a concrete module atom or `nil` (non-static), so a real
  # module is exactly a non-`nil` result.
  defp module?(m), do: not is_nil(m)

  # --- stamping the harvest onto the `use` node's meta -----------------------
  #
  # The in-process expansion that *produces* the harvest lives in `Mutare.Transform.Uses.Harvest`;
  # here we only run it (`Harvest.run/3`) and write its `{directives, behaviours}` result onto the
  # node's meta under the keys the public readers (`directives/1`, `injected_behaviours/1`) read.

  # Stamp the `use` node with its harvested directives, or return it unchanged. Never raises:
  # any expansion failure degrades to `[]` (the current, unresolved behaviour). A `use` inside a
  # module whose name we couldn't resolve is left unexpanded — expanding it would run `__using__`
  # with the wrong (parent) caller module.
  defp stamp(node, @unresolved, _env), do: node

  defp stamp({:use, meta, args} = node, module, env) do
    {directives, behaviours} = Harvest.run(node, module, env)

    meta =
      meta
      |> put_harvest(@directives_key, directives)
      |> put_harvest(@behaviours_key, behaviours)

    {:use, meta, args}
  end

  defp put_harvest(meta, _key, []), do: meta
  defp put_harvest(meta, key, values), do: [{key, values} | meta]
end
