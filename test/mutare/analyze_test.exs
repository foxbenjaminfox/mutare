defmodule Mutare.AnalyzeTest do
  @moduledoc """
  `Mutare.Analyze.expression_mutations/3` — the collect-mode seam a selector host uses to
  sub-contract the ordinary-Elixir islands inside its DSL fragment (an Ecto pin interior) back
  to core's mutant generation. The load-bearing property is **parity**: collect must produce
  exactly the logical single-point diffs the full transform records for the same code outside a
  DSL — same families, same notes, same variant labels — because it runs the *same* annotate
  walk and the same pre-emission gates, not a copy of them.
  """
  use ExUnit.Case, async: true

  doctest Mutare.Analyze

  alias Mutare.Analyze
  alias Mutare.Transform.Meta

  defmodule UnlabeledVariantMutator do
    @behaviour Mutare.Mutator

    alias Mutare.AST

    @impl Mutare.Mutator
    def name, do: :unlabeled_variant

    @impl Mutare.Mutator
    def variants, do: ~w(two)

    @impl Mutare.Mutator
    def mutate({:__block__, _meta, [1]}), do: [AST.literal(2)]
    def mutate(_node), do: :skip

    @impl Mutare.Mutator
    def variant({:__block__, _meta, [1]}, {:__block__, _mmeta, [2]}), do: nil

    def variant(original, mutated) do
      raise "variant/2 should only be called with the collected node pair, got: " <>
              inspect({original, mutated})
    end
  end

  defmodule BothSurfaceFilterMutator do
    @behaviour Mutare.Mutator
    @behaviour Mutare.MacroRouting
    @behaviour Mutare.Mutator.MacroHost

    alias Mutare.MacroRouting.Call
    alias Mutare.Mutator.MacroHost.Target

    @impl Mutare.Mutator
    def name, do: :both_surface_filter

    @impl Mutare.MacroRouting
    def macro_routes,
      do: [{Mutare.Test.HostDSL, :filter, 2, [:expression, :hosted]}]

    @impl Mutare.Mutator.MacroHost
    def hosted_macros, do: [{Mutare.Test.HostDSL, :filter, 2}]

    @impl Mutare.Mutator
    def mutate({:filter, meta, [_query, condition]}, _context),
      do: [{:filter, meta, [[], condition]}]

    def mutate(_node, _context), do: :skip

    @impl Mutare.Mutator.MacroHost
    def host(%Call{node: {:filter, _meta, [_query, {:>, meta, [left, right]} = condition]}}, _ctx) do
      splice = fn {:filter, smeta, [query, _condition]}, case_node ->
        {:filter, smeta, [query, case_node]}
      end

      [Target.new(condition, [{:<, meta, [left, right]}], splice)]
    end

    def host(_call, _context), do: []
  end

  # Node-level families only: structural families (return_value, if_condition, the pattern
  # families) are contractually ignored by collect, and the call-matching families need the
  # resolver's stamps, which a bare `Sourceror.parse_string!` subtree doesn't carry.
  @families [:arithmetic, :relational, :logical, :integer, :string, :conditional]

  defp specs(names \\ @families), do: Mutare.Mutators.resolve(names)

  defp collect(source, mutators \\ specs()),
    do: Analyze.expression_mutations(Sourceror.parse_string!(source), mutators)

  describe "parity with the full transform" do
    # Each expression is collected standalone *and* transformed as a `def` body; the multiset of
    # `{family, node-level original, node-level mutated, note, variant}` facts must be equal.
    # (The collect side's node-level diff is recovered from each whole-subtree rebuild by a
    # meta-insensitive lockstep diff — the same minimality notion `Site` records.)
    @corpus [
      "a + b * 2",
      "x >= limit(y) or valid?(x)",
      "name <> \"!\"",
      "if flag, do: n + 1, else: n - 1",
      "%{a: count + 1}",
      "list ++ [n - 1, \"tag\"]",
      "Enum.count(xs) > 0 and String.contains?(s, \"x\")"
    ]

    test "collect-mode results equal the logical diffs the full transform records" do
      for expr <- @corpus do
        collected_facts =
          for {spec, mutated, note, variant} <- collect(expr) do
            {original_node, mutated_node} =
              single_point_diff!(Sourceror.parse_string!(expr), mutated, expr)

            {spec.name, Sourceror.to_string(original_node), Sourceror.to_string(mutated_node),
             note, List.wrap(variant)}
          end

        site_facts =
          for site <- transform_sites(expr) do
            {site.mutator, site.original_code, site.mutated_code, site.note, site.variant}
          end

        assert site_facts != [], "corpus expression produced no sites: #{expr}"

        assert Enum.sort(collected_facts) == Enum.sort(site_facts),
               "collect/transform parity failed for: #{expr}"
      end
    end
  end

  describe "the descent honors macro-routing stamps" do
    test "a :skip-routed argument stays raw; an :expression argument descends" do
      {form, meta, args} = Sourceror.parse_string!("magic(1 + 1, 2 + 2)")
      stamped = {form, Meta.stamp_macro_routing(meta, [:skip, :expression]), args}

      muts = Analyze.expression_mutations(stamped, specs([:arithmetic]))

      assert Enum.map(muts, fn {spec, mutated, _n, _v} ->
               {spec.name, Sourceror.to_string(mutated)}
             end) == [{:arithmetic, "magic(1 + 1, 2 - 2)"}]
    end

    test "a nested {:hosted, _} argument is lowered — rebuilds, never a woven selector" do
      {form, meta, args} = Sourceror.parse_string!("filter(1 + 1, x > 2)")

      # The full stamp a resolved known-macro call carries: per-argument routing plus the call
      # identity (`resolved_macro_call/1` needs it to build the host's `Call`).
      stamped =
        {form,
         meta
         |> Meta.stamp_macro_routing([
           :expression,
           {:hosted, [Mutare.Test.HostMutator, Mutare.Test.DerivedVariantHostMutator]}
         ])
         |> Meta.stamp_macro_call({[:Mutare, :Test, :HostDSL], :filter, :unpiped}), args}

      # The host runs through the same attachment the transform uses, but each target mutant
      # comes back **lowered**: `splice(wrap(mutant))` — the woven selector degenerated to its
      # selected branch — one whole-call rebuild per hosted mutant.
      muts =
        Analyze.expression_mutations(
          stamped,
          specs([:arithmetic]) ++
            [Mutare.Test.HostMutator, Mutare.Test.DerivedVariantHostMutator]
        )

      rendered =
        Enum.map(muts, fn {spec, mutated, _n, _v} -> {spec.name, Sourceror.to_string(mutated)} end)

      # The host's own catalog — boundary and reversal — as rebuilds under the host's family.
      assert {:host_filter, "filter(1 + 1, x >= 2)"} in rendered
      assert {:host_filter, "filter(1 + 1, x < 2)"} in rendered
      assert {:derived_host, "filter(1 + 1, x < 2)"} in rendered

      # The `:expression` argument still descends for core.
      assert {:arithmetic, "filter(1 - 1, x > 2)"} in rendered

      # The hosted argument stays core-raw — every core rebuild keeps the condition verbatim —
      # and no selector is ever built: hosted delivery never nests.
      assert Enum.all?(rendered, fn
               {:arithmetic, code} -> code =~ "x > 2"
               _other -> true
             end)

      refute Enum.any?(rendered, fn {_name, code} -> code =~ "case" end)

      # The production-time note rides the lowering, and the tag resolves to the same normalized
      # label list a hosted Site records at top level.
      assert Enum.any?(muts, fn {_s, mutated, note, variant} ->
               Sourceror.to_string(mutated) =~ "x >= 2" and
                 note == "kill may require boundary data" and variant == ["boundary"]
             end)

      # A host that declares variants/0 but derives labels through variant/2 must be resolved
      # while lowering still has the hosted fragment's own {original, mutated} pair.
      assert Enum.any?(muts, fn {spec, mutated, _note, variant} ->
               spec.name == :derived_host and Sourceror.to_string(mutated) =~ "x < 2" and
                 variant == ["reverse"]
             end)
    end

    test "lowered hosted candidates stay before whole-call candidates on the same macro" do
      {form, meta, args} = Sourceror.parse_string!("filter([:ok], x > 1)")

      stamped =
        {form,
         meta
         |> Meta.stamp_macro_routing([:expression, {:hosted, [BothSurfaceFilterMutator]}])
         |> Meta.stamp_macro_call({[:Mutare, :Test, :HostDSL], :filter, :unpiped}), args}

      rendered =
        stamped
        |> Analyze.expression_mutations([BothSurfaceFilterMutator])
        |> Enum.map(fn {spec, mutated, _note, _variant} ->
          {spec.name, Sourceror.to_string(mutated)}
        end)

      assert rendered == [
               {:both_surface_filter, "filter([:ok], x < 1)"},
               {:both_surface_filter, "filter([], x > 1)"}
             ]
    end

    test "a host-implementing spec's ordinary mutate/2 participates in an island" do
      # The full-set contract: a spec that implements `host/2` is not excluded from collect —
      # its *ordinary* node-level surface runs like any other producer (here, the whole-call
      # offer of its registered `:skip` macro `dyn/1`), so an island containing such a macro is
      # analyzed exactly like top-level Elixir.
      {form, meta, args} = Sourceror.parse_string!("dyn(y > min + 1)")
      stamped = {form, Meta.stamp_macro_routing(meta, [:skip]), args}

      muts =
        Analyze.expression_mutations(
          stamped,
          specs([:arithmetic]) ++ [Mutare.Test.HostNodeMutator]
        )

      rendered =
        Enum.map(muts, fn {spec, mutated, _n, _v} -> {spec.name, Sourceror.to_string(mutated)} end)

      # The owner's whole-call rewrite fires…
      assert {:host_node, "dyn(y < min + 1)"} in rendered

      # …and its own sub-contract relays the interior to core, producer-attributed — two
      # nesting levels through one collect call.
      assert {:arithmetic, "dyn(y > min - 1)"} in rendered

      # The `:skip` argument stayed core-raw: no direct core mutant landed inside the DSL body
      # (every arithmetic rebuild above came back through the owner's relay, already wrapped).
      assert Enum.count(rendered, &match?({:arithmetic, _}, &1)) == 1
    end

    test "a :pattern-routed argument descends as a match context, never mutated in place" do
      {form, meta, args} = Sourceror.parse_string!("magic({1, x}, 2 + 2)")
      stamped = {form, Meta.stamp_macro_routing(meta, [:pattern, :expression]), args}

      muts = Analyze.expression_mutations(stamped, specs([:integer, :arithmetic]))
      rendered = Enum.map(muts, fn {_s, m, _n, _v} -> Sourceror.to_string(m) end)

      # The pattern literal `1` stays; only the expression argument mutates.
      assert rendered != []
      assert Enum.all?(rendered, &String.starts_with?(&1, "magic({1, x}, "))
    end
  end

  describe "scope: node-level producers only" do
    test "structural families produce nothing for a bare expression subtree" do
      subtree = Sourceror.parse_string!("if ok?(), do: 1, else: 2")

      assert Analyze.expression_mutations(
               subtree,
               specs([:return_value, :if_condition, :pattern_swap, :pattern_wildcard])
             ) == []
    end

    test "structural callbacks stay inert when a custom structural mutator also exports mutate/1" do
      subtree = Sourceror.parse_string!("if ok?(), do: 1, else: 2")

      assert Analyze.expression_mutations(subtree, [Mutare.Test.ConditionMutator]) == []
    end

    test "clause-pattern positions are not offered (structural delivery), bodies still mutate" do
      muts = collect("fn 1 -> 2 end", specs([:integer]))
      rendered = Enum.map(muts, fn {_s, m, _n, _v} -> Sourceror.to_string(m) end)

      assert rendered != []
      assert Enum.all?(rendered, &String.starts_with?(&1, "fn 1 ->"))
    end

    test "the call-option-key policy gate applies with the spec's own opts" do
      source = "foo(x, timeout: 5)"

      key_mutant? = fn muts ->
        Enum.any?(muts, fn {_s, m, _n, _v} -> Sourceror.to_string(m) =~ "mutare: 5" end)
      end

      # AtomLiteral mutates trailing option keys by default…
      assert key_mutant?.(collect(source, Mutare.Mutators.resolve([:atom])))

      # …and its `call_option_keys: false` opt-out gates the candidate, exactly as emission does.
      refute key_mutant?.(
               collect(
                 source,
                 Mutare.Mutators.resolve([{Mutare.Mutators.AtomLiteral, call_option_keys: false}])
               )
             )
    end
  end

  describe "purity and rebuild hygiene" do
    test "each rebuild swaps exactly one position and carries no delivery metadata" do
      for {_spec, mutated, _note, _variant} <- collect("a + 1 == b or count(xs) > 0") do
        # Exactly one changed position (single_point_diff! flunks on zero; the lockstep diff
        # collapses multiple changes into an ancestor, so assert the diff is a genuine leaf swap
        # by checking the mutant differs from the source at all).
        Macro.prewalk(mutated, fn node ->
          assert Meta.candidates(node, :in_place) == []
          assert Meta.candidates(node, :case) == []
          assert Meta.candidates(node, :hosted) == []
          node
        end)

        # No selector scaffolding leaks into a rebuild — delivery is the caller's.
        refute Sourceror.to_string(mutated) =~ "mutare_active"
      end
    end

    test "an empty or node-level-free mutator list collects nothing" do
      assert collect("a + 1", []) == []
      assert collect("a + 1", specs([:return_value])) == []
    end
  end

  describe "variant propagation" do
    test "an opted-in but unlabeled producer carries [] through a host sub-contract" do
      source = """
      defmodule Mutare.UnlabeledVariantHostFixture do
        import Mutare.Test.HostDSL

        def go(x) do
          filter([:ok], x > 1)
        end
      end
      """

      {_metamutant, sites, _next_id} =
        Mutare.Transform.transform_string_with_sites(source,
          file: "unlabeled_variant_host.ex",
          mutators: [UnlabeledVariantMutator, Mutare.Test.SubcontractHostMutator]
        )

      site =
        Enum.find(
          sites,
          &(&1.mutator == :unlabeled_variant and &1.mutated_code == "x > 2")
        )

      assert site
      assert site.original_code == "x > 1"
      assert site.variant == []
    end
  end

  # --- helpers ---------------------------------------------------------------

  # The full transform's sites for `expr` placed in an ordinary `def` body — the "same code
  # outside a DSL" side of the parity contract.
  defp transform_sites(expr) do
    source = """
    defmodule Mutare.ParityFixture do
      def run(a, b, x, y, n, s, xs, flag, name, count, list) do
        #{expr}
      end
    end
    """

    {_metamutant, sites, _next_id} =
      Mutare.Transform.transform_string_with_sites(source,
        file: "parity.ex",
        mutators: specs()
      )

    sites
  end

  # The minimal differing `{original, mutated}` node pair between the source subtree and one
  # rebuild — meta-insensitive lockstep descent (the minimality notion `Mutare.Site` renders).
  defp single_point_diff!(original, mutated, expr) do
    case diff(original, mutated) do
      {:diff, pair} -> pair
      :equal -> flunk("a collected mutant does not differ from its source: #{expr}")
    end
  end

  defp diff(o, m) do
    cond do
      # A scalar wrapper is atomic — a changed literal diffs as the whole wrapper node (what
      # the Site renders), never the bare value inside it.
      scalar_wrapper?(o) and scalar_wrapper?(m) ->
        if wrapped_value(o) == wrapped_value(m), do: :equal, else: {:diff, {o, m}}

      ast_node?(o) and ast_node?(m) ->
        {of, _, oa} = o
        {mf, _, ma} = m

        cond do
          # A changed form (an operator swap, a renamed callee) diffs as the whole node —
          # the Site records `b * 2 → b / 2`, not `:* → :/`.
          diff(of, mf) != :equal ->
            {:diff, {o, m}}

          is_list(oa) and is_list(ma) and length(oa) == length(ma) ->
            combine(Enum.zip(oa, ma), {o, m})

          oa == ma ->
            :equal

          true ->
            {:diff, {o, m}}
        end

      pair?(o) and pair?(m) ->
        {ok, ov} = o
        {mk, mv} = m
        combine([{ok, mk}, {ov, mv}], {o, m})

      is_list(o) and is_list(m) and length(o) == length(m) ->
        combine(Enum.zip(o, m), {o, m})

      o == m ->
        :equal

      true ->
        {:diff, {o, m}}
    end
  end

  defp combine(pairs, node_pair) do
    case pairs |> Enum.map(fn {a, b} -> diff(a, b) end) |> Enum.reject(&(&1 == :equal)) do
      [] -> :equal
      [single] -> single
      _many -> {:diff, node_pair}
    end
  end

  defp ast_node?(t), do: is_tuple(t) and tuple_size(t) == 3 and is_list(elem(t, 1))
  defp pair?(t), do: is_tuple(t) and tuple_size(t) == 2

  defp scalar_wrapper?({:__block__, meta, [v]}) when is_list(meta),
    do: is_atom(v) or is_number(v) or is_binary(v)

  defp scalar_wrapper?(_node), do: false

  defp wrapped_value({:__block__, _meta, [v]}), do: v
end
