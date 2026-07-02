defmodule Mutare.MacroRouting.Registry do
  @moduledoc false

  alias Mutare.Macro.Spec
  alias Mutare.MacroRouting.ContractError
  alias Mutare.MacroRouting.Registry.Entry
  alias Mutare.Mutator

  @builtin [
    {Kernel, :match?, 2, [:pattern, :expression]},
    {Kernel, :destructure, 2, [:binding_pattern, :expression]}
  ]

  @type selector :: {Spec.module_key(), atom(), non_neg_integer() | :any}
  @type host_subscription :: %{selector: selector(), module: module()}
  @type registry :: %__MODULE__{
          routes: %{optional(selector()) => Entry.t()},
          hosts: [host_subscription()]
        }

  @enforce_keys [:routes, :hosts]
  defstruct [:routes, :hosts]

  @spec builtin() :: [Entry.t()]
  def builtin,
    do: @builtin |> resolve() |> Enum.map(&Entry.static(&1, {:builtin, __MODULE__}))

  @spec resolve([Mutare.MacroRouting.route() | Spec.t()] | term()) :: [Spec.t()]
  def resolve(entries) when is_list(entries), do: Enum.map(entries, &resolve!/1)

  def resolve(other) do
    raise ArgumentError, ":macro_routes must be a list of route entries, got: #{inspect(other)}"
  end

  defp resolve!(%Spec{} = spec), do: spec
  defp resolve!({module, name, arity, args}), do: Spec.new(module, name, arity, args)
  defp resolve!({module, name, args}), do: Spec.new(module, name, :any, args)

  defp resolve!(other) do
    raise ArgumentError,
          "a macro route must be {module, name, arity, treatments} or " <>
            "{module, name, treatments}, got: #{inspect(other)}"
  end

  @spec from_mutators([Mutator.Spec.t()]) :: [Entry.t()]
  def from_mutators(mutator_specs) when is_list(mutator_specs) do
    mutator_specs
    |> modules()
    |> collect_routes(:mutator)
  end

  @spec from_extensions([Mutare.Extension.Spec.t() | module()]) :: [Entry.t()]
  def from_extensions(extensions) when is_list(extensions) do
    extensions
    |> Enum.map(&extension_module/1)
    |> Enum.uniq()
    |> collect_routes(:extension)
  end

  @spec build(
          [Mutare.MacroRouting.route() | Spec.t()],
          [Mutator.Spec.t()],
          [Mutare.Extension.Spec.t() | module()]
        ) :: registry()
  def build(config_routes, mutator_specs, extensions \\ []) do
    mutator_modules = modules(mutator_specs)
    hosts = collect_hosts(mutator_modules)

    config_entries =
      config_routes
      |> resolve()
      |> validate_config!()
      |> reject_duplicate_config!()

    config_keys = MapSet.new(config_entries, &Entry.key/1)

    code_routes =
      builtin() ++ from_mutators(mutator_specs) ++ from_extensions(extensions)

    routes =
      code_routes
      |> reject_config_overridden(config_keys)
      |> merge_code_routes()
      |> apply_config_routes(config_entries)

    validate_hosts!(routes, hosts)
    %__MODULE__{routes: routes, hosts: hosts}
  end

  @spec lookup(registry(), Spec.module_key() | nil, atom(), non_neg_integer()) :: Entry.t() | nil
  def lookup(%__MODULE__{routes: routes, hosts: hosts}, module_key, name, arity) do
    case lookup_route(routes, module_key, name, arity) do
      nil -> nil
      %Entry{} = entry -> %{entry | hosts: matching_hosts(hosts, {module_key, name, arity})}
    end
  end

  # Internal callers historically use `%{}` for "no registered macros" in focused resolver tests.
  # Keep that empty value accepted without making the registry representation public.
  def lookup(routes, module_key, name, arity) when is_map(routes) do
    lookup(%__MODULE__{routes: routes, hosts: []}, module_key, name, arity)
  end

  @spec entries(registry()) :: [Entry.t()]
  def entries(%__MODULE__{routes: routes, hosts: hosts}) do
    Enum.map(routes, fn {_key, entry} ->
      matching =
        hosts
        |> Enum.filter(&selectors_overlap?(Spec.key(entry.spec), &1.selector))
        |> Enum.map(& &1.module)
        |> Enum.uniq()

      %{entry | hosts: matching}
    end)
  end

  defp modules(mutator_specs), do: mutator_specs |> Enum.map(& &1.module) |> Enum.uniq()

  defp extension_module(%Mutare.Extension.Spec{module: module}), do: module
  defp extension_module(module) when is_atom(module), do: module

  defp collect_routes(modules, kind) do
    Enum.flat_map(modules, fn module ->
      has_routes? = exports?(module, :macro_routes, 0)
      has_router? = exports?(module, :route_arguments, 2)

      entries =
        if has_routes? do
          module
          |> invoke!(:macro_routes, 0, [])
          |> resolve_provider_routes!(module)
          |> Enum.map(&prepare_route!(&1, module, kind))
        else
          []
        end

      if has_router? and not Enum.any?(entries, &Spec.classifier?(&1.spec)) do
        contract_error!(
          provider: module,
          callback: {:route_arguments, 2},
          reason: :unused_callback,
          message:
            "#{inspect(module)} implements route_arguments/2 but registers no :routing route; " <>
              "add one to macro_routes/0 or remove the callback"
        )
      end

      entries
    end)
  end

  defp resolve_provider_routes!(routes, module) do
    resolve(routes)
  rescue
    error in ArgumentError ->
      contract_error!(
        provider: module,
        callback: {:macro_routes, 0},
        value: routes,
        reason: :invalid_routes,
        message: "#{inspect(module)} returned invalid macro routes: #{Exception.message(error)}"
      )
  end

  defp prepare_route!(spec, module, kind) do
    if Spec.classifier?(spec) and not exports?(module, :route_arguments, 2) do
      contract_error!(
        provider: module,
        route: Spec.key(spec),
        callback: {:route_arguments, 2},
        reason: :missing_callback,
        message:
          "#{inspect(module)} registers :routing for #{inspect(Spec.key(spec))} but does not " <>
            "implement route_arguments/2"
      )
    end

    %Entry{
      spec: spec,
      router: if(Spec.classifier?(spec), do: module),
      sources: [{kind, module}]
    }
  end

  defp collect_hosts(modules) do
    Enum.flat_map(modules, fn module ->
      has_host? = exports?(module, :host, 2)
      has_selectors? = exports?(module, :hosted_macros, 0)

      cond do
        has_host? and has_selectors? ->
          module
          |> invoke!(:hosted_macros, 0, [])
          |> resolve_host_selectors!(module)
          |> Enum.map(&%{selector: &1, module: module})

        has_host? ->
          contract_error!(
            provider: module,
            callback: {:hosted_macros, 0},
            reason: :missing_callback,
            message:
              "#{inspect(module)} implements host/2 but not hosted_macros/0; declare the macros " <>
                "the host subscribes to"
          )

        has_selectors? ->
          contract_error!(
            provider: module,
            callback: {:host, 2},
            reason: :missing_callback,
            message: "#{inspect(module)} implements hosted_macros/0 but not host/2"
          )

        true ->
          []
      end
    end)
  end

  defp resolve_host_selectors!([], module) do
    contract_error!(
      provider: module,
      callback: {:hosted_macros, 0},
      value: [],
      reason: :empty_selectors,
      message:
        "#{inspect(module)} hosted_macros/0 returned an empty list; a host mutator must " <>
          "subscribe to at least one macro"
    )
  end

  defp resolve_host_selectors!(selectors, module) when is_list(selectors) do
    Enum.map(selectors, fn
      {route_module, name} -> selector!(route_module, name, :any, module)
      {route_module, name, arity} -> selector!(route_module, name, arity, module)
      other -> invalid_selector!(module, other)
    end)
  end

  defp resolve_host_selectors!(other, module), do: invalid_selector!(module, other)

  defp selector!(module, name, arity, provider) do
    Spec.new(module, name, arity, :skip) |> Spec.key()
  rescue
    error in ArgumentError ->
      contract_error!(
        provider: provider,
        callback: {:hosted_macros, 0},
        value: {module, name, arity},
        reason: :invalid_selector,
        message:
          "#{inspect(provider)} returned an invalid hosted macro: #{Exception.message(error)}"
      )
  end

  @spec invalid_selector!(module(), term()) :: no_return()
  defp invalid_selector!(module, value) do
    contract_error!(
      provider: module,
      callback: {:hosted_macros, 0},
      value: value,
      reason: :invalid_selector,
      message:
        "#{inspect(module)} hosted_macros/0 must return {module, name} or " <>
          "{module, name, arity} selectors, got: #{inspect(value)}"
    )
  end

  defp merge_code_routes(entries) do
    Enum.reduce(entries, %{}, fn entry, routes ->
      Map.update(routes, Entry.key(entry), entry, &merge_code_entry!(&1, entry))
    end)
  end

  defp reject_config_overridden(entries, config_keys) do
    Enum.reject(entries, &MapSet.member?(config_keys, Entry.key(&1)))
  end

  defp merge_code_entry!(left, right) do
    cond do
      left.spec.args != right.spec.args ->
        conflict!(left, right, :conflicting_treatments)

      left.router && right.router && left.router != right.router ->
        conflict!(left, right, :conflicting_routers)

      true ->
        %{
          left
          | router: left.router || right.router,
            sources: Enum.uniq(left.sources ++ right.sources)
        }
    end
  end

  @spec conflict!(Entry.t(), Entry.t(), atom()) :: no_return()
  defp conflict!(left, right, reason) do
    contract_error!(
      route: Entry.key(left),
      value: %{left: left.sources, right: right.sources},
      reason: reason,
      message:
        "conflicting macro routes for #{inspect(Entry.key(left))} from " <>
          "#{inspect(left.sources)} and #{inspect(right.sources)}; identical static declarations " <>
          "coalesce, but incompatible treatments or dynamic routers require one owner"
    )
  end

  defp validate_config!(specs) do
    Enum.map(specs, fn spec ->
      cond do
        Spec.classifier?(spec) ->
          raise ArgumentError,
                "declarative :macro_routes entry #{inspect(Spec.key(spec))} uses :routing, which " <>
                  "requires macro_routes/0 and route_arguments/2 on an enabled provider"

        Spec.adapter_graded?(spec) ->
          raise ArgumentError,
                "declarative :macro_routes entry #{inspect(Spec.key(spec))} uses an " <>
                  "adapter-grade treatment (#{inspect(spec.args)}); :interpolated, :hosted, and " <>
                  "{:keyword, ...} assert DSL facts Mutare cannot check, so they must come from " <>
                  "a module implementing Mutare.MacroRouting (a :mutators or :extensions " <>
                  "entry), not from configuration"

        true ->
          %Entry{spec: spec, sources: [:config]}
      end
    end)
  end

  defp apply_config_routes(routes, config_entries) do
    Enum.reduce(config_entries, routes, fn entry, acc -> Map.put(acc, Entry.key(entry), entry) end)
  end

  defp reject_duplicate_config!(entries) do
    Enum.reduce(entries, {%{}, []}, fn entry, {seen, ordered} ->
      key = Entry.key(entry)

      if Map.has_key?(seen, key) do
        raise ArgumentError,
              "duplicate declarative :macro_routes entries for #{inspect(key)}; one explicit " <>
                "override per route is allowed"
      end

      {Map.put(seen, key, true), [entry | ordered]}
    end)
    |> elem(1)
    |> Enum.reverse()
  end

  defp validate_hosts!(routes, hosts) do
    Enum.each(routes, fn {_key, entry} ->
      if Spec.host_required?(entry.spec) and not any_covering_host?(entry.spec, hosts) do
        contract_error!(
          route: Entry.key(entry),
          reason: :missing_host,
          message:
            "macro route #{inspect(Entry.key(entry))} contains :hosted but no enabled " <>
              "Mutare.Mutator.MacroHost subscribes to it"
        )
      end
    end)

    Enum.each(hosts, fn host ->
      reachable? = host_reachable?(routes, host.selector)

      if not reachable? do
        contract_error!(
          provider: host.module,
          route: host.selector,
          callback: {:host, 2},
          reason: :unused_callback,
          message:
            "#{inspect(host.module)} subscribes to #{inspect(host.selector)}, but no active " <>
              ":hosted or :routing macro route can reach its host/2 callback"
        )
      end
    end)
  end

  defp any_covering_host?(spec, hosts),
    do: Enum.any?(hosts, &selector_covers?(&1.selector, Spec.key(spec)))

  defp matching_hosts(hosts, concrete),
    do:
      hosts
      |> Enum.filter(&selector_matches?(&1.selector, concrete))
      |> Enum.map(& &1.module)
      |> Enum.uniq()

  # A host is reachable only when some concrete call matching its selector resolves, through the
  # same specificity cascade as `lookup/4`, to a hosted or shape-aware route. Testing every route
  # constant plus one unmatched representative per wildcard dimension is exhaustive for this
  # equality/wildcard pattern language: calls within each resulting class have identical lookup
  # behaviour.
  defp host_reachable?(routes, {host_module, host_name, host_arity} = host_selector) do
    modules = witness_values(routes, 0, host_module, Spec.wildcard())
    names = witness_values(routes, 1, host_name, Spec.wildcard())
    arities = witness_values(routes, 2, host_arity, :any)

    Enum.any?(modules, fn module ->
      Enum.any?(names, fn name ->
        Enum.any?(arities, fn arity ->
          concrete = {module, name, arity}

          selector_matches?(host_selector, concrete) and
            case lookup_route(routes, module, name, arity) do
              %Entry{spec: spec} -> Spec.host_required?(spec) or Spec.classifier?(spec)
              nil -> false
            end
        end)
      end)
    end)
  end

  defp witness_values(_routes, _position, host_value, wildcard) when host_value != wildcard,
    do: [host_value]

  defp witness_values(routes, position, _host_value, wildcard) do
    values =
      routes
      |> Map.keys()
      |> Enum.map(&elem(&1, position))
      |> Enum.reject(&(&1 == wildcard))
      |> Enum.uniq()

    Enum.uniq(values ++ unmatched_witness(position, values))
  end

  # These sentinels cannot be valid normalized route slots, so unlike a made-up atom/integer they
  # are guaranteed not to collide with a user declaration. Lookup only compares them for equality
  # or against a wildcard, which is exactly the equivalence class they represent.
  defp unmatched_witness(0, _values), do: [nil]
  defp unmatched_witness(1, _values), do: [{:__mutare_unmatched__, :name}]
  defp unmatched_witness(2, _values), do: [-1]

  defp selector_matches?({module, name, arity}, {actual_module, actual_name, actual_arity}) do
    slot_matches?(module, actual_module, Spec.wildcard()) and
      slot_matches?(name, actual_name, Spec.wildcard()) and
      slot_matches?(arity, actual_arity, :any)
  end

  defp lookup_route(routes, module_key, name, arity) do
    wild = Spec.wildcard()

    Map.get(routes, {module_key, name, arity}) ||
      Map.get(routes, {module_key, name, :any}) ||
      Map.get(routes, {module_key, wild, :any}) ||
      Map.get(routes, {wild, name, arity}) ||
      Map.get(routes, {wild, name, :any})
  end

  defp selectors_overlap?({lm, ln, la}, {rm, rn, ra}) do
    slots_overlap?(lm, rm, Spec.wildcard()) and
      slots_overlap?(ln, rn, Spec.wildcard()) and
      slots_overlap?(la, ra, :any)
  end

  defp selector_covers?({hm, hn, ha}, {rm, rn, ra}) do
    slot_covers?(hm, rm, Spec.wildcard()) and
      slot_covers?(hn, rn, Spec.wildcard()) and
      slot_covers?(ha, ra, :any)
  end

  defp slot_matches?(wildcard, _actual, wildcard), do: true
  defp slot_matches?(expected, actual, _wildcard), do: expected == actual

  defp slots_overlap?(wildcard, _right, wildcard), do: true
  defp slots_overlap?(_left, wildcard, wildcard), do: true
  defp slots_overlap?(left, right, _wildcard), do: left == right

  defp slot_covers?(wildcard, _route, wildcard), do: true
  defp slot_covers?(host, route, _wildcard), do: host == route

  defp invoke!(module, fun, arity, args) do
    apply(module, fun, args)
  rescue
    error ->
      contract_error!(
        provider: module,
        callback: {fun, arity},
        reason: :callback_failed,
        message: "#{inspect(module)}.#{fun}/#{arity} failed: #{Exception.message(error)}"
      )
  end

  defp exports?(module, fun, arity),
    do: Code.ensure_loaded?(module) and function_exported?(module, fun, arity)

  @spec contract_error!(keyword()) :: no_return()
  defp contract_error!(opts), do: raise(ContractError, opts)
end
