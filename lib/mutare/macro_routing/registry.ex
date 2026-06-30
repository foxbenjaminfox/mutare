defmodule Mutare.MacroRouting.Registry do
  @moduledoc """
  The merged catalog of known macro-argument routes.

  Routes come from built-ins, enabled mutators, enabled extensions, and the declarative
  `:macro_routes` option, in that order; later entries override earlier entries. Use
  `:macro_routes` to describe an application macro directly, or implement `Mutare.MacroRouting`
  when shipping routes in a mutator or extension.

  See `Mutare.Macro.Spec` for entry forms, treatments, and wildcard precedence.
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
  Returns routes contributed by enabled mutators.

  Each distinct loaded module is consulted once. Shape-aware routes record the
  module as their router. Hosted routes also require the module to implement
  `Mutare.Mutator.MacroHost`.
  """
  @spec from_mutators([Mutator.Spec.t()]) :: [Spec.t()]
  def from_mutators(mutator_specs) when is_list(mutator_specs) do
    mutator_specs
    |> Enum.map(& &1.module)
    |> collect_routes(:macro_routes)
    |> Enum.map(&prepare_mutator_route!/1)
  end

  @doc """
  Returns routes contributed by enabled extensions.

  Extensions may provide static and shape-aware routes. They may not provide hosted
  routes because extensions do not emit mutations.
  """
  @spec from_extensions([Mutare.Extension.Spec.t() | module()]) :: [Spec.t()]
  def from_extensions(extensions) when is_list(extensions) do
    extensions
    |> Enum.map(&extension_module/1)
    |> collect_routes(:macro_routes)
    |> Enum.map(&prepare_extension_route!/1)
  end

  defp extension_module(%Mutare.Extension.Spec{module: module}), do: module
  defp extension_module(module) when is_atom(module), do: module

  defp prepare_mutator_route!({spec, module}) do
    cond do
      Spec.classifier?(spec) ->
        require_callback!(spec, module, :macro_routing, 1)

        spec
        |> Spec.put_router(module)
        |> maybe_put_host(module)

      Spec.host_required?(spec) ->
        require_callback!(spec, module, :host, 2)
        Spec.put_host(spec, module)

      true ->
        spec
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
        require_callback!(spec, module, :macro_routing, 1)
        Spec.put_router(spec, module)

      true ->
        spec
    end
  end

  defp maybe_put_host(spec, module) do
    if exports?(module, :host, 2), do: Spec.put_host(spec, module), else: spec
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

    1. built-in routes
    2. routes from enabled mutators
    3. routes from enabled extensions
    4. declarative `:macro_routes` entries

  Later entries replace earlier entries with the same key, so declarative
  configuration has the highest precedence. Raw entries and resolved
  `Mutare.Macro.Spec` structs are accepted.

      iex> registry =
      ...>   Mutare.MacroRouting.Registry.build([{Ecto.Query, :from, :skip}], [])
      iex> Mutare.MacroRouting.Registry.lookup(registry, [:Kernel], :match?, 2).args
      [:pattern, :expression]
      iex> Mutare.MacroRouting.Registry.lookup(
      ...>   registry,
      ...>   [:Ecto, :Query],
      ...>   :from,
      ...>   2
      ...> ).args
      :skip
  """
  @spec build([tuple() | Spec.t()], [Mutator.Spec.t()], [Mutare.Extension.Spec.t() | module()]) ::
          registry()
  def build(config_routes, mutator_specs, extensions \\ []) do
    (builtin() ++
       from_mutators(mutator_specs) ++
       from_extensions(extensions) ++ validate_config!(resolve(config_routes)))
    |> Enum.map(&validate_providers/1)
    |> Map.new(&{Spec.key(&1), &1})
  end

  defp validate_config!(specs) do
    Enum.map(specs, fn spec ->
      cond do
        Spec.classifier?(spec) ->
          raise ArgumentError,
                "declarative :macro_routes entry #{inspect(Spec.key(spec))} uses :routing, " <>
                  "which requires macro_routes/0 and macro_routing/1 on an enabled " <>
                  "Mutare.MacroRouting module"

        Spec.host_required?(spec) ->
          raise ArgumentError,
                "declarative :macro_routes entry #{inspect(Spec.key(spec))} uses :hosted, " <>
                  "which requires macro_routes/0 on an enabled mutator implementing " <>
                  "Mutare.Mutator.MacroHost"

        true ->
          spec
      end
    end)
  end

  # Final invariant check after every source has been normalized. Static routes need no callback
  # provider. A classifier needs a router; a static hosted route needs a host. Dynamic hosting is
  # checked after classification in `Resolve.MacroStamp`.
  defp validate_providers(%Spec{} = spec) do
    cond do
      Spec.classifier?(spec) -> validate_provider!(spec, :router, :macro_routing, 1)
      Spec.host_required?(spec) -> validate_provider!(spec, :host, :host, 2)
      true -> :ok
    end

    spec
  end

  defp validate_provider!(%Spec{} = spec, field, fun, arity) do
    provider = Map.fetch!(spec, field)

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
  Returns the most specific macro spec matching `module_key`, `name`, and `arity`,
  or `nil`.

  Match precedence is:

    1. exact module, name, and arity
    2. exact module and name at any arity
    3. any macro in the exact module
    4. the exact name in any module at the exact arity
    5. the exact name in any module at any arity

  A name-only route may match when `module_key` is `nil`.

      iex> registry = Mutare.MacroRouting.Registry.build(
      ...>   [{Foo, :*, :skip}, {Foo, :bar, 1, [:pattern]}],
      ...>   []
      ...> )
      iex> Mutare.MacroRouting.Registry.lookup(registry, [:Foo], :baz, 2).args
      :skip
      iex> Mutare.MacroRouting.Registry.lookup(registry, [:Foo], :bar, 1).args
      [:pattern]
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
