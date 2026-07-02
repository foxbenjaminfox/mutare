defmodule Mutare.Transform.Analyze.Macros do
  @moduledoc false

  # The known-macro routing of the analyze pass: once `Mutare.Transform.Resolve` has
  # stamped a call's per-argument routing (`meta[:mutare_macro]`, from `Mutare.MacroRouting.Registry`),
  # this module routes each argument by its declared treatment instead of the default
  # all-runtime descent — a pattern arg (`match?`/`destructure`) isn't mutated in place,
  # an opaque DSL body (`Ecto.Query.from`) is left raw, and a `:hosted` fragment is handed
  # to the registering mutator's selector host.
  #
  # `Mutare.Transform.Analyze` reads the stamp (`Meta.macro_routing/1`, the shared `:mutare_macro`
  # contract reader) and routes a recognised call here: `analyze_known_macro/5` for a
  # written/piped stage, `analyze_piped_value/4` for the `|>` LHS that reaches back into a known
  # macro's argument-0 treatment. It drives the descent back through the **injected `descent`**
  # (the `Mutare.Transform.Analyze` module, passed in as the first argument —
  # `descent.annotate/2`, `descent.pattern/2`) rather than naming it statically, with the
  # whole-node offer on the dependency-neutral `Attach`.

  alias Mutare.Mutator.Dispatch
  alias Mutare.Transform.{Candidate, Meta, NodeRange}
  alias Mutare.Transform.Analyze.{Attach, CallOptions}

  # Analyze a known-macro call: offer the *whole* node to mutators (so a custom mutator
  # registered for the macro still fires — e.g. an Ecto query mutator on `from(...)`),
  # then route each *visible* argument by its declared treatment instead of the default
  # all-runtime descent. `context` carries the pipe flag (so a pipe-aware custom mutator sees
  # the effective arity); `CallOptions.mark/1` still runs (harmless for `:skip`/`:pattern`
  # args, which carry no candidates; correct for `:expression` args, preserving option-key gating).
  def analyze_known_macro(descent, node, routing, mutators, context \\ %{pipe_mode: :unpiped}) do
    {form, meta, args} = Attach.offer(node, node, mutators, context)
    routed = CallOptions.mark({form, meta, route_macro_args(descent, args, routing, mutators)})
    attach_hosted_candidates(routed, node, routing, mutators, context)
  end

  # When routing marks any argument `{:hosted, hosts}` (see `Mutare.Transform.Resolve`),
  # the fragment is offered to every subscribed selector host
  # (`c:Mutare.Mutator.MacroHost.host/2`), not by core. Hand the host the *raw* macro node (so it can
  # pull the DSL's bindings for its `wrap`) and attach one `Candidate.Hosted` per target it
  # returns, under a dedicated `:mutare_hosted` key (separate from `:mutare`, since emission
  # weaves the selector into the node rather than wrapping the node in one —
  # `Mutare.Transform.HostedEmit.emit/5`). No hosted position, no host spec, or no targets ⇒
  # the node is left as the ordinary (offered + arg-routed) macro node.
  #
  # The host is a **module**, but it may be enabled under *several* `Mutare.Mutator.Spec`s — a
  # configurable host mutator listed twice with distinct `:as` names / `opts` (e.g. `{Host, as:
  # :a}` and `{Host, as: :b}`). Each such spec is its own family (own name on its Sites, own
  # `opts` reaching `host/2`), exactly as the ordinary path runs every spec in `Dispatch.mutations/3`,
  # so we host *each* matching spec — not just the first — or a duplicate-configured host mutator
  # would silently lose every config past the first.
  #
  # The context handed down carries `:mutators` — the run's enabled **ordinary** (non-host) specs
  # — so `host/2` can sub-contract Elixir islands inside its fragment (a pin interior) back to
  # core's families via `Mutare.Analyze.expression_mutations/3`, under the user's actual
  # configuration (`:as` names and opts included). Hosts are excluded from the list to keep the
  # no-recursive-hosting property obvious: a nested `:hosted` stamp inside a fragment is left raw
  # regardless, and the interior has exactly one producer.
  defp attach_hosted_candidates(routed, raw_node, routing, mutators, context) do
    with [_ | _] = hosts <- hosted_hosts(routing),
         specs = Enum.filter(mutators, &(&1.module in hosts)),
         context = Map.put(context, :mutators, ordinary_mutators(mutators)),
         [_ | _] = candidates <- Enum.flat_map(specs, &host_candidates(&1, raw_node, context)) do
      put_hosted_candidates(routed, candidates)
    else
      _ -> routed
    end
  end

  # The enabled specs that are not selector hosts — what `host/2` receives as
  # `context.mutators` (see `attach_hosted_candidates/5`).
  defp ordinary_mutators(mutators) do
    hosts = Dispatch.implementing(mutators, :host, 2)
    Enum.reject(mutators, &(&1 in hosts))
  end

  defp hosted_hosts(routing) when is_list(routing),
    do: routing |> Enum.flat_map(&hosted_hosts/1) |> Enum.uniq()

  defp hosted_hosts({:hosted, hosts}), do: hosts
  defp hosted_hosts({:keyword, treatments}), do: hosted_hosts(treatments)
  defp hosted_hosts(_), do: []

  # Build the `Candidate.Hosted`s for a macro node from the host's targets, dropping any whose
  # fragment isn't rangeable (no `Mutare.Site` could be recorded). `range` defaults to the
  # logical fragment's own range.
  defp host_candidates(spec, raw_node, context) do
    call = Mutare.Transform.Calls.resolved_macro_call(raw_node)

    spec
    |> Dispatch.host_targets(call, Map.take(context, [:pipe_mode, :mutators]))
    |> Enum.map(fn target ->
      %Candidate.Hosted{
        mutator: spec,
        original: target.original,
        mutants: target.mutants,
        wrap: target.wrap,
        splice: target.splice,
        range: target.range || NodeRange.get(target.original)
      }
    end)
    |> Enum.filter(& &1.range)
  end

  defp put_hosted_candidates(node, candidates), do: Meta.put_candidates(node, :hosted, candidates)

  # Route each argument by its treatment. A position past the routing list defaults to
  # `:expression`.
  defp route_macro_args(descent, args, routing, mutators) do
    args
    |> Enum.with_index()
    |> Enum.map(fn {arg, i} ->
      route_macro_arg(descent, arg, Enum.at(routing, i, :expression), mutators)
    end)
  end

  # Route one macro argument by its declared treatment — shared by the visible-arg routing
  # (`route_macro_args/4`) and the piped-value reach-back (`analyze_piped_value/4`), so the
  # piped LHS is treated identically to a written first argument: `:expression` → ordinary
  # runtime (mutate); `:pattern`/`:binding_pattern` → a match context (descend for nested
  # runtime escapes, never mutate the pattern *in place*); `:skip` → leave the argument **raw**
  # (no descent, no mutation — an opaque value the macro may accept even though it is neither a
  # valid expression nor a valid pattern). `:binding_pattern` routes identically to `:pattern`
  # here; its *extra* structural-mutant offering is delivered separately (the macro call sits in
  # a value-discarded position — see `binding_pattern_macro/1` / `attach_macro_pattern_candidates/4`).
  defp route_macro_arg(_descent, arg, :skip, _mutators), do: arg

  # A `:hosted` position (stamped `{:hosted, host}` by `Mutare.Transform.Resolve`) is left
  # **raw** like `:skip` — core mutates nothing in place here (a bare selector would poison
  # the DSL); the hosting mutator weaves its own selector via `attach_hosted_candidates/5`.
  defp route_macro_arg(_descent, arg, {:hosted, _hosts}, _mutators), do: arg

  # A *bare* `:hosted` should never reach routing — `Resolve.MacroStamp` rewrites hosted treatments
  # to `{:hosted, host}` recursively. Leave it raw anyway, never the runtime catch-all below:
  # splicing a bare selector into an unknown macro position is the one outcome the "never poison"
  # stance forbids, so a future path that slipped a bare `:hosted` through degrades safely.
  defp route_macro_arg(_descent, arg, :hosted, _mutators), do: arg

  # **Per-keyword-pair** routing for a keyword-list argument (classifier-only — produced by a
  # recursive keyword routing from either a static route or
  # `c:Mutare.MacroRouting.route_arguments/2`).
  # For each `key: value` pair the **key is left raw** (a keyword key in a DSL is a field/option
  # *name*, not a value to mutate) and the **value is routed by its own treatment** from
  # `value_treatments`, positionally. The motivating case is Ecto's keyword-shorthand `where`
  # (`where(q, category: "Foo", deleted_at: nil)`): mutate `"Foo"` (its value `:expression`) but
  # not the column name `category`, and skip the `deleted_at: nil` pair (`IS NULL`, not `= nil`)
  # by routing its value `:skip`. A value treatment may itself be `{:keyword, …}`, so a *nested*
  # shorthand — a keyword list whose values are keyword lists, e.g. `from(S, where: [x: v])` —
  # routes too. The treatment list is strict: exactly one treatment per pair, or routing raises
  # (`validate_keyword_treatments!/2`) — no silent padding or truncation. A non-keyword argument
  # falls back to raw, so a mis-shaped classification can never splice into a non-pair.
  defp route_macro_arg(descent, arg, {:keyword, value_treatments}, mutators)
       when is_list(value_treatments),
       do: route_keyword(descent, arg, value_treatments, mutators)

  # An already-`^`-pinned value under `:interpolated` is descended, not re-pinned: past
  # the user's own `^` the code is plain Elixir evaluated at build time, where a bare selector
  # `case` is legal — so the inner expression is analyzed as ordinary runtime (arbitrarily deep,
  # no scalar restriction) and the existing `^` stays where it was written. Without this, a
  # *static* `:interpolated` route would abort the run on idiomatic target code
  # (`where(q, total: ^(a + b))`) whose value is already interpolated — a shape where the route's
  # assertion isn't even violated. The scalar-only rejection below is reserved for *bare*
  # compounds, where it is.
  defp route_macro_arg(descent, {:^, meta, [inner]}, :interpolated, mutators),
    do: {:^, meta, [descent.annotate(inner, mutators)]}

  # A bare scalar value that must be mutated **`^`-pinned**: it sits in a compile-time DSL position
  # that accepts an interpolated value but not a bare selector `case` — an Ecto keyword-shorthand
  # value (`where(q, category: "Foo")`), where Ecto rejects a raw `case` but accepts `^(case …)`.
  # Analyze it as ordinary runtime so the configured literal families attach their in-place
  # candidates (their *own* names ride to the Site, the value's mutation stays core's), then flag
  # those candidates `pin?` so `emit_site/3` wraps the selector in `^`. Only a **scalar** value
  # belongs here: `pin_inplace_candidates/1` pins only the value node's *own* candidates, so a
  # compound value (`[1, 2]`, `%{…}`) — whose mutations land on *descendant* nodes — would leave
  # those inner selectors un-pinned and poison the DSL. `reject_compound_value!/2` fails loud on
  # that (the classifier analogue of the documented scalar-only contract) rather than silently
  # degrading the inner mutants to `:poisoned`.
  defp route_macro_arg(descent, arg, :interpolated, mutators) do
    analyzed = descent.annotate(arg, mutators)
    reject_compound_value!(arg, analyzed)
    pin_inplace_candidates(analyzed)
  end

  defp route_macro_arg(descent, arg, treatment, mutators)
       when treatment in [:pattern, :binding_pattern],
       do: descent.pattern(arg, mutators)

  defp route_macro_arg(descent, arg, _expression, mutators), do: descent.annotate(arg, mutators)

  # Flag the in-place candidates on a node's own metadata `pin?: true` (the `:interpolated`
  # treatment), so emission `^`-pins their selector. Only the node's *own* candidates — a scalar
  # value's mutations sit here; the route is documented scalar-only.
  defp pin_inplace_candidates(node),
    do: Candidate.update_candidates(node, fn cands -> Enum.map(cands, &pin_candidate/1) end)

  defp pin_candidate(%Candidate.InPlace{} = candidate), do: %{candidate | pin?: true}
  defp pin_candidate(other), do: other

  # An `:interpolated` value is sound only when every in-place mutation lands on the value
  # node itself — `pin_inplace_candidates/1` `^`-pins only the top node's own candidates. A compound
  # value attaches candidates to *descendant* nodes that pinning would miss; those would emit as
  # bare selector `case`s spliced into the DSL value and poison the build. Raise loudly (the
  # offending value in the message) rather than silently degrade them to `:poisoned`. A value with
  # no descendant candidate — a scalar literal, or a non-literal like a variable (no candidate at
  # all) — is fine.
  defp reject_compound_value!(original, analyzed) do
    if descendant_inplace_candidate?(analyzed) do
      raise ArgumentError,
            "an :interpolated macro-routing treatment requires a scalar value (its " <>
              "mutation must pin in place), but `#{Macro.to_string(original)}` is compound — its " <>
              "inner mutations cannot be ^-pinned and would poison the DSL. Route a compound " <>
              "value :skip, or split it into scalar pairs. (A value the source already " <>
              "^-interpolates is fine: it is descended as plain Elixir.)"
    end
  end

  # Whether any node *strictly below* `node`'s top carries an in-place candidate.
  defp descendant_inplace_candidate?(node) do
    node |> child_nodes() |> Enum.any?(&subtree_has_inplace_candidate?/1)
  end

  defp child_nodes({_form, _meta, args}) when is_list(args), do: args
  defp child_nodes({left, right}), do: [left, right]

  # A bare list/2-tuple top node (a list argument routed `:interpolated` directly, not the Sourceror
  # `{:__block__, _, [list]}`-wrapped keyword value) carries no own meta, so pinning it pins nothing
  # — every candidate is on an element, i.e. a descendant. Descend the elements so it's caught.
  defp child_nodes(list) when is_list(list), do: list
  defp child_nodes(_), do: []

  defp subtree_has_inplace_candidate?(node) do
    {_, found?} = Macro.prewalk(node, false, fn n, acc -> {n, acc or inplace_candidate?(n)} end)
    found?
  end

  defp inplace_candidate?(node),
    do: Enum.any?(Meta.candidates(node, :in_place), &match?(%Candidate.InPlace{}, &1))

  # Route a keyword list's pair *values* by `value_treatments` (keys raw). Handles the bare list
  # (a trailing keyword argument, `where(q, x: v)`) and the Sourceror `{:__block__, _, [list]}`
  # wrap a list takes in a keyword *value* position (`where: [x: v]` inside a `from`) — unwrapped,
  # routed, re-wrapped so the rendering metadata is preserved. A non-keyword-shaped value is left
  # raw (nothing to route). The treatment list is **strict**: exactly one treatment per pair, or
  # `validate_keyword_treatments!/2` raises.
  defp route_keyword(descent, {:__block__, meta, [list]}, value_treatments, mutators)
       when is_list(list),
       do: {:__block__, meta, [route_keyword(descent, list, value_treatments, mutators)]}

  defp route_keyword(descent, list, value_treatments, mutators) when is_list(list) do
    if CallOptions.keyword_list_shaped?(list) do
      validate_keyword_treatments!(list, value_treatments)

      Enum.zip_with(list, value_treatments, fn {key, value}, treatment ->
        {key, route_macro_arg(descent, value, treatment, mutators)}
      end)
    else
      list
    end
  end

  defp route_keyword(_descent, arg, _value_treatments, _mutators), do: arg

  # A `{:keyword, value_treatments}` routing is a per-pair contract: a list shorter than the pairs
  # would silently leave the unnamed values raw (an author who *meant* `:skip` can write it), and a
  # longer one names positions that don't exist — either way the route and the call disagree about
  # the argument's shape, so fail loud rather than under- or over-route. A static route can only
  # satisfy this when every call site has the same pair count; variable shapes belong to `:routing`,
  # whose classifier sees the concrete call.
  defp validate_keyword_treatments!(pairs, value_treatments) do
    if length(pairs) != length(value_treatments) do
      raise ArgumentError,
            "a {:keyword, value_treatments} macro routing must name exactly one treatment per " <>
              "pair, but #{length(value_treatments)} treatment(s) were declared for the " <>
              "#{length(pairs)}-pair `#{Macro.to_string(pairs)}`. Name every pair (use :skip to " <>
              "leave a value raw); when call sites vary in pair count, register the macro with " <>
              ":routing and classify each call's shape in route_arguments/2."
    end
  end

  # The left side of a `|>` whose right side is a known macro: the piped value is the macro's
  # *effective argument 0*, so it inherits position 0's treatment, which `Resolve` recorded on
  # the stage as `:mutare_macro_piped` (stamped only when it isn't the `:expression` default —
  # so the common runtime LHS carries no stamp and falls through unchanged). Routing it through
  # the same `route_macro_arg/4` as the visible args keeps the piped position in lockstep with
  # a written first argument: a `1 |> match?(1)` LHS routes as `:pattern`, a `:skip` macro's LHS
  # is left raw, and any other LHS stays ordinary runtime.
  def analyze_piped_value(descent, lhs, {_form, rhs_meta, _args}, mutators)
      when is_list(rhs_meta) do
    case Meta.piped_macro_routing(rhs_meta) do
      nil -> descent.annotate(lhs, mutators)
      treatment -> route_macro_arg(descent, lhs, treatment, mutators)
    end
  end

  def analyze_piped_value(descent, lhs, _rhs, mutators), do: descent.annotate(lhs, mutators)
end
