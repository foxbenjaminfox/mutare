defmodule Mutare.Transform.Aliases do
  @moduledoc false
  # Lexical `alias` resolution for the transform — and the contract by which a mutator
  # recognises an aliased remote call.
  #
  # The call-matching mutator families (Collection, StringCall, MapKeyword,
  # CollectionArity, ModeSwap, CallRemoval, DefaultDrop, Numeric) recognise a remote call
  # by its *literal* module path — `Enum.filter`, `String.upcase`. An `alias` rebinds that
  # path (`alias String, as: S; S.upcase(x)`), so without resolution the call hides from
  # every one of them — and worse, `alias MyApp.Enum` makes a *local* module masquerade as
  # the stdlib one, so a family would wrongly fire on it.
  #
  # `annotate/1` walks a parsed (Sourceror) AST once, accumulating a lexically-scoped alias
  # environment, and stamps each *call-module* alias node with the module it actually refers
  # to under `meta[:mutare_alias]` — but only when that differs from the written path, so an
  # unaliased call carries no new metadata. `resolved_module/2` is the reader the mutators
  # call: the stamped module, or the literal path when none. (An unknown atom meta key is
  # ignored by Sourceror's renderer and never reaches compilation, so the stamp is invisible
  # in both the metamutant and the diff — verified by tests.)
  #
  # The diff is preserved because only *recognition* uses the resolved module: a mutator
  # still rebuilds from the node's own (aliased) `__aliases__`, so `S.upcase(x)` mutates to
  # `S.downcase(x)`, never `String.downcase(x)`. (Every built-in swap keeps the module
  # anyway — `Enum`→`Enum`, `Map.put`→`Map.put_new` — so reusing the literal alias node is
  # always correct.)
  #
  # ## Scope and limits
  #
  #   * Handles `alias Foo.Bar`, `alias Foo.Bar, as: Baz`, and `alias Foo.{Bar, Baz}`.
  #   * An alias whose target is itself aliased is resolved through the env *before*
  #     binding, so the stored value is always the fully-expanded module — never another
  #     alias. `alias MyApp, as: String; alias String, as: S` binds `S` to `MyApp` (the
  #     real module), not the intermediate `String`, so a later `S.upcase` is not mistaken
  #     for a stdlib `String` call.
  #   * Lexical and textual: an alias applies only to siblings *after* it and to nested
  #     scopes (a nested `defmodule`/function body inherits the enclosing aliases); aliases
  #     declared inside a child scope do not leak back out. This falls out of folding the
  #     environment left-to-right over each statement sequence and passing it *down* into
  #     children without bringing a child's additions back up.
  #   * A `__MODULE__`-relative alias (`alias __MODULE__.Sub`) cannot be resolved to a
  #     concrete module statically, so it is skipped (it never names a stdlib module).
  #   * `import` is **not** resolved — that would need the imported module's export list and
  #     local-shadowing rules (reconstructing the compiler on unexpanded source), and
  #     `use`-injected aliases are invisible without macro expansion. Both out of scope.

  @meta_key :mutare_alias

  @doc "Annotate every call-module alias node with the module it resolves to."
  @spec annotate(Macro.t()) :: Macro.t()
  def annotate(ast), do: walk(ast, %{})

  @doc """
  The module a call's `__aliases__` refers to: the resolved path stamped by `annotate/1`,
  or the literal path when no alias applied. The reader half of the `:mutare_alias` contract.
  """
  @spec resolved_module(keyword(), [atom()]) :: [atom()]
  def resolved_module(alias_meta, literal_path) when is_list(alias_meta),
    do: Keyword.get(alias_meta, @meta_key, literal_path)

  def resolved_module(_alias_meta, literal_path), do: literal_path

  # --- the scoped walk -------------------------------------------------------

  # A statement sequence: fold the env left-to-right so an `alias` extends it for the
  # *subsequent* siblings only. Each statement is walked under the env in force *before*
  # it (so an alias resolves nothing in its own line, and order is textual).
  defp walk({:__block__, meta, stmts}, env) when is_list(stmts) do
    {walked, _env} =
      Enum.map_reduce(stmts, env, fn stmt, env ->
        {walk(stmt, env), register(stmt, env)}
      end)

    {:__block__, meta, walked}
  end

  # A remote call `Mod.fun(...)`: stamp the module position with its resolved path (only
  # when an alias changes it), then walk the arguments under the same env.
  defp walk({{:., dot_meta, [{:__aliases__, _am, path} = aliases, fun]}, call_meta, args}, env)
       when is_list(args) do
    aliases = stamp(aliases, resolve(path, env))
    {{:., dot_meta, [aliases, fun]}, call_meta, Enum.map(args, &walk(&1, env))}
  end

  defp walk({form, meta, args}, env) when is_list(args),
    do: {form, meta, Enum.map(args, &walk(&1, env))}

  defp walk({left, right}, env), do: {walk(left, env), walk(right, env)}

  defp walk(list, env) when is_list(list), do: Enum.map(list, &walk(&1, env))

  defp walk(node, _env), do: node

  # Stamp the resolved module onto the alias node's meta, but only when it differs from the
  # written path (an unaliased call keeps clean metadata).
  defp stamp({:__aliases__, meta, path} = node, resolved) do
    if resolved == path,
      do: node,
      else: {:__aliases__, [{@meta_key, resolved} | meta], path}
  end

  # Resolve a written path against the env: a first segment that is an aliased name expands
  # to its target, the remaining segments riding along. Anything else is verbatim.
  defp resolve([first | rest], env) when is_atom(first) do
    case Map.fetch(env, first) do
      {:ok, base} -> base ++ rest
      :error -> [first | rest]
    end
  end

  defp resolve(path, _env), do: path

  # --- alias directives ------------------------------------------------------

  # Extend the env with the binding(s) an `alias` statement introduces; every other
  # statement leaves it unchanged.
  defp register({:alias, _meta, args}, env), do: register_alias(args, env)
  defp register(_stmt, env), do: env

  # `alias Foo.{Bar, Baz}` — the multi-alias special form: each child rides on the base.
  # The base is resolved through the env first, so `alias X, as: Foo; alias Foo.{Bar}`
  # binds `Bar` to the real `X.Bar`, not the written `Foo.Bar`.
  defp register_alias([{{:., _, [{:__aliases__, _, base}, :{}]}, _, children} | _], env)
       when is_list(base) and is_list(children) do
    if atoms?(base) do
      resolved_base = resolve(base, env)

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

  # `alias Foo.Bar, as: Baz` — an explicit name overrides the last-segment default.
  defp register_alias([{:__aliases__, _, path}, opts], env) when is_list(path) do
    cond do
      not atoms?(path) -> env
      (name = as_name(opts)) != nil -> Map.put(env, name, resolve(path, env))
      true -> bind(env, path, resolve(path, env))
    end
  end

  # `alias Foo.Bar` — the introduced name is the last segment.
  defp register_alias([{:__aliases__, _, path}], env) when is_list(path) do
    if atoms?(path), do: bind(env, path, resolve(path, env)), else: env
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
      {key, {:__aliases__, _, [name]}} when is_atom(name) -> if key_atom(key) == :as, do: name
      _ -> nil
    end)
  end

  defp as_name(_opts), do: nil

  defp key_atom({:__block__, _, [atom]}), do: atom
  defp key_atom(atom) when is_atom(atom), do: atom
  defp key_atom(_), do: nil

  defp atoms?(list), do: Enum.all?(list, &is_atom/1)
end
