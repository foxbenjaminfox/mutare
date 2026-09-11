defmodule Mutare.Transform.Uses do
  @moduledoc false
  # The `use` *expansion* vocabulary — the third lexical-resolution pre-pass, alongside
  # `Aliases` and `Imports`. Idiomatic Phoenix/Ecto hides `import`/`alias` behind `use`:
  # `use MyAppWeb, :controller` injects a bundle of imports/aliases, and `use Ecto.Schema`
  # injects `import Ecto.Schema` (bringing the `schema`/`field` DSL macros as *bare* calls).
  # Those directives are invisible to `Resolve`, so the calls that depend on them don't
  # resolve — call families miss mutants, and a registered `:raw` DSL routing (keyed on the
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
  # resolves `field`/`schema` against the real module and the `:raw` routing fires.
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

  alias Mutare.Extension
  alias Mutare.Transform.Aliases
  alias Mutare.Transform.MetaKeys
  alias Mutare.Transform.ModuleScope
  alias Mutare.Transform.Uses.EnvMirror
  alias Mutare.Transform.Uses.Harvest
  alias Mutare.UseExpansion.Dispatch

  @directives_key MetaKeys.use_directives_key()
  @behaviours_key MetaKeys.use_behaviours_key()
  @degraded_key MetaKeys.use_degraded_key()

  # The module name of a nested `defmodule` we couldn't resolve to a concrete atom (a non-static
  # head, or a child of an already-unresolved parent). Expansion is *skipped* under it — see
  # `ModuleScope.child_module/3` and `stamp/4`. Sourced from `ModuleScope` (which owns the
  # implicit-alias vocabulary) so the sentinel Uses pattern-matches can't drift from it.
  @unresolved ModuleScope.unresolved()

  @doc """
  Stamp each eligible module-level `use` node's meta with `:mutare_use_directives` — the
  Sourceror-form `import`/`alias`/`require …, as:` directives it injects (flattened across
  nested `use`s). A `use` that can't be expanded is left untouched.

  `extensions` (the resolved `:extensions` specs, default none) may **override** a `use`'s
  expansion: an extension's `c:Mutare.UseExpansion.expand_use/3` is consulted before in-process
  expansion, so a `use` whose `__using__` cannot run in the scan process (Gettext registers
  its backend by mutating the caller and raises) still surfaces its directives. See `Harvest`.

  The whole walk runs with `Mix.env()` mirrored to the sandbox env (`:test`) by
  `Mutare.Transform.Uses.EnvMirror`, so an env-sensitive `__using__` is expanded under the env
  the metamutant will compile in, not the scan env.
  """
  @spec annotate(Macro.t(), [Extension.Spec.t() | module() | {module(), keyword()}]) :: Macro.t()
  def annotate(ast, extensions \\ []) do
    handlers = Dispatch.handlers(extensions)
    EnvMirror.with_sandbox_env(fn -> walk_generic(ast, nil, %{}, handlers) end)
  end

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
  # Expansion needs the enclosing module (for a faithful `__CALLER__.module`), so `Uses` threads it
  # as it walks. It also threads a lexically-scoped **alias env** (`Aliases.register/2`, folded
  # left-to-right over a module body so a `use` sees only the aliases declared *before* it; nested
  # scopes inherit, a child's additions don't leak) so an aliased `use` target resolves to the real
  # module. The env mirrors **both** explicit aliases *and the implicit alias Elixir auto-introduces
  # for a nested module a body defines* — the shared `ModuleScope` vocabulary
  # (`register_lexical/3` / `register_defined_module/3`), also used by `Resolve` and `Behaviours`:
  # inside `Outer`, `defprotocol P` aliases `P => Outer.P`, so a later `defimpl P, for: Integer`
  # computes the caller `Outer.P.Integer` (not `P.Integer`) and a `defmodule U …; use U` resolves
  # `U => Outer.U` and stamps. Only a `use` that is a **direct module-body statement** is stamped —
  # a `use` nested in a `def` is data / invalid, never a module-level directive, so it is descended
  # without stamping.

  # `walk_generic/4` is the structural descent for any node *except* a module-body statement
  # sequence: it routes each `defmodule`/`defprotocol`/`defimpl` body to `walk_module_body/4`
  # (which stamps the `use`s), folds the lexical alias env over a plain block, and otherwise
  # just recurses. It never stamps a `use` itself — one it reaches is nested data, not a
  # module-level directive.
  # `defmodule M`/`defprotocol P` both define a named module scope (`defprotocol P do … end`
  # defines module `P`, and a direct `use` inside it — though rare — is a real directive), so
  # they share one clause, named exactly alike.
  defp walk_generic({form, meta, [mod_ast, [{do_key, body}]]} = node, module, env, handlers)
       when form in [:defmodule, :defprotocol] do
    child = ModuleScope.child_module(mod_ast, module, env)
    body_env = ModuleScope.register_defined_module(node, module, env)

    {form, meta, [mod_ast, [{do_key, walk_module_body(body, child, body_env, handlers)}]]}
  end

  # `defimpl P, for: T do … end` opens a module scope named `P.T` (**absolute** — never
  # parent-prefixed, regardless of nesting), where a direct `use` is expanded before the
  # implementation functions. Both `P` and `T` are resolved through the alias env; only a single,
  # statically-resolvable impl module is entered as a stamping scope (`impl_module/3` yields
  # `@unresolved` for a list `for:` or a non-static type, which conservatively skips the stamp).
  defp walk_generic({:defimpl, meta, [proto, opts, [{do_key, body}]]}, _module, env, handlers)
       when is_list(opts) do
    impl = ModuleScope.impl_module(proto, ModuleScope.for_type(opts), env)
    {:defimpl, meta, [proto, opts, [{do_key, walk_module_body(body, impl, env, handlers)}]]}
  end

  # `defimpl P do … end` — the `for:` is inferred from context we don't track, so the impl module
  # is unknown; descend without stamping (the conservative choice — a wrong caller is worse).
  defp walk_generic({:defimpl, meta, [proto, [{do_key, body}]]}, _module, env, handlers) do
    {:defimpl, meta, [proto, [{do_key, walk_module_body(body, @unresolved, env, handlers)}]]}
  end

  # A `quote` block is quoted *data*: a `defmodule … do use Foo end` inside it is only realised
  # if/when the quote is later expanded in some caller's context — it is not a module-level
  # directive of *this* program. Descending would invoke `Foo.__using__` during the scan in the
  # wrong caller context (and could harvest invalid directives), so we stop at quoted contexts.
  defp walk_generic({:quote, _meta, _args} = node, _module, _env, _handlers), do: node

  # A non-module-body block — the **file top level** (a multi-form file parses as a `:__block__`)
  # or a function body. A `use` here is never a module-level directive (descended, not stamped),
  # but an `alias` *does* scope to following siblings — including a sibling `defmodule`'s `use`
  # targets (`alias RealUsing, as: U` then `defmodule M do use U end`, which the compiler expands
  # as `RealUsing.__using__`). So the lexical alias env is folded left-to-right here too (source
  # aliases *and* the implicit alias a `defmodule`/`defprotocol` introduces). (A module body is
  # reached via `walk_module_body/4`, which folds + stamps; this clause never sees one.)
  defp walk_generic({:__block__, meta, stmts}, module, env, handlers) do
    {walked, _env} =
      Enum.map_reduce(stmts, env, fn stmt, env ->
        {walk_generic(stmt, module, env, handlers),
         ModuleScope.register_lexical(stmt, module, env)}
      end)

    {:__block__, meta, walked}
  end

  defp walk_generic({form, meta, args}, module, env, handlers) when is_list(args),
    do: {form, meta, Enum.map(args, &walk_generic(&1, module, env, handlers))}

  defp walk_generic({left, right}, module, env, handlers),
    do: {walk_generic(left, module, env, handlers), walk_generic(right, module, env, handlers)}

  defp walk_generic(list, module, env, handlers) when is_list(list),
    do: Enum.map(list, &walk_generic(&1, module, env, handlers))

  defp walk_generic(other, _module, _env, _handlers), do: other

  # A **module body** statement sequence (the only place a `use` is a directive): its direct
  # statements are module-level, so the alias env is folded left-to-right (a `use` resolves
  # against the aliases declared above it) and each `use` is stamped (`walk_stmt/4`); everything
  # else is descended via `walk_generic/4` (to reach nested `defmodule`s).
  defp walk_module_body({:__block__, meta, stmts}, module, env, handlers) do
    {walked, _env} =
      Enum.map_reduce(stmts, env, fn stmt, env ->
        node = walk_stmt(stmt, module, env, handlers)
        {node, advance_env(stmt, node, module, env)}
      end)

    {:__block__, meta, walked}
  end

  defp walk_module_body(stmt, module, env, handlers), do: walk_stmt(stmt, module, env, handlers)

  defp walk_stmt({:use, _meta, _args} = node, module, env, handlers),
    do: stamp(node, module, env, handlers)

  defp walk_stmt(stmt, module, env, handlers), do: walk_generic(stmt, module, env, handlers)

  # Advance the alias env past a statement: fold the lexical aliases it introduces (source
  # `alias`/`require …, as:` plus the implicit alias a nested `defmodule`/`defprotocol` defines),
  # then any aliases an earlier `use` *injected* (read back off the stamped node). Elixir expands a
  # later `use`/call through an alias an earlier `use` brought into scope (`use InjectAlias; use
  # T`), so without this the later `use` would resolve its target against the wrong (un-injected)
  # env and stay unstamped.
  defp advance_env(stmt, node, module, env) do
    env = ModuleScope.register_lexical(stmt, module, env)
    node |> injected_directives() |> Enum.reduce(env, &Aliases.register/2)
  end

  defp injected_directives({:use, meta, _args}) when is_list(meta), do: directives(meta)
  defp injected_directives(_node), do: []

  # --- stamping the harvest onto the `use` node's meta -----------------------
  #
  # The in-process expansion that *produces* the harvest lives in `Mutare.Transform.Uses.Harvest`;
  # here we only run it (`Harvest.run/4`) and write its `{directives, behaviours}` result onto the
  # node's meta under the keys the public readers (`directives/1`, `injected_behaviours/1`) read.

  # Stamp the `use` node with its harvested directives, or return it unchanged. Never raises:
  # any expansion failure degrades to `[]` (the current, unresolved behaviour). A `use` inside a
  # module whose name we couldn't resolve is left unexpanded — expanding it would run `__using__`
  # with the wrong (parent) caller module. `handlers` are the extension `use`-expansion overrides
  # (`Mutare.UseExpansion.Dispatch.handlers/1`), consulted by `Harvest.run/4` before in-process expansion.
  defp stamp(node, @unresolved, _env, _handlers), do: node

  defp stamp({:use, meta, args} = node, module, env, handlers) do
    {directives, behaviours, degraded} = Harvest.run(node, module, env, handlers)

    meta =
      meta
      |> put_harvest(@directives_key, directives)
      |> put_harvest(@behaviours_key, behaviours)
      |> put_degraded(degraded)

    {:use, meta, args}
  end

  defp put_harvest(meta, _key, []), do: meta
  defp put_harvest(meta, key, values), do: [{key, values} | meta]

  # Stamp a degradation reason (`{module, reason}`) onto the `use` node, or leave the meta
  # untouched when the `use` expanded. Cheap and harmless in the hot path (the key is
  # stripped before render like every `:mutare_*` stamp); `degraded_uses/1` reads it back.
  defp put_degraded(meta, nil), do: meta
  defp put_degraded(meta, {_mod, _reason} = degraded), do: [{@degraded_key, degraded} | meta]

  @typedoc "A module-level `use` that failed to expand in-process, and why."
  @type degraded_use :: %{module: module(), line: pos_integer() | nil, reason: atom()}

  @doc """
  The module-level `use`s in `annotated` — a tree `annotate/2` has stamped — that failed to
  expand in-process, as `[%{module: module, line: line | nil, reason: reason}]` in source
  order.

  Reads back the `:mutare_use_degraded` stamps `annotate/2` left, so it costs one prewalk and
  re-expands nothing: `Mutare.Transform`'s count pass collects them from the tree it already
  annotated and reports them to `Mutare.Schema` (its `:degraded_uses`), which `mix mutare
  --check` prints to warn that a `:call_routes` `:raw` keyed on such a `use`'s injected macros
  would be dead. Only the two module-known, unambiguous failures surface — `:not_loadable` and
  `:nonstatic_args` (see `t:Mutare.Transform.Uses.Harvest.degradation/0`); a `use` that
  expanded to genuinely nothing is not reported.
  """
  @spec degraded_uses(Macro.t()) :: [degraded_use()]
  def degraded_uses(annotated) do
    annotated
    |> collect_degraded()
    |> Enum.reverse()
  end

  # Prewalk the annotated tree gathering every `:mutare_use_degraded` stamp into
  # `[%{module, line, reason}]` (reversed — `degraded_uses/1` flips it to source order).
  defp collect_degraded(annotated) do
    annotated
    |> Macro.prewalk([], fn
      {:use, meta, _args} = node, acc when is_list(meta) ->
        case Keyword.get(meta, @degraded_key) do
          {mod, reason} ->
            {node, [%{module: mod, line: line_of(meta), reason: reason} | acc]}

          nil ->
            {node, acc}
        end

      node, acc ->
        {node, acc}
    end)
    |> elem(1)
  end

  defp line_of(meta), do: Keyword.get(meta, :line)
end
