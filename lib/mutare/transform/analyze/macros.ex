defmodule Mutare.Transform.Analyze.Macros do
  @moduledoc false

  # The known-macro routing of the analyze pass: once `Mutare.Transform.Resolve` has
  # stamped a call's per-argument routing (`meta[:mutare_macro]`, from `Mutare.Macros`),
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

  # When the routing marks any argument `{:hosted, host}` (see `Mutare.Transform.Resolve`),
  # the fragment in that position is mutated by the **hosting mutator's selector host**
  # (`c:Mutare.Mutator.MacroAware.host/2`), not by core. Hand the host the *raw* macro node (so it can
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
  defp attach_hosted_candidates(routed, raw_node, routing, mutators, context) do
    with host when not is_nil(host) <- hosted_host(routing),
         specs = Enum.filter(mutators, &(&1.module == host)),
         [_ | _] = candidates <- Enum.flat_map(specs, &host_candidates(&1, raw_node, context)) do
      put_hosted_candidates(routed, candidates)
    else
      _ -> routed
    end
  end

  # The hosting mutator module named by the first `{:hosted, host}` treatment in a routing tree,
  # or `nil` when no position is hosted. All hosted positions of one macro share a host (the
  # registering mutator), so the first is enough.
  defp hosted_host(routing) when is_list(routing) do
    Enum.find_value(routing, &hosted_host/1)
  end

  defp hosted_host({:hosted, host}), do: host
  defp hosted_host({:keyword, treatments}), do: hosted_host(treatments)

  defp hosted_host(_), do: nil

  # Build the `Candidate.Hosted`s for a macro node from the host's targets, dropping any whose
  # fragment isn't rangeable (no `Mutare.Site` could be recorded). `range` defaults to the
  # logical fragment's own range.
  defp host_candidates(spec, raw_node, context) do
    spec
    |> Dispatch.host_targets(raw_node, Map.take(context, [:pipe_mode]))
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
  defp route_macro_arg(_descent, arg, {:hosted, _host}, _mutators), do: arg

  # A *bare* `:hosted` should never reach routing — `Resolve.MacroStamp` rewrites hosted treatments
  # to `{:hosted, host}` recursively. Leave it raw anyway, never the runtime catch-all below:
  # splicing a bare selector into an unknown macro position is the one outcome the "never poison"
  # stance forbids, so a future path that slipped a bare `:hosted` through degrades safely.
  defp route_macro_arg(_descent, arg, :hosted, _mutators), do: arg

  # **Per-keyword-pair** routing for a keyword-list argument (classifier-only — produced by a
  # `c:Mutare.Mutator.MacroAware.macro_routing/1` that inspected the node; a static `args` can't express it).
  # For each `key: value` pair the **key is left raw** (a keyword key in a DSL is a field/option
  # *name*, not a value to mutate) and the **value is routed by its own treatment** from
  # `value_treatments`, positionally. The motivating case is Ecto's keyword-shorthand `where`
  # (`where(q, category: "Foo", deleted_at: nil)`): mutate `"Foo"` (its value `:expression`) but
  # not the column name `category`, and skip the `deleted_at: nil` pair (`IS NULL`, not `= nil`)
  # by routing its value `:skip`. A value treatment may itself be `{:keyword, …}`, so a *nested*
  # shorthand — a keyword list whose values are keyword lists, e.g. `from(S, where: [x: v])` —
  # routes too. A value position past the list defaults to `:skip` (raw), so only what the
  # classifier explicitly marked is ever mutated; a non-keyword argument falls back to raw, so a
  # mis-shaped classification can never splice into a non-pair.
  defp route_macro_arg(descent, arg, {:keyword, value_treatments}, mutators)
       when is_list(value_treatments),
       do: route_keyword(descent, arg, value_treatments, mutators)

  # A value that must be mutated **`^`-pinned** (classifier-only): it sits in a compile-time DSL
  # position that accepts an interpolated value but not a bare selector `case` — an Ecto
  # keyword-shorthand value (`where(q, category: "Foo")`), where Ecto rejects a raw `case` but
  # accepts `^(case …)`. Analyze it as ordinary runtime so the configured literal families attach
  # their in-place candidates (their *own* names ride to the Site, the value's mutation stays
  # core's), then flag those candidates `pin?` so `emit_site/3` wraps the selector in `^`. Only a
  # **scalar** value belongs here: `pin_inplace_candidates/1` pins only the value node's *own*
  # candidates, so a compound value (`[1, 2]`, `%{…}`) — whose mutations land on *descendant* nodes
  # — would leave those inner selectors un-pinned and poison the DSL. `reject_non_scalar_pinned!/2`
  # fails loud on that (the classifier analogue of the documented scalar-only contract) rather than
  # silently degrading the inner mutants to `:poisoned`.
  defp route_macro_arg(descent, arg, :pinned, mutators) do
    analyzed = descent.annotate(arg, mutators)
    reject_non_scalar_pinned!(arg, analyzed)
    pin_inplace_candidates(analyzed)
  end

  defp route_macro_arg(descent, arg, treatment, mutators)
       when treatment in [:pattern, :binding_pattern],
       do: descent.pattern(arg, mutators)

  defp route_macro_arg(descent, arg, _expression, mutators), do: descent.annotate(arg, mutators)

  # Flag the in-place candidates on a node's own metadata `pin?: true` (the `:pinned` treatment),
  # so emission `^`-pins their selector. Only the node's *own* candidates — a scalar value's
  # mutations sit here; the route is documented scalar-only.
  defp pin_inplace_candidates(node),
    do: Candidate.update_candidates(node, fn cands -> Enum.map(cands, &pin_candidate/1) end)

  defp pin_candidate(%Candidate.InPlace{} = candidate), do: %{candidate | pin?: true}
  defp pin_candidate(other), do: other

  # A `:pinned` value is sound only when every in-place mutation lands on the value node itself —
  # `pin_inplace_candidates/1` `^`-pins only the top node's own candidates. A compound value attaches
  # candidates to *descendant* nodes that pinning would miss; those would emit as bare selector
  # `case`s spliced into the DSL value and poison the build. Raise loudly (the offending value in the
  # message) rather than silently degrade them to `:poisoned`. A value with no descendant candidate —
  # a scalar literal, or a non-literal like a variable (no candidate at all) — is fine.
  defp reject_non_scalar_pinned!(original, analyzed) do
    if descendant_inplace_candidate?(analyzed) do
      raise ArgumentError,
            "a :pinned macro-routing treatment requires a scalar value (its mutation must pin in " <>
              "place), but `#{Macro.to_string(original)}` is compound — its inner mutations cannot " <>
              "be ^-pinned and would poison the DSL. Route a compound value :skip, or split it into " <>
              "scalar pairs."
    end
  end

  # Whether any node *strictly below* `node`'s top carries an in-place candidate.
  defp descendant_inplace_candidate?(node) do
    node |> child_nodes() |> Enum.any?(&subtree_has_inplace_candidate?/1)
  end

  defp child_nodes({_form, _meta, args}) when is_list(args), do: args
  defp child_nodes({left, right}), do: [left, right]
  # A bare list/2-tuple top node (a list argument routed `:pinned` directly, not the Sourceror
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
  # raw (nothing to route).
  defp route_keyword(descent, {:__block__, meta, [list]}, value_treatments, mutators)
       when is_list(list),
       do: {:__block__, meta, [route_keyword(descent, list, value_treatments, mutators)]}

  defp route_keyword(descent, list, value_treatments, mutators) when is_list(list) do
    if CallOptions.keyword_list_shaped?(list) do
      list
      |> Enum.with_index()
      |> Enum.map(fn
        {{key, value}, i} ->
          {key, route_macro_arg(descent, value, Enum.at(value_treatments, i, :skip), mutators)}

        {other, _i} ->
          other
      end)
    else
      list
    end
  end

  defp route_keyword(_descent, arg, _value_treatments, _mutators), do: arg

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
