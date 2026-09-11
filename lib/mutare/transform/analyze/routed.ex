defmodule Mutare.Transform.Analyze.Routed do
  @moduledoc false

  # The call routing of the analyze pass: once `Mutare.Transform.Resolve` has
  # stamped a call's per-argument routing (`meta[:mutare_route]`, from `Mutare.CallRouting.Registry`),
  # this module routes each argument by its declared treatment instead of the default
  # all-runtime descent — a pattern arg (`match?`/`destructure`) isn't mutated in place,
  # an opaque DSL body (`Ecto.Query.from`) is left raw, and a `:hosted` fragment is handed
  # to the registering mutator's selector host.
  #
  # `Mutare.Transform.Analyze` reads the stamp (`Meta.routing/1`, the shared `:mutare_route`
  # contract reader) and routes a recognised call here: `analyze_routed_call/4` for a
  # written/piped stage, `analyze_piped_value/3` for the `|>` LHS that reaches back into a known
  # macro's argument-0 treatment. It drives the descent back through `Analyze.annotate/2` /
  # `Analyze.pattern/2`, with the whole-node offer on `Attach`.

  alias Mutare.AST
  alias Mutare.Mutator.Dispatch
  alias Mutare.Transform.{Candidate, Meta, NodeRange}
  alias Mutare.Transform.Analyze
  alias Mutare.Transform.Analyze.{Attach, CallOptions, Syntax}
  alias Mutare.Transform.Suppression

  import Suppression, only: [is_equality_op: 1, is_negation_op: 1]

  # Analyze a routed call: offer the *whole* node to mutators (so a custom mutator
  # registered for the macro still fires — e.g. an Ecto query mutator on `from(...)`),
  # then route each *visible* argument by its declared treatment instead of the default
  # all-runtime descent. `context` carries the pipe flag (so a pipe-aware custom mutator sees
  # the effective arity); `CallOptions.mark/1` still runs (harmless for `:raw`/`:pattern`
  # args, which carry no candidates; correct for `:expression` args, preserving option-key gating).
  #
  # The context is enriched with `:mutators` — the run's enabled specs, **hosts included** —
  # before both deliveries here: the whole-call offer and the selector hosts
  # (`attach_hosted_candidates/5`). That is the sub-contract seam
  # (`Mutare.Analyze.expression_mutations/3`): a mutator whose routing left a region of this
  # call core-raw (`:raw`, a `{:keyword, …}` `:raw` value, `:hosted`) may hand an
  # ordinary-Elixir island inside it back to core's generation and relay the rebuilds with
  # `producer:`. Injected for registered macro calls only, NOT on ordinary `mutate/1,2` offers:
  # an ordinary node is fully core-descended, so sub-contracting inside one would produce the
  # same logical mutant twice — a registered macro call is exactly where routing can make
  # regions core-raw, i.e. where the sub-contract precondition holds. The list is the full spec
  # set, so an island is analyzed exactly like top-level Elixir — a host-implementing plugin's
  # ordinary surface *and its hosted surface* both produce inside an island. The
  # no-recursive-hosting property is collect's, where it belongs: `expression_mutations` runs a
  # nested `:hosted` stamp's `host/2` through this same attachment but *lowers* each target
  # mutant to a whole-call rebuild (`splice(wrap(mutant))` — the woven selector degenerated to
  # its selected branch), so hosted semantics participate while no selector ever nests.
  def analyze_routed_call(node, routing, env, context \\ %{pipe_mode: :unpiped})

  # The call-level `:skip` (an inert leaf) is normally intercepted by the dispatch before it reaches
  # here (`Mutare.Transform.Analyze.do_analyze_call_node/3`); this clause keeps the contract total
  # for any other caller — no offer, no descent, no hosts.
  def analyze_routed_call(node, :skip, _env, _context), do: node

  def analyze_routed_call(node, routing, env, context) do
    context = Map.put(context, :mutators, env.mutators)
    {form, meta, args} = Attach.offer(node, node, env.mutators, context)
    routed = CallOptions.mark({form, meta, route_macro_args(args, routing, env)})
    attach_hosted_candidates(routed, node, routing, env, context)
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
  # The context handed down already carries `:mutators` (injected once in
  # `analyze_routed_call/4`) — so `host/2` can sub-contract Elixir islands inside its fragment
  # (a pin interior) back to core's families via `Mutare.Analyze.expression_mutations/3`, under
  # the user's actual configuration (`:as` names and opts included).
  defp attach_hosted_candidates(routed, raw_node, routing, env, context) do
    with [_ | _] = hosts <- hosted_hosts(routing),
         specs = Enum.filter(env.mutators, &(&1.module in hosts)),
         [_ | _] = candidates <- Enum.flat_map(specs, &host_candidates(&1, raw_node, context)) do
      put_hosted_candidates(routed, candidates)
    else
      _ -> routed
    end
  end

  defp hosted_hosts(routing) when is_list(routing),
    do: routing |> Enum.flat_map(&hosted_hosts/1) |> Enum.uniq()

  defp hosted_hosts({:hosted, hosts}), do: hosts
  defp hosted_hosts({:keyword, treatments}), do: hosted_hosts(treatments)

  defp hosted_hosts({:keyed, leading, pairs}),
    do:
      hosted_hosts(leading) ++
        Enum.flat_map(pairs, fn {_key, position} -> hosted_hosts(position) end)

  defp hosted_hosts(_), do: []

  # Build the `Candidate.Hosted`s for a macro node from the host's targets, dropping any whose
  # fragment isn't rangeable (no `Mutare.Site` could be recorded). `range` defaults to the
  # logical fragment's own range.
  defp host_candidates(spec, raw_node, context) do
    call = Mutare.Transform.Calls.resolved_routed_call(raw_node)

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
  defp route_macro_args(args, routing, env) do
    args
    |> Enum.with_index()
    |> Enum.map(fn {arg, i} ->
      route_macro_arg(arg, Enum.at(routing, i, :expression), env)
    end)
  end

  # Route one argument by its declared treatment — shared by the visible-arg routing
  # (`route_macro_args/3`) and the piped-value reach-back (`analyze_piped_value/3`), so the
  # piped LHS is treated identically to a written first argument: `:expression` → ordinary
  # runtime (mutate); `:pattern`/`:binding_pattern` → a match context (descend for nested
  # runtime escapes, never mutate the pattern *in place*); `:raw` → leave the argument **as
  # written** (no descent, no mutation — an opaque DSL value the macro accepts even though it is
  # neither a valid expression nor a valid pattern, or a value the user simply wants left alone);
  # `:interior` → descend as an expression but offer nothing on the argument's own node (its
  # contents mutate, the container doesn't — the "an emptied assigns map is a crash-kill, its
  # values are the signal" shape); a keyed refinement → the leading treatment, with named
  # keyword values routed by their own position. `:binding_pattern` routes identically to
  # `:pattern` here; its *extra* structural-mutant offering is delivered separately (the macro
  # call sits in a value-discarded position — see `binding_pattern_macro/1` /
  # `attach_macro_pattern_candidates/4`).
  defp route_macro_arg(arg, :raw, _env), do: arg

  # `:interior`: analyze the argument as ordinary runtime, then drop the in-place candidates that
  # landed on the argument node *itself* — the mirror image of `:interpolated`'s
  # `pin_inplace_candidates/1` (which touches only that same set). Descendants keep theirs.
  #
  # A negation whose operand the equivalent-sibling suppression left un-offered needs one more
  # step, or `:interior` keeps nothing at all. `Mutare.Transform.Analyze` withholds that operand
  # *because the negation carries the mutation for both* (shapes 1-3: a negation over the same
  # operator, over `in`, or over an equality) — and the negation is exactly what `:interior` then
  # drops, so the pair vanishes together and `MyApp.consume(not not x)` yields nothing. Re-analyze
  # the operand on its own once the root is withheld: with no surviving sibling to duplicate, its
  # mutations are distinct again (`not (a == b)` withheld leaves `a == b`, which is neither the
  # original nor the outer's strip). The root still goes through `Analyze.annotate/2` first, so it
  # keeps every other stamp analysis puts on it; only its own candidates go.
  defp route_macro_arg({neg, _meta, [inner]} = arg, :interior, env)
       when is_negation_op(neg) do
    if suppressed_operand?(neg, inner) do
      case strip_interior(arg, env) do
        {^neg, meta, [_withheld]} -> {neg, meta, [Analyze.annotate(inner, env)]}
        other -> other
      end
    else
      strip_interior(arg, env)
    end
  end

  defp route_macro_arg(arg, :interior, env),
    do: strip_interior(arg, env)

  # A keyed refinement `{:keyed, leading, pairs}` over a literal keyword list (the trailing sugar
  # or an explicit `[k: v]`): every pair is routed **once**, by its final position — a named key's
  # value by the position the refinement gives it, every other value and every key by the leading
  # treatment's reading one level down (`descendant_treatment/1`) — and the container is offered
  # by the leading treatment (`offer_container/4`). Choosing the final position *before*
  # descending keeps the once-per-node invariant: a two-pass "route by the leading treatment,
  # then re-route the named values from the raw source" analyzes every named value twice, and
  # with nested calls routed the same way (`f(k: f(k: f(k: …)))`) the repeats compound
  # exponentially — eight levels ran a mutator 256 times over the innermost literal. A non-keyword
  # argument (a variable, a `Keyword.merge/2` call, a map) has no keys to refine and takes the
  # leading treatment alone — exactly the "if it is a literal keyword list with a literal key"
  # contract. (`Mutare.Transform.Tag.tag_routed_arg/4` is the guard-path twin.)
  defp route_macro_arg(arg, {:keyed, leading, pairs}, env) do
    case CallOptions.keyword_pairs(arg) do
      {:ok, kw_pairs, rewrap} ->
        inner = descendant_treatment(leading)

        routed =
          Enum.map(kw_pairs, fn {key, value} ->
            position =
              case List.keyfind(pairs, AST.key_atom(key), 0) do
                {_key, position} -> position
                nil -> inner
              end

            {route_key(key, inner, env), route_macro_arg(value, position, env)}
          end)

        offer_container(rewrap.(routed), arg, leading, env)

      :error ->
        route_macro_arg(arg, leading, env)
    end
  end

  # A `:hosted` position (stamped `{:hosted, host}` by `Mutare.Transform.Resolve`) is left
  # **raw** like `:raw` — core mutates nothing in place here (a bare selector would poison
  # the DSL); the hosting mutator weaves its own selector via `attach_hosted_candidates/5`.
  defp route_macro_arg(arg, {:hosted, _hosts}, _env), do: arg

  # A *bare* `:hosted` should never reach routing — `Resolve.RouteStamp` rewrites hosted treatments
  # to `{:hosted, host}` recursively. Leave it raw anyway, never the runtime catch-all below:
  # splicing a bare selector into an unknown macro position is the one outcome the "never poison"
  # stance forbids, so a future path that slipped a bare `:hosted` through degrades safely.
  defp route_macro_arg(arg, :hosted, _env), do: arg

  # **Per-keyword-pair** routing for a keyword-list argument (classifier-only — produced by a
  # recursive keyword routing from either a static route or
  # `c:Mutare.CallRouting.route_arguments/2`).
  # For each `key: value` pair the **key is left raw** (a keyword key in a DSL is a field/option
  # *name*, not a value to mutate) and the **value is routed by its own treatment** from
  # `value_treatments`, positionally. The motivating case is Ecto's keyword-shorthand `where`
  # (`where(q, category: "Foo", deleted_at: nil)`): mutate `"Foo"` (its value `:expression`) but
  # not the column name `category`, and skip the `deleted_at: nil` pair (`IS NULL`, not `= nil`)
  # by routing its value `:raw`. A value treatment may itself be `{:keyword, …}`, so a *nested*
  # shorthand — a keyword list whose values are keyword lists, e.g. `from(S, where: [x: v])` —
  # routes too. The treatment list is strict: exactly one treatment per pair, or routing raises
  # (`validate_keyword_treatments!/2`) — no silent padding or truncation. A non-keyword argument
  # falls back to raw, so a mis-shaped classification can never splice into a non-pair; when a
  # `:routing` classifier caused that fallback, `Mutare.Transform.Resolve.RouteStamp` already
  # printed an advisory warning at stamp time (a static route stays silent — its non-keyword
  # call sites are legitimate alternate macro forms).
  defp route_macro_arg(arg, {:keyword, value_treatments}, env)
       when is_list(value_treatments),
       do: route_keyword(arg, value_treatments, env)

  # An already-`^`-pinned value under `:interpolated` is descended, not re-pinned: past
  # the user's own `^` the code is plain Elixir evaluated at build time, where a bare selector
  # `case` is legal — so the inner expression is analyzed as ordinary runtime (arbitrarily deep,
  # no scalar restriction) and the existing `^` stays where it was written. Without this, a
  # *static* `:interpolated` route would abort the run on idiomatic target code
  # (`where(q, total: ^(a + b))`) whose value is already interpolated — a shape where the route's
  # assertion isn't even violated. The scalar-only rejection below is reserved for *bare*
  # compounds, where it is.
  defp route_macro_arg({:^, meta, [inner]}, :interpolated, env),
    do: {:^, meta, [Analyze.annotate(inner, env)]}

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
  defp route_macro_arg(arg, :interpolated, env) do
    analyzed = Analyze.annotate(arg, env)
    reject_compound_value!(arg, analyzed)
    pin_inplace_candidates(analyzed)
  end

  defp route_macro_arg(arg, treatment, env)
       when treatment in [:pattern, :binding_pattern],
       do: Analyze.pattern(arg, env)

  defp route_macro_arg(arg, _expression, env), do: Analyze.annotate(arg, env)

  # A keyword key under a keyed refinement, treated as the generic pair clause treats it
  # (`Mutare.Transform.Analyze`): a **block key** (`do:`/`else:`/`rescue:`/`catch:`/`after:`) is a
  # structural label and stays raw — a selector in its place is malformed, and a macro matching
  # `wrap(do: body)` would not even expand — while a data key is a runtime value and follows the
  # leading treatment's reading.
  defp route_key(key, inner, env) do
    if Syntax.block_key?(key), do: key, else: route_macro_arg(key, inner, env)
  end

  # What a leading treatment means one level down a keyed refinement: `:interior` withholds only
  # the container, so its children are ordinary expressions; every other word means the same at
  # every depth (`:raw` children stay raw, `:pattern` children are patterns, `:interpolated`
  # children are each pinned — the scalar-per-value shape the keyword form is for).
  defp descendant_treatment(:interior), do: :expression
  defp descendant_treatment(other), do: other

  # The keyword container's own offer under a keyed refinement, by the leading treatment. Only the
  # Sourceror-wrapped explicit list (`{:__block__, _, [list]}`) is a node the generic walk offers
  # (the collection families' `[…] → []` collapse and pair drops); the bare trailing sugar is a
  # plain list and never was. `:expression` offers it — built from the routed pairs, diffed against
  # the raw argument, as any rebuilt node; every other leading word withholds the container:
  # `:interior` by definition, `:raw`/`:hosted` because the list is DSL data, `:pattern` because a
  # pattern is never offered in place, `:interpolated` because pinning a container is the compound
  # case `reject_compound_value!/2` forbids.
  defp offer_container({:__block__, _meta, _args} = routed, raw, :expression, env),
    do: Attach.offer(routed, raw, env.mutators)

  defp offer_container(routed, _raw, _leading, _env), do: routed

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
              "value :raw, or split it into scalar pairs. (A value the source already " <>
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
  defp route_keyword({:__block__, meta, [list]}, value_treatments, env)
       when is_list(list),
       do: {:__block__, meta, [route_keyword(list, value_treatments, env)]}

  defp route_keyword(list, value_treatments, env) when is_list(list) do
    if CallOptions.keyword_list_shaped?(list) do
      validate_keyword_treatments!(list, value_treatments)

      Enum.zip_with(list, value_treatments, fn {key, value}, treatment ->
        {key, route_macro_arg(value, treatment, env)}
      end)
    else
      list
    end
  end

  defp route_keyword(arg, _value_treatments, _env), do: arg

  # The plain `:interior` move: analyze, then withhold the node's own candidates.
  defp strip_interior(arg, env),
    do: arg |> Analyze.annotate(env) |> strip_own_inplace_candidates()

  # The operands `Mutare.Transform.Analyze` leaves un-offered beneath a negation: shape 1 (the
  # same negation operator again), shape 2 (`in`), shape 3 (an equality operator). An *ordering*
  # operator is deliberately absent — shape 3 excludes it, so it is offered in its own right
  # already and re-analyzing it would change nothing.
  defp suppressed_operand?(neg, {neg, _meta, [_operand]}), do: true
  defp suppressed_operand?(_neg, {:in, _meta, [_left, _right]}), do: true

  defp suppressed_operand?(_neg, {op, _meta, [_left, _right]}) when is_equality_op(op), do: true

  defp suppressed_operand?(_neg, _inner), do: false

  # Drop the in-place candidates on a node's *own* metadata, keeping every descendant's. The
  # `:interior` treatment; same move as `Mutare.Transform.Analyze.QuoteEscape`'s strip.
  defp strip_own_inplace_candidates(node),
    do:
      Candidate.update_candidates(node, fn candidates ->
        Enum.reject(candidates, &match?(%Candidate.InPlace{}, &1))
      end)

  # A `{:keyword, value_treatments}` routing is a per-pair contract: a list shorter than the pairs
  # would silently leave the unnamed values raw (an author who *meant* `:raw` can write it), and a
  # longer one names positions that don't exist — either way the route and the call disagree about
  # the argument's shape, so fail loud rather than under- or over-route. A static route can only
  # satisfy this when every call site has the same pair count; variable shapes belong to `:routing`,
  # whose classifier sees the concrete call.
  defp validate_keyword_treatments!(pairs, value_treatments) do
    if length(pairs) != length(value_treatments) do
      raise ArgumentError,
            "a {:keyword, value_treatments} macro routing must name exactly one treatment per " <>
              "pair, but #{length(value_treatments)} treatment(s) were declared for the " <>
              "#{length(pairs)}-pair `#{Macro.to_string(pairs)}`. Name every pair (use :raw to " <>
              "leave a value as written); when call sites vary in pair count, register the macro with " <>
              ":routing and classify each call's shape in route_arguments/2."
    end
  end

  # The left side of a `|>` whose right side is a known macro: the piped value is the macro's
  # *effective argument 0*, so it inherits position 0's treatment, which `Resolve` recorded on
  # the stage as `:mutare_route_piped` (stamped only when it isn't the `:expression` default —
  # so the common runtime LHS carries no stamp and falls through unchanged). Routing it through
  # the same `route_macro_arg/3` as the visible args keeps the piped position in lockstep with
  # a written first argument: a `1 |> match?(1)` LHS routes as `:pattern`, a `:raw` macro's LHS
  # is left raw, and any other LHS stays ordinary runtime.
  def analyze_piped_value(lhs, {_form, rhs_meta, _args}, env)
      when is_list(rhs_meta) do
    case Meta.piped_routing(rhs_meta) do
      nil -> Analyze.annotate(lhs, env)
      treatment -> route_macro_arg(lhs, treatment, env)
    end
  end

  def analyze_piped_value(lhs, _rhs, env), do: Analyze.annotate(lhs, env)
end
