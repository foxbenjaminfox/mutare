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

  @directives_key :mutare_use_directives
  @behaviours_key :mutare_use_behaviours
  @max_depth 16

  # The env the metamutant is compiled and tested under — mirror it during `__using__` expansion.
  # Kept in sync with `Mutare.Sandbox.Command`'s `{"MIX_ENV", "test"}`.
  @sandbox_env :test

  # The module name of a nested `defmodule` we couldn't resolve to a concrete atom (a non-static
  # head, or a child of an already-unresolved parent). Expansion is *skipped* under it — see
  # `child_module/3` and `stamp/3`.
  @unresolved :__mutare_unresolved__

  # The `:persistent_term` key holding the env-mirror **seqlock** — a one-slot `:atomics` counter
  # the swap bumps to mark itself in-flight, so a concurrent reader can tell a stable base `:test`
  # from a swapper's transient one. See `with_sandbox_env/1`.
  @seq_key {__MODULE__, :env_seq}

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
  # `Mix.env()` read is.)
  #
  # `Mix.env/1` mutates **global** (node-wide ETS) state, so concurrent callers must not corrupt
  # each other's view. The design splits into a lock-free fast path and a serialized swap:
  #
  #   * **Fast path** when the *stable* base env is already the sandbox env: no mutation, no lock.
  #     The test suite and the sandbox run *in* `:test`, so every concurrent transform there (async
  #     tests, parallel library callers, the property soaks) skips the swap — and crucially, in a
  #     `:test` base **no swap ever runs** (nothing reads a non-`:test` env), so the global is never
  #     mutated and the fast path is contention-free.
  #   * **Serialize** the swap (the CLI's `:dev`) behind a node-local `:global` lock, held for the
  #     *whole* expansion. Concurrent swappers run one at a time, each reading the true previous env
  #     and restoring it.
  #
  # The subtlety the obvious version gets wrong: a swapper in a `:dev` base transiently sets the
  # global to `:test`, so a *second* concurrent transform reading `Mix.env()` could see that
  # transient `:test`, wrongly take the lock-free fast path, and keep expanding an env-sensitive
  # `__using__` after the first swapper restores `:dev` — harvesting directives for the wrong env.
  # So the fast-path test is **not** a bare `Mix.env() == :test`: it is guarded by a node-local
  # **seqlock** (`@seq_key`, an `:atomics` counter the swap bumps to *odd* on entry and back to
  # *even* on exit, both **inside** the lock and bracketing the env mutation). A reader samples
  # `seq → Mix.env() → seq` and only trusts a `:test` reading when the seq was **even and unchanged**
  # across it — i.e. no swap was active for even an instant of the read. A transient `:test` is only
  # ever set while seq is odd, so it can never be mistaken for the stable base. (`Mix.State`'s ETS
  # and `:atomics` are each internally synchronized, so the swapper's `odd` bump is visible to any
  # reader that observes its `:test`.) In a `:test` base seq stays `0`, so the guard is two atomic
  # reads — no lock, no contention.
  #
  # `Mix.env/0` raises if Mix hasn't been *started* — the public `transform_string/2` API embedded
  # in a plain process that never ran Mix — in which case there's no sandbox env to mirror, so we
  # run unmirrored (the fallback keeps the library API working without Mix).
  defp with_sandbox_env(fun) do
    case classify_env() do
      :sandbox -> fun.()
      :other -> swap(fun)
      :unavailable -> fun.()
    end
  end

  # Classify the *stable* base env, immune to a concurrent swapper's transient `:test`: `:sandbox`
  # (fast path) only when `Mix.env()` reads the sandbox env **and** the seqlock shows no swap
  # touched the global across the read (even and unchanged). Anything else is `:other` (swap path) —
  # including a `:test` reading caught mid-swap, which then blocks on the lock and mirrors correctly.
  # `:unavailable` when Mix isn't started (`Mix.env/0` raises).
  defp classify_env do
    ref = seq_ref()
    s0 = :atomics.get(ref, 1)
    env = Mix.env()
    s1 = :atomics.get(ref, 1)

    if env == @sandbox_env and s0 == s1 and rem(s0, 2) == 0,
      do: :sandbox,
      else: :other
  rescue
    _ -> :unavailable
  end

  # The seqlock counter — a one-slot `:atomics`, created once and shared via `:persistent_term`.
  # The one-time creation is serialized by a `:global` lock so concurrent first-callers converge on
  # a single ref (a lock-free create-and-put would let one process bump a ref another never sees);
  # every later call is a bare `:persistent_term.get`.
  defp seq_ref do
    case :persistent_term.get(@seq_key, :missing) do
      :missing -> create_seq_ref()
      ref -> ref
    end
  end

  defp create_seq_ref do
    :global.trans({{__MODULE__, :env_seq_init}, self()}, fn ->
      case :persistent_term.get(@seq_key, :missing) do
        :missing ->
          ref = :atomics.new(1, signed: false)
          :persistent_term.put(@seq_key, ref)
          ref

        ref ->
          ref
      end
    end)
  end

  # The `:global.trans` id is `{ResourceId, LockRequesterId}`. The lock is keyed on the
  # **ResourceId** (`{__MODULE__, :sandbox_env}` — a constant, *shared* across processes, so two
  # callers contend for the same lock and serialize). `LockRequesterId` is the requester *identity*
  # and **must stay `self()`**: `:global` grants a lock re-entrantly to the *same* requester, so a
  # process-independent (constant) requester id would make every process the same requester and
  # grant them all at once — defeating the mutex. (Counter-intuitive but verified; the concurrent
  # transform test in `uses_env_test.exs` guards it.)
  #
  # The seqlock bumps bracket the env mutation: `add → odd` *before* `Mix.env(@sandbox_env)`, and
  # `add → even` *after* the restore (in `after`, so a raising `fun` still leaves it even). Both run
  # inside the lock, so swaps never interleave their bumps — seq cycles `even → odd → even` cleanly.
  defp swap(fun) do
    ref = seq_ref()

    :global.trans({{__MODULE__, :sandbox_env}, self()}, fn ->
      :atomics.add(ref, 1, 1)
      previous = Mix.env()
      Mix.env(@sandbox_env)

      try do
        fun.()
      after
        Mix.env(previous)
        :atomics.add(ref, 1, 1)
      end
    end)
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

  defp walk({:defmodule, meta, [mod_ast, [{do_key, body}]]} = node, module, env) do
    child = child_module(mod_ast, module, env)
    {:defmodule, meta, [mod_ast, [{do_key, walk_body(body, child, body_env(node, module, env))}]]}
  end

  # `defprotocol P do … end` defines module `P` — a module scope (a direct `use` inside it, though
  # rare, is a real directive), named exactly like a `defmodule`.
  defp walk({:defprotocol, meta, [mod_ast, [{do_key, body}]]} = node, module, env) do
    child = child_module(mod_ast, module, env)

    {:defprotocol, meta,
     [mod_ast, [{do_key, walk_body(body, child, body_env(node, module, env))}]]}
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
  # as `RealUsing.__using__`). So the lexical alias env is folded left-to-right here too (source
  # aliases *and* the implicit alias a `defmodule`/`defprotocol` introduces). (A module body is
  # reached via `walk_body`, which folds + stamps; this clause never sees one.)
  defp walk({:__block__, meta, stmts}, module, env) do
    {walked, _env} =
      Enum.map_reduce(stmts, env, fn stmt, env ->
        {walk(stmt, module, env), register_lexical(stmt, module, env)}
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
        {node, advance_env(stmt, node, module, env)}
      end)

    {:__block__, meta, walked}
  end

  defp walk_body(stmt, module, env), do: walk_stmt(stmt, module, env)

  defp walk_stmt({:use, _meta, _args} = node, module, env), do: stamp(node, module, env)
  defp walk_stmt(stmt, module, env), do: walk(stmt, module, env)

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
    stmt |> register_source(env) |> then(&register_defined_module(stmt, module, &1))
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

  # Fold the alias a *source* statement introduces: a plain `alias`, or a `require Mod, as: Name`
  # (which the compiler also treats as an alias). Both are handled directly by
  # `Aliases.register/2`, so this is a straight delegation; a bare `require Mod` (no `as:`)
  # introduces no alias and passes through.
  defp register_source(stmt, env), do: Aliases.register(stmt, env)

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
      not Enum.all?(path, &is_atom/1) -> @unresolved
      match?([:"Elixir" | _], path) -> Module.concat(path)
      parent == @unresolved -> @unresolved
      parent == nil -> path |> Aliases.resolve_path(env) |> to_module()
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
    {directives, behaviours} = harvest(node, module, env)

    meta =
      meta
      |> put_harvest(@directives_key, directives)
      |> put_harvest(@behaviours_key, behaviours)

    {:use, meta, args}
  end

  defp put_harvest(meta, _key, []), do: meta
  defp put_harvest(meta, key, values), do: [{key, values} | meta]

  # Expand the `use` and partition what its `__using__` body injects into two harvests:
  # `@behaviour` modules (tagged `{:mutare_behaviour, mod}` by `collect/6`, kept as bare
  # atoms) and `import`/`alias`/`require …, as:` directives (normalized to Sourceror form,
  # the shape `Resolve.register/2` folds). Returns `{directives, behaviours}`; both `[]` on
  # any failure (degrades to the unresolved behaviour, never raises).
  defp harvest(sourceror_use_node, caller_module, env) do
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
      true ->
        expand_using(mod, opts, caller, caller_aliases)
        |> collect(caller, caller_aliases, depth + 1, MapSet.put(seen, key), %{})
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
  # `Mutare.Transform.Uses`'s own compile-time aliases), so a `__using__` that branches on
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
    Enum.map(env, fn {name, target} -> {Module.concat([name]), to_module(target)} end)
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
  # alias env, tagged `{:mutare_behaviour, mod}` so `harvest/3` separates it from the
  # name-resolution directives. Only the canonical `@behaviour` is recognised — Elixir
  # rejects `@behavior`. A non-static / unresolvable module (`module_atom/2` → `nil`) is
  # dropped, like an un-round-trippable directive.
  defp collect(
         {:@, _, [{:behaviour, _, [mod_ast]}]},
         _caller,
         _caller_aliases,
         _depth,
         _seen,
         env
       ) do
    case module_atom(mod_ast, env) do
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
  # (the same Sourceror round-trip `harvest` applies at the end, turning the atom into an
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
