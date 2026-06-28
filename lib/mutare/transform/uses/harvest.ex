defmodule Mutare.Transform.Uses.Harvest do
  @moduledoc false
  # In-process `use` **expansion + harvesting** — the machinery `Mutare.Transform.Uses` runs at each
  # module-level `use` to discover the `import`/`alias`/`require …, as:` directives and `@behaviour`s
  # its `__using__` injects. `run/4` takes the Sourceror `use` node, the caller module, and the alias
  # env in force, and returns `{directives, behaviours}` (both `[]` on any failure — it never raises).
  # `Uses` stamps the result onto the node's meta; the walk + meta contract stay there.
  #
  # ## Why in-process expansion is sound (and where it degrades)
  #
  # In the primary deployment (the user adds `{:mutare, …}` as a dep and runs `mix mutare`) the task
  # process has the app's deps (Ecto, Phoenix) on the BEAM code path, so a `use Foo` is expandable:
  # `Code.ensure_loaded?(Foo)` is true and `Foo.__using__/1` can be invoked. `Macro.expand/2` is **one
  # level only** — it yields `require Foo; Foo.__using__(opts)` and stops, because it won't expand a
  # *remote* macro call — so we expand the **inner** `Foo.__using__(opts)` call directly (via
  # `Macro.expand_once`, not `expand`, which would over-expand a nested `use`), with `Foo` added to the
  # env's `:requires`. The `__using__` body (a `quote` block) is returned *unexpanded*; we harvest its
  # top-level directives and recurse through nested `use`s (depth- and cycle-capped).
  #
  # Everything degrades to no harvest and **never raises** — each `use` expansion is wrapped in `try`,
  # so a raising `__using__` (one that reads caller-module attributes, say) drops only its own
  # contribution, not its siblings'. A `use` is skipped when the module isn't loadable, when its args
  # aren't static literals, or when `__using__` raises. Imports gated behind a runtime `if`/`unless`
  # inside a `__using__` body are not harvested (we don't evaluate injected conditionals).
  #
  # ## Why directives are normalized to Sourceror form
  #
  # `Macro.expand` returns **standard** quoted AST, where a module is `{:__aliases__, …}` *or* a bare
  # atom (`import unquote(mod)` → `{:import, _, [Ecto.Schema]}`) — a shape `Imports.register` doesn't
  # accept. Each harvested directive is re-rendered through Sourceror
  # (`Sourceror.parse_string!(Macro.to_string(d))`), so it arrives indistinguishable from a textual
  # directive and `Aliases`/`Imports`/`Calls` need no new clauses.
  #
  # ## Why the caller env is mirrored into the expansion `Macro.Env`
  #
  # The source alias env in scope at the `use` site is threaded into the expansion `Macro.Env` as its
  # `:aliases`, so a `__using__` that consults `__CALLER__.aliases` — picking an import/alias out of the
  # caller's lexical bindings — expands against the real caller env, not Mutare's. `alias Enum, as: U;
  # use AliasAware` makes `__CALLER__.aliases` report `U => Enum`, exactly what the compiler sees, so the
  # fallback directives we harvest are the ones that will actually be in scope when the metamutant
  # compiles (see `expand_using/4`).

  alias Mutare.Plugin
  alias Mutare.Transform.Aliases

  # The recursion context threaded through `collect/3` and `expand_and_collect/3`, so the
  # clauses carry one `ctx` instead of five positional args most of them ignore. `caller`
  # and `handlers` are constant for a whole harvest; `caller_aliases`, `depth` and `seen`
  # update only at the recursion boundaries — a nested `use` merges the body's aliases in,
  # and `expand_and_collect` bumps `depth` and records the `{mod, opts}` key in `seen`.
  defmodule Ctx do
    @moduledoc false
    @enforce_keys [:caller, :caller_aliases, :depth, :seen, :handlers]
    defstruct [:caller, :caller_aliases, :depth, :seen, :handlers]
  end

  @max_depth 16

  @doc """
  Discover the directives a `use` injects, partitioned into two harvests: `@behaviour`
  modules (kept as bare atoms) and `import`/`alias`/`require …, as:` directives (normalized
  to Sourceror form, the shape `Resolve.register/2` folds). Returns `{directives, behaviours}`;
  both `[]` on any failure (degrades to the unresolved behaviour, never raises).

  `handlers` are the plugin `use`-expansion overrides (`Mutare.Plugin.use_handlers/1`).
  After the `use` target is alias-resolved, they are consulted **first**: a plugin that does
  not `:decline` supplies the directives directly, bypassing in-process expansion entirely —
  so a `use` whose `__using__` can't run in the scan process (Gettext mutates its caller and
  raises) still surfaces its directives. When every plugin declines, the `use` is expanded
  in-process as before. The plugin path skips both the static-literal opts gate (Gettext's
  `backend:` is a module alias, not a literal) and the `Code.ensure_loaded?` check (the plugin
  asserts the directives), since it never invokes `__using__`.
  """
  @spec run(Macro.t(), module(), map(), [Plugin.Spec.t()]) :: {[Macro.t()], [module()]}
  def run(sourceror_use_node, caller_module, env, handlers) do
    case target(sourceror_use_node, env) do
      {:ok, mod, args} ->
        # The plugin `context`: the caller `:module` (the dispatcher adds each handler's `:opts`).
        # A map, so `expand_use/3` can gain context keys without an arity bump.
        case Plugin.expand_use(handlers, mod, args, %{module: caller_module}) do
          :decline ->
            in_process(mod, args, caller_module, env, handlers)

          %Plugin.Expansion{directives: directives, behaviours: behaviours} ->
            from_plugin(directives, behaviours)
        end

      :error ->
        {[], []}
    end
  rescue
    # Any plugin **misbehavior** — a malformed return, or a raise/throw — reaches here as a
    # `Mutare.Plugin.ContractError` (`safe_expand/4` wraps a raise/throw). That is a *configuration*
    # error — the user installed a broken plugin — not a property of the target being scanned, so it
    # must surface loudly rather than degrade like an un-expandable `use`: it rides *through* the
    # otherwise catch-all rescue up to `Mutare.Schema`, which re-raises it.
    e in Plugin.ContractError -> reraise e, __STACKTRACE__
    _ -> {[], []}
  catch
    _, _ -> {[], []}
  end

  # In-process expansion: expand `mod.__using__(opts)` and harvest, the path taken when no
  # plugin overrides the `use`. The static-literal opts gate and the loadability check live
  # here — a plugin override needs neither (see `run/4`). `handlers` are threaded through so a
  # `use` nested in the expanded `__using__` body is *also* offered to the plugins (see `collect`).
  defp in_process(mod, args, caller_module, env, handlers) do
    with {:ok, opts} <- use_opts(args),
         true <- Code.ensure_loaded?(mod) do
      ctx = %Ctx{
        caller: caller_module,
        caller_aliases: env,
        depth: 0,
        seen: MapSet.new(),
        handlers: handlers
      }

      {behaviour_items, directive_items} =
        mod
        |> expand_and_collect(opts, ctx)
        |> Enum.split_with(&match?({:mutare_behaviour, _}, &1))

      directives = to_sourceror_directives(directive_items)
      behaviours = Enum.map(behaviour_items, fn {:mutare_behaviour, beh} -> beh end)
      {directives, behaviours}
    else
      _ -> {[], []}
    end
  end

  # A plugin override's result → the `{directives, behaviours}` harvest shape. The directives
  # are standard-quoted (from the plugin's `quote/2`), so they go through the same `to_sourceror/1`
  # (`Macro.to_string |> Sourceror.parse_string!`) as an in-process harvest, arriving as the
  # Sourceror directives `Resolve.register/2` folds. Behaviours are kept as bare atoms.
  defp from_plugin(directives, behaviours) do
    {directives |> flatten_directives() |> to_sourceror_directives(),
     normalize_behaviours(behaviours)}
  end

  # Plugin behaviours arrive as resolved **module atoms** per the `Mutare.Plugin.Expansion`
  # contract (`behaviours: [module()]`) — a plugin writes module literals (`[GenServer]`), which
  # *are* atoms, never quoted `{:__aliases__, …}` nodes. So keep every **concrete atom** (an Elixir
  # module `GenServer`, or an Erlang behaviour atom `:gen_statem`), dropping only a non-atom (a stray
  # quoted node, a junk string/number) and the degenerate `nil`/`true`/`false`. It does **not** verify
  # the atom names a real `@behaviour` — that would mean loading each module — it **trusts** the
  # contract: a stray atom that matches no `@behaviour` is inert (downstream it only ever fails a
  # `MapSet` membership check, never crashes), so the trust is safe. (Resolving a quoted node here
  # would mis-fire anyway: there is no caller alias env at this point, so a single-segment or aliased
  # node would resolve to a *wrong* module silently.)
  defp normalize_behaviours(behaviours) do
    behaviours |> List.wrap() |> Enum.filter(&behaviour_module?/1)
  end

  defp behaviour_module?(term), do: is_atom(term) and term not in [nil, true, false]

  # Flatten a plugin's directive list to one element per directive: `List.wrap` (a plugin may hand a
  # single node, though `expand/2` requires a list) then descend any quoted `__block__` into its
  # component statements (`flatten_directive/1`). The shared front-half of both plugin harvests
  # (`from_plugin/2` top-level, `plugin_items/2` nested).
  defp flatten_directives(directives),
    do: directives |> List.wrap() |> Enum.flat_map(&flatten_directive/1)

  # Standard-quoted directives → the Sourceror form `Resolve.register/2` folds (`to_sourceror/1`),
  # dropping any that fail to round-trip. Shared by `from_plugin/2` (a top-level plugin override) and
  # `in_process/5` (every collected directive, plugin or in-process).
  defp to_sourceror_directives(directives),
    do: directives |> Enum.map(&to_sourceror/1) |> Enum.reject(&is_nil/1)

  # A plugin's directives list may hold a single quoted **block** of several directives
  # (`Mutare.Plugin.expand([quote do import A; import B end])` → a one-element list wrapping a
  # `{:__block__, _, [import_a, import_b]}` node) instead of one element per directive — both are
  # valid `[Macro.t()]` lists. (`expand/2` itself requires a list, so the block must be wrapped in
  # one; a *bare* `quote do … end` is rejected by its contract.) `Resolve.register/2` folds one
  # directive at a time and treats a `__block__` as a no-op, so descend a block into its component
  # statements here (mirroring the in-process `collect/3`, which descends `__using__` blocks the
  # same way); a non-block directive passes through unchanged. The descent **recurses**,
  # so a block nested inside a block (a legal, if unusual, `Macro.t()`) is flattened to its leaves
  # rather than surfacing an inner `__block__` that `to_sourceror/1` would render and `register/2` drop.
  defp flatten_directive({:__block__, _meta, stmts}) when is_list(stmts),
    do: Enum.flat_map(stmts, &flatten_directive/1)

  defp flatten_directive(directive), do: [directive]

  # Sourceror `use` node → `{:ok, module_atom, raw_args}`, or `:error`. The Sourceror→standard
  # round-trip is **deliberate**, not a smell: it is the parser-based *inverse* of `to_sourceror/1`'s
  # `Macro.to_string |> Sourceror.parse_string!` (standard→Sourceror), using the real tokenizer to
  # convert between quoting formats rather than reimplementing Sourceror's block-wrapping inverse by
  # hand — which would have to track every wrapped shape (nested keyword lists, maps, tuples) and
  # would be *more* fragile. It also strips block-wrapping so `__using__` receives the real term
  # (`:controller`, not `{:__block__, [], [:controller]}`) and a plugin sees a clean opts AST. The
  # round-tripped `{:use, _, args}` is exactly `use_target/2`'s arg shape, so module resolution + the
  # `nil`-is-an-atom guard are delegated there — the single home — rather than duplicated.
  defp target(sourceror_use_node, env) do
    case Code.string_to_quoted!(Sourceror.to_string(sourceror_use_node)) do
      {:use, _, args} -> use_target(args, env)
      _ -> :error
    end
  end

  # `[mod_ast | rest]` (standard quoted) → `{:ok, module_atom, raw_rest}`, or `:error`. The single
  # home for resolving a `use` target + its raw args, shared by the top-level `target/2` (after its
  # round-trip) and a **nested** `use` reached in a `__using__` body. It resolves the module through
  # the `env` (an aliased `alias RealUse, as: Foo; use Foo` yields the real module) and returns the
  # **raw** args with no static-literal gate, so a plugin override sees them as written (Gettext's
  # `backend:` is not a literal); the in-process fallbacks (`in_process/5`, `nested_in_process/3`)
  # apply the opts gate.
  #
  # `not is_nil` matters: `Aliases.resolve_node/2` returns `nil` (itself an atom) for an unresolvable
  # target, so an un-guarded `is_atom` would yield `{:ok, nil, rest}` and hand a `nil` module to every
  # plugin's `expand_use/3`. The in-process path degrades safely on `nil`, but a plugin with an
  # unguarded catch-all clause would fire on a `use` it can't see.
  defp use_target([mod_ast | rest], env) do
    case Aliases.resolve_node(mod_ast, env) do
      mod when is_atom(mod) and not is_nil(mod) -> {:ok, mod, rest}
      _ -> :error
    end
  end

  defp use_target(_args, _env), do: :error

  # In-process expansion of a nested `use` no plugin overrode: apply the static-literal opts gate
  # + loadability check (the old `use_args/2` behaviour), then recurse. `caller_aliases` already
  # carries the body's injected aliases (merged by the caller).
  defp nested_in_process(mod, raw_args, %Ctx{} = ctx) do
    with {:ok, opts} <- use_opts(raw_args),
         true <- Code.ensure_loaded?(mod) do
      expand_and_collect(mod, opts, ctx)
    else
      _ -> []
    end
  end

  # A plugin override of a *nested* `use` → `collect/3`-shape items, so it merges with the
  # in-process harvest of its sibling directives. Directives stay standard-quoted (a single quoted
  # block flattened to its leaves) and are normalized later by `in_process/5` like every collected
  # directive; behaviours become `{:mutare_behaviour, mod}` tuples (atoms only, via
  # `normalize_behaviours/1`) — the same shape the in-process `@behaviour` clause produces. Mirrors
  # the top-level `from_plugin/2`, but in the un-normalized collect-item shape its position needs.
  defp plugin_items(directives, behaviours) do
    directive_items = flatten_directives(directives)
    behaviour_items = behaviours |> normalize_behaviours() |> Enum.map(&{:mutare_behaviour, &1})
    directive_items ++ behaviour_items
  end

  # `rest` (standard quoted) → `{:ok, opts_literal}` with the static gate, or `:error`. A `use`
  # takes at most one opts argument, and in-process expansion requires it be a compile-time
  # literal (`Macro.quoted_literal?` is false on Sourceror block-wrapping, hence the round-trip).
  defp use_opts([]), do: {:ok, []}
  defp use_opts([opts]), do: if(Macro.quoted_literal?(opts), do: {:ok, opts}, else: :error)
  defp use_opts(_rest), do: :error

  # Expand `mod.__using__(opts)` and collect the directives in its body, recursing through
  # nested `use`s. Bounded by depth and a `seen` set so a `use`-cycle terminates. `seen` keys on
  # the `{module, options}` pair, not the module alone: a `__using__` that re-dispatches to the
  # *same* module with different static options (`use Foo, :a` → `use Foo, :b`) is a real
  # option-specific clause Elixir would expand, not a cycle — only an exact `{mod, opts}` repeat
  # is (and the depth cap backstops a non-repeating chain).
  #
  # `caller_aliases` is the **source alias env in scope at the original `use` site** (a
  # `%{name => path | atom}` map), threaded down so the expanded `__using__` sees a faithful
  # `__CALLER__.aliases` — see `expand_using/4`.
  defp expand_and_collect(mod, opts, %Ctx{} = ctx) do
    key = {mod, opts}

    cond do
      ctx.depth > @max_depth ->
        []

      MapSet.member?(ctx.seen, key) ->
        []

      # A fresh alias scope (`%{}`) for this `__using__` body — its directives are folded as the
      # block is descended, so an in-body `alias … as: T` resolves a sibling `use T`.
      #
      # The `try` makes **each `use` expansion** the failure-isolation unit — both this top-level
      # call (from `run/4`) and every *nested* `use` reached recursively via `collect/3`. A
      # raising `__using__` (e.g. `use Gettext, backend: …`, whose body runs `Module.put_attribute`
      # on the already-compiled caller → `ArgumentError`) then drops only *its own* contribution,
      # while its siblings — harvested in the enclosing block's `flat_map_reduce` — survive. Without
      # it, one bad nested `use` propagated out to `run/4`'s outer rescue and collapsed the whole
      # bundle to `{[], []}`, silently dropping the good `import`/`@behaviour` directives beside it.
      # See NOTES "isolate failure per `use`, not per bundle".
      true ->
        try do
          expand_using(mod, opts, ctx.caller, ctx.caller_aliases)
          |> collect(%{ctx | depth: ctx.depth + 1, seen: MapSet.put(ctx.seen, key)}, %{})
        rescue
          # A plugin contract violation in a *nested* `use`'s override must stay loud (see `run/4`);
          # everything else degrades this one `use` to `[]`.
          e in Plugin.ContractError -> reraise e, __STACKTRACE__
          _ -> []
        catch
          _, _ -> []
        end
    end
  end

  # `Macro.expand/2` won't expand a remote macro call, so we expand the inner
  # `mod.__using__(opts)` directly with `mod` required. The env's `:module` is the using
  # module so `__CALLER__.module` reads faithfully. **`expand_once`, not `expand`** — `expand`
  # would keep going, and a nested `use Bar` in the body (itself a macro) would over-expand to
  # `require Bar; Bar.__using__(...)`; one step leaves the nested `use` intact for `collect/3`
  # to re-expand.
  #
  # The env's `:aliases` is populated from the threaded source alias env (not left as
  # `Mutare.Transform.Uses.Harvest`'s own compile-time aliases), so a `__using__` that branches on
  # `__CALLER__.aliases` — choosing an import/alias from the caller's lexical bindings — expands
  # against the *real* caller env: `alias Enum, as: U; use AliasAware` makes `__CALLER__.aliases`
  # report `U => Enum`, the same the compiler sees, so the harvested fallback directives match the
  # ones that will actually be in scope. (The source env carries Elixir-module paths and Erlang
  # atom modules; `env_aliases/1` renders both into the `[{Elixir.Name, module}]` shape Elixir
  # builds — exercised in `uses_test.exs` via the `Mutare.Test.AliasAwareUsing` fixture.)
  defp expand_using(mod, opts, caller, caller_aliases) do
    env = %{
      __ENV__
      | module: caller,
        aliases: env_aliases(caller_aliases),
        requires: Enum.uniq([mod | __ENV__.requires])
    }

    Macro.expand_once({{:., [], [mod, :__using__]}, [], [opts]}, env)
  end

  # The source alias env (`%{name => path | atom}`, the form `Aliases.register/2` builds) rendered
  # into the `Macro.Env.aliases` shape — `[{Elixir.Name, module}]`, e.g. `[{U, Enum}, {B, :binary}]`
  # — a `__using__` body reads via `__CALLER__.aliases`. Each name (a single segment atom) becomes
  # its module atom (`Module.concat([U]) == Elixir.U`); the target is an Elixir path
  # (`[:Enum]` → `Enum`) or an Erlang atom module (`:binary`, kept verbatim).
  defp env_aliases(env) do
    Enum.map(env, fn {name, target} -> {Module.concat([name]), Aliases.to_module(target)} end)
  end

  # Gather `import`/`alias`/`require …, as:` from a `__using__` body, descending only blocks
  # and re-expanding nested `use`s — never `def`/`quote`/`if` bodies (those degrade). An alias
  # env (`env`) is folded left-to-right over a block so an in-body `alias … as: T` resolves a
  # sibling `use T` (the way the compiler expands it).
  defp collect({:__block__, _, stmts}, %Ctx{} = ctx, env)
       when is_list(stmts) do
    {collected, _env} =
      Enum.flat_map_reduce(stmts, env, fn stmt, env ->
        harvested = collect(stmt, ctx, env)

        # Advance the env with the directives this statement *yields*, not its literal text — so a
        # nested `use` (or `require …, as:`) that injects an alias resolves a later sibling `use`
        # (`use AliasInjector; use T`), exactly as Elixir expands it. (A direct `alias` yields
        # itself, so its binding is captured too; an `import` yields a no-op for the alias env.)
        {harvested, Enum.reduce(harvested, env, &register_harvested/2)}
      end)

    collected
  end

  defp collect({directive, _, _} = node, _ctx, _env)
       when directive in [:import, :alias],
       do: [node]

  # `require Foo, as: Bar` introduces an alias; harvest it as the equivalent `alias` directive
  # (its canonical form) so it folds into resolution like any other harvested binding. A plain
  # `require` doesn't affect name resolution and is dropped.
  defp collect({:require, _, [mod_ast, opts]}, _ctx, _env) when is_list(opts) do
    case as_value(opts) do
      nil -> []
      as -> [{:alias, [], [mod_ast, [as: as]]}]
    end
  end

  # A nested `use` harvested from an *expanded* `__using__` body (e.g. `use MyAppWeb, :html` whose
  # body injects `use Gettext, …` — the idiomatic Phoenix integration point). Like the **top-level**
  # `use`, the plugin `handlers` are consulted **first** (so the same override that surfaces a
  # directly-written `use Gettext` also surfaces a nested one); only on `:decline` does it expand
  # in-process (`nested_in_process/3`, which keeps the static-literal opts gate + loadability check).
  # The module is resolved through the body's own alias scope (`env`) so an earlier sibling
  # `alias … as: T` redirects `use T`; the recursion's `__CALLER__.aliases` is the source aliases
  # *plus* the ones this body injected (`Map.merge(caller_aliases, env)`, body-injected shadowing
  # source) — exactly how the compiler expands a later nested `use`. The plugin override sees the
  # **raw** args (no opts gate), matching `target/2`.
  defp collect({:use, _, args}, %Ctx{} = ctx, env) do
    case use_target(args, env) do
      {:ok, mod, raw_args} ->
        nested_ctx = %{ctx | caller_aliases: Map.merge(ctx.caller_aliases, env)}

        case Plugin.expand_use(ctx.handlers, mod, raw_args, %{module: ctx.caller}) do
          :decline ->
            nested_in_process(mod, raw_args, nested_ctx)

          %Plugin.Expansion{directives: directives, behaviours: behaviours} ->
            plugin_items(directives, behaviours)
        end

      :error ->
        []
    end
  end

  # `@behaviour Foo` injected by the `__using__` body (e.g. `use GenServer` injects
  # `@behaviour GenServer`): harvest the behaviour *module*, resolved through the body's
  # alias env, tagged `{:mutare_behaviour, mod}` so `run/4` separates it from the
  # name-resolution directives. Only the canonical `@behaviour` is recognised — Elixir
  # rejects `@behavior`. A non-static / unresolvable module (`Aliases.resolve_node/2` → `nil`) is
  # dropped, like an un-round-trippable directive.
  defp collect({:@, _, [{:behaviour, _, [mod_ast]}]}, _ctx, env) do
    case Aliases.resolve_node(mod_ast, env) do
      nil -> []
      mod -> [{:mutare_behaviour, mod}]
    end
  end

  defp collect(_other, _ctx, _env), do: []

  defp as_value(opts), do: Keyword.get(opts, :as)

  # Re-render one harvested (standard-quoted) directive into Sourceror form, so it is
  # indistinguishable from a textual directive when folded through `Resolve.register/2`. A
  # directive that can't round-trip is dropped (nil), not fatal.
  defp to_sourceror(directive) do
    directive |> Macro.to_string() |> Sourceror.parse_string!()
  rescue
    _ -> nil
  end

  # Fold one harvested directive into the body-local alias env *after converting it to Sourceror
  # form*. The harvested directives are raw standard-quoted (pre-`to_sourceror`), where an
  # `unquote(mod)`/`bind_quoted` alias carries its target as a **bare module atom**
  # (`{:alias, _, [Mutare.Foo, [as: T]]}`) — a shape `Aliases.register/2` doesn't recognise, so
  # binding it raw is a silent no-op. Converting first (the same Sourceror round-trip `run` applies
  # at the end, turning the atom into an `{:__aliases__, …}` node) makes `alias unquote(target),
  # as: T` actually bind `T`, so a later sibling `use T` in the same expanded body resolves and
  # expands. An un-round-trippable directive (nil) is a no-op.
  # A harvested `@behaviour` tuple introduces no alias and must never reach `to_sourceror`
  # (`Macro.to_string` over a `{:mutare_behaviour, mod}` tuple would be garbage) — skip it.
  defp register_harvested({:mutare_behaviour, _}, env), do: env

  defp register_harvested(directive, env) do
    case to_sourceror(directive) do
      nil -> env
      normalized -> Aliases.register(normalized, env)
    end
  end
end
