defmodule Mutare.Transform.Resolve.RouteStamp do
  @moduledoc false

  # Known-macro routing stamp for the lexical resolve pass. `Resolve` decides what module a call
  # resolves to; this module turns a matched `Mutare.CallRouting.Spec` into the metadata the analyzer
  # later reads, including shape-aware classifier validation and pipe-position splitting.

  alias Mutare.CallRouting.Registry, as: Routes
  alias Mutare.CallRouting.Registry.Entry
  alias Mutare.CallRouting.{ArgumentRoutes, Call, ContractError}
  alias Mutare.{AST, Mutator}
  alias Mutare.CallRouting.Spec
  alias Mutare.Transform.Analyze.CallOptions
  alias Mutare.Transform.{Calls, Imports, Meta, StructuralForms}

  @typep diag :: %{warn?: boolean(), file: String.t()}

  # The slice of the resolve pass's env this stamp reads: the known-macro registry, whether the
  # call is a `|>` right-hand side (for its effective arity), and the diagnostics wiring
  # (whether advisory warnings print, and the file that labels them) — see
  # `Mutare.Transform.Resolve.annotate/3`.
  @typep env :: %{
           :call_routes => Routes.registry(),
           :pipe_mode => Mutator.pipe_mode(),
           :diag => diag(),
           optional(atom()) => term()
         }

  @doc """
  Stamp a call's meta with known-macro argument routing, when the registry in `env` matches it.
  """
  @spec stamp(keyword(), Spec.module_key() | nil, atom(), [Macro.t()], Macro.t(), env()) ::
          keyword()
  def stamp(meta, module_key, fun, args, call_node, env) do
    %{call_routes: registry, pipe_mode: pipe_mode, diag: diag} = env
    arity = Mutator.effective_arity(args, pipe_mode)

    case Routes.lookup(registry, module_key, fun, arity) do
      nil ->
        meta

      %Entry{spec: spec} = entry ->
        cond do
          # A positional route never meets a piped call: `Resolve` rewrites such a stage into a
          # direct call before walking it (`positional?/4` is the question it asks). The one
          # stage still walked piped under a positional route sits beneath a `|>` that is
          # itself `:skip`ped — an inert leaf nothing will read — so it is left unstamped.
          pipe_mode == :piped and not Spec.skip?(spec) ->
            meta

          StructuralForms.applies?(module_key, fun, spec) ->
            stamp_matched(meta, entry, module_key, fun, call_node, arity, diag)

          true ->
            # A wildcard route (`{Kernel, :*, :raw}`, `{:*, :if, …}`) whose cascade reached a
            # head its key never named and that cannot carry it: a positional route on a
            # structural form (`if`, `and`, `case`, …), or any route on a declaration (`def`,
            # `use`, …). The explicit key forms were rejected at
            # `Mutare.CallRouting.Spec.new/4`; here the route's positions simply do not apply,
            # so the head stays unstamped — analyzed as usual, and not counted among the
            # route's matches (`Mutare.Transform.ConfigMatches`).
            meta
        end
    end
  end

  # A known macro routes its arguments specially, so a bare-import witness that rebuilds the call
  # as an anonymous function may be invalid. Drop the witness where the macro is known; the
  # resolution stamp itself stays.
  #
  # Stamp the resolved identity (`t:Mutare.Transform.Meta.routed_call/0`) *before* dispatching, and
  # thread the updated meta back onto `call_node` — so a `:routing` classifier (invoked *inside*
  # `stamp_spec`) that normalizes the node via `Mutare.Transform.Calls.resolved_routed_call/1`
  # already sees it. `module_key` is `nil` only for a name-only (`{:*, name, …}`) match whose
  # module the resolver couldn't see; the reader then returns `{nil, name, arity}`, which a
  # module-matching classifier clause simply skips (its purpose — match by name instead).
  defp stamp_matched(meta, %Entry{} = entry, module_key, fun, call_node, arity, diag) do
    meta = stamp_identity(Imports.drop_witness(meta), module_key, fun, arity)
    stamp_spec(meta, entry, put_meta(call_node, meta), arity, diag)
  end

  @doc """
  Whether a call resolving to `module_key`/`fun` at `arity` takes a **positional** route — one
  that treats its arguments, as opposed to no route or the call-level `:skip`. The question
  `Mutare.Transform.Resolve` asks of a `|>` stage before rewriting the pipe as a direct call.
  """
  @spec positional?(Routes.registry(), Spec.module_key() | nil, atom(), non_neg_integer()) ::
          boolean()
  def positional?(registry, module_key, fun, arity) do
    case Routes.lookup(registry, module_key, fun, arity) do
      nil ->
        false

      %Entry{spec: spec} ->
        not Spec.skip?(spec) and StructuralForms.applies?(module_key, fun, spec)
    end
  end

  # Record the resolved macro identity on the call meta, read back by
  # `Mutare.Transform.Calls.resolved_routed_call/1` — at routing, at hosting, and from a mutator's
  # own `mutate/2`.
  defp stamp_identity(meta, module_key, fun, arity),
    do: Meta.stamp_routed_call(meta, {module_key, fun, arity})

  # Replace a call node's own (top) meta — `{head, _meta, args}` covers both the remote
  # (`head = {:., …}`) and bare (`head = fun`) shapes the resolver hands here.
  defp put_meta({head, _meta, args}, meta), do: {head, meta, args}

  # Compute and stamp a matched macro spec's per-position routing.
  #
  # Both static and dynamic declarations normalize to `ArgumentRoutes`: one treatment per
  # argument of the call node.
  defp stamp_spec(
         meta,
         %Entry{spec: %Spec{args: :routing} = spec, router: router} = entry,
         call_node,
         _arity,
         diag
       ) do
    call = resolved_call!(call_node, spec)
    routes = invoke_router!(router, call, spec)
    routes = validate_routes!(spec, call, routes)
    warn_misshapen_keyword_routes(diag, router, spec, call, routes)
    stamp_routes(meta, attach_hosts!(routes, entry))
  end

  # The call-level `:skip`: the whole call is an inert leaf. Stamp the bare `:skip` (not a
  # per-position list) so every reader sees one distinguished value — `Mutare.Transform.Analyze`
  # leaves the node raw without offering it, `Mutare.Transform.Tag` does the same in a guard, and
  # `Mutare.Transform.Calls.routed_treatments/1` reports `:skip`. No piped stamp is written: a piped
  # receiver is the `|>`'s left operand, a sibling of the skipped call rather than part of it, so it
  # is analyzed as ordinary runtime (a `Repo.insert!(u) |> Mixpanel.track(…)` keeps its mutants).
  defp stamp_spec(
         meta,
         %Entry{spec: %Spec{args: :skip}} = entry,
         {_head, _meta, args},
         arity,
         _diag
       ),
       do: meta |> Meta.stamp_routing(:skip) |> stamp_skipped_pipe(entry, length(args), arity)

  defp stamp_spec(meta, %Entry{spec: spec} = entry, call_node, arity, _diag) do
    call = resolved_call!(call_node, spec)
    routes = ArgumentRoutes.new(call, Spec.routing(spec, arity))
    stamp_routes(meta, attach_hosts!(routes, entry))
  end

  # The one position a bare `:skip` still has to answer for. A piped receiver is the `|>`'s left
  # operand but the call's *effective argument 0*, so when the skip displaced a code-provided
  # route, that route's position 0 governs it — otherwise `--skip-call Kernel.match?/2` would
  # route `1 |> match?(x)`'s receiver as runtime and splice a selector `case` into a match, which
  # the displaced `[:pattern, :expression]` route forbids. A `:skip` must not route a position
  # less safely than the route it replaced.
  #
  # A displaced *classifier* is answered `:raw`: its treatments are computed per call node by a
  # router the user just skipped, so the position's shape is unknowable here and the adapter-grade
  # DSLs classifiers describe are exactly where a spliced `case` is illegal. Displacing nothing
  # keeps the documented default — an unrouted receiver is ordinary runtime, so
  # `Repo.insert!(u) |> Mixpanel.track(…)` keeps its `Repo.insert!(u)` mutants.
  defp stamp_skipped_pipe(meta, %Entry{displaced: nil}, _visible, _arity), do: meta

  # Written directly, the skipped call has no piped receiver to answer for.
  defp stamp_skipped_pipe(meta, %Entry{}, arity, arity), do: meta

  defp stamp_skipped_pipe(meta, %Entry{displaced: %Spec{} = displaced}, _visible, arity) do
    if Spec.classifier?(displaced) do
      Meta.stamp_piped_routing(meta, :raw)
    else
      case displaced |> Spec.routing(arity) |> hd() |> Spec.normalize_position!() do
        :expression -> meta
        treatment -> Meta.stamp_piped_routing(meta, treatment)
      end
    end
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
    |> ArgumentRoutes.treatments()
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

  # A keyed refinement: check the leading treatment against the argument, then each named key's
  # position against that key's value (a non-keyword argument has no named values to check).
  defp warn_misshapen_keyword({:keyed, leading, pairs}, arg, index, diag, router, spec) do
    warn_misshapen_keyword(leading, arg, index, diag, router, spec)

    with {:ok, kw_pairs} <- keyword_pairs(arg) do
      Enum.each(kw_pairs, fn {key, value} ->
        case List.keyfind(pairs, AST.key_atom(key), 0) do
          {_key, position} -> warn_misshapen_keyword(position, value, index, diag, router, spec)
          nil -> :ok
        end
      end)
    end

    :ok
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

  defp invoke_router!(router, call, spec) do
    router.route_arguments(call, %{})
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

    Enum.map(ArgumentRoutes.treatments(routes), &attach_hosts(&1, hosts))
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
    do: Enum.any?(ArgumentRoutes.treatments(routes), &contains_hosted?/1)

  defp contains_hosted?(:hosted), do: true
  defp contains_hosted?({:hosted, _hosts}), do: true
  defp contains_hosted?({:keyword, treatments}), do: Enum.any?(treatments, &contains_hosted?/1)

  defp contains_hosted?({:keyed, leading, pairs}),
    do: contains_hosted?(leading) or Enum.any?(pairs, fn {_k, p} -> contains_hosted?(p) end)

  defp contains_hosted?(_), do: false

  defp stamp_routes(meta, treatments), do: Meta.stamp_routing(meta, treatments)

  @spec contract_error!(keyword()) :: no_return()
  defp contract_error!(opts), do: raise(ContractError, opts)
end
