defmodule Mutare.Transform.Resolve.MacroStamp do
  @moduledoc false

  # Known-macro routing stamp for the lexical resolve pass. `Resolve` decides what module a call
  # resolves to; this module turns a matched `Mutare.Macro.Spec` into the metadata the analyzer
  # later reads, including shape-aware classifier validation and pipe-position splitting.

  alias Mutare.MacroRouting.Registry, as: Macros
  alias Mutare.MacroRouting.Registry.Entry
  alias Mutare.MacroRouting.{ArgumentRoutes, Call, ContractError}
  alias Mutare.Mutator
  alias Mutare.Macro.Spec
  alias Mutare.Transform.{Calls, Imports, Meta}

  @doc """
  Stamp a call's meta with known-macro argument routing, when the registry matches it.
  """
  @spec stamp(
          keyword(),
          Spec.module_key() | nil,
          atom(),
          [Macro.t()],
          Macro.t(),
          Macros.registry(),
          Mutator.pipe_mode()
        ) :: keyword()
  def stamp(meta, module_key, fun, args, call_node, registry, pipe_mode) do
    arity = Mutator.effective_arity(args, pipe_mode)

    case Macros.lookup(registry, module_key, fun, arity) do
      nil ->
        meta

      %Entry{} = entry ->
        # A known macro routes its arguments specially, so a bare-import witness that rebuilds
        # the call as an anonymous function may be invalid. Drop the witness where the macro is
        # known; the resolution stamp itself stays.
        #
        # Stamp the resolved identity (`{module_key, name}`) *before* dispatching, and thread the
        # updated meta back onto `call_node` — so a `:routing` classifier (invoked *inside*
        # `stamp_spec`) that normalizes the node via `Mutare.Transform.Calls.resolved_macro_call/1`
        # already sees it. `module_key` is `nil` only for a name-only (`{:*, name, …}`) match whose
        # module the resolver couldn't see; the reader then returns `{nil, name, …}`, which a
        # module-matching classifier clause simply skips (its purpose — match by name instead).
        meta = stamp_identity(Imports.drop_witness(meta), module_key, fun, pipe_mode)
        stamp_spec(meta, entry, put_meta(call_node, meta), arity, pipe_mode)
    end
  end

  # Record the resolved macro identity on the call meta, read back by
  # `Mutare.Transform.Calls.resolved_macro_call/1`.
  defp stamp_identity(meta, module_key, fun, pipe_mode),
    do: Meta.stamp_macro_call(meta, {module_key, fun, pipe_mode})

  # Replace a call node's own (top) meta — `{head, _meta, args}` covers both the remote
  # (`head = {:., …}`) and bare (`head = fun`) shapes the resolver hands here.
  defp put_meta({head, _meta, args}, meta), do: {head, meta, args}

  # Compute and stamp a matched macro spec's per-position routing.
  #
  # Both static and dynamic declarations normalize to `ArgumentRoutes`: visible treatments align
  # exactly with the call node, while a piped LHS has its own explicit slot.
  defp stamp_spec(
         meta,
         %Entry{spec: %Spec{args: :routing} = spec, router: router} = entry,
         call_node,
         _arity,
         pipe_mode
       ) do
    call = resolved_call!(call_node, spec)
    routes = invoke_router!(router, call, spec, pipe_mode)
    routes = validate_routes!(spec, call, routes)
    stamp_routes(meta, attach_hosts!(routes, entry), spec)
  end

  defp stamp_spec(meta, %Entry{spec: spec} = entry, call_node, arity, _pipe_mode) do
    call = resolved_call!(call_node, spec)
    routes = ArgumentRoutes.from_effective(call, Spec.routing(spec, arity))
    stamp_routes(meta, attach_hosts!(routes, entry), spec)
  end

  defp resolved_call!(call_node, spec) do
    case Calls.resolved_macro_call(call_node) do
      %Call{} = call -> call
      nil -> contract_error!(route: Spec.key(spec), reason: :unresolved_call)
    end
  end

  defp invoke_router!(router, call, spec, pipe_mode) do
    router.route_arguments(call, %{pipe_mode: pipe_mode})
  rescue
    error ->
      contract_error!(
        provider: router,
        route: Spec.key(spec),
        callback: {:route_arguments, 2},
        value: error,
        reason: :callback_failed,
        message:
          "#{inspect(router)}.route_arguments/2 failed for #{inspect(Spec.key(spec))}: " <>
            Exception.message(error)
      )
  end

  defp validate_routes!(spec, call, routes) do
    case ArgumentRoutes.validate(routes, call) do
      :ok -> routes
      {:error, detail} -> invalid_routes!(spec, routes, detail)
    end
  end

  @spec invalid_routes!(Spec.t(), term(), String.t()) :: no_return()
  defp invalid_routes!(spec, value, detail) do
    contract_error!(
      route: Spec.key(spec),
      callback: {:route_arguments, 2},
      value: value,
      reason: :invalid_result,
      message:
        "route_arguments/2 for #{inspect(Spec.key(spec))} #{detail}, got: #{inspect(value)}"
    )
  end

  defp attach_hosts!(routes, %Entry{spec: spec, hosts: hosts}) do
    if routes_contain_hosted?(routes) and hosts == [] do
      contract_error!(
        route: Spec.key(spec),
        reason: :missing_host,
        message:
          "macro #{inspect(Spec.key(spec))} routes an argument as :hosted, but no enabled " <>
            "MacroHost subscribes to this concrete call"
      )
    end

    {
      Enum.map(ArgumentRoutes.visible(routes), &attach_hosts(&1, hosts)),
      attach_hosts(ArgumentRoutes.piped(routes), hosts)
    }
  end

  defp attach_hosts(:hosted, hosts), do: {:hosted, hosts}

  defp attach_hosts({:keyword, treatments}, hosts),
    do: {:keyword, Enum.map(treatments, &attach_hosts(&1, hosts))}

  defp attach_hosts(other, _hosts), do: other

  defp routes_contain_hosted?(routes),
    do:
      Enum.any?(ArgumentRoutes.visible(routes), &contains_hosted?/1) or
        contains_hosted?(ArgumentRoutes.piped(routes))

  defp contains_hosted?(:hosted), do: true
  defp contains_hosted?({:hosted, _hosts}), do: true
  defp contains_hosted?({:keyword, treatments}), do: Enum.any?(treatments, &contains_hosted?/1)
  defp contains_hosted?(_), do: false

  defp stamp_routes(meta, {visible, piped}, spec) do
    if contains_hosted?(piped) do
      contract_error!(
        route: Spec.key(spec),
        reason: :unhostable_pipe_argument,
        message:
          "macro #{inspect(Spec.key(spec))} routes the pipe's left side as :hosted, but host/2 " <>
            "receives only the visible macro call"
      )
    end

    meta = Meta.stamp_macro_routing(meta, visible)

    if is_nil(piped) or piped == :expression,
      do: meta,
      else: Meta.stamp_piped_macro_routing(meta, piped)
  end

  @spec contract_error!(keyword()) :: no_return()
  defp contract_error!(opts), do: raise(ContractError, opts)
end
