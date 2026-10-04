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
  # `Resolve` folds a lexically-scoped alias env with `register/3` and, at each remote call,
  # stamps the *call-module* `__aliases__` node with the module it actually refers to under
  # `meta[:mutare_alias]` via `stamp_module/3` — but only when that differs from the written
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
  #   * A **fully-qualified** `Elixir.`-prefixed path (`Elixir.String.first`) resolves to the
  #     bare module key (`[:String]`) — the leading `Elixir` segment is the alias-proof escape
  #     `Mutare.Transform.Calls.qualifier/1` itself emits, so without stripping it the call
  #     carries the key `[:Elixir, :String]`, matches no family swap table, and is silently
  #     never mutated. The strip is **env-free**: `Elixir.` ignores aliases, so under
  #     `alias Wrong, as: String` the prefixed call is still the real `String` while a *bare*
  #     `String.first` resolves to `Wrong` — the two deliberately differ. The **same**
  #     normalization is applied to a path *assembled* by alias expansion or a grouped alias,
  #     not only a literal prefix: `alias Elixir, as: E; E.String` and `alias Elixir.{String};
  #     String` both produce the combined key `[:Elixir, :String]`, which collapses to
  #     `[:String]` too — so a fully-qualified stdlib call reached through a root-namespace
  #     alias mutates like a direct one. A **doubled** prefix (`Elixir.Elixir.MyUse`, a module
  #     whose real first segment *is* `Elixir`) is the one exception: it is kept **whole**, not
  #     stripped, so `to_module/1`'s `Module.concat` folds the single canonical prefix and lands
  #     on `Elixir.MyUse` — stripping would collide with an aliased root namespace
  #     (`alias Elixir, as: E; E.MyUse`), which resolves to the same `[:Elixir, :MyUse]` but
  #     must fold to the bare `MyUse`.
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
  #   * A `__MODULE__`-led name (`__MODULE__`, `__MODULE__.Sub`) names the module it is written
  #     in, wherever it stands — an `alias` target (`alias __MODULE__.{A, B}` too), an `import`,
  #     `use` or `@behaviour` target, a call's receiver, a `defmodule` or `defimpl` head — so
  #     every reader here takes that module (`t:enclosing/0`) beside the alias env. The segments
  #     after `__MODULE__` are appended as written, never read through an alias, as the compiler
  #     does, and an `alias` without `as:` binds the last segment of the module named (`alias
  #     __MODULE__` inside `A.B` binds `B`). At a file's top level `__MODULE__` is `nil`, so
  #     `__MODULE__.Sub` is `Sub` and `__MODULE__` names nothing; where the module is unknown
  #     (`unresolved_module/0`) neither resolves.
  #   * `use`-injected aliases are surfaced by `Mutare.Transform.Uses` (it expands an
  #     expandable, static-arg, module-level `use` and folds the `alias`es it injects through
  #     `register/3`); a dynamic-arg or non-loadable `use`, or a non-`use` macro that injects an
  #     alias, stays invisible. `import` resolution is the sibling vocabulary in
  #     `Mutare.Transform.Imports`.

  alias Mutare.AST
  alias Mutare.Transform.MetaKeys

  @meta_key MetaKeys.alias_key()

  @typedoc """
  A resolved module reference: an Elixir-module **path** (`[:Enum]`, `[:String]`) or an
  Erlang-module **atom** (`:binary`, `:string`). The shape the module-key operations here
  (`resolve_path/3`, `to_module/1`, `resolve_node/3`, `resolved_module/2`) produce or consume,
  and the key the call-matching families table on. The single home for the type, referenced by
  `Mutare.Transform.{Calls, Imports, ImportWitness}` rather than each re-spelling `[atom()] |
  atom()`.
  """
  @type module_key :: [atom()] | atom()

  @unresolved :__mutare_unresolved__

  @typedoc """
  The module a statement is written in, as the module-scope walks thread it
  (`Mutare.Transform.ModuleScope`, `Mutare.Lifting`): the module, `nil` at a file's top level,
  or `unresolved_module/0` under a `defmodule` head that names no module statically (`unquote`,
  `Module.concat(…)`), and so under everything nested in one. `__MODULE__` reads it.
  """
  @type enclosing :: module() | nil

  @doc """
  The `t:enclosing/0` value for a module that cannot be known statically. Distinct from
  `nil`: a name resolved by the top-level rules beneath a dynamic head would land on an
  unrelated module.
  """
  @spec unresolved_module() :: :__mutare_unresolved__
  def unresolved_module, do: @unresolved

  @doc """
  The module a call's `__aliases__` refers to: the resolved path stamped by
  `stamp_module/3`, or the literal path when no alias applied. The reader half of the
  `:mutare_alias` contract. For a `__MODULE__` receiver, pass `nil` as the literal path: it
  has none, and is `nil` where `stamp_module/3` could not name its module.
  """
  @spec resolved_module(keyword(), [atom()] | nil) :: module_key() | nil
  def resolved_module(alias_meta, literal_path) when is_list(alias_meta),
    do: Keyword.get(alias_meta, @meta_key, literal_path)

  def resolved_module(_alias_meta, literal_path), do: literal_path

  @doc """
  Resolve a written module path against an alias env: a first segment that is an
  aliased name expands to its target, the remaining segments riding along, and a leading
  `__MODULE__` is the `enclosing` module (see the moduledoc). Anything else is verbatim,
  a `__MODULE__`-led path whose module is not known included. Exposed so the `import` pre-pass
  (`Mutare.Transform.Imports`) can resolve an `import E` (where `E` is an alias)
  through the *same* lexical alias environment, never reimplementing it.

  A binding may be an Elixir-module **path** (`[:String]`) or an Erlang-module **atom**
  (`:binary`, from `alias :binary, as: B`). An atom binding resolves a lone segment
  (`B` → `:binary`); a trailing segment after it (`B.Sub`) is not a real module, so it is
  left unresolved.
  """
  @spec resolve_path([atom()] | term(), map(), enclosing()) :: module_key() | term()
  def resolve_path([{:__MODULE__, _meta, context} | rest] = path, _env, enclosing)
      when is_atom(context) do
    case beneath_module(enclosing, rest) do
      {:ok, key} -> key
      :error -> path
    end
  end

  # A literal `Elixir.`-prefixed written path (`Elixir.String`, `Elixir.Elixir.MyUse`) is the
  # **fully-qualified, alias-proof** form — `Elixir.` ignores every alias in scope (it's exactly
  # what `Mutare.Transform.Calls.qualifier/1` emits to dodge a rebinding alias). Normalize it
  # **env-free**: `alias Wrong, as: String; Elixir.String.first(s)` still resolves to the real
  # `String`, whereas a *bare* `String.first` resolves to `Wrong` (below) — the two deliberately
  # differ. The `[:"Elixir", _ | _]` shape (two+ segments) is required so a *lone* `Elixir` (the
  # root namespace, never a call target) falls through to the env-consulting clause unchanged.
  def resolve_path([:"Elixir", _ | _] = path, _env, _enclosing), do: normalize(path)

  def resolve_path([first | rest], env, _enclosing) when is_atom(first) do
    case Map.fetch(env, first) do
      # An alias expands to its bound base; **normalize the combined path** because the base may
      # itself be — or end on — the root namespace. `alias Elixir, as: E; E.String` and
      # `alias Elixir.{String}; String` both assemble `[Elixir, :String]`, which must collapse to
      # the bare `[:String]` the call families key on, exactly as a literal `Elixir.String` does.
      # (Without this, a fully-qualified stdlib call reached through such an alias matched no swap
      # table and silently produced no mutants.)
      {:ok, base} when is_list(base) -> normalize(base ++ rest)
      {:ok, base} when is_atom(base) and rest == [] -> base
      {:ok, _base} -> [first | rest]
      :error -> [first | rest]
    end
  end

  def resolve_path(path, _env, _enclosing), do: path

  # `__MODULE__` followed by the written `rest`, as the compiler reads it: the segments are
  # appended to the enclosing module, none of them read through an alias. Beneath an
  # Erlang-atom module the result is the quoted atom the compiler makes (`:"Elixir.foo.Sub"`).
  # At the top level `__MODULE__` is `nil`, which names no module alone and drops out of a
  # longer name.
  defp beneath_module(@unresolved, _rest), do: :error
  defp beneath_module(nil, []), do: :error

  defp beneath_module(enclosing, rest) when is_atom(enclosing) do
    if atoms?(rest),
      do:
        {:ok, from_module(if rest == [], do: enclosing, else: Module.concat([enclosing | rest]))},
      else: :error
  end

  # Strip the single leading `Elixir` **canonical prefix** off an assembled module key so it
  # matches the bare key the call families and `to_module/1` expect (`[Elixir, :String]` →
  # `[:String]`). A **doubled** prefix is kept whole: `Elixir.Elixir.MyUse` names a module whose
  # real first segment *is* `Elixir` (the module `Elixir.MyUse`), and `to_module/1`'s
  # `Module.concat` folds exactly one leading `Elixir`, so the kept path lands on it — stripping
  # would leave `[:Elixir, :MyUse]`, colliding with an aliased root namespace (which must fold to
  # the bare `MyUse`), an ambiguity `to_module/1` can't undo. A **lone** `Elixir` (the root
  # namespace) and any non-`Elixir`-led path are left untouched.
  defp normalize([:"Elixir", :"Elixir" | _] = path), do: path
  defp normalize([:"Elixir" | rest]) when rest != [], do: rest
  defp normalize(other), do: other

  @doc """
  Extend an alias env with the binding(s) a statement introduces. An `alias` directive
  changes it, **and so does a `require Mod, as: Name`** — Elixir's `:as` on `require` "sets
  up an alias" exactly like `alias/2`, so `require String, as: S; S.upcase(x)` resolves
  `S` to `String`. A bare `require Mod` (no `as:`) brings macros into scope but introduces
  no name, and every other statement passes through unchanged. `enclosing` is the module the
  statement is written in, which a `__MODULE__`-led target names.
  The unified resolution walk (`Mutare.Transform.Resolve`) folds the alias env with this as it
  descends each statement sequence; `Mutare.Transform.Behaviours` and `Mutare.Transform.Uses`
  fold it too.
  """
  @spec register(Macro.t(), map(), enclosing()) :: map()
  def register({:alias, _meta, args}, env, module), do: register_alias(args, env, module)

  # `require Mod, as: Name` aliases identically to `alias Mod, as: Name` (same arg shape:
  # `[mod_ast, opts]`), so it delegates to `register_alias/3` — but only when an `as:` is
  # present; a bare `require Mod` introduces no alias.
  def register({:require, _meta, [mod_ast, opts]}, env, module) when is_list(opts) do
    if as_name(opts), do: register_alias([mod_ast, opts], env, module), else: env
  end

  def register(_stmt, env, _module), do: env

  @doc """
  Stamp a call's `__aliases__` module node with the module it resolves to under the env,
  but only when that differs from the written path (an unaliased call keeps clean
  metadata). The write half of the `:mutare_alias` contract; called by
  `Mutare.Transform.Resolve` at each remote call, where a `__MODULE__` receiver is stamped
  with the `enclosing` module.
  """
  @spec stamp_module(Macro.t(), map(), enclosing()) :: Macro.t()
  def stamp_module({:__aliases__, _meta, path} = node, env, enclosing),
    do: stamp(node, resolve_path(path, env, enclosing))

  # A `__MODULE__` receiver has no written path to fall back on, so it is stamped whenever its
  # module is known.
  def stamp_module({:__MODULE__, meta, context} = node, _env, enclosing)
      when is_list(meta) and is_atom(context) do
    case beneath_module(enclosing, []) do
      {:ok, key} -> {:__MODULE__, [{@meta_key, key} | meta], context}
      :error -> node
    end
  end

  def stamp_module(node, _env, _enclosing), do: node

  # Stamp the resolved module onto the alias node's meta, but only when it differs from the
  # written path (an unaliased call keeps clean metadata).
  defp stamp({:__aliases__, meta, path} = node, resolved) do
    if resolved == path,
      do: node,
      else: {:__aliases__, [{@meta_key, resolved} | meta], path}
  end

  # --- alias directives ------------------------------------------------------

  # `alias Foo.{Bar, Baz}` — the multi-alias special form: each child rides on the base, and is
  # bound under its own last segment. The base is resolved first, so `alias X, as: Foo;
  # alias Foo.{Bar}` binds `Bar` to the real `X.Bar`, not the written `Foo.Bar`. A base that
  # names an Erlang-atom module has nothing beneath it, so it binds nothing.
  defp register_alias([{{:., _, [base, :{}]}, _, children} | _], env, module)
       when is_list(children) do
    case target(base, env, module) do
      {:ok, _name, resolved_base} when is_list(resolved_base) ->
        Enum.reduce(children, env, fn
          # `normalize/1`: the assembled child target may lead with the root namespace
          # (`alias Elixir.{String}` assembles `[Elixir, :String]`), which must collapse to the
          # bare key — exactly the combined-path normalization the resolution clause applies.
          {:__aliases__, _, seg}, env when is_list(seg) ->
            if atoms?(seg),
              do: Map.put(env, List.last(seg), normalize(resolved_base ++ seg)),
              else: env

          _other, env ->
            env
        end)

      _ ->
        env
    end
  end

  # `alias Foo.Bar` / `alias Foo.Bar, as: Baz` — an explicit `as:` name overrides the default.
  defp register_alias([target_ast], env, module),
    do: bind(env, target(target_ast, env, module), nil)

  defp register_alias([target_ast, opts], env, module),
    do: bind(env, target(target_ast, env, module), as_name(opts))

  defp register_alias(_args, env, _module), do: env

  defp bind(env, {:ok, default, resolved}, as) do
    case as || default do
      nil -> env
      name -> Map.put(env, name, resolved)
    end
  end

  defp bind(env, :error, _as), do: env

  # A written alias target → `{:ok, default_name, module_key}`, or `:error` when it names no
  # module statically. The key is always fully expanded, never another alias: `alias MyApp, as:
  # String; alias String, as: S` binds `S` to `MyApp`, so a later `S.upcase` is not mistaken for
  # a stdlib `String` call. The default name is the last *written* segment, so an aliased
  # single-segment target keeps its written name (`alias X, as: Foo; alias Foo` binds `Foo`),
  # except under `__MODULE__`, whose own name is the last segment of the enclosing module. An
  # Erlang atom (`alias :binary, as: B`) has no segment to default the name from, so it binds
  # only with an `as:`.
  defp target({:__aliases__, _, [{:__MODULE__, _, context} | rest]}, _env, enclosing)
       when is_atom(context),
       do: target_beneath(enclosing, rest)

  defp target({:__MODULE__, _, context}, _env, enclosing) when is_atom(context),
    do: target_beneath(enclosing, [])

  defp target({:__aliases__, _, path}, env, enclosing) when is_list(path) do
    if atoms?(path), do: {:ok, List.last(path), resolve_path(path, env, enclosing)}, else: :error
  end

  defp target({:__block__, _, [atom]}, _env, _module) when is_atom(atom), do: {:ok, nil, atom}
  defp target(_ast, _env, _module), do: :error

  # Beneath an Erlang-atom module the key is a quoted atom, with no segment to default the
  # name from, so it binds only with an `as:`.
  defp target_beneath(enclosing, rest) do
    case beneath_module(enclosing, rest) do
      {:ok, key} -> {:ok, if(is_list(key), do: List.last(key)), key}
      :error -> :error
    end
  end

  # The `as:` target's single segment, or nil. Handles Sourceror's block-wrapped key, and keeps
  # only a single-segment alias value (`as: Foo`) — a multi-segment or non-alias `as:` yields nil.
  defp as_name(opts) when is_list(opts) do
    case AST.opts_get(opts, :as) do
      {:__aliases__, _, [name]} when is_atom(name) -> name
      _ -> nil
    end
  end

  defp as_name(_opts), do: nil

  @doc """
  Whether every element is an atom — i.e. a segment list is a valid module-key **path**
  (`[:Foo, :Bar]`). The guard the `alias`/`import` vocabulary uses before treating a
  segment list as a module path. Public so `Mutare.Transform.Imports` shares the one
  definition instead of reimplementing it.
  """
  @spec atoms?(term()) :: boolean()
  def atoms?(list) when is_list(list), do: Enum.all?(list, &is_atom/1)
  def atoms?(_other), do: false

  @doc """
  A module **key** — an Elixir path (`[:Enum]`) or an Erlang atom (`:binary`) — to its
  concrete module atom: a path is `Module.concat`-ed, an atom is itself, any other shape
  (never a real key) is `nil`. The follow-on to `resolve_path/3`: the import/use/behaviour
  pre-passes all do `path |> resolve_path(env, enclosing) |> to_module()` to land on the
  runtime module.

  A plain `Module.concat` is exactly right and needs **no** leading-`Elixir` compensation:
  `resolve_path/3` already normalizes the key it hands back — a single canonical `Elixir`
  prefix is stripped (`[:String]`), a *doubled* one (a real `Elixir` segment) is kept whole
  (`[:Elixir, :Elixir, :MyUse]`) — so `Module.concat` lands correctly either way (folding the
  one canonical prefix off a doubled key → `Elixir.MyUse`). A path reaching here therefore
  never carries a *single* leading `Elixir`; compensating for one would wrongly double-fold a
  genuine doubled prefix. The canonical-prefix disambiguation lives in `resolve_path/3`, not
  here.
  """
  @spec to_module(module_key() | term()) :: module() | nil
  def to_module(path) when is_list(path), do: Module.concat(path)
  def to_module(atom) when is_atom(atom), do: atom
  def to_module(_other), do: nil

  @doc """
  A concrete module atom → its module **key**, the inverse of `to_module/1`: an Elixir
  module becomes its segment path (`Ecto.Query` → `[:Ecto, :Query]`), an Erlang-module
  atom stays itself (`:binary` → `:binary`). The one encoding of the key representation,
  published to authors as `Mutare.Calls.module_key/1` so they can compare configured
  modules against resolved calls. (`Mutare.CallRouting.Spec.normalize_module/1` mirrors it for
  registry input — kept separate, like the `module_key` type, because that layer stays
  free of any dependency on the transform.)
  """
  @spec from_module(module()) :: module_key()
  def from_module(module) when is_atom(module) do
    case Macro.classify_atom(module) do
      :alias -> module |> Module.split() |> Enum.map(&String.to_atom/1)
      _ -> module
    end
  end

  @doc """
  A module **reference node** → its concrete module atom, or `nil`. Resolves the shapes a
  module reference takes in the AST: an Elixir alias path (`{:__aliases__, _, segments}`,
  resolved through the alias `env` and the `enclosing` module then `Module.concat`-ed — a
  non-static segment yields `nil`), `__MODULE__` (the `enclosing` module), a Sourceror-wrapped
  atom (`{:__block__, _, [:gen_server]}`), and a bare atom — the latter two being Erlang-style
  modules taken as-is.

  The single home for the "AST node + env → module" step the `use`/`@behaviour`/`import`
  pre-passes need, composing `resolve_path/3` with `to_module/1`.
  """
  @spec resolve_node(Macro.t(), map(), enclosing()) :: module() | nil
  def resolve_node({:__aliases__, _meta, path}, env, enclosing) when is_list(path) do
    case resolve_path(path, env, enclosing) do
      atom when is_atom(atom) -> atom
      key -> if atoms?(key), do: to_module(key)
    end
  end

  def resolve_node({:__MODULE__, _meta, context}, _env, enclosing) when is_atom(context) do
    case beneath_module(enclosing, []) do
      {:ok, key} -> to_module(key)
      :error -> nil
    end
  end

  def resolve_node({:__block__, _meta, [atom]}, _env, _enclosing) when is_atom(atom), do: atom
  def resolve_node(atom, _env, _enclosing) when is_atom(atom), do: atom
  def resolve_node(_other, _env, _enclosing), do: nil
end
