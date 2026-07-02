defmodule Mutare.Test.HostDSL do
  @moduledoc """
  A tiny fake DSL with a `filter/2` macro, the test analog of Ecto's `where` — a macro
  whose **condition** argument is a fragment with foreign (non-Elixir) evaluation that core
  must mutate *inside* the DSL, not by wrapping the whole call. Unlike Ecto there is no real
  `^`/`dynamic` (which would need the dep), so the woven selector `case` is spliced straight
  into the condition position; that exercises the whole hosted machinery — shape-aware
  routing, the `host/2` seam, core building the selector + ids + Site + coverage + poison —
  without any external dependency.

  A real, loadable `defmacro` so a bare `import Mutare.Test.HostDSL` resolves `filter` by
  reflection (the same path the built-in known-macro tests use).
  """

  @doc """
  Keep `query` when `condition` is truthy, else drop it (`[]`). The condition's value is
  **observable** in the result, so a mutated fragment (`>` → `>=`) changes behaviour and can
  be killed — unlike a DSL that discards its condition.
  """
  defmacro filter(query, condition) do
    quote do
      if unquote(condition), do: unquote(query), else: []
    end
  end

  @doc """
  A **binding-escaping** DSL macro (the `destructure` analog): bind `pattern` from a list
  chosen by `condition`'s truthiness, the bindings **escaping** into the caller's scope. Its
  arg 0 routes as `:binding_pattern` (so it earns structural swap/wildcard mutants via the
  tuple-re-export delivery) and arg 1 as `:hosted` (the comparison fragment) — so the *same*
  call node carries both a `Candidate.MacroPattern` and a `Candidate.Hosted`, the case the
  hosted emit path must dispatch correctly after the hosted selectors are woven.
  """
  defmacro pick(pattern, condition) do
    quote do
      unquote(pattern) = if unquote(condition), do: [1, 2], else: [0, 0]
    end
  end

  @doc """
  A **keyword-shorthand** DSL macro — the analog of Ecto's `where(q, col: val)` form, whose
  second argument is a keyword list of `field: value` pairs (the keys are field *names*, not
  values to mutate). Exercises the per-keyword-pair `{:keyword, value_treatments}` routing and
  the `:interpolated` value treatment: a value is routed `:interpolated`, so core mutates it (a literal
  family) but delivers the selector `^`-pinned (`category: ^(case … end)`). Like Ecto, this DSL
  accepts an interpolated `^value` but not a bare `case` — so the macro **strips the pin** from
  each value (the test analog of Ecto interpolating it), proving the pinned metamutant compiles.
  A nested keyword list value (`filters: [name: "x"]`, the `from(S, where: [x: v])` shape) is
  unpinned recursively, so a nested `:interpolated` value compiles too.
  """
  defmacro set(query, assigns) do
    assigns = unpin(assigns)

    quote do
      {unquote(query), unquote(assigns)}
    end
  end

  # Recursively consume `^value` interpolations (the analog of Ecto reading a pinned value), so a
  # metamutant that `^`-pins a value's selector compiles — including a value that is itself a
  # keyword list, whose inner values are pinned too. A non-pinned value passes through.
  defp unpin({:^, _meta, [inner]}), do: inner

  defp unpin(list) when is_list(list) do
    Enum.map(list, fn
      {key, value} -> {key, unpin(value)}
      other -> unpin(other)
    end)
  end

  defp unpin(other), do: other
end

defmodule Mutare.Test.HostMutator do
  @moduledoc """
  A reference **selector-hosting** custom mutator, used in tests to exercise the deep-DSL
  extensions: the `:hosted` argument treatment, the `:routing` shape-aware classifier
  (`c:Mutare.MacroRouting.route_arguments/2`), and the mutator-supplied selector host
  (`c:Mutare.Mutator.MacroHost.host/2`). It produces *only* through the host, so it carries no
  `mutate/1` — `name/0` plus `host/2` is a complete mutator.

  It registers `Mutare.Test.HostDSL.filter/2` with `:routing`, so the **condition** argument's
  treatment is decided per call shape: a comparison (`x > 1`) is a `:hosted` DSL fragment (core
  weaves the host's selector into it), while plain data (`category: "Foo"`) is an ordinary
  `:expression` (mutated in place). For a hosted condition, `host/2` supplies core with the
  logical original/mutant fragments (its *own* comparison-flip catalog) and a `splice` that
  drops the assembled selector `case` into the condition position; core owns the ids, the Site
  (showing only the `x > 1` → `x >= 1` diff), the coverage record, and poison mapping.
  """
  @behaviour Mutare.Mutator
  @behaviour Mutare.MacroRouting
  @behaviour Mutare.Mutator.MacroHost

  alias Mutare.MacroRouting.{ArgumentRoutes, Call}
  alias Mutare.Mutator.MacroHost.Target
  alias Mutare.Mutator.Mutation

  @comparisons [:>, :<, :>=, :<=]

  @impl Mutare.Mutator
  def name, do: :host_filter

  # Opt into the variant-label system so a tagged *host* mutant's label is recorded on its Site —
  # the boundary flip carries `boundary` (see `flips/1`), proving a `host/2`-supplied variant rides
  # through `Mutare.Transform.HostedEmit` to the Site (and a `[host_filter:boundary]` directive
  # validates against this vocabulary).
  @impl Mutare.Mutator
  def variants, do: ~w(boundary)

  # `filter` routes its condition by shape (`:routing`); `pick` is a binding-escaping macro
  # with a **static** routing — arg 0 the escaping pattern (`:binding_pattern`), arg 1 the
  # hosted comparison (`:hosted`) — so one call node carries both a `MacroPattern` and a
  # `Hosted` candidate, exercising the hosted path's in-place dispatch.
  @impl Mutare.MacroRouting
  def macro_routes,
    do: [
      {Mutare.Test.HostDSL, :filter, :any, :routing},
      {Mutare.Test.HostDSL, :set, :any, :routing},
      {Mutare.Test.HostDSL, :pick, 2, [:binding_pattern, :hosted]}
    ]

  @impl Mutare.Mutator.MacroHost
  def hosted_macros,
    do: [
      {Mutare.Test.HostDSL, :filter, :any},
      {Mutare.Test.HostDSL, :pick, 2}
    ]

  # Shape-aware routing over the node's *visible* args.
  #
  #   * `set` (the keyword-shorthand macro) routes its keyword-list argument as
  #     `{:keyword, value_treatments}` — per-pair *value* routing, keys left raw. The fixture
  #     policy: a string value is mutable data delivered `:interpolated` (core mutates it, the selector
  #     is `^`-pinned for the DSL), anything else is left raw (`:skip`) — so a test can observe
  #     the value-`:interpolated`/value-`:skip` split and that the keys are never mutated.
  #   * any other macro (`filter`) routes a comparison condition `:hosted` and everything else
  #     (the query, keyword data) as an ordinary `:expression`.
  @impl Mutare.MacroRouting
  def route_arguments(%Call{name: :set, arguments: args} = call, _context) do
    routes =
      Enum.map(args, fn arg ->
        if keyword_list?(arg), do: {:keyword, value_treatments(arg)}, else: :expression
      end)

    ArgumentRoutes.from_visible(call, routes)
  end

  def route_arguments(%Call{arguments: args} = call, _context) do
    routes = Enum.map(args, fn arg -> if comparison?(arg), do: :hosted, else: :expression end)
    ArgumentRoutes.from_visible(call, routes)
  end

  defp keyword_list?(list) when is_list(list) and list != [],
    do: Enum.all?(list, &match?({_k, _v}, &1))

  defp keyword_list?(_node), do: false

  # Per-pair value treatments for `set`'s keyword arg: a string value is mutated and delivered
  # `:interpolated` (the DSL needs `^`); a nested keyword list recurses as `{:keyword, …}` (so a value
  # that is itself `field: value` pairs routes per-pair too — the `from(S, where: [x: v])` shape);
  # anything else (an integer, here) is left raw (`:skip`).
  defp value_treatments(pairs), do: Enum.map(pairs, fn {_k, v} -> value_treatment(v) end)

  # A list value is Sourceror-wrapped in `{:__block__, _, [list]}` in a keyword *value* position.
  defp value_treatment({:__block__, _meta, [list]}) when is_list(list),
    do: if(keyword_list?(list), do: {:keyword, value_treatments(list)}, else: :skip)

  defp value_treatment(v), do: if(string_literal?(v), do: :interpolated, else: :skip)

  defp string_literal?({:__block__, _meta, [s]}) when is_binary(s), do: true
  defp string_literal?(_node), do: false

  # The selector host: produce one target for the condition fragment. Both two-visible-arg
  # macros host their condition at index 1 — `filter(query, condition)` (query at 0) and
  # `pick(pattern, condition)` (the escaping pattern at 0, mutated separately by the
  # `:binding_pattern` route). The piped stage `query |> filter(condition)` has it at index 0
  # (the query is the piped LHS).
  @impl Mutare.Mutator.MacroHost
  def host(%Call{node: {_form, _meta, [_arg0, condition]}}, _context),
    do: condition_target(condition, 1)

  def host(%Call{node: {_form, _meta, [condition]}}, _context),
    do: condition_target(condition, 0)

  def host(_call, _context), do: []

  defp condition_target(condition, index) do
    case flips(condition) do
      [] ->
        []

      mutants ->
        # Replace the condition (visible arg `index`) with the assembled selector `case`.
        # `wrap` is the identity default (no `dynamic`-style wrapping in this fixture DSL).
        splice = fn {form, meta, args}, case_node ->
          {form, meta, List.replace_at(args, index, case_node)}
        end

        [Target.new(condition, mutants, splice)]
    end
  end

  # The host's own (foreign-semantics) catalog: flip a comparison both ways, reusing the operands
  # so each mutant is compile-safe. The **boundary** neighbour carries per-mutant metadata (the
  # `%Mutare.Mutator.Mutation{}` form — a `note` advisory the report surfaces *and* a `boundary`
  # variant label, both recorded on the Site), while the **reversal** is a bare node (no metadata)
  # — so one target exercises both forms.
  defp flips({op, meta, [left, right]}) when op in @comparisons do
    [boundary, reversal] = flip_targets(op)

    [
      %Mutation{
        node: {boundary, meta, [left, right]},
        note: "kill may require boundary data",
        variant: "boundary"
      },
      {reversal, meta, [left, right]}
    ]
  end

  defp flips(_node), do: []

  # Each comparison's boundary neighbour (noted) and its reversal (bare) — two genuinely distinct
  # mutants per operator (`>` → `>=` and `>` → `<`).
  defp flip_targets(:>), do: [:>=, :<]
  defp flip_targets(:<), do: [:<=, :>]
  defp flip_targets(:>=), do: [:>, :<=]
  defp flip_targets(:<=), do: [:<, :>=]

  defp comparison?({op, _meta, [_left, _right]}) when op in @comparisons, do: true
  defp comparison?(_node), do: false
end

defmodule Mutare.Test.SubcontractHostMutator do
  @moduledoc """
  A selector host that **sub-contracts** the ordinary-Elixir island inside its hosted fragment
  back to core's mutant generation — the `mutare_ecto` pin-interior pattern
  (`where: u.age > ^(min + 1)`), minus the pin syntax this dependency-free DSL doesn't need.

  It hosts `filter/2`'s comparison condition (like `Mutare.Test.HostMutator`) and treats the
  comparison's **right operand** as the island: its own foreign-semantics catalog contributes
  only the comparison reversal, while every mutant *inside* the right operand comes from
  `Mutare.Analyze.expression_mutations/3` over `context.mutators` (the run's enabled non-host
  specs, threaded by core) — each relayed as a `%Mutare.Mutator.Mutation{}` with `producer:`
  set, so the Site (and its `# mutare:ignore` vocabulary) belongs to the core family that
  reasoned about it, not to this host. Delivery stays 100% host-owned: the relayed rebuilds are
  just more branches of the same woven selector.
  """
  @behaviour Mutare.Mutator
  @behaviour Mutare.MacroRouting
  @behaviour Mutare.Mutator.MacroHost

  alias Mutare.MacroRouting.{ArgumentRoutes, Call}
  alias Mutare.Mutator.MacroHost.Target
  alias Mutare.Mutator.Mutation

  @comparisons [:>, :<, :>=, :<=]

  @impl Mutare.Mutator
  def name, do: :sub_host

  @impl Mutare.MacroRouting
  def macro_routes, do: [{Mutare.Test.HostDSL, :filter, :any, :routing}]

  @impl Mutare.Mutator.MacroHost
  def hosted_macros, do: [{Mutare.Test.HostDSL, :filter, :any}]

  @impl Mutare.MacroRouting
  def route_arguments(%Call{arguments: args} = call, _context) do
    routes = Enum.map(args, fn arg -> if comparison?(arg), do: :hosted, else: :expression end)
    ArgumentRoutes.from_visible(call, routes)
  end

  # The condition is the last visible argument (index 1 direct, 0 piped).
  @impl Mutare.Mutator.MacroHost
  def host(%Call{node: {_form, _meta, args}}, context) when length(args) in [1, 2] do
    index = length(args) - 1

    case Enum.at(args, index) do
      {op, meta, [left, right]} = condition when op in @comparisons ->
        mutants = [
          own_reversal(op, meta, left, right) | island_mutants(op, meta, left, right, context)
        ]

        splice = fn {form, smeta, sargs}, case_node ->
          {form, smeta, List.replace_at(sargs, index, case_node)}
        end

        [Target.new(condition, mutants, splice)]

      _other ->
        []
    end
  end

  def host(_call, _context), do: []

  # The host's own (foreign-semantics) catalog: just the comparison reversal, a bare node.
  defp own_reversal(op, meta, left, right), do: {reverse(op), meta, [left, right]}

  # The sub-contract: core generates the right operand's mutants under the user's configured
  # families; the host rebuilds its condition around each and relays it with `producer:` set.
  defp island_mutants(op, meta, left, right, context) do
    for {spec, mutated, note, variant} <-
          Mutare.Analyze.expression_mutations(right, context.mutators, context) do
      Mutation.new({op, meta, [left, mutated]}, producer: spec, note: note, variant: variant)
    end
  end

  defp reverse(:>), do: :<
  defp reverse(:<), do: :>
  defp reverse(:>=), do: :<=
  defp reverse(:<=), do: :>=

  defp comparison?({op, _meta, [_left, _right]}) when op in @comparisons, do: true
  defp comparison?(_node), do: false
end

defmodule Mutare.Test.SecondHostMutator do
  @moduledoc "A second host-only subscriber used to prove independent hosts compose."
  @behaviour Mutare.Mutator
  @behaviour Mutare.Mutator.MacroHost

  @impl Mutare.Mutator
  def name, do: :second_host

  @impl Mutare.Mutator.MacroHost
  def hosted_macros, do: [{Mutare.Test.HostDSL, :filter, :any}]

  @impl Mutare.Mutator.MacroHost
  def host(%Mutare.MacroRouting.Call{node: {form, _meta, args}}, _context)
      when form == :filter and length(args) in [1, 2] do
    index = length(args) - 1
    original = Enum.at(args, index)

    splice = fn {name, meta, current_args}, case_node ->
      {name, meta, List.replace_at(current_args, index, case_node)}
    end

    [
      Mutare.Mutator.MacroHost.Target.new(
        original,
        [Mutare.AST.literal(true)],
        splice
      )
    ]
  end

  def host(_call, _context), do: []
end

defmodule Mutare.Test.CustomRangeHostMutator do
  @moduledoc """
  A second host-only subscriber that targets the same fragment as HostMutator, but reports a
  custom Site range. Selector nesting must still use the fragment's own source identity, not this
  report range, or this host's splice overwrites the selector woven by the earlier host.
  """
  @behaviour Mutare.Mutator
  @behaviour Mutare.Mutator.MacroHost

  @impl Mutare.Mutator
  def name, do: :custom_range_host

  @impl Mutare.Mutator.MacroHost
  def hosted_macros, do: [{Mutare.Test.HostDSL, :filter, :any}]

  @impl Mutare.Mutator.MacroHost
  def host(%Mutare.MacroRouting.Call{node: {form, _meta, args}}, _context)
      when form == :filter and length(args) in [1, 2] do
    index = length(args) - 1
    original = Enum.at(args, index)

    splice = fn {name, meta, current_args}, case_node ->
      {name, meta, List.replace_at(current_args, index, case_node)}
    end

    [
      Mutare.Mutator.MacroHost.Target.new(
        original,
        [Mutare.AST.literal(true)],
        splice,
        range: expanded_range(original)
      )
    ]
  end

  def host(_call, _context), do: []

  defp expanded_range(original) do
    case Mutare.Transform.NodeRange.get(original) do
      %Sourceror.Range{} = range ->
        %{range | end: Keyword.update!(range.end, :column, &(&1 + 1))}

      nil ->
        nil
    end
  end
end

defmodule Mutare.Test.ShadowedHostMutator do
  @moduledoc "An exact host subscription shadowed by a more specific non-hosted route."
  @behaviour Mutare.Mutator
  @behaviour Mutare.Mutator.MacroHost

  @impl Mutare.Mutator
  def name, do: :shadowed_host

  @impl Mutare.Mutator.MacroHost
  def hosted_macros, do: [{Mutare.Test.HostDSL, :filter, 2}]

  @impl Mutare.Mutator.MacroHost
  def host(_call, _context), do: []
end

defmodule Mutare.Test.BroadHostedRouteMutator do
  @moduledoc """
  A host mutator whose `macro_routes/0` declares a **whole-module** static `:hosted` route while
  its subscription covers only one macro. A broad static `:hosted` requires a subscription
  covering its *full* selector — otherwise some matched call would have no deliverer — so the
  registry rejects the pair at build.
  """
  @behaviour Mutare.Mutator
  @behaviour Mutare.Mutator.MacroHost
  @behaviour Mutare.MacroRouting

  @impl Mutare.Mutator
  def name, do: :broad_hosted_route

  @impl Mutare.MacroRouting
  def macro_routes, do: [{Mutare.Test.HostDSL, :*, :hosted}]

  @impl Mutare.Mutator.MacroHost
  def hosted_macros, do: [{Mutare.Test.HostDSL, :filter, 2}]

  @impl Mutare.Mutator.MacroHost
  def host(_call, _context), do: []
end

defmodule Mutare.Test.EmptySubscriptionHostMutator do
  @moduledoc "A host-only mutator whose empty subscription list is an invalid inert capability."
  @behaviour Mutare.Mutator
  @behaviour Mutare.Mutator.MacroHost

  @impl Mutare.Mutator
  def name, do: :empty_subscription_host

  @impl Mutare.Mutator.MacroHost
  def hosted_macros, do: []

  @impl Mutare.Mutator.MacroHost
  def host(_call, _context), do: []
end

defmodule Mutare.Test.PipedDSL do
  @moduledoc """
  A one-argument DSL macro (`rotate/1`) whose **sole** argument is a hosted fragment — used
  to exercise the unsupported corner where a *static* `:hosted` lands on argument 0 of a
  **piped** call (`frag |> rotate()`), where argument 0 is the piped value, not part of the
  macro node `host/2` receives. See `Mutare.Test.PipedHostMutator`.
  """
  defmacro rotate(condition) do
    quote do: if(unquote(condition), do: :ok, else: :no)
  end
end

defmodule Mutare.Test.PipedHostMutator do
  @moduledoc """
  A host mutator registering `Mutare.Test.PipedDSL.rotate/1` with a **static** `:hosted`
  argument 0 (not the `:routing` classifier). Direct `rotate(frag)` hosts fine, but a piped
  `frag |> rotate()` puts the hosted fragment at the piped-value position — undeliverable —
  so `Mutare.Transform.Resolve` raises rather than silently dropping the mutation. `host/2`
  exists only to satisfy build-time validation (it is never reached on the piped path, which
  raises first).
  """
  @behaviour Mutare.Mutator
  @behaviour Mutare.MacroRouting
  @behaviour Mutare.Mutator.MacroHost

  @impl Mutare.Mutator
  def name, do: :piped_host

  @impl Mutare.MacroRouting
  def macro_routes, do: [{Mutare.Test.PipedDSL, :rotate, 1, :hosted}]

  @impl Mutare.Mutator.MacroHost
  def hosted_macros, do: [{Mutare.Test.PipedDSL, :rotate, 1}]

  @impl Mutare.Mutator.MacroHost
  def host(_call, _context), do: []
end

defmodule Mutare.Test.NoDeliveryHostMutator do
  @moduledoc """
  A `:routing` classifier whose `c:Mutare.MacroRouting.route_arguments/2` routes a comparison condition
  `:hosted` but which **omits** `c:Mutare.Mutator.MacroHost.host/2` to deliver it. Build-time validation
  passes (a `:routing` route is only required to implement `route_arguments/2` — a classifier may
  legitimately never route `:hosted`), but the moment a concrete call *is* routed `:hosted` with
  no host to deliver it, `Mutare.Transform.Resolve.MacroStamp` raises rather
  than silently leaving the fragment raw and dropping the intended mutation. It is a routing-only
  mutator (no host), so its `mutate/1` is its mutation producer.
  """
  @behaviour Mutare.Mutator
  @behaviour Mutare.MacroRouting

  @comparisons [:>, :<, :>=, :<=]

  @impl Mutare.Mutator
  def name, do: :no_delivery_host

  @impl Mutare.Mutator
  def mutate(_node), do: :skip

  @impl Mutare.MacroRouting
  def macro_routes, do: [{Mutare.Test.HostDSL, :filter, :any, :routing}]

  # Routes a comparison condition `:hosted` — but there is no `host/2` to deliver it.
  @impl Mutare.MacroRouting
  def route_arguments(%Mutare.MacroRouting.Call{arguments: args} = call, _context) do
    routes = Enum.map(args, fn arg -> if comparison?(arg), do: :hosted, else: :expression end)
    Mutare.MacroRouting.ArgumentRoutes.from_visible(call, routes)
  end

  defp comparison?({op, _meta, [_left, _right]}) when op in @comparisons, do: true
  defp comparison?(_node), do: false
end

defmodule Mutare.Test.IncompleteHostMutator do
  @moduledoc """
  A host mutator that registers a **static** `:hosted` macro argument but **forgets** to
  implement `c:Mutare.Mutator.MacroHost.host/2`. Used to prove `Mutare.MacroRouting.Registry.build/3`
  rejects an un-deliverable hosting registration at *build* time (the contributing module is
  required to export `host/2` for the route), rather than failing cryptically at delivery later.
  """
  @behaviour Mutare.Mutator
  @behaviour Mutare.MacroRouting

  @impl Mutare.Mutator
  def name, do: :incomplete_host

  @impl Mutare.Mutator
  def mutate(_node), do: :skip

  # Static `:hosted` at argument 1, but no `host/2` — undeliverable, caught at build.
  @impl Mutare.MacroRouting
  def macro_routes, do: [{Mutare.Test.HostDSL, :filter, 2, [:expression, :hosted]}]
end

defmodule Mutare.Test.KeywordHostedMutator do
  @moduledoc """
  A `:routing` classifier that hosts values nested inside keyword routing. The host still receives
  and weaves into the whole macro node; the nested treatment only identifies which values core must
  leave raw while the host builds its targets. It covers both a direct keyword value and a value in
  a nested keyword list, and its `host/2` locates those leaves by reading the routed treatments
  back through `Mutare.Calls.macro_treatment/1` instead of re-classifying the call —
  exercising the documented "permission, not a target list" contract end to end.
  """
  @behaviour Mutare.Mutator
  @behaviour Mutare.MacroRouting
  @behaviour Mutare.Mutator.MacroHost

  @impl Mutare.Mutator
  def name, do: :keyword_hosted

  @impl Mutare.MacroRouting
  def macro_routes, do: [{Mutare.Test.HostDSL, :set, :any, :routing}]

  @impl Mutare.Mutator.MacroHost
  def hosted_macros, do: [{Mutare.Test.HostDSL, :set, :any}]

  # `set(query, assigns)` — leave the query an ordinary expression, route the keyword-list
  # argument `{:keyword, …}` with each pair's value `:hosted`. A value that
  # is itself a keyword list recurses as `{:keyword, …}`, so a nested-shorthand value yields a
  # *nested* `:hosted` (`{:keyword, [{:keyword, [:hosted]}]}`).
  @impl Mutare.MacroRouting
  def route_arguments(
        %Mutare.MacroRouting.Call{name: :set, arguments: [_query, assigns]} = call,
        _context
      )
      when is_list(assigns) do
    Mutare.MacroRouting.ArgumentRoutes.from_visible(
      call,
      [:expression, {:keyword, value_treatments(assigns)}]
    )
  end

  def route_arguments(%Mutare.MacroRouting.Call{arguments: args} = call, _context) do
    Mutare.MacroRouting.ArgumentRoutes.from_visible(
      call,
      Enum.map(args, fn _arg -> :expression end)
    )
  end

  defp value_treatments(pairs), do: Enum.map(pairs, fn {_k, v} -> value_treatment(v) end)

  # A list value is Sourceror-wrapped `{:__block__, _, [list]}` in a keyword *value* position; a
  # keyword-list value recurses, anything else is hosted.
  defp value_treatment({:__block__, _meta, [list]}) when is_list(list),
    do: if(keyword_list?(list), do: {:keyword, value_treatments(list)}, else: :hosted)

  defp value_treatment(_v), do: :hosted

  defp keyword_list?(list) when is_list(list) and list != [],
    do: Enum.all?(list, &match?({_k, _v}, &1))

  defp keyword_list?(_node), do: false

  # Locate the fragments by reading the routed treatments *back* rather than re-classifying:
  # `Mutare.Calls.macro_treatment/1` on the host's own call node returns what
  # `route_arguments/2` produced, so the `:hosted` leaves (and their keyword paths) come from
  # the route itself.
  @impl Mutare.Mutator.MacroHost
  def host(%Mutare.MacroRouting.Call{node: node}, _context) do
    with {_form, _meta, [_query, assigns]} when is_list(assigns) <- node,
         [_query_treatment, {:keyword, treatments}] <-
           Mutare.Calls.macro_treatment(node) do
      for {original, path} <- hosted_leaves(assigns, treatments, []) do
        splice = fn {name, meta, [query, current]}, case_node ->
          {name, meta, [query, replace_keyword_value(current, path, case_node)]}
        end

        Mutare.Mutator.MacroHost.Target.new(original, [replacement(original)], splice)
      end
    else
      _ -> []
    end
  end

  # Walk the assigns pairs in lockstep with the routed value treatments: `:hosted` marks a leaf,
  # `{:keyword, …}` recurses into the Sourceror-wrapped nested list, anything else isn't hosted.
  # The routed list aligns 1:1 with the pairs — core enforces the length strictly at routing.
  defp hosted_leaves(pairs, treatments, path) do
    pairs
    |> Enum.with_index()
    |> Enum.flat_map(fn {{_key, value}, index} ->
      case Enum.at(treatments, index) do
        :hosted ->
          [{value, path ++ [index]}]

        {:keyword, nested_treatments} ->
          {:__block__, _meta, [nested]} = value
          hosted_leaves(nested, nested_treatments, path ++ [index])

        _other ->
          []
      end
    end)
  end

  defp replace_keyword_value(pairs, [index], replacement) do
    {key, _value} = Enum.at(pairs, index)
    List.replace_at(pairs, index, {key, replacement})
  end

  defp replace_keyword_value(pairs, [index | rest], replacement) do
    {key, {:__block__, meta, [nested]}} = Enum.at(pairs, index)
    nested = replace_keyword_value(nested, rest, replacement)
    List.replace_at(pairs, index, {key, {:__block__, meta, [nested]}})
  end

  defp replacement({:__block__, meta, [value]}) when is_binary(value),
    do: {:__block__, meta, [value <> "!"]}

  defp replacement({:__block__, meta, [_value]}), do: {:__block__, meta, [:hosted]}

  # A keyword leaf value need not be a Sourceror-wrapped literal — it can be a variable or any
  # expression. Fall back to a clean-meta sentinel so `replacement/1` stays total (and the mutant
  # still compiles in a value position) rather than raising on the shapes the fixtures don't use.
  defp replacement(_node), do: {:__block__, [], [:hosted]}
end

defmodule Mutare.Test.UnknownTreatmentMutator do
  @moduledoc """
  A `:routing` classifier that returns an **unrecognised** treatment atom (`:bogus`) for a visible
  argument. Without validation it would fall through `Mutare.Transform.Analyze`'s `:expression`
  catch-all and silently mutate a position the author meant to route specially;
  `Mutare.Transform.Resolve.validate_routing!/2` rejects it loudly instead (the classifier analogue
  of build-time static-`args` validation, `Mutare.Macro.Spec.validate_args/1`).
  """
  @behaviour Mutare.Mutator
  @behaviour Mutare.MacroRouting

  @impl Mutare.Mutator
  def name, do: :unknown_treatment

  @impl Mutare.Mutator
  def mutate(_node), do: :skip

  @impl Mutare.MacroRouting
  def macro_routes, do: [{Mutare.Test.HostDSL, :filter, :any, :routing}]

  # Route the condition (visible arg 1) with a bogus treatment; the query stays an expression.
  @impl Mutare.MacroRouting
  def route_arguments(%Mutare.MacroRouting.Call{}, _context) do
    %Mutare.MacroRouting.ArgumentRoutes{visible: [:expression, :bogus], piped: nil}
  end
end

defmodule Mutare.Test.MisroutedKeywordMutator do
  @moduledoc """
  A buggy `:routing` classifier that routes `set`'s second argument `{:keyword, …}` **without
  checking its shape** — so a call site passing a variable (`set(q, opts)`) gets a keyword
  routing for an argument with no pairs. Core leaves the argument raw (the shape fallback) but
  `Mutare.Transform.Resolve.MacroStamp` prints an advisory warning naming this classifier: the
  classifier saw the concrete argument, so the mismatch is its bug, and silent raw-ness would
  read as "no mutants here".
  """
  @behaviour Mutare.Mutator
  @behaviour Mutare.MacroRouting

  @impl Mutare.Mutator
  def name, do: :misrouted_keyword

  @impl Mutare.Mutator
  def mutate(_node), do: :skip

  @impl Mutare.MacroRouting
  def macro_routes, do: [{Mutare.Test.HostDSL, :set, 2, :routing}]

  # Argument 1 is always routed `{:keyword, [:skip]}`, shape unchecked — the bug under test.
  @impl Mutare.MacroRouting
  def route_arguments(%Mutare.MacroRouting.Call{} = call, _context),
    do:
      Mutare.MacroRouting.ArgumentRoutes.from_visible(
        call,
        [:expression, {:keyword, [:skip]}]
      )
end

defmodule Mutare.Test.CompoundInterpolatedMutator do
  @moduledoc """
  A `:routing` classifier that routes every keyword *value* `:interpolated` regardless of shape, so a
  **compound** value (a list/map) lands on `:interpolated`. `:interpolated` is scalar-only — pinning `^`-wraps
  only the value node's own selector, so a compound value's *inner* mutations would emit as bare
  selector `case`s and poison the DSL. `Mutare.Transform.Analyze.reject_non_scalar_pinned!/2` raises
  at analyze time (loud) rather than silently degrading those inner mutants to `:poisoned`. A scalar
  value (a string) still pins normally.
  """
  @behaviour Mutare.Mutator
  @behaviour Mutare.MacroRouting

  @impl Mutare.Mutator
  def name, do: :compound_pinned

  @impl Mutare.Mutator
  def mutate(_node), do: :skip

  @impl Mutare.MacroRouting
  def macro_routes, do: [{Mutare.Test.HostDSL, :set, :any, :routing}]

  @impl Mutare.MacroRouting
  def route_arguments(
        %Mutare.MacroRouting.Call{name: :set, arguments: [_query, assigns]} = call,
        _context
      )
      when is_list(assigns) do
    Mutare.MacroRouting.ArgumentRoutes.from_visible(
      call,
      [:expression, {:keyword, Enum.map(assigns, fn _pair -> :interpolated end)}]
    )
  end

  def route_arguments(%Mutare.MacroRouting.Call{arguments: args} = call, _context) do
    Mutare.MacroRouting.ArgumentRoutes.from_visible(
      call,
      Enum.map(args, fn _arg -> :expression end)
    )
  end
end

defmodule Mutare.Test.BadShapeMutator do
  @moduledoc """
  A `:routing` classifier whose `c:Mutare.MacroRouting.route_arguments/2` returns the wrong type.
  `Mutare.Transform.Resolve.validate_routing!/2` catches it with a clear message rather than letting
  it crash inside `inject_host/2`'s `Enum.map`.
  """
  @behaviour Mutare.Mutator
  @behaviour Mutare.MacroRouting

  @impl Mutare.Mutator
  def name, do: :bad_shape

  @impl Mutare.Mutator
  def mutate(_node), do: :skip

  @impl Mutare.MacroRouting
  def macro_routes, do: [{Mutare.Test.HostDSL, :filter, :any, :routing}]

  @impl Mutare.MacroRouting
  def route_arguments(_call, _context), do: :not_an_argument_routes_struct
end

defmodule Mutare.Test.ArgInterpolatedMutator do
  @moduledoc """
  A `:routing` classifier that routes a whole **list argument** `:interpolated` (the top-level, not
  keyword-value, `:interpolated` shape — a bare list rather than the Sourceror `{:__block__, _, [list]}`
  wrap). It exercises `reject_non_scalar_pinned!/2`'s bare-list descent: the list carries no own
  candidate, so every mutation is on an element (a descendant), and pinning would miss them — caught
  loud rather than poisoned. Routes `filter`'s first argument (the `[:foo]` list) `:interpolated`.
  """
  @behaviour Mutare.Mutator
  @behaviour Mutare.MacroRouting

  @impl Mutare.Mutator
  def name, do: :arg_pinned

  @impl Mutare.Mutator
  def mutate(_node), do: :skip

  @impl Mutare.MacroRouting
  def macro_routes, do: [{Mutare.Test.HostDSL, :filter, :any, :routing}]

  @impl Mutare.MacroRouting
  def route_arguments(%Mutare.MacroRouting.Call{} = call, _context),
    do: Mutare.MacroRouting.ArgumentRoutes.from_visible(call, [:interpolated, :expression])
end

defmodule Mutare.Test.DeadHostMutator do
  @moduledoc """
  A mutator that implements `c:Mutare.Mutator.MacroHost.host/2` but registers only a static,
  non-hosted route — so `host/2` is never reached. The registry rejects this at build (the #8
  safety net) rather than leaving the host silently inert (the symptom of a forgotten
  `:hosted`/`:routing` registration).
  """
  @behaviour Mutare.Mutator
  @behaviour Mutare.MacroRouting
  @behaviour Mutare.Mutator.MacroHost

  @impl Mutare.Mutator
  def name, do: :dead_host

  @impl Mutare.Mutator
  def mutate(_node), do: :skip

  @impl Mutare.MacroRouting
  def macro_routes, do: [{Mutare.Test.HostDSL, :filter, 2, [:expression, :skip]}]

  @impl Mutare.Mutator.MacroHost
  def hosted_macros, do: [{Mutare.Test.HostDSL, :filter, 2}]

  @impl Mutare.Mutator.MacroHost
  def host(_call, _context), do: []
end

defmodule Mutare.Test.DeadRouterMutator do
  @moduledoc """
  A mutator that implements `c:Mutare.MacroRouting.route_arguments/2` but registers no `:routing`
  route — so the classifier is never reached. Rejected at build (the #8 safety net).
  """
  @behaviour Mutare.Mutator
  @behaviour Mutare.MacroRouting

  @impl Mutare.Mutator
  def name, do: :dead_router

  @impl Mutare.Mutator
  def mutate(_node), do: :skip

  @impl Mutare.MacroRouting
  def macro_routes, do: [{Mutare.Test.HostDSL, :filter, 2, [:expression, :skip]}]

  @impl Mutare.MacroRouting
  def route_arguments(call, _context),
    do: Mutare.MacroRouting.ArgumentRoutes.from_visible(call, [:expression, :expression])
end

defmodule Mutare.Test.MalformedHost do
  @moduledoc """
  A plain module with a `host/2` returning **malformed** targets, used to prove
  `Mutare.Mutator.Dispatch.host_targets/3` normalization fails loud: a non-1-arity `:wrap`, a non-string
  `%Mutare.Mutator.Mutation{}` `:note`, a **bare `%{node:, note:}` map** mutant (the rejected
  pre-struct form), and a non-`Sourceror.Range` `:range` each raise an `ArgumentError` (rather
  than a raw `FunctionClauseError`, a silently dropped note, a bare selector spliced into the
  DSL, or a deep crash at site-recording time). Dispatched by the probe node's head so one module
  covers every case.
  """
  alias Mutare.Mutator.Mutation
  alias Mutare.Mutator.MacroHost.Target

  def host(%Mutare.MacroRouting.Call{node: {:bad_wrap, _meta, _args}}, _context),
    do: [%Target{original: 1, mutants: [2], splice: &splice/2, wrap: :not_a_function}]

  def host(%Mutare.MacroRouting.Call{node: {:bad_note, _meta, _args}}, _context),
    do: [%Target{original: 1, mutants: [%Mutation{node: 2, note: 42}], splice: &splice/2}]

  def host(%Mutare.MacroRouting.Call{node: {:bare_map, _meta, _args}}, _context),
    do: [%Target{original: 1, mutants: [%{node: 2, note: "x"}], splice: &splice/2}]

  def host(%Mutare.MacroRouting.Call{node: {:bad_range, _meta, _args}}, _context),
    do: [%Target{original: 1, mutants: [2], splice: &splice/2, range: {3, 7}}]

  def host(_call, _context), do: []

  defp splice(macro_node, _case_node), do: macro_node
end
