defmodule Mutare.Macros do
  @moduledoc """
  The catalog of **known macros** — macros whose arguments the transform routes by
  a declared treatment instead of the default all-runtime descent.

  The counterpart to `Mutare.Mutators`, but for *argument routing* rather than node
  mutation. A `Mutare.Macro.Spec` says, per argument, whether it is an
  `:expression` (mutate), a `:pattern` (a match context — descend but don't mutate
  the pattern), `:skip` (leave raw — an opaque DSL body), or `:hosted` (leave raw for
  core, but deliver mutations through the registering mutator's selector host — the deep
  `Ecto.from`/`where` case; see `Mutare.Macro.Spec`). The per-argument treatment may also
  be a `:routing` classifier deferred to the mutator's `c:Mutare.Mutator.macro_routing/1`,
  for a treatment that depends on the call *shape*. Specs come from three sources, merged
  (later overrides earlier):

    * **built-ins** (`builtin/0`) — `Kernel.match?/2` and `Kernel.destructure/2`,
      both routing argument 0 as a pattern. Always on.
    * the declarative **`:macros`** option (`.mutare.exs` / `Mutare.run/2`) — a list
      of `{module, name, arity, treatment}` / `{module, name, treatment}` entries,
      resolved by `resolve/1`.
    * an optional **`c:Mutare.Mutator.macros/0`** callback on any enabled mutator
      (`from_mutators/1`) — so a library ships its custom mutator *and* the macro
      registration it relies on in one module, and the user adds a single
      `:mutators` entry. Mutare core never needs to know about the library.

  Resolution of declarative entries is **purely syntactic** (no reflection on the
  module), so a `{Ecto.Query, :from, :any, :skip}` entry resolves even when `Ecto`
  is not a dependency of the Mutare process.

  ## Wildcards (`:*`)

  Beyond a specific `{module, name, arity}`/`{module, name}` entry, the glob atom
  `:*` (`Mutare.Macro.Spec.wildcard/0`) wildcards a slot:

    * `{module, :*, treatment}` — a **whole module**: route *every* macro in `module`
      (e.g. `{Ecto.Query, :*, :skip}` to leave a whole query DSL raw). Override a
      single macro with a more specific entry on a separate line — `{Ecto.Query, :from,
      2, :hosted}` wins for `from/2` while the rest stay `:skip`.
    * `{:*, name, treatment}` — a **name-only escape hatch**: route a macro of that name
      no matter which module exports it. This is the fallback for when module resolution
      can't see the macro's module (a `use`-injected import, an alias Mutare can't follow);
      it is deliberately *not* the standard way to register a macro, and is consulted last
      (see `lookup/4`).

  See `Mutare.Macro.Spec` for the precedence and the wildcard validation rules.

  For the no-mutator case (just route a custom DSL's argument as a pattern, or
  leave a macro body opaque) the declarative `:macros` option is enough; a mutator
  that needs the routing usually ships it via `c:Mutare.Mutator.macros/0` instead.
  See `Mutare.Macro.Spec` for the per-argument treatments.
  """

  alias Mutare.Macro.Spec
  alias Mutare.Mutator

  # The built-in known macros, as plain `{module, name, arity, args}` tuples run
  # through the same `resolve/1` as user entries — one validation/normalization
  # path, like `Mutare.Mutators.all/0` derives from its `@registry`.
  #
  #   * `Kernel.match?(pattern, expr)` — arg 0 is a match context (it expands to
  #     `case expr do pattern -> true; _ -> false end`); a literal there is a
  #     pattern, not a value.
  #   * `Kernel.destructure(left, right)` — arg 0 is a list of variables matched
  #     against `right` (padding with `nil`), i.e. a pattern position. Its bindings
  #     **escape** into the enclosing scope (unlike `match?`'s, which are local to its
  #     `case` expansion), so it is `:binding_pattern` — additionally offered to the
  #     structural families in a value-discarded position (see `Mutare.Macro.Spec`).
  @builtin [
    {Kernel, :match?, 2, [:pattern, :expression]},
    {Kernel, :destructure, 2, [:binding_pattern, :expression]}
  ]

  @typedoc "A merged registry: a lookup from `{module_key, name, arity}` to its `Spec`."
  @type registry :: %{optional({Spec.module_key(), atom(), non_neg_integer() | :any}) => Spec.t()}

  @doc "The built-in known-macro specs (`Kernel.match?/2`, `Kernel.destructure/2`)."
  @spec builtin() :: [Spec.t()]
  def builtin, do: resolve(@builtin)

  @doc """
  Resolve a list of declarative macro entries into `Mutare.Macro.Spec`s.

  Each entry is a `{module, name, arity, treatment}` 4-tuple, a
  `{module, name, treatment}` 3-tuple (arity `:any`), or an already-resolved
  `%Mutare.Macro.Spec{}` (idempotent). The `module` and `name` may be the wildcard
  `:*` (a name-only escape hatch / a whole-module entry — see the moduledoc).
  Raises `ArgumentError` on a malformed entry.

      iex> [spec] = Mutare.Macros.resolve([{Ecto.Query, :from, :skip}])
      iex> {spec.module, spec.name, spec.arity, spec.args}
      {[:Ecto, :Query], :from, :any, :skip}
  """
  @spec resolve([tuple() | Spec.t()] | term()) :: [Spec.t()]
  def resolve(entries) when is_list(entries), do: Enum.map(entries, &resolve!/1)

  def resolve(other),
    do: raise(ArgumentError, ":macros must be a list of macro entries, got: #{inspect(other)}")

  defp resolve!(%Spec{} = spec), do: spec
  defp resolve!({module, name, arity, args}), do: Spec.new(module, name, arity, args)
  defp resolve!({module, name, args}), do: Spec.new(module, name, :any, args)

  defp resolve!(other) do
    raise ArgumentError,
          "a macro entry must be {module, name, arity, treatment} or {module, name, treatment}, " <>
            "got: #{inspect(other)}"
  end

  @doc """
  Collect macro specs contributed by enabled mutators via the optional
  `c:Mutare.Mutator.macros/0` callback.

  `mutator_specs` are resolved `Mutare.Mutator.Spec`s; each distinct module that is
  loaded and exports `macros/0` contributes its entries (resolved like declarative
  ones). A module is consulted once even if listed twice.
  """
  @spec from_mutators([Mutator.Spec.t()]) :: [Spec.t()]
  def from_mutators(mutator_specs) when is_list(mutator_specs) do
    mutator_specs
    |> Enum.map(& &1.module)
    |> Enum.uniq()
    |> Enum.filter(&exports_macros?/1)
    |> Enum.flat_map(fn module ->
      # Stamp the **hosting mutator** onto every spec the module contributes, so a
      # `:hosted`/`:routing` registration points back at that module's
      # `c:Mutare.Mutator.host/2` / `c:Mutare.Mutator.macro_routing/1` callbacks. Harmless
      # on an ordinary `:skip`/`:pattern` registration (host is only read for hosting).
      module.macros() |> resolve() |> Enum.map(&Spec.put_host(&1, module))
    end)
  end

  defp exports_macros?(module),
    do: Code.ensure_loaded?(module) and function_exported?(module, :macros, 0)

  @doc """
  Build the merged lookup registry from declarative `:macros` entries and the
  enabled mutator specs.

  Order is built-ins, then declarative `:macros`, then mutator-provided — collected
  with `Map.new`, so a later entry for the same `{module_key, name, arity}`
  overrides an earlier one (config and mutator-provided override built-ins).
  `config_macros` may be raw entries or already-resolved specs (idempotent).

      iex> registry = Mutare.Macros.build([{Ecto.Query, :from, :skip}], [])
      iex> Mutare.Macros.lookup(registry, [:Kernel], :match?, 2).args
      [:pattern, :expression]
      iex> Mutare.Macros.lookup(registry, [:Ecto, :Query], :from, 2).args
      :skip
  """
  @spec build([tuple() | Spec.t()], [Mutator.Spec.t()]) :: registry()
  def build(config_macros, mutator_specs) do
    (builtin() ++ resolve(config_macros) ++ from_mutators(mutator_specs))
    |> Enum.map(&validate_host/1)
    |> Map.new(&{Spec.key(&1), &1})
  end

  # A `:hosted` argument or the `:routing` classifier needs a hosting mutator to deliver /
  # answer it. `from_mutators/1` stamps the host for a mutator-contributed spec; a declarative
  # `:macros` entry (or a built-in) has none, so asking for hosting there is a configuration
  # error caught here rather than silently producing an un-deliverable mutant — or a cryptic
  # `UndefinedFunctionError` at resolve time — later. Checked at build (the host is an enabled,
  # loaded mutator), so a missing callback is named with a clear message.
  #
  # A `:routing` classifier needs `macro_routing/1` (called every resolve); a static `:hosted`
  # needs `host/2` (called to deliver). `host/2` is *not* demanded of a `:routing` spec at build —
  # a classifier may legitimately route only to `:expression`/`:pattern` and never host. But if it
  # *does* route a position `:hosted` without a `host/2` to deliver it, `Mutare.Transform.Resolve`
  # (`reject_undeliverable_hosted!/2`) raises loudly at resolve — the first point the undeliverable
  # `:hosted` is known — rather than silently leaving the fragment raw and dropping the mutation.
  defp validate_host(%Spec{} = spec) do
    cond do
      Spec.classifier?(spec) -> validate_host!(spec, :macro_routing, 1)
      Spec.host_required?(spec) -> validate_host!(spec, :host, 2)
      true -> :ok
    end

    spec
  end

  defp validate_host!(%Spec{host: host} = spec, fun, arity) do
    cond do
      is_nil(host) ->
        raise ArgumentError,
              "the macro entry #{inspect(Spec.key(spec))} uses a :hosted/:routing treatment, " <>
                "which needs a hosting mutator (implementing #{fun}/#{arity}) — register it via " <>
                "a mutator's macros/0, not the declarative :macros option"

      not (Code.ensure_loaded?(host) and function_exported?(host, fun, arity)) ->
        raise ArgumentError,
              "the hosting mutator #{inspect(host)} for macro #{inspect(Spec.key(spec))} must " <>
                "implement #{fun}/#{arity} for its :hosted/:routing treatment"

      true ->
        :ok
    end
  end

  @doc """
  The `Mutare.Macro.Spec` a call resolving to `module_key`/`name` at `arity` matches, or `nil`.
  Returns the whole spec, so `Mutare.Transform.Resolve` can read its `host`/`args` to resolve a
  `:routing` classifier or stamp a `:hosted` treatment with its hosting mutator. The per-position
  treatment list for a static spec is `Mutare.Macro.Spec.routing/2` of the result.

  Resolution is **most-specific-wins**, cascading from the exact entry down to the wildcards
  (`#{inspect(Spec.wildcard())}`, see `Mutare.Macro.Spec`):

    1. `{module, name, arity}` — the exact macro at the exact arity;
    2. `{module, name, :any}` — that macro at any arity;
    3. `{module, :*, :any}` — a **whole-module** entry (every macro in the module);
    4. `{:*, name, arity}` — a **name-only** entry at the exact arity;
    5. `{:*, name, :any}` — a name-only entry at any arity.

  So a module-specific entry always beats a whole-module one, which beats the name-only escape
  hatch — and the hatch is consulted last, never shadowing a module-matched (or built-in)
  treatment. A name-only entry fires even when `module_key` is `nil` (an unresolvable bare call),
  which is exactly the case it exists for.

      iex> registry = Mutare.Macros.build([{Foo, :*, :skip}, {Foo, :bar, 1, [:pattern]}], [])
      iex> # the whole-module entry catches any other macro in Foo…
      iex> Mutare.Macros.lookup(registry, [:Foo], :baz, 2).args
      :skip
      iex> # …but a specific {Foo, :bar, 1} entry wins for bar/1
      iex> Mutare.Macros.lookup(registry, [:Foo], :bar, 1).args
      [:pattern]

      iex> registry = Mutare.Macros.build([{:*, :sigil_X, :skip}], [])
      iex> # a name-only entry matches the name in any module (here even an unresolved one)
      iex> Mutare.Macros.lookup(registry, [:Whatever], :sigil_X, 1).args
      :skip
      iex> Mutare.Macros.lookup(registry, nil, :sigil_X, 2).args
      :skip
  """
  @spec lookup(registry(), Spec.module_key() | nil, atom(), non_neg_integer()) :: Spec.t() | nil
  def lookup(registry, module_key, name, arity) when is_map(registry) do
    wild = Spec.wildcard()

    Map.get(registry, {module_key, name, arity}) ||
      Map.get(registry, {module_key, name, :any}) ||
      Map.get(registry, {module_key, wild, :any}) ||
      Map.get(registry, {wild, name, arity}) ||
      Map.get(registry, {wild, name, :any})
  end
end
