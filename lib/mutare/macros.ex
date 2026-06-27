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
  be a `:routing` classifier deferred to the mutator's `c:Mutare.Mutator.MacroAware.macro_routing/1`,
  for a treatment that depends on the call *shape*. Specs come from **four** sources, merged
  in this order so a **later** entry wins a key:

    * **built-ins** (`builtin/0`) — `Kernel.match?/2` and `Kernel.destructure/2`,
      both routing argument 0 as a pattern. Always on.
    * an optional **`c:Mutare.Mutator.MacroAware.macros/0`** callback on any enabled mutator
      (`from_mutators/1`) — so a library ships its custom mutator *and* the macro
      registration it relies on in one module, and the user adds a single
      `:mutators` entry. Mutare core never needs to know about the library.
    * an optional **`c:Mutare.Plugin.macros/0`** callback on any enabled plugin
      (`from_plugins/1`) — the non-mutating counterpart, for a library that only
      teaches routing (e.g. a Gettext plugin). Folded after mutators, so a plugin
      wins a tie over a mutator.
    * the declarative **`:macros`** option (`.mutare.exs` / `Mutare.run/2`) — a list
      of `{module, name, arity, treatment}` / `{module, name, treatment}` entries,
      resolved by `resolve/1`. Folded **last**, so an explicit config entry is the
      final authority for a key (winning over a mutator's *or* a plugin's `macros/0`).

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
  that needs the routing usually ships it via `c:Mutare.Mutator.MacroAware.macros/0` instead.
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
  `c:Mutare.Mutator.MacroAware.macros/0` callback.

  `mutator_specs` are resolved `Mutare.Mutator.Spec`s; each distinct module that is
  loaded and exports `macros/0` contributes its entries (resolved like declarative
  ones). A module is consulted once even if listed twice.
  """
  @spec from_mutators([Mutator.Spec.t()]) :: [Spec.t()]
  def from_mutators(mutator_specs) when is_list(mutator_specs),
    do: mutator_specs |> Enum.map(& &1.module) |> collect_macros(&Spec.put_host/2)

  @doc """
  Collect macro specs contributed by enabled **plugins** via the optional
  `c:Mutare.Plugin.macros/0` callback — the plugin counterpart of `from_mutators/1`.

  `plugins` are resolved `Mutare.Plugin.Spec`s **or** bare modules (it extracts the module from
  each, mirroring `from_mutators/1`'s `& &1.module`, so either shape works); each that is loaded and
  exports `macros/0` contributes its entries (resolved exactly like a mutator's), so a plugin ships
  its DSL's argument routing alongside its `use` override. A module is consulted once even if listed
  twice.

  A plugin produces **no mutations**, so it cannot *host* one: a `:hosted` argument or a `:routing`
  classifier needs a hosting mutator's `host/2`/`macro_routing/1`. A plugin's `macros/0` declaring
  either is rejected here with a plugin-specific message — rather than letting `build/3`'s generic
  `validate_host!` abort the run calling the plugin a "hosting mutator" it can never be.
  """
  @spec from_plugins([Mutare.Plugin.Spec.t() | module()]) :: [Spec.t()]
  def from_plugins(plugins) when is_list(plugins) do
    specs = plugins |> Enum.map(&plugin_module/1) |> collect_macros()
    Enum.each(specs, &reject_plugin_hosting!/1)
    specs
  end

  defp plugin_module(%Mutare.Plugin.Spec{module: module}), do: module
  defp plugin_module(module) when is_atom(module), do: module

  # `Spec.host_required?/1` already covers both hosting treatments — `@host_required` is
  # `[:hosted, :routing]`, so a `:routing` classifier (whose `args` *is* `:routing`) reports
  # `host_required?` true — hence no separate `classifier?/1` check is needed here.
  defp reject_plugin_hosting!(%Spec{} = spec) do
    if Spec.host_required?(spec) do
      raise ArgumentError,
            "the plugin macro entry #{inspect(Spec.key(spec))} uses a :hosted/:routing treatment, " <>
              "but a plugin produces no mutations and cannot host one. Use " <>
              ":skip/:pattern/:binding_pattern/:expression, or register the hosting routing from a " <>
              "mutator's macros/0 instead."
    end
  end

  # Harvest `macros/0` from a list of modules (mutators or plugins): dedupe, keep the exporters,
  # resolve each module's entries, and apply `stamp` to each `{spec, contributing module}` pair. A
  # **mutator** passes `&Spec.put_host/2`, stamping the contributing module as the host so a
  # `:hosted`/`:routing` registration points back at its `c:Mutare.Mutator.MacroAware.host/2` /
  # `c:Mutare.Mutator.MacroAware.macro_routing/1`. A **plugin** keeps the default (no stamp): a plugin can never
  # host (`reject_plugin_hosting!` rejects a `:hosted`/`:routing` plugin entry off its `args`, not its
  # `host`), so its specs carry no host — keeping `Spec.host` a true invariant (a non-nil host always
  # names a real hosting mutator) instead of stamping a plugin as its own impossible host.
  defp collect_macros(modules, stamp \\ fn spec, _module -> spec end) do
    modules
    |> Enum.uniq()
    |> Enum.filter(&exports_macros?/1)
    |> Enum.flat_map(fn module ->
      module.macros() |> resolve() |> Enum.map(&stamp.(&1, module))
    end)
  end

  defp exports_macros?(module),
    do: Code.ensure_loaded?(module) and function_exported?(module, :macros, 0)

  @doc """
  Build the merged lookup registry from declarative `:macros` entries, the enabled
  mutator specs, and the enabled plugin modules.

  Order is built-ins, then mutator-provided, then plugin-provided, then declarative
  `:macros` — collected with `Map.new`, so a later entry for the same
  `{module_key, name, arity}` overrides an earlier one. An explicit `:macros` config
  entry is therefore the **final authority** for a key (it wins over a mutator's *or* a
  plugin's `macros/0`); among the code extensions a plugin wins a tie over a mutator;
  all three override the built-ins. So a user can always pin a macro's routing from
  `.mutare.exs`, even against an installed plugin — at the cost of being able to override
  a mutator's correctness-critical routing (e.g. an Ecto mutator's `{Ecto.Query, :from,
  :skip}`), which is a deliberate, explicit opt-in the poison backstop still guards.
  `config_macros` may be raw entries or already-resolved specs (idempotent);
  `plugins` are resolved `Mutare.Plugin.Spec`s or bare modules (it reads each's `macros/0`),
  and defaults to none.

      iex> registry = Mutare.Macros.build([{Ecto.Query, :from, :skip}], [])
      iex> Mutare.Macros.lookup(registry, [:Kernel], :match?, 2).args
      [:pattern, :expression]
      iex> Mutare.Macros.lookup(registry, [:Ecto, :Query], :from, 2).args
      :skip
  """
  @spec build([tuple() | Spec.t()], [Mutator.Spec.t()], [Mutare.Plugin.Spec.t() | module()]) ::
          registry()
  def build(config_macros, mutator_specs, plugins \\ []) do
    (builtin() ++
       from_mutators(mutator_specs) ++ from_plugins(plugins) ++ resolve(config_macros))
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
  # *does* route a position `:hosted` without a `host/2` to deliver it,
  # `Mutare.Transform.Resolve.MacroStamp` raises loudly at resolve — the first point the undeliverable
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
  Returns the whole spec, so the transform can read its `host`/`args` to resolve a
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
