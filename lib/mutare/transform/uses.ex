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

  @directives_key :mutare_use_directives
  @max_depth 16

  # The module name of a nested `defmodule` we couldn't resolve to a concrete atom (a non-static
  # head, or a child of an already-unresolved parent). Expansion is *skipped* under it — see
  # `child_module/2` and `stamp/2`.
  @unresolved :__mutare_unresolved__

  @doc """
  Stamp each eligible module-level `use` node's meta with `:mutare_use_directives` — the
  Sourceror-form `import`/`alias`/`require …, as:` directives it injects (flattened across
  nested `use`s). A `use` that can't be expanded is left untouched.
  """
  @spec annotate(Macro.t()) :: Macro.t()
  def annotate(ast), do: walk(ast, nil)

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
  # faithful `__CALLER__.module`), so `Uses` runs its own small walk. Only a `use` that is a
  # **direct module-body statement** is stamped — a `use` nested in a `def` is data / invalid,
  # never a module-level directive, so it is descended without stamping.

  defp walk({:defmodule, meta, [mod_ast, [{do_key, body}]]}, module) do
    child = child_module(mod_ast, module)
    {:defmodule, meta, [mod_ast, [{do_key, walk_body(body, child)}]]}
  end

  # A `quote` block is quoted *data*: a `defmodule … do use Foo end` inside it is only realised
  # if/when the quote is later expanded in some caller's context — it is not a module-level
  # directive of *this* program. Descending would invoke `Foo.__using__` during the scan in the
  # wrong caller context (and could harvest invalid directives), so we stop at quoted contexts.
  defp walk({:quote, _meta, _args} = node, _module), do: node

  defp walk({form, meta, args}, module) when is_list(args),
    do: {form, meta, Enum.map(args, &walk(&1, module))}

  defp walk({left, right}, module), do: {walk(left, module), walk(right, module)}
  defp walk(list, module) when is_list(list), do: Enum.map(list, &walk(&1, module))
  defp walk(other, _module), do: other

  # A module body: its direct statements are module-level. A `use` here is stamped; everything
  # else is descended via `walk/2` (to reach nested `defmodule`s).
  defp walk_body({:__block__, meta, stmts}, module),
    do: {:__block__, meta, Enum.map(stmts, &walk_stmt(&1, module))}

  defp walk_body(stmt, module), do: walk_stmt(stmt, module)

  defp walk_stmt({:use, _meta, _args} = node, module), do: stamp(node, module)
  defp walk_stmt(stmt, module), do: walk(stmt, module)

  # The full module name of a nested `defmodule`, best-effort: Elixir prepends the enclosing
  # module to a nested alias. A non-static head (`__MODULE__.Child`, `unquote(mod)`, a
  # `Module.concat(…)` call) can't be resolved to a concrete module, so it yields `@unresolved`
  # and expansion is **skipped** inside that module (see `stamp/2`) rather than run with the wrong
  # `__CALLER__.module` — a `__using__` that derives imports/aliases from `__CALLER__.module`
  # would otherwise stamp directives for the *parent's* namespace. The sentinel propagates inward
  # (an unresolved parent ⇒ unresolved child). A bare-atom head (`defmodule :foo`) is itself a
  # concrete module — atoms aren't namespaced — so it resolves to that atom.
  defp child_module({:__aliases__, _, path}, parent) when is_list(path) do
    cond do
      not Enum.all?(path, &is_atom/1) -> @unresolved
      parent == @unresolved -> @unresolved
      parent == nil -> Module.concat(path)
      true -> Module.concat([parent | path])
    end
  end

  defp child_module(mod, _parent) when is_atom(mod), do: mod
  defp child_module(_mod_ast, _parent), do: @unresolved

  # --- expansion + harvest ---------------------------------------------------

  # Stamp the `use` node with its harvested directives, or return it unchanged. Never raises:
  # any expansion failure degrades to `[]` (the current, unresolved behaviour). A `use` inside a
  # module whose name we couldn't resolve is left unexpanded — expanding it would run `__using__`
  # with the wrong (parent) caller module.
  defp stamp(node, @unresolved), do: node

  defp stamp({:use, meta, args} = node, module) do
    case harvest(node, module) do
      [] -> node
      directives -> {:use, [{@directives_key, directives} | meta], args}
    end
  end

  defp harvest(sourceror_use_node, caller_module) do
    with {:ok, mod, opts} <- standardize(sourceror_use_node),
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
  # gate runs, since `Macro.quoted_literal?` is false on Sourceror block-wrapping.
  defp standardize(sourceror_use_node) do
    {:use, _, args} = Code.string_to_quoted!(Sourceror.to_string(sourceror_use_node))
    use_args(args)
  end

  # `[module | rest]` (standard quoted) → `{:ok, module_atom, opts}` with the literal gate, or
  # `:error`. A `use` takes a module and at most one opts argument.
  defp use_args([mod_ast | rest]) do
    with mod when is_atom(mod) <- module_atom(mod_ast),
         {:ok, opts} <- use_opts(rest) do
      {:ok, mod, opts}
    else
      _ -> :error
    end
  end

  defp use_args(_args), do: :error

  defp use_opts([]), do: {:ok, []}
  defp use_opts([opts]), do: if(Macro.quoted_literal?(opts), do: {:ok, opts}, else: :error)
  defp use_opts(_rest), do: :error

  # A standard-quoted module reference → its concrete atom, or `nil`. An `__aliases__` with a
  # non-static segment (an aliased `use Web` we can't resolve) yields `nil` → degrade.
  defp module_atom({:__aliases__, _, path}) when is_list(path),
    do: if(Enum.all?(path, &is_atom/1), do: Module.concat(path), else: nil)

  defp module_atom(atom) when is_atom(atom), do: atom
  defp module_atom(_other), do: nil

  # Expand `mod.__using__(opts)` and collect the directives in its body, recursing through
  # nested `use`s. Bounded by depth and a `seen` set so a `use`-cycle terminates.
  defp expand_and_collect(mod, opts, caller, depth, seen) do
    cond do
      depth > @max_depth -> []
      MapSet.member?(seen, mod) -> []
      true -> collect(expand_using(mod, opts, caller), caller, depth + 1, MapSet.put(seen, mod))
    end
  end

  # `Macro.expand/2` won't expand a remote macro call, so we expand the inner
  # `mod.__using__(opts)` directly with `mod` required. The env's `:module` is the using
  # module so `__CALLER__.module` reads faithfully. **`expand_once`, not `expand`** — `expand`
  # would keep going, and a nested `use Bar` in the body (itself a macro) would over-expand to
  # `require Bar; Bar.__using__(...)`; one step leaves the nested `use` intact for `collect/4`
  # to re-expand.
  defp expand_using(mod, opts, caller) do
    env = %{__ENV__ | module: caller, requires: Enum.uniq([mod | __ENV__.requires])}
    Macro.expand_once({{:., [], [mod, :__using__]}, [], [opts]}, env)
  end

  # Gather `import`/`alias`/`require …, as:` from a `__using__` body, descending only blocks
  # and re-expanding nested `use`s — never `def`/`quote`/`if` bodies (those degrade).
  defp collect({:__block__, _, stmts}, caller, depth, seen) when is_list(stmts),
    do: Enum.flat_map(stmts, &collect(&1, caller, depth, seen))

  defp collect({directive, _, _} = node, _caller, _depth, _seen)
       when directive in [:import, :alias],
       do: [node]

  # `require Foo, as: Bar` introduces an alias; rewrite to the equivalent `alias` so
  # `Aliases.register` (which doesn't read `require`) picks it up. A plain `require` doesn't
  # affect name resolution and is dropped.
  defp collect({:require, _, [mod_ast, opts]}, _caller, _depth, _seen) when is_list(opts) do
    case as_value(opts) do
      nil -> []
      as -> [{:alias, [], [mod_ast, [as: as]]}]
    end
  end

  defp collect({:use, _, args}, caller, depth, seen) do
    case use_args(args) do
      {:ok, mod, opts} ->
        if Code.ensure_loaded?(mod),
          do: expand_and_collect(mod, opts, caller, depth, seen),
          else: []

      :error ->
        []
    end
  end

  defp collect(_other, _caller, _depth, _seen), do: []

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
