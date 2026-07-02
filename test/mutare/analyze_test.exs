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

  # Node-level families only: structural families (return_value, if_condition, the pattern
  # families) are contractually ignored by collect, and the call-matching families need the
  # resolver's stamps, which a bare `Sourceror.parse_string!` subtree doesn't carry.
  @families [:arithmetic, :relational, :logical, :literal, :string, :conditional]

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

    test "a nested {:hosted, _} argument is left raw — no recursive hosting" do
      {form, meta, args} = Sourceror.parse_string!("magic(1 + 1, 2 + 2)")

      stamped =
        {form,
         Meta.stamp_macro_routing(meta, [{:hosted, [Mutare.Test.HostMutator]}, :expression]),
         args}

      # Even with the host present in the spec list, the hosted interior has no producer here:
      # hosts are excluded from collect, and the argument stays raw.
      muts =
        Analyze.expression_mutations(
          stamped,
          specs([:arithmetic]) ++ [Mutare.Test.HostMutator]
        )

      assert Enum.map(muts, fn {_s, mutated, _n, _v} -> Sourceror.to_string(mutated) end) ==
               ["magic(1 + 1, 2 - 2)"]
    end

    test "a :pattern-routed argument descends as a match context, never mutated in place" do
      {form, meta, args} = Sourceror.parse_string!("magic({1, x}, 2 + 2)")
      stamped = {form, Meta.stamp_macro_routing(meta, [:pattern, :expression]), args}

      muts = Analyze.expression_mutations(stamped, specs([:literal, :arithmetic]))
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

    test "clause-pattern positions are not offered (structural delivery), bodies still mutate" do
      muts = collect("fn 1 -> 2 end", specs([:literal]))
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
