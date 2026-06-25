defmodule Mutare.Transform.Uses.Harvest do
  @moduledoc false
  # In-process `use` **expansion + harvesting** — the machinery `Mutare.Transform.Uses` runs at each
  # module-level `use` to discover the `import`/`alias`/`require …, as:` directives and `@behaviour`s
  # its `__using__` injects. `run/3` takes the Sourceror `use` node, the caller module, and the alias
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

  alias Mutare.Transform.Aliases

  @max_depth 16

  @doc """
  Expand the `use` and partition what its `__using__` body injects into two harvests:
  `@behaviour` modules (kept as bare atoms) and `import`/`alias`/`require …, as:` directives
  (normalized to Sourceror form, the shape `Resolve.register/2` folds). Returns
  `{directives, behaviours}`; both `[]` on any failure (degrades to the unresolved behaviour,
  never raises).
  """
  @spec run(Macro.t(), module(), map()) :: {[Macro.t()], [module()]}
  def run(sourceror_use_node, caller_module, env) do
    with {:ok, mod, opts} <- standardize(sourceror_use_node, env),
         true <- Code.ensure_loaded?(mod) do
      {behaviour_items, directive_items} =
        mod
        |> expand_and_collect(opts, caller_module, env, 0, MapSet.new())
        |> Enum.split_with(&match?({:mutare_behaviour, _}, &1))

      directives = directive_items |> Enum.map(&normalize/1) |> Enum.reject(&is_nil/1)
      behaviours = Enum.map(behaviour_items, fn {:mutare_behaviour, beh} -> beh end)
      {directives, behaviours}
    else
      _ -> {[], []}
    end
  rescue
    _ -> {[], []}
  catch
    _, _ -> {[], []}
  end

  # Sourceror `use` node → `{:ok, module_atom, opts_literal}` (standard quoted), or `:error`.
  # The Sourceror→standard round-trip strips block-wrapping so `__using__` receives the real
  # term (`:controller`, not `{:__block__, [], [:controller]}`); it is also where the static
  # gate runs, since `Macro.quoted_literal?` is false on Sourceror block-wrapping. The module is
  # resolved through `env` so an aliased target (`alias RealUse, as: Foo; use Foo`) expands the
  # real module.
  #
  # The round-trip is **deliberate**, not a smell: it is the parser-based *inverse* of
  # `normalize/1`'s `Macro.to_string |> Sourceror.parse_string!` (which goes standard→Sourceror),
  # using the real tokenizer to convert between quoting formats rather than reimplementing
  # Sourceror's block-wrapping inverse by hand — which would have to track every wrapped shape
  # (nested keyword lists, maps, tuples) and would be *more* fragile. Module resolution alone
  # wouldn't need it (`Aliases.resolve_node/2` reads the aliased segments directly), but the
  # `Macro.quoted_literal?` opts gate and the real term `__using__` receives both do.
  defp standardize(sourceror_use_node, env) do
    {:use, _, args} = Code.string_to_quoted!(Sourceror.to_string(sourceror_use_node))
    use_args(args, env)
  end

  # `[module | rest]` (standard quoted) → `{:ok, module_atom, opts}` with the literal gate, or
  # `:error`. A `use` takes a module and at most one opts argument.
  defp use_args([mod_ast | rest], env) do
    with mod when is_atom(mod) <- Aliases.resolve_node(mod_ast, env),
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
  defp expand_and_collect(mod, opts, caller, caller_aliases, depth, seen) do
    key = {mod, opts}

    cond do
      depth > @max_depth ->
        []

      MapSet.member?(seen, key) ->
        []

      # A fresh alias scope (`%{}`) for this `__using__` body — its directives are folded as the
      # block is descended, so an in-body `alias … as: T` resolves a sibling `use T`.
      #
      # The `try` makes **each `use` expansion** the failure-isolation unit — both this top-level
      # call (from `run/3`) and every *nested* `use` reached recursively via `collect/6`. A
      # raising `__using__` (e.g. `use Gettext, backend: …`, whose body runs `Module.put_attribute`
      # on the already-compiled caller → `ArgumentError`) then drops only *its own* contribution,
      # while its siblings — harvested in the enclosing block's `flat_map_reduce` — survive. Without
      # it, one bad nested `use` propagated out to `run/3`'s outer rescue and collapsed the whole
      # bundle to `{[], []}`, silently dropping the good `import`/`@behaviour` directives beside it.
      # See NOTES "isolate failure per `use`, not per bundle".
      true ->
        try do
          expand_using(mod, opts, caller, caller_aliases)
          |> collect(caller, caller_aliases, depth + 1, MapSet.put(seen, key), %{})
        rescue
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
  # `require Bar; Bar.__using__(...)`; one step leaves the nested `use` intact for `collect/6`
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
  defp collect({:__block__, _, stmts}, caller, caller_aliases, depth, seen, env)
       when is_list(stmts) do
    {collected, _env} =
      Enum.flat_map_reduce(stmts, env, fn stmt, env ->
        harvested = collect(stmt, caller, caller_aliases, depth, seen, env)

        # Advance the env with the directives this statement *yields*, not its literal text — so a
        # nested `use` (or `require …, as:`) that injects an alias resolves a later sibling `use`
        # (`use AliasInjector; use T`), exactly as Elixir expands it. (A direct `alias` yields
        # itself, so its binding is captured too; an `import` yields a no-op for the alias env.)
        {harvested, Enum.reduce(harvested, env, &register_harvested/2)}
      end)

    collected
  end

  defp collect({directive, _, _} = node, _caller, _caller_aliases, _depth, _seen, _env)
       when directive in [:import, :alias],
       do: [node]

  # `require Foo, as: Bar` introduces an alias; harvest it as the equivalent `alias` directive
  # (its canonical form) so it folds into resolution like any other harvested binding. A plain
  # `require` doesn't affect name resolution and is dropped.
  defp collect({:require, _, [mod_ast, opts]}, _caller, _caller_aliases, _depth, _seen, _env)
       when is_list(opts) do
    case as_value(opts) do
      nil -> []
      as -> [{:alias, [], [mod_ast, [as: as]]}]
    end
  end

  # A nested `use` harvested from an *expanded* `__using__` body: standard-quoted, resolved through
  # the body's own alias scope (`env`) so an earlier sibling `alias … as: T` redirects `use T`. The
  # nested `__using__`'s `__CALLER__.aliases` is the source aliases *plus* the ones this body has
  # injected so far (`Map.merge(caller_aliases, env)`, body-injected shadowing source on a clash) —
  # the compiler likewise expands a later nested `use` with the earlier injected aliases in scope.
  defp collect({:use, _, args}, caller, caller_aliases, depth, seen, env) do
    case use_args(args, env) do
      {:ok, mod, opts} ->
        if Code.ensure_loaded?(mod),
          do: expand_and_collect(mod, opts, caller, Map.merge(caller_aliases, env), depth, seen),
          else: []

      :error ->
        []
    end
  end

  # `@behaviour Foo` injected by the `__using__` body (e.g. `use GenServer` injects
  # `@behaviour GenServer`): harvest the behaviour *module*, resolved through the body's
  # alias env, tagged `{:mutare_behaviour, mod}` so `run/3` separates it from the
  # name-resolution directives. Only the canonical `@behaviour` is recognised — Elixir
  # rejects `@behavior`. A non-static / unresolvable module (`Aliases.resolve_node/2` → `nil`) is
  # dropped, like an un-round-trippable directive.
  defp collect(
         {:@, _, [{:behaviour, _, [mod_ast]}]},
         _caller,
         _caller_aliases,
         _depth,
         _seen,
         env
       ) do
    case Aliases.resolve_node(mod_ast, env) do
      nil -> []
      mod -> [{:mutare_behaviour, mod}]
    end
  end

  defp collect(_other, _caller, _caller_aliases, _depth, _seen, _env), do: []

  defp as_value(opts), do: Keyword.get(opts, :as)

  # Re-render one harvested (standard-quoted) directive into Sourceror form, so it is
  # indistinguishable from a textual directive when folded through `Resolve.register/2`. A
  # directive that can't round-trip is dropped (nil), not fatal.
  defp normalize(directive) do
    directive |> Macro.to_string() |> Sourceror.parse_string!()
  rescue
    _ -> nil
  end

  # Fold one harvested directive into the body-local alias env *after normalizing it*. The harvested
  # directives are raw standard-quoted (pre-`normalize`), where an `unquote(mod)`/`bind_quoted` alias
  # carries its target as a **bare module atom** (`{:alias, _, [Mutare.Foo, [as: T]]}`) — a shape
  # `Aliases.register/2` doesn't recognise, so binding it raw is a silent no-op. Normalizing first
  # (the same Sourceror round-trip `run` applies at the end, turning the atom into an
  # `{:__aliases__, …}` node) makes `alias unquote(target), as: T` actually bind `T`, so a later
  # sibling `use T` in the same expanded body resolves and expands. An un-round-trippable directive
  # (nil) is a no-op.
  # A harvested `@behaviour` tuple introduces no alias and must never reach `normalize`
  # (`Macro.to_string` over a `{:mutare_behaviour, mod}` tuple would be garbage) — skip it.
  defp register_harvested({:mutare_behaviour, _}, env), do: env

  defp register_harvested(directive, env) do
    case normalize(directive) do
      nil -> env
      normalized -> Aliases.register(normalized, env)
    end
  end
end
