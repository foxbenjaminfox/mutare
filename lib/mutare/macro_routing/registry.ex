defmodule Mutare.MacroRouting.Registry do
  @moduledoc """
  **Internal.** Not part of Mutare's public API — the public extension surface is the
  `Mutare.MacroRouting` / `Mutare.Mutator.MacroHost` behaviours and the `Mutare.Macro.Spec` entry
  forms. This module (and its `Entry`) is the registry that merges and resolves those declarations;
  its functions may change without notice.

  The catalog of **known macros** — macros whose arguments the transform routes by
  a declared treatment instead of the default all-runtime descent.

  The counterpart to `Mutare.Mutators`, but for *argument routing* rather than node
  mutation. A `Mutare.Macro.Spec` says, per argument, whether it is an
  `:expression` (mutate), a `:pattern` (a match context — descend but don't mutate
  the pattern), `:skip` (leave raw — an opaque DSL body), or `:hosted` (leave raw for
  core, but deliver mutations through the registering mutator's selector host — the deep
  `Ecto.from`/`where` case; see `Mutare.Macro.Spec`). The per-argument treatment may also
  be a `:routing` classifier deferred to its contributor's
  `c:Mutare.MacroRouting.macro_routing/2`, for a treatment that depends on the call *shape*.
  Specs come from **four** sources, merged
  in this order so a **later** entry wins a key:

  See `Mutare.Macro.Spec` for entry forms, treatments, and wildcard precedence.
  """

  alias Mutare.Macro.Spec
  alias Mutare.MacroRouting.Registry.Entry
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

  @typedoc "A merged registry: a lookup from `{module_key, name, arity}` to its resolved `Entry`."
  @type registry :: %{
          optional({Spec.module_key(), atom(), non_neg_integer() | :any}) => Entry.t()
        }

  @doc "The built-in known-macro entries (`Kernel.match?/2`, `Kernel.destructure/2`)."
  @spec builtin() :: [Entry.t()]
  def builtin, do: @builtin |> resolve() |> Enum.map(&Entry.static/1)

  @doc """
  Resolve a list of declarative macro entries into `Mutare.Macro.Spec`s.

  Each entry is a `{module, name, arity, treatment}` 4-tuple, a
  `{module, name, treatment}` 3-tuple (arity `:any`), or an already-resolved
  `%Mutare.Macro.Spec{}` (idempotent). The `module` and `name` may use `:*` for a
  name-only or whole-module wildcard.
  Raises `ArgumentError` on a malformed entry.

      iex> [spec] = Mutare.MacroRouting.Registry.resolve([{Ecto.Query, :from, :skip}])
      iex> {spec.module, spec.name, spec.arity, spec.args}
      {[:Ecto, :Query], :from, :any, :skip}
  """
  @spec resolve([tuple() | Spec.t()] | term()) :: [Spec.t()]
  def resolve(entries) when is_list(entries), do: Enum.map(entries, &resolve!/1)

  def resolve(other),
    do:
      raise(
        ArgumentError,
        ":macro_routes must be a list of route entries, got: #{inspect(other)}"
      )

  defp resolve!(%Spec{} = spec), do: spec
  defp resolve!({module, name, arity, args}), do: Spec.new(module, name, arity, args)
  defp resolve!({module, name, args}), do: Spec.new(module, name, :any, args)

  defp resolve!(other) do
    raise ArgumentError,
          "a macro entry must be {module, name, arity, treatment} or {module, name, treatment}, " <>
            "got: #{inspect(other)}"
  end

  @doc """
  Collect macro routes contributed by enabled mutators, as `Entry`s.

  `mutator_specs` are resolved `Mutare.Mutator.Spec`s; each distinct module that is
  loaded and exporting `c:Mutare.MacroRouting.macro_routes/0` contributes routes. A `:routing`
  entry is stamped with that module as its router. A static `:hosted` entry is stamped with it as
  its host after validating `c:Mutare.Mutator.MacroHost.host/2`. A classifier's host is attached
  only when the mutator exports `host/2`, because the need for hosting is shape-dependent. A module
  is consulted once even if configured more than once.

  A module whose `host/2` or `macro_routing/2` is never reached by any of its own routes is a
  silently-inert mistake (a typo'd or missing route), so it is rejected here rather than left dead.
  """
  @spec from_mutators([Mutator.Spec.t()]) :: [Entry.t()]
  def from_mutators(mutator_specs) when is_list(mutator_specs) do
    modules = mutator_specs |> Enum.map(& &1.module) |> Enum.uniq()
    entries = modules |> collect_routes(:macro_routes) |> Enum.map(&prepare_mutator_route!/1)
    Enum.each(modules, &reject_unused_callbacks!(&1, entries, :mutator))
    entries
  end

  @doc """
  Collect routes contributed by enabled non-mutating extensions, as `Entry`s.

  Extensions may provide static and shape-aware routes. They may not provide hosted
  routes because extensions do not emit mutations.
  """
  @spec from_extensions([Mutare.Extension.Spec.t() | module()]) :: [Entry.t()]
  def from_extensions(extensions) when is_list(extensions) do
    modules = extensions |> Enum.map(&extension_module/1) |> Enum.uniq()
    entries = modules |> collect_routes(:macro_routes) |> Enum.map(&prepare_extension_route!/1)
    Enum.each(modules, &reject_unused_callbacks!(&1, entries, :extension))
    entries
  end

  defp extension_module(%Mutare.Extension.Spec{module: module}), do: module
  defp extension_module(module) when is_atom(module), do: module

  defp prepare_mutator_route!({spec, module}) do
    cond do
      Spec.classifier?(spec) ->
        require_callback!(spec, module, :macro_routing, 2)
        host = if exports?(module, :host, 2), do: module
        %Entry{spec: spec, router: module, host: host}

      Spec.host_required?(spec) ->
        require_callback!(spec, module, :host, 2)
        %Entry{spec: spec, host: module}

      true ->
        Entry.static(spec)
    end
  end

  defp prepare_extension_route!({spec, module}) do
    cond do
      Spec.host_required?(spec) ->
        raise ArgumentError,
              "extension #{inspect(module)} returned hosted route #{inspect(Spec.key(spec))} " <>
                "from macro_routes/0. Extensions do not produce mutations and cannot host them; " <>
                "register this route from an enabled mutator implementing " <>
                "Mutare.Mutator.MacroHost."

      Spec.classifier?(spec) ->
        require_callback!(spec, module, :macro_routing, 2)
        %Entry{spec: spec, router: module}

      true ->
        Entry.static(spec)
    end
  end

  # #8 safety net: a callback that no route reaches is dead — the symptom of a typo'd or forgotten
  # route registration, which would otherwise leave the mutator silently inert. Caught at build,
  # named with the fix.
  defp reject_unused_callbacks!(module, entries, kind) do
    if kind == :mutator and exports?(module, :host, 2) and
         not Enum.any?(entries, &(&1.host == module)) do
      raise ArgumentError,
            "#{inspect(module)} implements Mutare.Mutator.MacroHost.host/2 but registers no " <>
              ":hosted or :routing macro route to deliver through it. Add a :hosted/:routing " <>
              "entry to macro_routes/0, or remove host/2."
    end

    if exports?(module, :macro_routing, 2) and not Enum.any?(entries, &(&1.router == module)) do
      raise ArgumentError,
            "#{inspect(module)} implements Mutare.MacroRouting.macro_routing/2 but registers no " <>
              ":routing macro route for it to classify. Add a {module, name, :routing} entry to " <>
              "macro_routes/0, or remove macro_routing/2."
    end
  end

  defp require_callback!(spec, module, fun, arity) do
    unless exports?(module, fun, arity) do
      raise ArgumentError,
            "macro-routing module #{inspect(module)} must implement #{fun}/#{arity} for route " <>
              inspect(Spec.key(spec))
    end
  end

  defp exports?(module, fun, arity),
    do: Code.ensure_loaded?(module) and function_exported?(module, fun, arity)

  # Return `{resolved_spec, contributing_module}` pairs so each capability boundary can validate
  # and stamp router/host provenance explicitly.
  defp collect_routes(modules, callback) do
    modules
    |> Enum.uniq()
    |> Enum.filter(fn module ->
      Code.ensure_loaded?(module) and function_exported?(module, callback, 0)
    end)
    |> Enum.flat_map(fn module ->
      module
      |> apply(callback, [])
      |> resolve()
      |> Enum.map(&{&1, module})
    end)
  end

  @doc """
  Builds the macro-route lookup registry.

  Sources are applied in this order:

      iex> registry = Mutare.MacroRouting.Registry.build([{Ecto.Query, :from, :skip}], [])
      iex> Mutare.MacroRouting.Registry.lookup(registry, [:Kernel], :match?, 2).spec.args
      [:pattern, :expression]
      iex> Mutare.MacroRouting.Registry.lookup(registry, [:Ecto, :Query], :from, 2).spec.args
      :skip
  """
  @spec build([tuple() | Spec.t()], [Mutator.Spec.t()], [Mutare.Extension.Spec.t() | module()]) ::
          registry()
  def build(config_routes, mutator_specs, extensions \\ []) do
    (builtin() ++
       from_mutators(mutator_specs) ++
       from_extensions(extensions) ++ validate_config!(resolve(config_routes)))
    |> Enum.map(&validate_providers/1)
    |> Map.new(&{Entry.key(&1), &1})
  end

  defp validate_config!(specs) do
    Enum.map(specs, fn spec ->
      cond do
        Spec.classifier?(spec) ->
          raise ArgumentError,
                "declarative :macro_routes entry #{inspect(Spec.key(spec))} uses :routing, " <>
                  "which requires macro_routes/0 and macro_routing/2 on an enabled " <>
                  "Mutare.MacroRouting module"

        Spec.host_required?(spec) ->
          raise ArgumentError,
                "declarative :macro_routes entry #{inspect(Spec.key(spec))} uses :hosted, " <>
                  "which requires macro_routes/0 on an enabled mutator implementing " <>
                  "Mutare.Mutator.MacroHost"

        true ->
          Entry.static(spec)
      end
    end)
  end

  # Final invariant check after every source has been normalized. Static routes need no callback
  # provider. A classifier needs a router; a static hosted route needs a host. Dynamic hosting is
  # checked after classification in `Resolve.MacroStamp`.
  defp validate_providers(%Entry{spec: spec} = entry) do
    cond do
      Spec.classifier?(spec) -> validate_provider!(entry, :router, :macro_routing, 2)
      Spec.host_required?(spec) -> validate_provider!(entry, :host, :host, 2)
      true -> :ok
    end

    entry
  end

  defp validate_provider!(%Entry{spec: spec} = entry, field, fun, arity) do
    provider = Map.fetch!(entry, field)

    cond do
      is_nil(provider) ->
        raise ArgumentError,
              "the macro entry #{inspect(Spec.key(spec))} needs a #{field} implementing " <>
                "#{fun}/#{arity}; register it through macro_routes/0 on an enabled module, not " <>
                "the declarative :macro_routes option"

      not exports?(provider, fun, arity) ->
        raise ArgumentError,
              "the macro #{field} #{inspect(provider)} for #{inspect(Spec.key(spec))} must " <>
                "implement #{fun}/#{arity} for its :hosted/:routing treatment"

      true ->
        :ok
    end
  end

  @doc """
  The `Entry` a call resolving to `module_key`/`name` at `arity` matches, or `nil`.
  Returns the whole entry, so the transform can read its `spec`/`router`/`host` to resolve a
  `:routing` classifier or stamp a `:hosted` treatment with its hosting mutator. The per-position
  treatment list for a static spec is `Mutare.Macro.Spec.routing/2` of `entry.spec`.

  Match precedence is:

    1. exact module, name, and arity
    2. exact module and name at any arity
    3. any macro in the exact module
    4. the exact name in any module at the exact arity
    5. the exact name in any module at any arity

  A name-only route may match when `module_key` is `nil`.

      iex> registry = Mutare.MacroRouting.Registry.build([{Foo, :*, :skip}, {Foo, :bar, 1, [:pattern]}], [])
      iex> # the whole-module entry catches any other macro in Foo…
      iex> Mutare.MacroRouting.Registry.lookup(registry, [:Foo], :baz, 2).spec.args
      :skip
      iex> # …but a specific {Foo, :bar, 1} entry wins for bar/1
      iex> Mutare.MacroRouting.Registry.lookup(registry, [:Foo], :bar, 1).spec.args
      [:pattern]

      iex> registry = Mutare.MacroRouting.Registry.build([{:*, :sigil_X, :skip}], [])
      iex> # a name-only entry matches the name in any module (here even an unresolved one)
      iex> Mutare.MacroRouting.Registry.lookup(registry, [:Whatever], :sigil_X, 1).spec.args
      :skip
      iex> Mutare.MacroRouting.Registry.lookup(registry, nil, :sigil_X, 2).spec.args
      :skip
  """
  @spec lookup(registry(), Spec.module_key() | nil, atom(), non_neg_integer()) :: Entry.t() | nil
  def lookup(registry, module_key, name, arity) when is_map(registry) do
    wild = Spec.wildcard()

    Map.get(registry, {module_key, name, arity}) ||
      Map.get(registry, {module_key, name, :any}) ||
      Map.get(registry, {module_key, wild, :any}) ||
      Map.get(registry, {wild, name, arity}) ||
      Map.get(registry, {wild, name, :any})
  end
end
