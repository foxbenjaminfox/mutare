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
  hosted emit path must dispatch correctly (`Mutare.Transform.emit_hosted_inplace/3`).
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
  the `:pinned` value treatment: a value is routed `:pinned`, so core mutates it (a literal
  family) but delivers the selector `^`-pinned (`category: ^(case … end)`). Like Ecto, this DSL
  accepts an interpolated `^value` but not a bare `case` — so the macro **strips the pin** from
  each value (the test analog of Ecto interpolating it), proving the pinned metamutant compiles.
  A nested keyword list value (`filters: [name: "x"]`, the `from(S, where: [x: v])` shape) is
  unpinned recursively, so a nested `:pinned` value compiles too.
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
  (`c:Mutare.Mutator.macro_routing/1`), and the mutator-supplied selector host
  (`c:Mutare.Mutator.host/2`).

  It registers `Mutare.Test.HostDSL.filter/2` with `:routing`, so the **condition** argument's
  treatment is decided per call shape: a comparison (`x > 1`) is a `:hosted` DSL fragment (core
  weaves the host's selector into it), while plain data (`category: "Foo"`) is an ordinary
  `:expression` (mutated in place). For a hosted condition, `host/2` supplies core with the
  logical original/mutant fragments (its *own* comparison-flip catalog) and a `splice` that
  drops the assembled selector `case` into the condition position; core owns the ids, the Site
  (showing only the `x > 1` → `x >= 1` diff), the coverage record, and poison mapping.
  """
  @behaviour Mutare.Mutator

  @comparisons [:>, :<, :>=, :<=]

  @impl Mutare.Mutator
  def name, do: :host_filter

  # No whole-node mutation — every mutation rides the host.
  @impl Mutare.Mutator
  def mutate(_node), do: :skip

  # `filter` routes its condition by shape (`:routing`); `pick` is a binding-escaping macro
  # with a **static** routing — arg 0 the escaping pattern (`:binding_pattern`), arg 1 the
  # hosted comparison (`:hosted`) — so one call node carries both a `MacroPattern` and a
  # `Hosted` candidate, exercising the hosted path's in-place dispatch.
  @impl Mutare.Mutator
  def macros,
    do: [
      {Mutare.Test.HostDSL, :filter, :any, :routing},
      {Mutare.Test.HostDSL, :set, :any, :routing},
      {Mutare.Test.HostDSL, :pick, 2, [:binding_pattern, :hosted]}
    ]

  # Shape-aware routing over the node's *visible* args.
  #
  #   * `set` (the keyword-shorthand macro) routes its keyword-list argument as
  #     `{:keyword, value_treatments}` — per-pair *value* routing, keys left raw. The fixture
  #     policy: a string value is mutable data delivered `:pinned` (core mutates it, the selector
  #     is `^`-pinned for the DSL), anything else is left raw (`:skip`) — so a test can observe
  #     the value-`:pinned`/value-`:skip` split and that the keys are never mutated.
  #   * any other macro (`filter`) routes a comparison condition `:hosted` and everything else
  #     (the query, keyword data) as an ordinary `:expression`.
  @impl Mutare.Mutator
  def macro_routing({:set, _meta, args}) when is_list(args) do
    Enum.map(args, fn arg ->
      if keyword_list?(arg), do: {:keyword, value_treatments(arg)}, else: :expression
    end)
  end

  def macro_routing({_form, _meta, args}) when is_list(args),
    do: Enum.map(args, fn arg -> if comparison?(arg), do: :hosted, else: :expression end)

  def macro_routing(_node), do: []

  defp keyword_list?(list) when is_list(list) and list != [],
    do: Enum.all?(list, &match?({_k, _v}, &1))

  defp keyword_list?(_node), do: false

  # Per-pair value treatments for `set`'s keyword arg: a string value is mutated and delivered
  # `:pinned` (the DSL needs `^`); a nested keyword list recurses as `{:keyword, …}` (so a value
  # that is itself `field: value` pairs routes per-pair too — the `from(S, where: [x: v])` shape);
  # anything else (an integer, here) is left raw (`:skip`).
  defp value_treatments(pairs), do: Enum.map(pairs, fn {_k, v} -> value_treatment(v) end)

  # A list value is Sourceror-wrapped in `{:__block__, _, [list]}` in a keyword *value* position.
  defp value_treatment({:__block__, _meta, [list]}) when is_list(list),
    do: if(keyword_list?(list), do: {:keyword, value_treatments(list)}, else: :skip)

  defp value_treatment(v), do: if(string_literal?(v), do: :pinned, else: :skip)

  defp string_literal?({:__block__, _meta, [s]}) when is_binary(s), do: true
  defp string_literal?(_node), do: false

  # The selector host: produce one target for the condition fragment. Both two-visible-arg
  # macros host their condition at index 1 — `filter(query, condition)` (query at 0) and
  # `pick(pattern, condition)` (the escaping pattern at 0, mutated separately by the
  # `:binding_pattern` route). The piped stage `query |> filter(condition)` has it at index 0
  # (the query is the piped LHS).
  @impl Mutare.Mutator
  def host({_form, _meta, [_arg0, condition]} = _node, _context),
    do: condition_target(condition, 1)

  def host({_form, _meta, [condition]} = _node, _context),
    do: condition_target(condition, 0)

  def host(_node, _context), do: []

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

        [%{original: condition, mutants: mutants, splice: splice}]
    end
  end

  # The host's own (foreign-semantics) catalog: flip a comparison both ways, reusing the operands
  # so each mutant is compile-safe. The **boundary** neighbour carries a per-mutant note (the
  # `%{node:, note:}` form — a hosting mutator's advisory the report surfaces on the Site), while
  # the **reversal** is a bare node (no note) — so one target exercises both forms.
  defp flips({op, meta, [left, right]}) when op in @comparisons do
    [boundary, reversal] = flip_targets(op)

    [
      %{node: {boundary, meta, [left, right]}, note: "kill may require boundary data"},
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

  @impl Mutare.Mutator
  def name, do: :piped_host

  @impl Mutare.Mutator
  def mutate(_node), do: :skip

  @impl Mutare.Mutator
  def macros, do: [{Mutare.Test.PipedDSL, :rotate, 1, :hosted}]

  @impl Mutare.Mutator
  def host(_node, _context), do: []
end

defmodule Mutare.Test.NoDeliveryHostMutator do
  @moduledoc """
  A `:routing` classifier whose `c:Mutare.Mutator.macro_routing/1` routes a comparison condition
  `:hosted` but which **omits** `c:Mutare.Mutator.host/2` to deliver it. Build-time validation
  passes (a `:routing` spec is only required to implement `macro_routing/1` — a classifier may
  legitimately never route `:hosted`), but the moment a concrete call *is* routed `:hosted` with
  no host to deliver it, `Mutare.Transform.Resolve.reject_undeliverable_hosted!/2` raises rather
  than silently leaving the fragment raw and dropping the intended mutation.
  """
  @behaviour Mutare.Mutator

  @comparisons [:>, :<, :>=, :<=]

  @impl Mutare.Mutator
  def name, do: :no_delivery_host

  @impl Mutare.Mutator
  def mutate(_node), do: :skip

  @impl Mutare.Mutator
  def macros, do: [{Mutare.Test.HostDSL, :filter, :any, :routing}]

  # Routes a comparison condition `:hosted` — but there is no `host/2` to deliver it.
  @impl Mutare.Mutator
  def macro_routing({_form, _meta, args}) when is_list(args),
    do: Enum.map(args, fn arg -> if comparison?(arg), do: :hosted, else: :expression end)

  def macro_routing(_node), do: []

  defp comparison?({op, _meta, [_left, _right]}) when op in @comparisons, do: true
  defp comparison?(_node), do: false
end

defmodule Mutare.Test.IncompleteHostMutator do
  @moduledoc """
  A host mutator that registers a **static** `:hosted` macro argument but **forgets** to
  implement `c:Mutare.Mutator.host/2`. Used to prove `Mutare.Macros.build/2` rejects an
  un-deliverable hosting registration at *build* time (the `validate_host!/3` host-present-but-
  missing-callback branch), rather than failing cryptically at delivery later.
  """
  @behaviour Mutare.Mutator

  @impl Mutare.Mutator
  def name, do: :incomplete_host

  @impl Mutare.Mutator
  def mutate(_node), do: :skip

  # Static `:hosted` at argument 1, but no `host/2` — undeliverable, caught at build.
  @impl Mutare.Mutator
  def macros, do: [{Mutare.Test.HostDSL, :filter, 2, [:expression, :hosted]}]
end
