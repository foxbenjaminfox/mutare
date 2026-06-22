defmodule Mutare.Transform.Aliases do
  @moduledoc false
  # The `alias` *vocabulary* — the env-building, resolution, stamping, and reading rules for
  # `alias`, used by the unified lexical-resolution walk in `Mutare.Transform.Resolve`. (The
  # walk itself, and the interleaving with `import`, live there; this module is pure rules.)
  #
  # The call-matching mutator families (Collection, StringCall, MapKeyword, CollectionArity,
  # ModeSwap, CallRemoval, DefaultDrop, Numeric, Integer) recognise a remote call by its
  # *literal* module path — `Enum.filter`, `String.upcase`. An `alias` rebinds that path
  # (`alias String, as: S; S.upcase(x)`), so without resolution the call hides from every one
  # of them — and worse, `alias MyApp.Enum` makes a *local* module masquerade as the stdlib
  # one, so a family would wrongly fire on it.
  #
  # `Resolve` folds a lexically-scoped alias env with `register/2` and, at each remote call,
  # stamps the *call-module* `__aliases__` node with the module it actually refers to under
  # `meta[:mutare_alias]` via `stamp_module/2` — but only when that differs from the written
  # path, so an unaliased call carries no new metadata. `resolved_module/2` is the reader: the
  # stamped module, or the literal path when none. (An unknown atom meta key is ignored by
  # Sourceror's renderer and never reaches compilation, so the stamp is invisible in both the
  # metamutant and the diff — verified by tests.) The remote-call reader the mutators actually
  # call lives in `Mutare.Transform.Calls.resolved_call/1` (which folds in `resolved_module/2`).
  #
  # The diff is preserved because only *recognition* uses the resolved module: a mutator
  # still rebuilds from the node's own (aliased) `__aliases__`, so `S.upcase(x)` mutates to
  # `S.downcase(x)`, never `String.downcase(x)`. (Every built-in swap keeps the module
  # anyway — `Enum`→`Enum`, `Map.put`→`Map.put_new` — so reusing the literal alias node is
  # always correct.)
  #
  # ## Scope and limits
  #
  #   * Handles `alias Foo.Bar`, `alias Foo.Bar, as: Baz`, and `alias Foo.{Bar, Baz}`, plus
  #     `alias :binary, as: B` for an Erlang atom module (bound to the atom; the `as:` is
  #     mandatory, since an atom has no last segment to default the name from). A
  #     **`require Mod, as: Name`** introduces the same alias (`require`'s `:as` "sets up an
  #     alias"), so it is registered identically — a bare `require Mod` (no `as:`) is a no-op.
  #   * An alias whose target is itself aliased is resolved through the env *before*
  #     binding, so the stored value is always the fully-expanded module — never another
  #     alias. `alias MyApp, as: String; alias String, as: S` binds `S` to `MyApp` (the
  #     real module), not the intermediate `String`, so a later `S.upcase` is not mistaken
  #     for a stdlib `String` call.
  #   * Lexical and textual: an alias applies only to siblings *after* it and to nested
  #     scopes (a nested `defmodule`/function body inherits the enclosing aliases); aliases
  #     declared inside a child scope do not leak back out. This falls out of `Resolve`
  #     folding the env left-to-right over each statement sequence and passing it *down* into
  #     children without bringing a child's additions back up.
  #   * A `__MODULE__`-relative alias (`alias __MODULE__.Sub`) cannot be resolved to a
  #     concrete module statically, so it is skipped (it never names a stdlib module).
  #   * `use`-injected aliases are surfaced by `Mutare.Transform.Uses` (it expands an
  #     expandable, static-arg, module-level `use` and folds the `alias`es it injects through
  #     `register/2`); a dynamic-arg or non-loadable `use`, or a non-`use` macro that injects an
  #     alias, stays invisible. `import` resolution is the sibling vocabulary in
  #     `Mutare.Transform.Imports`.

  alias Mutare.AST

  @meta_key :mutare_alias

  @doc """
  The module a call's `__aliases__` refers to: the resolved path stamped by
  `stamp_module/2`, or the literal path when no alias applied. The reader half of the
  `:mutare_alias` contract.
  """
  @spec resolved_module(keyword(), [atom()]) :: [atom()] | atom()
  def resolved_module(alias_meta, literal_path) when is_list(alias_meta),
    do: Keyword.get(alias_meta, @meta_key, literal_path)

  def resolved_module(_alias_meta, literal_path), do: literal_path

  @doc """
  Resolve a written module path against an alias env: a first segment that is an
  aliased name expands to its target, the remaining segments riding along.
  Anything else is verbatim. Exposed so the `import` pre-pass
  (`Mutare.Transform.Imports`) can resolve an `import E` (where `E` is an alias)
  through the *same* lexical alias environment, never reimplementing it.

  A binding may be an Elixir-module **path** (`[:String]`) or an Erlang-module **atom**
  (`:binary`, from `alias :binary, as: B`). An atom binding resolves a lone segment
  (`B` → `:binary`); a trailing segment after it (`B.Sub`) is not a real module, so it is
  left unresolved.
  """
  @spec resolve_path([atom()] | term(), map()) :: [atom()] | atom() | term()
  def resolve_path([first | rest], env) when is_atom(first) do
    case Map.fetch(env, first) do
      {:ok, base} when is_list(base) -> base ++ rest
      {:ok, base} when is_atom(base) and rest == [] -> base
      {:ok, _base} -> [first | rest]
      :error -> [first | rest]
    end
  end

  def resolve_path(path, _env), do: path

  @doc """
  Extend an alias env with the binding(s) a statement introduces. An `alias` directive
  changes it, **and so does a `require Mod, as: Name`** — Elixir's `:as` on `require` "sets
  up an alias" exactly like `alias/2`, so `require String, as: S; S.upcase(x)` resolves
  `S` to `String`. A bare `require Mod` (no `as:`) brings macros into scope but introduces
  no name, and every other statement passes through unchanged. The unified resolution walk
  (`Mutare.Transform.Resolve`) folds the alias env with this as it descends each statement
  sequence; `Mutare.Transform.Behaviours` and `Mutare.Transform.Uses` fold it too.
  """
  @spec register(Macro.t(), map()) :: map()
  def register({:alias, _meta, args}, env), do: register_alias(args, env)

  # `require Mod, as: Name` aliases identically to `alias Mod, as: Name` (same arg shape:
  # `[mod_ast, opts]`), so it delegates to `register_alias/2` — but only when an `as:` is
  # present; a bare `require Mod` introduces no alias.
  def register({:require, _meta, [mod_ast, opts]}, env) when is_list(opts) do
    if has_as?(opts), do: register_alias([mod_ast, opts], env), else: env
  end

  def register(_stmt, env), do: env

  @doc """
  Stamp a call's `__aliases__` module node with the module it resolves to under the env,
  but only when that differs from the written path (an unaliased call keeps clean
  metadata). The write half of the `:mutare_alias` contract; called by
  `Mutare.Transform.Resolve` at each remote call.
  """
  @spec stamp_module(Macro.t(), map()) :: Macro.t()
  def stamp_module({:__aliases__, _meta, path} = node, env),
    do: stamp(node, resolve_path(path, env))

  def stamp_module(node, _env), do: node

  # Stamp the resolved module onto the alias node's meta, but only when it differs from the
  # written path (an unaliased call keeps clean metadata).
  defp stamp({:__aliases__, meta, path} = node, resolved) do
    if resolved == path,
      do: node,
      else: {:__aliases__, [{@meta_key, resolved} | meta], path}
  end

  # --- alias directives ------------------------------------------------------

  # `alias Foo.{Bar, Baz}` — the multi-alias special form: each child rides on the base.
  # The base is resolved through the env first, so `alias X, as: Foo; alias Foo.{Bar}`
  # binds `Bar` to the real `X.Bar`, not the written `Foo.Bar`.
  defp register_alias([{{:., _, [{:__aliases__, _, base}, :{}]}, _, children} | _], env)
       when is_list(base) and is_list(children) do
    if atoms?(base) do
      resolved_base = resolve_path(base, env)

      Enum.reduce(children, env, fn
        {:__aliases__, _, seg}, env when is_list(seg) ->
          if atoms?(seg), do: bind(env, base ++ seg, resolved_base ++ seg), else: env

        _other, env ->
          env
      end)
    else
      env
    end
  end

  # `alias :erlang_mod, as: Name` — an Erlang atom module bound to its `as:` name. (An atom
  # has no last segment, so the `as:` is mandatory; `alias :binary` with none binds nothing.)
  defp register_alias([{:__block__, _meta, [atom]}, opts], env) when is_atom(atom) do
    case as_name(opts) do
      nil -> env
      name -> Map.put(env, name, atom)
    end
  end

  # `alias Foo.Bar, as: Baz` — an explicit name overrides the last-segment default.
  defp register_alias([{:__aliases__, _, path}, opts], env) when is_list(path) do
    cond do
      not atoms?(path) -> env
      (name = as_name(opts)) != nil -> Map.put(env, name, resolve_path(path, env))
      true -> bind(env, path, resolve_path(path, env))
    end
  end

  # `alias Foo.Bar` — the introduced name is the last segment.
  defp register_alias([{:__aliases__, _, path}], env) when is_list(path) do
    if atoms?(path), do: bind(env, path, resolve_path(path, env)), else: env
  end

  defp register_alias(_args, env), do: env

  # Bind the introduced name (the last segment of the *written* path) to the *resolved*
  # path. The name comes from what was written so an aliased single-segment target keeps
  # its written name even when resolution expands it (`alias X, as: Foo; alias Foo` binds
  # `Foo`, not `X`).
  defp bind(env, written, resolved), do: Map.put(env, List.last(written), resolved)

  # The `as:` target's single segment, or nil. Handles Sourceror's block-wrapped key.
  defp as_name(opts) when is_list(opts) do
    Enum.find_value(opts, fn
      {key, {:__aliases__, _, [name]}} when is_atom(name) -> if AST.key_atom(key) == :as, do: name
      _ -> nil
    end)
  end

  defp as_name(_opts), do: nil

  # Whether an opts list carries an `as:` key (Sourceror block-wrapped or plain) — gates
  # `require Mod, as: Name` into the alias machinery (a bare `require Mod` has none).
  defp has_as?(opts) do
    Enum.any?(opts, fn
      {key, _value} -> AST.key_atom(key) == :as
      _ -> false
    end)
  end

  defp atoms?(list), do: Enum.all?(list, &is_atom/1)
end
