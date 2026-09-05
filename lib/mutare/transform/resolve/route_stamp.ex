defmodule Mutare.Transform.Resolve.RouteStamp do
  @moduledoc false

  # Known-macro routing stamp for the lexical resolve pass. `Resolve` decides what module a call
  # resolves to; this module turns a matched `Mutare.CallRouting.Spec` into the metadata the analyzer
  # later reads, including shape-aware classifier validation and pipe-position splitting.

  alias Mutare.CallRouting.Registry, as: Routes
  alias Mutare.CallRouting.Registry.Entry
  alias Mutare.CallRouting.{ArgumentRoutes, Call, ContractError}
  alias Mutare.Mutator
  alias Mutare.CallRouting.Spec
  alias Mutare.Transform.Analyze.CallOptions
  alias Mutare.Transform.{Calls, Imports, Meta}

  @typep diag :: %{warn?: boolean(), file: String.t()}

  @doc """
  Stamp a call's meta with known-macro argument routing, when the registry matches it.

  `diag` carries the pass's diagnostics wiring (whether advisory warnings print, and the
  file that labels them) — see `Mutare.Transform.Resolve.annotate/3`.
  """
  @spec stamp(
          keyword(),
          Spec.module_key() | nil,
          atom(),
          [Macro.t()],
          Macro.t(),
          Routes.registry(),
          Mutator.pipe_mode(),
          diag()
        ) :: keyword()
  def stamp(meta, module_key, fun, args, call_node, registry, pipe_mode, diag) do
    arity = Mutator.effective_arity(args, pipe_mode)

    case Routes.lookup(registry, module_key, fun, arity) do
      nil ->
        meta

      %Entry{} = entry ->
        # A known macro routes its arguments specially, so a bare-import witness that rebuilds
        # the call as an anonymous function may be invalid. Drop the witness where the macro is
        # known; the resolution stamp itself stays.
        #
        # Stamp the resolved identity (`{module_key, name}`) *before* dispatching, and thread the
        # updated meta back onto `call_node` — so a `:routing` classifier (invoked *inside*
        # `stamp_spec`) that normalizes the node via `Mutare.Transform.Calls.resolved_routed_call/1`
        # already sees it. `module_key` is `nil` only for a name-only (`{:*, name, …}`) match whose
        # module the resolver couldn't see; the reader then returns `{nil, name, …}`, which a
        # module-matching classifier clause simply skips (its purpose — match by name instead).
        meta = stamp_identity(Imports.drop_witness(meta), module_key, fun, pipe_mode)
        stamp_spec(meta, entry, put_meta(call_node, meta), arity, pipe_mode, diag)
    end
  end

  # Record the resolved macro identity on the call meta, read back by
  # `Mutare.Transform.Calls.resolved_routed_call/1`.
  defp stamp_identity(meta, module_key, fun, pipe_mode),
    do: Meta.stamp_routed_call(meta, {module_key, fun, pipe_mode})

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
         pipe_mode,
         diag
       ) do
    call = resolved_call!(call_node, spec)
    routes = invoke_router!(router, call, spec, pipe_mode)
    routes = validate_routes!(spec, call, routes)
    warn_misshapen_keyword_routes(diag, router, spec, call, routes)
    stamp_routes(meta, attach_hosts!(routes, entry), spec)
  end

  # The call-level `:skip`: the whole call is an inert leaf. Stamp the bare `:skip` (not a
  # per-position list) so every reader sees one distinguished value — `Mutare.Transform.Analyze`
  # leaves the node raw without offering it, `Mutare.Transform.Tag` does the same in a guard, and
  # `Mutare.Transform.Calls.routed_treatments/1` reports `:skip`. No piped stamp is written: a piped
  # receiver is the `|>`'s left operand, a sibling of the skipped call rather than part of it, so it
  # is analyzed as ordinary runtime (a `Repo.insert!(u) |> Mixpanel.track(…)` keeps its mutants).
  defp stamp_spec(meta, %Entry{spec: %Spec{args: :skip}}, _call_node, _arity, _pipe_mode, _diag),
    do: Meta.stamp_routing(meta, :skip)

  defp stamp_spec(meta, %Entry{spec: spec} = entry, call_node, arity, _pipe_mode, _diag) do
    call = resolved_call!(call_node, spec)
    routes = ArgumentRoutes.from_effective(call, Spec.routing(spec, arity))
    stamp_routes(meta, attach_hosts!(routes, entry), spec)
  end

  # Advisory (dynamic path only): a `:routing` classifier that returns `{:keyword, …}` for an
  # argument that is not a literal keyword list is almost certainly buggy — unlike a static
  # route, it *saw* the concrete argument and classified it anyway. The analyzer's shape
  # fallback still leaves the argument raw (never poison, never splice into a non-pair — see
  # `Mutare.Transform.Analyze.Routed`), so this can't be a hard error; but silent raw-ness
  # reads as "no mutants here", so name the classifier while the author is looking. Static
  # routes stay silent on purpose: their non-keyword call sites are legitimate polymorphic
  # macro forms (`set(q, opts)`, `where(q, ^dyn)`), not mistakes.
  #
  # The walk mirrors the analyzer's: unwrap the Sourceror `{:__block__, _, [list]}` a keyword
  # value takes, recurse into nested `{:keyword, …}` value treatments (zip truncates — a
  # keyword-shaped length mismatch is the analyzer's strict raise, not this warning's job).
  # The piped LHS is not checked: it isn't among `call.arguments` here.
  defp warn_misshapen_keyword_routes(%{warn?: false}, _router, _spec, _call, _routes), do: :ok

  defp warn_misshapen_keyword_routes(diag, router, spec, call, routes) do
    routes
    |> ArgumentRoutes.visible()
    |> Enum.zip(call.arguments)
    |> Enum.with_index()
    |> Enum.each(fn {{treatment, arg}, index} ->
      warn_misshapen_keyword(treatment, arg, index, diag, router, spec)
    end)
  end

  defp warn_misshapen_keyword({:keyword, treatments}, arg, index, diag, router, spec) do
    case keyword_pairs(arg) do
      {:ok, pairs} ->
        pairs
        |> Enum.zip(treatments)
        |> Enum.each(fn {{_key, value}, treatment} ->
          warn_misshapen_keyword(treatment, value, index, diag, router, spec)
        end)

      :error ->
        IO.warn(
          "#{inspect(router)}.route_arguments/2 routed argument #{index} of " <>
            "#{inspect(Spec.key(spec))} as {:keyword, …}, but " <>
            "`#{Macro.to_string(arg)}` is not a literal keyword list " <>
            "(#{location(diag, arg)}). The value is left unrouted and produces no " <>
            "mutants. A runtime-built keyword list has no pairs to route — classify this " <>
            "shape explicitly (:raw to leave it as written).",
          []
        )
    end
  end

  defp warn_misshapen_keyword(_treatment, _arg, _index, _diag, _router, _spec), do: :ok

  defp keyword_pairs({:__block__, _meta, [list]}) when is_list(list), do: keyword_pairs(list)

  defp keyword_pairs(list) when is_list(list),
    do: if(CallOptions.keyword_list_shaped?(list), do: {:ok, list}, else: :error)

  defp keyword_pairs(_other), do: :error

  defp location(diag, {_form, meta, _rest}) when is_list(meta),
    do: "#{diag.file}:#{meta[:line] || "?"}"

  defp location(diag, _arg), do: diag.file

  defp resolved_call!(call_node, spec) do
    case Calls.resolved_routed_call(call_node) do
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

  # A classifier's result may be a hand-built struct, so validate it against the concrete call and
  # take the **normalized** routes back (a keyed refinement written in author form is stored in its
  # internal shape, exactly as a static route's positions are).
  defp validate_routes!(spec, call, routes) do
    case ArgumentRoutes.validate(routes, call) do
      {:ok, normalized} -> normalized
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

  defp attach_hosts({:keyed, leading, pairs}, hosts),
    do:
      {:keyed, attach_hosts(leading, hosts),
       Enum.map(pairs, fn {key, position} -> {key, attach_hosts(position, hosts)} end)}

  defp attach_hosts(other, _hosts), do: other

  defp routes_contain_hosted?(routes),
    do:
      Enum.any?(ArgumentRoutes.visible(routes), &contains_hosted?/1) or
        contains_hosted?(ArgumentRoutes.piped(routes))

  defp contains_hosted?(:hosted), do: true
  defp contains_hosted?({:hosted, _hosts}), do: true
  defp contains_hosted?({:keyword, treatments}), do: Enum.any?(treatments, &contains_hosted?/1)

  defp contains_hosted?({:keyed, leading, pairs}),
    do: contains_hosted?(leading) or Enum.any?(pairs, fn {_k, p} -> contains_hosted?(p) end)

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

    meta = Meta.stamp_routing(meta, visible)

    if is_nil(piped) or piped == :expression,
      do: meta,
      else: Meta.stamp_piped_routing(meta, piped)
  end

  @spec contract_error!(keyword()) :: no_return()
  defp contract_error!(opts), do: raise(ContractError, opts)
end
