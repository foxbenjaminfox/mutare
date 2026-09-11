defmodule Mutare.Mutator.Dispatch do
  @moduledoc false
  # The transform-facing side of the mutator contract: running mutators over a node, discovering
  # which enabled specs implement a structural hook, invoking those hooks (preferring the
  # context-aware arity), normalizing the noted-mutant / selector-host return shapes, and the
  # mutator-resolution check the registry uses. None of this is something a *mutator author*
  # touches — they implement `Mutare.Mutator`'s callbacks; `Mutare.Transform` (and the
  # `Mutare.Mutators` registry) call into here. Split out of `Mutare.Mutator` so the behaviour
  # module stays a focused author-facing contract.

  alias Mutare.Mutator.{Mutation, Spec}
  alias Mutare.Reflection

  defmodule Result do
    @moduledoc false

    # One produced mutation, as the transform sees it — the single shape on **both** delivery
    # paths: the ordinary `mutate/1`/`mutate/2` return (`mutations/3`) and a selector host's
    # target `:mutants` (`host_targets/3`, carried on `Mutare.Transform.Candidate.Hosted`). Built
    # only by `to_result/2`, which is where the author-facing return contract (a bare node or a
    # `%Mutare.Mutator.Mutation{}`) is validated and the recording spec resolved. A struct so a
    # field only some consumers read (`:attribution`, read by `Mutare.Transform.Analyze.Attach`
    # alone) rides through every choke point without a positional slot: the consumers that don't
    # care (guard/pattern tagging in `Mutare.Transform.Tag`, `Mutare.Transform.HostedEmit`) match
    # `%Result{}` and read only the fields they use. `spec` is the **recording** `Mutare.Mutator.Spec`
    # (the `%Mutation{}`'s explicit `:producer` when relayed, else the returning mutator); `node` the
    # replacement AST; `note`/`variant` the optional advisory / `# mutare:ignore` tag; `attribution`
    # the optional `Mutare.Mutator.Mutation.Attribution` (`nil` for a bare-node or unattributed
    # mutation).

    @enforce_keys [:spec, :node]
    defstruct [:spec, :node, note: nil, variant: nil, attribution: nil]

    @type t :: %__MODULE__{
            spec: Spec.t(),
            node: Macro.t(),
            note: String.t() | nil,
            variant: Mutation.variant(),
            attribution: Mutation.Attribution.t() | nil
          }
  end

  @doc """
  Run every mutator over `node`, flattening to `Mutare.Mutator.Dispatch.Result` structs.

  The single place a node meets the mutator set. Both the in-place analyzer
  (`Mutare.Transform`) and the lifted-guard planner (`Mutare.Transform.FunctionPlan`)
  call this, so "which mutations does this node admit" has one answer regardless of
  where the node sits — placement is decided afterwards, positionally.

  Each entry is a `Mutare.Mutator.Spec` (a bare module is coerced to one). If the
  module exports `mutate/2`, dispatch calls that context-aware callback; otherwise
  it falls back to `mutate/1`. A mutator that wants both behaviours can call its
  own `mutate/1` helper from `mutate/2`, making composition explicit instead of
  a hidden double-dispatch rule. The per-spec `context` carries the pipe mode
  **and** the spec's `:opts`/`:config`, so pipe-aware/arity-changing and configurable
  mutators both participate here. `context` defaults to `%{pipe_mode: :unpiped}`; the transform passes
  `%{pipe_mode: :piped}` for a `|>` right-hand side. Each result is a `%Result{}`: `spec` the
  **spec** (not the bare module), so the family name and config travel with it; `node` the
  replacement AST; `note` (`nil` unless the mutator returned a `%Mutare.Mutator.Mutation{}` with one),
  so a per-mutant advisory rides through to the `Mutare.Site`; `variant` (the
  `%Mutare.Mutator.Mutation{}`'s production-time variant tag, `nil` for a bare node), the carried
  `# mutare:ignore` label(s) that override the derived `variant/2` at `Site` build; and `attribution`
  (the `%Mutare.Mutator.Mutation{}`'s report-location override, `nil` for a bare node).

      iex> [%Mutare.Mutator.Dispatch.Result{spec: spec, node: node}] = Mutare.Mutator.Dispatch.mutations({:+, [], [1, 2]}, [Mutare.Mutators.Arithmetic])
      iex> {spec.name, node}
      {:arithmetic, {:-, [], [1, 2]}}
  """
  @spec mutations(Macro.t(), [Spec.t() | module()], Mutare.Mutator.context()) :: [Result.t()]
  def mutations(node, mutators, context \\ %{pipe_mode: :unpiped}) do
    Enum.flat_map(mutators, fn entry ->
      spec = Spec.coerce(entry)
      node_level(spec, node, put_spec_context(context, spec))
    end)
  end

  # Inject the per-spec configuration facts into a callback context: the raw `:opts`, the
  # `init/1`-normalized `:config`, and the enclosing module's `:behaviours`. The one place
  # the spec-derived context keys are named, shared by the node-level (`mutations/3`) and
  # selector-host (`host_targets/3`) paths — `structural_context/1` builds the same keys
  # minus `:pipe_mode` from scratch.
  defp put_spec_context(context, %Spec{
         name: name,
         opts: opts,
         config: config,
         behaviours: behaviours
       }) do
    context
    |> Map.put(:name, name)
    |> Map.put(:opts, opts)
    |> Map.put(:config, config)
    |> Map.put(:behaviours, behaviours)
  end

  # `mutate/2` is the context-aware override; `mutate/1` is the fallback. This keeps the
  # author-facing contract conventional and avoids silently running two callbacks from one
  # mutator. A mutator that wants composition can make that visible in its own `mutate/2`.
  defp node_level(spec, node, context) do
    cond do
      callback_enabled?(spec, :mutate, 2) and function_exported?(spec.module, :mutate, 2) ->
        contextual(spec, node, context)

      callback_enabled?(spec, :mutate, 1) and function_exported?(spec.module, :mutate, 1) ->
        node_local(spec, node, context)

      true ->
        []
    end
  end

  defp node_local(spec, node, context) do
    tag(spec, spec.module.mutate(node), context)
  end

  defp contextual(spec, node, context) do
    tag(spec, spec.module.mutate(node, context), context)
  end

  defp tag(_spec, :skip, _context), do: []

  # The mutator's optional `finalize/2` funnel runs first (`finalize_mutations/3`), then each
  # returned mutation becomes the `%Result{}` recorded under its spec (`to_result/2`) — or under the
  # `%Mutation{}`'s explicit `producer` when set (the relayed-mutation attribution: the site and its
  # ignore vocabulary belong to the family that reasoned about the mutant, not the one that
  # returned it).
  defp tag(spec, mutations, context) when is_list(mutations),
    do:
      mutations
      |> finalize_mutations(spec, context)
      |> Enum.map(&to_result(&1, spec))

  # Apply the spec's optional `c:Mutare.Mutator.finalize/2` hook to each produced mutation —
  # the core-guaranteed tag → filter → enrich funnel a family-rich mutator would otherwise
  # have to remember at every delivery site. The one definition both delivery paths share:
  # the `mutate/1`/`mutate/2` return (`tag/3`) and a host target's `:mutants`
  # (`normalize_target/3`). Each raw element is validated (`validate!/1`) *before* reaching
  # plugin code (so a malformed producer return fails loud with core's message, not a
  # confusing crash inside the plugin's `finalize/2`); the finalized value is validated again
  # when the caller builds its `%Result{}` (`to_result/2`). A relayed mutation (an explicit
  # `:producer` — the sub-contract case) passes through untouched: it belongs to the producing
  # family, whose own funnel already ran when the mutation was generated.
  defp finalize_mutations(mutations, %Spec{module: module} = spec, context) do
    if callback_enabled?(spec, :finalize, 2) and exports?(module, :finalize, 2) do
      Enum.flat_map(mutations, fn mutation ->
        validate!(mutation)
        finalize(module, mutation, context)
      end)
    else
      mutations
    end
  end

  defp finalize(_module, %Mutation{producer: %Spec{}} = relayed, _context), do: [relayed]

  defp finalize(module, mutation, context) do
    case module.finalize(mutation, context) do
      :skip ->
        []

      nil ->
        raise ArgumentError,
              "#{inspect(module)}.finalize/2 must return a mutation or :skip, got: nil"

      finalized ->
        [finalized]
    end
  end

  @doc """
  The specs in `specs` whose module implements the optional callback `fun`/`arity`.

  The single home for "which enabled mutators opt into this structural hook", used for the
  position-routed structural callbacks (`return_replacements/1`, `condition_replacements/1`,
  `pattern_mutations/2`) — so the transform asks every implementer rather than hardcoding a
  built-in module.
  """
  @spec implementing([Spec.t()], atom(), arity()) :: [Spec.t()]
  def implementing(specs, fun, arity), do: implementing_any(specs, fun, [arity])

  @doc """
  The specs in `specs` whose module implements `fun` at **any** of `arities` — the
  any-arity variant of `implementing/3`, used to discover the structural hooks that come
  in a base form (`fun/n`) *and* a context-aware form (`fun/(n+1)`, taking the structural
  context): a mutator implements one or the other. `return_replacements/{1,2}`,
  `condition_replacements/{1,2}`, `pattern_mutations/{2,3}`. The dispatch helpers
  (`return_replacements/2`, `condition_replacements/2`, `pattern_mutations/3` below) then
  call whichever arity each spec actually exports.
  """
  @spec implementing_any([Spec.t()], atom(), [arity()]) :: [Spec.t()]
  def implementing_any(specs, fun, arities) do
    Enum.filter(specs, fn %{module: module} = spec ->
      Enum.any?(arities, &(callback_enabled?(spec, fun, &1) and exports?(module, fun, &1)))
    end)
  end

  defp callback_enabled?(%{disabled_callbacks: disabled}, fun, arity),
    do: not MapSet.member?(disabled, {fun, arity})

  defp callback_enabled?(_spec, _fun, _arity), do: true

  # The capability probe (load on demand, then check the export) lives in `Mutare.Reflection`;
  # this is its local name.
  defp exports?(module, fun, arity), do: Reflection.exports?(module, fun, arity)

  @doc """
  Whether `module` is a **selector host** — it implements `Mutare.Mutator.MacroHost`, exporting
  *both* `host/2` and `hosted_macros/0`. The one decision behind every "is this a host" question:
  `implemented_by?/1` (a host needs no `mutate`), `hosts/1` (collect mode's producers), and the
  call-routing registry's host subscriptions. A module exporting only one of the pair is not a
  host here; the registry is what reports that half-implementation as a contract error.
  """
  @spec host?(term()) :: boolean()
  def host?(module), do: exports?(module, :host, 2) and exports?(module, :hosted_macros, 0)

  @doc """
  The specs in `specs` whose module is a selector host (`host?/1`) with `host/2` enabled — the
  host-side twin of `implementing/3`.
  """
  @spec hosts([Spec.t()]) :: [Spec.t()]
  def hosts(specs),
    do: Enum.filter(specs, &(callback_enabled?(&1, :host, 2) and host?(&1.module)))

  @doc """
  Run `spec`'s return-tail hook over `tail`, preferring the context-aware
  `c:Mutare.Mutator.Structural.return_replacements/2` (passing the structural context) when the module
  exports it, else the base `c:Mutare.Mutator.Structural.return_replacements/1`, so a mutator can
  implement either arity.
  """
  @spec return_replacements(Spec.t(), Macro.t()) :: [Macro.t()]
  def return_replacements(%Spec{} = spec, tail),
    do: dispatch_structural(spec, :return_replacements, [tail])

  @doc """
  Run `spec`'s condition hook over `condition`, preferring
  `c:Mutare.Mutator.Structural.condition_replacements/2` (with the structural context) when exported, else
  `c:Mutare.Mutator.Structural.condition_replacements/1`. The condition-position twin of
  `return_replacements/2`.
  """
  @spec condition_replacements(Spec.t(), Macro.t()) :: [Macro.t()]
  def condition_replacements(%Spec{} = spec, condition),
    do: dispatch_structural(spec, :condition_replacements, [condition])

  @doc """
  Run `spec`'s head-pattern hook over `head_args`/`used_outside`, preferring
  `c:Mutare.Mutator.Structural.pattern_mutations/3` (with the structural context) when exported, else
  `c:Mutare.Mutator.Structural.pattern_mutations/2`. The lifted-pattern twin of `return_replacements/2`.
  """
  @spec pattern_mutations(Spec.t(), [Macro.t()], MapSet.t()) :: [[Macro.t()]]
  def pattern_mutations(%Spec{} = spec, head_args, used_outside),
    do: dispatch_structural(spec, :pattern_mutations, [head_args, used_outside])

  # The shared arity dispatch behind the three structural hooks above: prefer the
  # context-aware `fun/(n+1)` (the base args plus the structural context) when the module
  # exports it, else the base `fun/n`. So the three are one-line faces and adding a fourth
  # structural hook is one more delegating clause, not another copy of this exported-or-base
  # dance.
  @spec dispatch_structural(Spec.t(), atom(), [term()]) :: term()
  defp dispatch_structural(%Spec{module: module} = spec, fun, base_args) do
    context_arity = length(base_args) + 1
    base_arity = length(base_args)

    cond do
      callback_enabled?(spec, fun, context_arity) and
          function_exported?(module, fun, context_arity) ->
        apply(module, fun, base_args ++ [structural_context(spec)])

      callback_enabled?(spec, fun, base_arity) and function_exported?(module, fun, base_arity) ->
        apply(module, fun, base_args)

      true ->
        []
    end
  end

  @doc """
  The **selector-host targets** `spec`'s mutator declares for the resolved known-macro `call`
  (`c:Mutare.Mutator.MacroHost.host/2`), normalized from public `MacroHost.Target` values into the
  transform's internal candidate shape. `[]` when the module doesn't implement `host/2`.
  `context0` is enriched with the spec's `:opts`/`:config`/`:behaviours` before the callback runs,
  mirroring `mutations/3`.

  The single home for invoking a hosting mutator and validating its target shape, so
  `Mutare.Transform.Analyze` builds `Mutare.Transform.Candidate.Hosted`s without re-deriving
  the contract.
  """
  @spec host_targets(
          Spec.t(),
          Mutare.CallRouting.Call.t(),
          Mutare.Mutator.context()
        ) :: [map()]
  def host_targets(%Spec{module: module} = spec, call, context0) do
    if callback_enabled?(spec, :host, 2) and exports?(module, :host, 2) do
      context = put_spec_context(context0, spec)

      try do
        case module.host(call, context) do
          targets when is_list(targets) ->
            targets
            |> Enum.map(&normalize_target(&1, spec, context))
            |> Enum.reject(&(&1.mutants == []))

          other ->
            host_contract_error!(module, other, "host/2 must return a list of Target values")
        end
      rescue
        error in Mutare.CallRouting.ContractError ->
          reraise error, __STACKTRACE__

        error ->
          host_callback_raised!(module, error, __STACKTRACE__)
      end
    else
      []
    end
  end

  # Default `:wrap` to identity and `:range` to absent; require `:original`, a list `:mutants`,
  # and a 2-arity `:splice`. A malformed target raises (a library bug, not a target to silently
  # drop) — caught at transform time with the offending value. Each mutant runs through the
  # host's optional `finalize/2` funnel (`finalize_mutations/3`, same as a `mutate/2` return —
  # a `:skip` removes it, and `host_targets/3` drops a target left with no mutants), then becomes
  # the same `%Result{}` the ordinary path records (`to_result/2`). A host fragment is *usually*
  # untagged (foreign semantics, no vocabulary), so `variant` is nil — but a hosting mutator
  # declaring `variants/0` may tag one via `Mutation.tagged/2`, and that label rides through
  # `Mutare.Transform.HostedEmit` to the Site. The result's `spec` is the sub-contract
  # attribution resolved: a mutant the host relayed from a core family (collected via
  # `Mutare.Analyze.expression_mutations/3`) records under that family's spec, a host-authored
  # one under the host's.
  defp normalize_target(
         %Mutare.Mutator.MacroHost.Target{
           original: original,
           mutants: mutants,
           splice: splice
         } = target,
         %Spec{} = spec,
         context
       )
       when is_list(mutants) and is_function(splice, 2) do
    %{
      original: original,
      mutants: mutants |> finalize_mutations(spec, context) |> Enum.map(&to_result(&1, spec)),
      splice: splice,
      wrap: target_wrap(Map.get(target, :wrap)),
      range: target_range(Map.get(target, :range))
    }
  end

  defp normalize_target(other, %Spec{module: module}, _context) do
    host_contract_error!(
      module,
      other,
      "host/2 must return Mutare.Mutator.MacroHost.Target values built with Target.new/4"
    )
  end

  @spec host_contract_error!(module(), term(), String.t()) :: no_return()
  defp host_contract_error!(module, value, message) do
    raise Mutare.CallRouting.ContractError,
      provider: module,
      callback: {:host, 2},
      value: value,
      reason: :invalid_host_target,
      message: "#{inspect(module)} #{message}, got: #{inspect(value)}"
  end

  # `host/2` itself raised (a bug in the provider), as opposed to *returning* a malformed target
  # (`host_contract_error!/3`). Report it as a callback failure — naming the exception rather than
  # implying a bad return — and reraise with the provider's own stacktrace so the author sees where.
  @spec host_callback_raised!(module(), Exception.t(), Exception.stacktrace()) :: no_return()
  defp host_callback_raised!(module, error, stacktrace) do
    reraise Mutare.CallRouting.ContractError.exception(
              provider: module,
              callback: {:host, 2},
              value: error,
              reason: :host_callback_failed,
              message:
                "#{inspect(module)} host/2 raised #{inspect(error.__struct__)}: " <>
                  Exception.message(error)
            ),
            stacktrace
  end

  @doc """
  The `%Result{}` one produced mutation is recorded as: a bare replacement node, or a
  `%Mutare.Mutator.Mutation{}` carrying a note, a variant tag, a producer spec, and/or a
  report-location override. Recorded under `spec` — the returning mutator — unless the
  `%Mutation{}` names an explicit `:producer` (a relayed sub-contract mutant, recorded under the
  family that reasoned about it). The single home for the enriched-mutant contract, shared by the
  `mutate/1`/`mutate/2` return path (`tag/3`) and the selector-host `:mutants` path
  (`normalize_target/3`), so malformed entries fail loud in one place (`validate!/1`).

  An empty-string note is coerced to `nil`: a blank note carries no signal, and `nil` keeps the
  report from rendering a dangling `— ` suffix (and the JSON reporter from emitting an empty
  `description`).
  """
  @spec to_result(Macro.t() | Mutation.t(), Spec.t()) :: Result.t()
  def to_result(mutation, %Spec{} = spec) do
    validate!(mutation)

    case mutation do
      %Mutation{} = mutation ->
        %Result{
          spec: mutation.producer || spec,
          node: mutation.node,
          note: presence(mutation.note),
          variant: mutation.variant,
          attribution: mutation.attribution
        }

      node ->
        %Result{spec: spec, node: node}
    end
  end

  # Anything other than a bare node or a well-formed `%Mutation{}` is a library bug — a bare
  # top-level `nil` (filter it before returning the list, or use `Mutare.AST.literal(nil)` for a
  # literal nil replacement), a bare `%{node:, note:}` *map* (the struct is required: a quoted map
  # literal is itself a valid mutation node, so a bare map can't unambiguously mean "noted mutant"),
  # some *other* struct (no AST node is a struct, and the note would otherwise silently vanish), or a
  # `%Mutation{}` whose `:note` is neither a string nor nil (the report renders it verbatim) or
  # whose `:producer` is not a spec. All raise rather than silently drop — fail loud over a
  # vanishing/garbled mutant.
  defp validate!(%Mutation{note: note, producer: producer})
       when (is_binary(note) or is_nil(note)) and
              (is_nil(producer) or is_struct(producer, Spec)),
       do: :ok

  defp validate!(%Mutation{note: note}) when not is_binary(note) and not is_nil(note) do
    raise ArgumentError,
          "a Mutare.Mutator.Mutation :note must be a string or nil, got: #{inspect(note)}"
  end

  defp validate!(%Mutation{producer: producer}) do
    raise ArgumentError,
          "a Mutare.Mutator.Mutation :producer must be a Mutare.Mutator.Spec or nil, " <>
            "got: #{inspect(producer)}"
  end

  defp validate!(nil) do
    raise ArgumentError,
          "a mutation list item cannot be bare nil; filter inapplicable entries before returning " <>
            "the list, or return Mutare.AST.literal(nil) to replace with literal nil"
  end

  defp validate!(%{node: _} = map) when not is_struct(map) do
    raise ArgumentError,
          "a noted mutant must be a %Mutare.Mutator.Mutation{}, not a bare map, got: #{inspect(map)}"
  end

  defp validate!(%_{} = other) do
    raise ArgumentError,
          "a noted mutant must be a %Mutare.Mutator.Mutation{}, got a " <>
            "#{inspect(other.__struct__)}: #{inspect(other)}"
  end

  defp validate!(_node), do: :ok

  # A blank note is no note — collapse `""` to `nil` so downstream rendering treats it as absent.
  defp presence(""), do: nil
  defp presence(note), do: note

  defp target_wrap(nil), do: &Function.identity/1
  defp target_wrap(wrap) when is_function(wrap, 1), do: wrap

  defp target_wrap(other) do
    raise ArgumentError, "a host target :wrap must be a 1-arity function, got: #{inspect(other)}"
  end

  defp target_range(nil), do: nil
  defp target_range(%Sourceror.Range{} = range), do: range

  defp target_range(other) do
    raise ArgumentError,
          "a host target :range must be a %Sourceror.Range{} or nil, got: #{inspect(other)}"
  end

  # The structural-callback context: the same per-spec configuration facts as the
  # node-level context, minus :pipe_mode (structural positions are not pipe
  # stages). :opts/:config make {Module, opts} configurable structural mutators
  # work, and :behaviours lets behaviour-gated structural mutators restrict
  # themselves to modules implementing a target behaviour.
  defp structural_context(%Spec{} = spec), do: put_spec_context(%{}, spec)

  # The mutation-producing callbacks: a module is a mutator if it exports `name/0` *and* at least
  # one of these. `mutate/1` is no longer required — a structural/pipe-only family produces its
  # mutations through `mutate/2` or a structural hook instead.
  # (`call_routes/0`/`mutate_call_option_keys?/1` are routing/policy, not producers, so they don't
  # qualify a module on their own.)
  #
  # `mutate/1,2` are base-behaviour, `host/2` is `MacroHost`; the structural hooks
  # (`return_replacements`, `condition_replacements`, `pattern_mutations`) are derived from
  # `Structural`'s own `@callback`s, so adding a structural hook there updates this set
  # automatically — it can't drift. Order is irrelevant (consumed via `Enum.any?`).
  @producing_callbacks [mutate: 1, mutate: 2] ++
                         Mutare.Mutator.Structural.behaviour_info(:callbacks)

  @doc """
  Whether `term` is a module that implements `Mutare.Mutator` — it exports `name/0` and at least
  one mutation-producing callback (`mutate/1`, the pipe-aware `mutate/2`, or a structural hook such
  as `return_replacements/1`). Total over any term, so a non-module entry in a `:mutators` list is
  *reported* by resolution rather than crashing a guard.

      iex> Mutare.Mutator.Dispatch.implemented_by?(Mutare.Mutators.Arithmetic)
      true
      iex> Mutare.Mutator.Dispatch.implemented_by?(Enum)
      false
      iex> Mutare.Mutator.Dispatch.implemented_by?("arithmetic")
      false
  """
  @spec implemented_by?(term()) :: boolean()
  def implemented_by?(module) when is_atom(module) do
    exports?(module, :name, 0) and
      (Enum.any?(@producing_callbacks, fn {fun, arity} -> exports?(module, fun, arity) end) or
         host?(module))
  end

  # Total over any term: a non-atom (e.g. a string in `.mutare.exs`) is simply
  # not a mutator, so resolution reports it rather than crashing on the guard.
  def implemented_by?(_term), do: false

  @doc """
  Whether `spec`'s mutator wants to keep candidates that mutate a call's trailing
  keyword-option keys.

  This is opt-in policy: a module without `c:Mutare.Mutator.mutate_call_option_keys?/1`
  keeps the candidate regardless of similarly named opts. A module implementing the
  callback receives its own configured opts and decides. The transform remains the
  owner of identifying the position; this dispatcher keeps callback discovery out of
  emission.
  """
  @spec mutate_call_option_keys?(Spec.t()) :: boolean()
  def mutate_call_option_keys?(%Spec{module: module, opts: opts}) do
    not function_exported?(module, :mutate_call_option_keys?, 1) or
      module.mutate_call_option_keys?(opts)
  end

  @doc """
  The **variant label(s)** recorded for one mutation of `spec`'s module — a deduplicated, downcased
  label list, or `[]` when the family hasn't opted in or this mutation has no label. The single home
  for resolving a site's variant, so `Mutare.Site` records the labels without reaching into a mutator
  module itself. Dispatching on the *producing* spec's module is correct: only the mutator that
  emitted the mutation knows which kind(s) it is.

  Two label sources, in precedence order — a mutator uses whichever is cleaner:

    1. **`carried`** — a label (list) the mutator attached at production time via
       `Mutare.Mutator.Mutation.tagged/2` (the `%Mutation{}`'s `variant` field), threaded here from
       `mutations/3`. A value family tags here, where the semantic kind is known at construction.
    2. else **`c:Mutare.Mutator.variant/2`** — derived from the `{original, mutated}` pair, when the
       module exports it. An operator family reads the swapped operator off the node this way.

  Both are gated on `opted_in?/1` (the family declared a `c:Mutare.Mutator.variants/0` vocabulary): a
  label is recorded only for a family with a vocabulary to validate it against, keeping this
  *recording* side consistent with the *validation* side (`Mutare.Mutators.vocabulary/1`).

  A mutation is usually **one** kind (a single label), but may be several: a value-family mutant
  that collapses two relationships onto one value (`Mutare.Mutators.IntegerLiteral`'s deduped `1 - 1`/`0`)
  yields `["pred", "zero"]`, and a qualifier naming *either* suppresses it. `carried`/`variant/2`
  may each be `nil`, a single label, or a list — all normalized here through `List.wrap/1`.
  """
  @spec variant(Spec.t(), Macro.t(), Macro.t(), Mutation.variant()) :: [String.t()]
  def variant(%Spec{module: module}, original, mutated, carried \\ nil) do
    cond do
      not opted_in?(module) ->
        []

      not is_nil(carried) ->
        normalize_labels(carried)

      function_exported?(module, :variant, 2) ->
        normalize_labels(module.variant(original, mutated))

      true ->
        []
    end
  end

  defp normalize_labels(labels),
    do: labels |> List.wrap() |> Enum.map(&Mutare.Mutator.normalize_label/1) |> Enum.uniq()

  @doc """
  Whether `module` opts into the variant-label system — it exports `c:Mutare.Mutator.variants/0`,
  declaring the label vocabulary. The *single* definition of "opted in", shared by `variant/4`
  (which records a site's label) and `Mutare.Mutators.vocabulary/1` (which validates a
  `[family:label]` qualifier against the declared labels) — so a family exposes a vocabulary
  exactly when its mutations can carry labels. *How* a family assigns those labels (a production-time
  `Mutare.Mutator.Mutation.tagged/2` tag, or the `c:Mutare.Mutator.variant/2` callback) is an
  implementation detail, not part of opting in. A module exporting `variant/2` but **no** `variants/0`
  declares no vocabulary, so it is *not* opted in (its labels would validate against nothing).
  (`exports?/3` loads the module on demand, so an un-loadable module degrades to `false`.)
  """
  @spec opted_in?(module()) :: boolean()
  def opted_in?(module), do: exports?(module, :variants, 0)
end
