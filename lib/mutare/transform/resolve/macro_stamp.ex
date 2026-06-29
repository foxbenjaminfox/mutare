defmodule Mutare.Transform.Resolve.MacroStamp do
  @moduledoc false

  # Known-macro routing stamp for the lexical resolve pass. `Resolve` decides what module a call
  # resolves to; this module turns a matched `Mutare.Macro.Spec` into the metadata the analyzer
  # later reads, including shape-aware classifier validation and pipe-position splitting.

  alias Mutare.MacroRouting.Registry, as: Macros
  alias Mutare.Mutator
  alias Mutare.Macro.Spec
  alias Mutare.Transform.{Imports, Meta}

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

      %Spec{} = spec ->
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
        meta = stamp_identity(Imports.drop_witness(meta), module_key, fun)
        stamp_spec(meta, spec, put_meta(call_node, meta), arity, pipe_mode)
    end
  end

  # Record the resolved macro identity on the call meta, read back by
  # `Mutare.Transform.Calls.resolved_macro_call/1`.
  defp stamp_identity(meta, module_key, fun), do: Meta.stamp_macro_call(meta, {module_key, fun})

  # Replace a call node's own (top) meta — `{head, _meta, args}` covers both the remote
  # (`head = {:., …}`) and bare (`head = fun`) shapes the resolver hands here.
  defp put_meta({head, _meta, args}, meta), do: {head, meta, args}

  # Compute and stamp a matched macro spec's per-position routing.
  #
  # A `:routing` classifier sees the concrete visible call node and returns visible-argument
  # routing, so it rides whole on @macro_key. A static spec is effective-arity based and is split
  # for piped calls so the LHS can be routed as effective argument 0.
  defp stamp_spec(
         meta,
         %Spec{args: :routing, router: router} = spec,
         call_node,
         _arity,
         _pipe_mode
       ) do
    raw = router.macro_routing(call_node)
    validate_routing!(spec, raw)
    routing = inject_host(raw, spec)
    reject_undeliverable_hosted!(spec, routing)
    Meta.stamp_macro_routing(meta, routing)
  end

  defp stamp_spec(meta, spec, _call_node, arity, pipe_mode) do
    routing = Spec.routing(spec, arity) |> inject_host(spec)
    reject_piped_hosted!(spec, routing, pipe_mode)
    stamp_routing(meta, routing, pipe_mode)
  end

  # A static `:hosted` at effective position 0 is undeliverable when the call is piped, because
  # that position is the pipe LHS, not a visible macro-node argument handed to host/2.
  defp reject_piped_hosted!(spec, [{:hosted, _host} | _], :piped) do
    raise ArgumentError,
          "macro #{inspect(Spec.key(spec))} routes argument 0 as :hosted, but it is called " <>
            "piped (`x |> #{spec.name}(...)`) where argument 0 is the piped value — not part of " <>
            "the macro node handed to host/2, so it cannot be hosted. A :hosted position must be " <>
            "a visible argument; use the :routing classifier for shape/position-dependent hosting."
  end

  defp reject_piped_hosted!(_spec, _routing, _pipe_mode), do: :ok

  # A `:routing` classifier is only required to implement host/2 once it actually routes a
  # position as hosted. Fail at the stamp point, where that concrete routing is first known.
  defp reject_undeliverable_hosted!(%Spec{router: router, host: host} = spec, routing) do
    if hosted?(routing) and not host_exports?(host, :host, 2) do
      raise ArgumentError,
            "macro #{inspect(Spec.key(spec))}'s macro_routing/1 routed an argument as :hosted, " <>
              "but its router #{inspect(router)} is not an enabled mutator implementing " <>
              "Mutare.Mutator.MacroHost.host/2 to deliver it — implement MacroHost, or do not " <>
              "route that position as :hosted."
    end
  end

  defp hosted?(routing) when is_list(routing), do: Enum.any?(routing, &hosted?/1)
  defp hosted?({:hosted, _host}), do: true
  defp hosted?({:keyword, treatments}), do: hosted?(treatments)
  defp hosted?(_treatment), do: false

  # `host` is `module() | nil`; `Code.ensure_loaded?(nil)` and `function_exported?(nil, …)` are
  # both false, so a nil host is handled for free.
  defp host_exports?(host, fun, arity),
    do: Code.ensure_loaded?(host) and function_exported?(host, fun, arity)

  # Validate the raw macro_routing/1 output before `inject_host/2`. A classifier is untrusted:
  # unrecognised or mis-shaped treatments would otherwise fall through to expression routing.
  defp validate_routing!(spec, routing) when is_list(routing) do
    Enum.each(routing, &validate_treatment!(spec, &1, :argument))
  end

  defp validate_routing!(spec, routing) do
    raise ArgumentError,
          "macro #{inspect(Spec.key(spec))}'s macro_routing/1 must return a list of treatments " <>
            "(one per visible argument), got: #{inspect(routing)}"
  end

  defp validate_treatment!(_spec, :hosted, _position), do: :ok

  defp validate_treatment!(spec, {:keyword, value_treatments}, _position)
       when is_list(value_treatments) do
    Enum.each(value_treatments, &validate_treatment!(spec, &1, :keyword_value))
  end

  defp validate_treatment!(spec, treatment, _position) do
    if treatment in recognised_atom_treatments() do
      :ok
    else
      raise ArgumentError,
            "macro #{inspect(Spec.key(spec))}'s macro_routing/1 returned an unrecognised treatment " <>
              "#{inspect(treatment)} — expected one of :expression/:pattern/:binding_pattern/:skip/" <>
              ":hosted/:pinned or {:keyword, [value_treatments]}."
    end
  end

  defp recognised_atom_treatments, do: [:pinned | Spec.treatments()]

  # Tag each `:hosted` treatment with its hosting mutator module so the analyzer can reach host/2.
  # Keyword routing can nest arbitrarily, so preserve its shape while injecting recursively.
  defp inject_host(routing, %Spec{host: host}) do
    Enum.map(routing, &inject_host_treatment(&1, host))
  end

  defp inject_host_treatment(:hosted, host), do: {:hosted, host}

  defp inject_host_treatment({:keyword, treatments}, host),
    do: {:keyword, Enum.map(treatments, &inject_host_treatment(&1, host))}

  defp inject_host_treatment(other, _host), do: other

  # Split effective routing across the visible-call stamp and the piped-LHS stamp.
  defp stamp_routing(meta, routing, :unpiped), do: Meta.stamp_macro_routing(meta, routing)

  defp stamp_routing(meta, [piped | visible], :piped) do
    meta = Meta.stamp_macro_routing(meta, visible)
    if piped == :expression, do: meta, else: Meta.stamp_piped_macro_routing(meta, piped)
  end
end
