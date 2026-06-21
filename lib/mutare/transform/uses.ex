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
  # ## Why the `use` target is alias-resolved
  #
  # `use Foo` may name an *aliased* module (`alias RealUse, as: Foo; use Foo`), in which case the
  # compiler expands `RealUse.__using__`, not `Foo.__using__`. So the walk folds a lexically-scoped
  # alias env (reusing `Aliases.register/2` + `resolve_path/2`, the very rules `Resolve` uses for
  # `import`) and resolves each `use` target through it before expanding — otherwise an unrelated
  # but loadable `Foo` would be expanded and its directives stamped as the wrong module.

  alias Mutare.AST
  alias Mutare.Transform.Aliases

  @directives_key :mutare_use_directives
  @max_depth 16

  # The env the metamutant is compiled and tested under — mirror it during `__using__` expansion.
  # Kept in sync with `Mutare.Sandbox.Command`'s `{"MIX_ENV", "test"}`.
  @sandbox_env :test

  # The module name of a nested `defmodule` we couldn't resolve to a concrete atom (a non-static
  # head, or a child of an already-unresolved parent). Expansion is *skipped* under it — see
  # `child_module/3` and `stamp/3`.
  @unresolved :__mutare_unresolved__

  @doc """
  Stamp each eligible module-level `use` node's meta with `:mutare_use_directives` — the
  Sourceror-form `import`/`alias`/`require …, as:` directives it injects (flattened across
  nested `use`s). A `use` that can't be expanded is left untouched.
  """
  @spec annotate(Macro.t()) :: Macro.t()
  def annotate(ast), do: with_sandbox_env(fn -> walk(ast, nil, %{}) end)

  # The metamutant is compiled and run under `MIX_ENV=test` (`Mutare.Sandbox.Command`), but the
  # scan/transform usually runs in the task's `:dev` env. So we mirror the sandbox env while
  # expanding `__using__`: a macro that branches on `Mix.env()` then injects the directives that
  # will actually be in scope when the metamutant compiles, not the scan-env ones. (Compile-time
  # config baked into the already-loaded modules can't be re-mirrored in-process — only a runtime
  # `Mix.env()` read is.) The scan is sequential, so the global set/restore can't race; Mix is
  # always loaded here — every entry point (the Mix task, the test suite) runs under it.
  defp with_sandbox_env(fun) do
    previous = Mix.env()
    Mix.env(@sandbox_env)

    try do
      fun.()
    after
      Mix.env(previous)
    end
  end

  @doc """
  The harvested directives stamped on a `use` node's meta, or `[]` for any other node. The
  reader half of the `:mutare_use_directives` contract, mirroring `Imports.resolved_import/1`.
  """
  @spec directives(keyword() | term()) :: [Macro.t()]
  def directives(meta) when is_list(meta), do: Keyword.get(meta, @directives_key, [])
  def directives(_meta), do: []

  # --- the module-tracking walk ----------------------------------------------
  #
  # `Resolve` deliberately doesn't track the enclosing module, but expansion needs it (for a
  # faithful `__CALLER__.module`), so `Uses` runs its own small walk. It also threads a
  # lexically-scoped **alias env** (`Aliases.register/2`, folded left-to-right over a module body
  # so a `use` sees only the aliases declared *before* it; nested scopes inherit, a child's
  # additions don't leak) so an aliased `use` target resolves to the real module. Only a `use`
  # that is a **direct module-body statement** is stamped — a `use` nested in a `def` is data /
  # invalid, never a module-level directive, so it is descended without stamping.

  defp walk({:defmodule, meta, [mod_ast, [{do_key, body}]]}, module, env) do
    child = child_module(mod_ast, module, env)
    {:defmodule, meta, [mod_ast, [{do_key, walk_body(body, child, env)}]]}
  end

  # `defprotocol P do … end` defines module `P` — a module scope (a direct `use` inside it, though
  # rare, is a real directive), named exactly like a `defmodule`.
  defp walk({:defprotocol, meta, [mod_ast, [{do_key, body}]]}, module, env) do
    child = child_module(mod_ast, module, env)
    {:defprotocol, meta, [mod_ast, [{do_key, walk_body(body, child, env)}]]}
  end

  # `defimpl P, for: T do … end` opens a module scope named `P.T` (**absolute** — never
  # parent-prefixed, regardless of nesting), where a direct `use` is expanded before the
  # implementation functions. Both `P` and `T` are resolved through the alias env; only a single,
  # statically-resolvable impl module is entered as a stamping scope (`impl_module/3` yields
  # `@unresolved` for a list `for:` or a non-static type, which conservatively skips the stamp).
  defp walk({:defimpl, meta, [proto, opts, [{do_key, body}]]}, _module, env) when is_list(opts) do
    impl = impl_module(proto, for_type(opts), env)
    {:defimpl, meta, [proto, opts, [{do_key, walk_body(body, impl, env)}]]}
  end

  # `defimpl P do … end` — the `for:` is inferred from context we don't track, so the impl module
  # is unknown; descend without stamping (the conservative choice — a wrong caller is worse).
  defp walk({:defimpl, meta, [proto, [{do_key, body}]]}, _module, env) do
    {:defimpl, meta, [proto, [{do_key, walk_body(body, @unresolved, env)}]]}
  end

  # A `quote` block is quoted *data*: a `defmodule … do use Foo end` inside it is only realised
  # if/when the quote is later expanded in some caller's context — it is not a module-level
  # directive of *this* program. Descending would invoke `Foo.__using__` during the scan in the
  # wrong caller context (and could harvest invalid directives), so we stop at quoted contexts.
  defp walk({:quote, _meta, _args} = node, _module, _env), do: node

  # A non-module-body block — the **file top level** (a multi-form file parses as a `:__block__`)
  # or a function body. A `use` here is never a module-level directive (descended, not stamped),
  # but an `alias` *does* scope to following siblings — including a sibling `defmodule`'s `use`
  # targets (`alias RealUsing, as: U` then `defmodule M do use U end`, which the compiler expands
  # as `RealUsing.__using__`). So the alias env is folded left-to-right here too. (A module body
  # is reached via `walk_body`, which folds + stamps; this clause never sees one.)
  defp walk({:__block__, meta, stmts}, module, env) do
    {walked, _env} =
      Enum.map_reduce(stmts, env, fn stmt, env ->
        {walk(stmt, module, env), Aliases.register(stmt, env)}
      end)

    {:__block__, meta, walked}
  end

  defp walk({form, meta, args}, module, env) when is_list(args),
    do: {form, meta, Enum.map(args, &walk(&1, module, env))}

  defp walk({left, right}, module, env), do: {walk(left, module, env), walk(right, module, env)}
  defp walk(list, module, env) when is_list(list), do: Enum.map(list, &walk(&1, module, env))
  defp walk(other, _module, _env), do: other

  # A module body: its direct statements are module-level. The alias env is folded left-to-right
  # (so a `use` resolves against the aliases declared above it). A `use` is stamped; everything
  # else is descended via `walk/3` (to reach nested `defmodule`s).
  defp walk_body({:__block__, meta, stmts}, module, env) do
    {walked, _env} =
      Enum.map_reduce(stmts, env, fn stmt, env ->
        node = walk_stmt(stmt, module, env)
        {node, advance_env(stmt, node, env)}
      end)

    {:__block__, meta, walked}
  end

  defp walk_body(stmt, module, env), do: walk_stmt(stmt, module, env)

  defp walk_stmt({:use, _meta, _args} = node, module, env), do: stamp(node, module, env)
  defp walk_stmt(stmt, module, env), do: walk(stmt, module, env)

  # Advance the alias env past a statement: fold the source `alias`, then any aliases an earlier
  # `use` *injected* (read back off the stamped node). Elixir expands a later `use`/call through
  # an alias an earlier `use` brought into scope (`use InjectAlias; use T`), so without this the
  # later `use` would resolve its target against the wrong (un-injected) env and stay unstamped.
  defp advance_env(stmt, node, env) do
    env = Aliases.register(stmt, env)
    node |> injected_directives() |> Enum.reduce(env, &Aliases.register/2)
  end

  defp injected_directives({:use, meta, _args}) when is_list(meta), do: directives(meta)
  defp injected_directives(_node), do: []

  # The full module name of a nested `defmodule`, best-effort: Elixir prepends the enclosing
  # module to a nested alias. A non-static head (`__MODULE__.Child`, `unquote(mod)`, a
  # `Module.concat(…)` call) can't be resolved to a concrete module, so it yields `@unresolved`
  # and expansion is **skipped** inside that module (see `stamp/3`) rather than run with the wrong
  # `__CALLER__.module` — a `__using__` that derives imports/aliases from `__CALLER__.module`
  # would otherwise stamp directives for the *parent's* namespace. The sentinel propagates inward
  # (an unresolved parent ⇒ unresolved child). A leading `Elixir` segment (`defmodule Elixir.Bar`)
  # is the **absolute** escape — it defines `Bar`, never `Parent.Elixir.Bar` — so it is not
  # prefixed. A bare-atom head (`defmodule :foo`) is itself a concrete module — atoms aren't
  # namespaced — so it resolves to that atom.
  #
  # A **top-level** (no-parent) head is resolved through the alias env — `alias RealParent, as: RP;
  # defmodule RP.Child` defines `RealParent.Child`, so `__CALLER__.module` must be that. A **nested**
  # head is *not* alias-resolved: Elixir prepends the parent to the *literal* segments (`defmodule
  # RP.Child` inside `Outer` is `Outer.RP.Child`, the alias untouched), which the literal-path
  # `Module.concat([parent | path])` already matches.
  defp child_module({:__aliases__, _, path}, parent, env) when is_list(path) do
    cond do
      not Enum.all?(path, &is_atom/1) -> @unresolved
      match?([:"Elixir" | _], path) -> Module.concat(path)
      parent == @unresolved -> @unresolved
      parent == nil -> path |> Aliases.resolve_path(env) |> to_module()
      true -> Module.concat([parent | path])
    end
  end

  defp child_module(mod, _parent, _env) when is_atom(mod), do: mod
  defp child_module(_mod_ast, _parent, _env), do: @unresolved

  # The implementation module of a `defimpl P, for: T`: `Module.concat(P, T)` (absolute), both
  # resolved through the alias env. `@unresolved` (⇒ no stamping) unless both are statically a
  # single concrete module — a list `for:`, a missing `for:`, or a non-static type degrades.
  defp impl_module(proto, type, env) do
    proto_mod = module_atom(proto, env)
    type_mod = type && module_atom(type, env)

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

  # `module_atom/2` returns a concrete module atom or `nil` (non-static), so a real module is
  # exactly a non-`nil` result.
  defp module?(m), do: not is_nil(m)

  # --- expansion + harvest ---------------------------------------------------

  # Stamp the `use` node with its harvested directives, or return it unchanged. Never raises:
  # any expansion failure degrades to `[]` (the current, unresolved behaviour). A `use` inside a
  # module whose name we couldn't resolve is left unexpanded — expanding it would run `__using__`
  # with the wrong (parent) caller module.
  defp stamp(node, @unresolved, _env), do: node

  defp stamp({:use, meta, args} = node, module, env) do
    case harvest(node, module, env) do
      [] -> node
      directives -> {:use, [{@directives_key, directives} | meta], args}
    end
  end

  defp harvest(sourceror_use_node, caller_module, env) do
    with {:ok, mod, opts} <- standardize(sourceror_use_node, env),
         true <- Code.ensure_loaded?(mod) do
      mod
      |> expand_and_collect(opts, caller_module, 0, MapSet.new())
      |> Enum.map(&normalize/1)
      |> Enum.reject(&is_nil/1)
    else
      _ -> []
    end
  rescue
    _ -> []
  catch
    _, _ -> []
  end

  # Sourceror `use` node → `{:ok, module_atom, opts_literal}` (standard quoted), or `:error`.
  # The Sourceror→standard round-trip strips block-wrapping so `__using__` receives the real
  # term (`:controller`, not `{:__block__, [], [:controller]}`); it is also where the static
  # gate runs, since `Macro.quoted_literal?` is false on Sourceror block-wrapping. The module is
  # resolved through `env` so an aliased target (`alias RealUse, as: Foo; use Foo`) expands the
  # real module.
  defp standardize(sourceror_use_node, env) do
    {:use, _, args} = Code.string_to_quoted!(Sourceror.to_string(sourceror_use_node))
    use_args(args, env)
  end

  # `[module | rest]` (standard quoted) → `{:ok, module_atom, opts}` with the literal gate, or
  # `:error`. A `use` takes a module and at most one opts argument.
  defp use_args([mod_ast | rest], env) do
    with mod when is_atom(mod) <- module_atom(mod_ast, env),
         {:ok, opts} <- use_opts(rest) do
      {:ok, mod, opts}
    else
      _ -> :error
    end
  end

  defp use_args(_args, _env), do: :error

  defp use_opts([]), do: {:ok, []}
  defp use_opts([opts]), do: if(Macro.quoted_literal?(opts), do: {:ok, opts}, else: :error)
  defp use_opts(_rest), do: :error

  # A standard-quoted module reference → its concrete atom, or `nil`. The path is resolved through
  # the lexical alias env first (`Aliases.resolve_path/2`), so an aliased target binds to the real
  # module (a list path → `Module.concat`; an Erlang-atom binding stays the atom). An `__aliases__`
  # with a non-static segment (an aliased `use Web` we can't resolve) yields `nil` → degrade.
  defp module_atom({:__aliases__, _, path}, env) when is_list(path) do
    if Enum.all?(path, &is_atom/1),
      do: path |> Aliases.resolve_path(env) |> to_module(),
      else: nil
  end

  defp module_atom(atom, _env) when is_atom(atom), do: atom
  defp module_atom(_other, _env), do: nil

  defp to_module(path) when is_list(path), do: Module.concat(path)
  defp to_module(atom) when is_atom(atom), do: atom

  # Expand `mod.__using__(opts)` and collect the directives in its body, recursing through
  # nested `use`s. Bounded by depth and a `seen` set so a `use`-cycle terminates. `seen` keys on
  # the `{module, options}` pair, not the module alone: a `__using__` that re-dispatches to the
  # *same* module with different static options (`use Foo, :a` → `use Foo, :b`) is a real
  # option-specific clause Elixir would expand, not a cycle — only an exact `{mod, opts}` repeat
  # is (and the depth cap backstops a non-repeating chain).
  defp expand_and_collect(mod, opts, caller, depth, seen) do
    key = {mod, opts}

    cond do
      depth > @max_depth ->
        []

      MapSet.member?(seen, key) ->
        []

      # A fresh alias scope (`%{}`) for this `__using__` body — its directives are folded as the
      # block is descended, so an in-body `alias … as: T` resolves a sibling `use T`.
      true ->
        collect(expand_using(mod, opts, caller), caller, depth + 1, MapSet.put(seen, key), %{})
    end
  end

  # `Macro.expand/2` won't expand a remote macro call, so we expand the inner
  # `mod.__using__(opts)` directly with `mod` required. The env's `:module` is the using
  # module so `__CALLER__.module` reads faithfully. **`expand_once`, not `expand`** — `expand`
  # would keep going, and a nested `use Bar` in the body (itself a macro) would over-expand to
  # `require Bar; Bar.__using__(...)`; one step leaves the nested `use` intact for `collect/5`
  # to re-expand.
  defp expand_using(mod, opts, caller) do
    env = %{__ENV__ | module: caller, requires: Enum.uniq([mod | __ENV__.requires])}
    Macro.expand_once({{:., [], [mod, :__using__]}, [], [opts]}, env)
  end

  # Gather `import`/`alias`/`require …, as:` from a `__using__` body, descending only blocks
  # and re-expanding nested `use`s — never `def`/`quote`/`if` bodies (those degrade). An alias
  # env (`env`) is folded left-to-right over a block so an in-body `alias … as: T` resolves a
  # sibling `use T` (the way the compiler expands it).
  defp collect({:__block__, _, stmts}, caller, depth, seen, env) when is_list(stmts) do
    {collected, _env} =
      Enum.flat_map_reduce(stmts, env, fn stmt, env ->
        harvested = collect(stmt, caller, depth, seen, env)

        # Advance the env with the directives this statement *yields*, not its literal text — so a
        # nested `use` (or `require …, as:`) that injects an alias resolves a later sibling `use`
        # (`use AliasInjector; use T`), exactly as Elixir expands it. (A direct `alias` yields
        # itself, so its binding is captured too; an `import` yields a no-op for the alias env.)
        {harvested, Enum.reduce(harvested, env, &Aliases.register/2)}
      end)

    collected
  end

  defp collect({directive, _, _} = node, _caller, _depth, _seen, _env)
       when directive in [:import, :alias],
       do: [node]

  # `require Foo, as: Bar` introduces an alias; rewrite to the equivalent `alias` so
  # `Aliases.register` (which doesn't read `require`) picks it up. A plain `require` doesn't
  # affect name resolution and is dropped.
  defp collect({:require, _, [mod_ast, opts]}, _caller, _depth, _seen, _env) when is_list(opts) do
    case as_value(opts) do
      nil -> []
      as -> [{:alias, [], [mod_ast, [as: as]]}]
    end
  end

  # A nested `use` harvested from an *expanded* `__using__` body: standard-quoted, resolved through
  # the body's own alias scope (`env`) so an earlier sibling `alias … as: T` redirects `use T`.
  defp collect({:use, _, args}, caller, depth, seen, env) do
    case use_args(args, env) do
      {:ok, mod, opts} ->
        if Code.ensure_loaded?(mod),
          do: expand_and_collect(mod, opts, caller, depth, seen),
          else: []

      :error ->
        []
    end
  end

  defp collect(_other, _caller, _depth, _seen, _env), do: []

  defp as_value(opts), do: Keyword.get(opts, :as)

  # Re-render one harvested (standard-quoted) directive into Sourceror form, so it is
  # indistinguishable from a textual directive when folded through `Resolve.register/2`. A
  # directive that can't round-trip is dropped (nil), not fatal.
  defp normalize(directive) do
    directive |> Macro.to_string() |> Sourceror.parse_string!()
  rescue
    _ -> nil
  end
end
