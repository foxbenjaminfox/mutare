defmodule Mutare.IgnoreEmissionTest do
  use ExUnit.Case, async: false

  alias Mutare.{Manifest, Selector, Transform}

  defmodule CountedVariant do
    @behaviour Mutare.Mutator
    def name, do: :counted_variant
    def variants, do: ~w(sub)
    def mutate({:+, meta, args}), do: [{:-, meta, args}]
    def mutate(_node), do: :skip

    def variant(_original, _mutated) do
      send(self(), :variant_called)
      "sub"
    end
  end

  setup do
    Selector.put(Selector.baseline())
    on_exit(fn -> Selector.put(Selector.baseline()) end)
    :ok
  end

  test "counting reserves ignored ids without constructing sites or deriving variants" do
    source = """
    defmodule CountIgnored do
      def run(x), do: x + 2 # mutare:ignore[counted_variant:sub] intentional
    end
    """

    opts = [mutators: [CountedVariant], selection_lines: MapSet.new([2])]
    assert %{mutants: 1, selected_ids: [1]} = Transform.count_report(source, opts)
    refute_received :variant_called

    assert {^source, [%{id: 1, ignored: true, ignore_reason: "intentional"}], 2} =
             Transform.transform_string_with_sites(source, opts)

    assert_received :variant_called
    refute_received :variant_called
  end

  for {name, body, mutators, calls} <- [
        {:nested,
         """
         # mutare:ignore-file[arithmetic] file reason
         def run(x), do: x + 2 >= 3 # mutare:ignore[relational:>] boundary
         """, [:arithmetic, :relational], [{:run, [0]}, {:run, [1]}, {:run, [2]}]},
        {:lifted,
         """
         # mutare:ignore-start[relational, guard_drop, clause_drop] delegated guard
         def run(x) when x >= 2, do: x + 3
         def run(_), do: 0
         # mutare:ignore-end
         def partial(x) when x >= 2, do: x # mutare:ignore[relational:>, clause_drop] boundary
         def partial(_), do: 0 # mutare:ignore[clause_drop]
         """, [:arithmetic, :relational, :guard_drop, :clause_drop],
         [{:run, [0]}, {:run, [2]}, {:partial, [0]}, {:partial, [2]}]},
        {:case_clauses,
         """
         def run(x) do
           case x do
             2 -> 10 # mutare:ignore[integer:zero] zero is covered elsewhere
             n when n >= 3 -> n + 4 # mutare:ignore[relational:>, guard_drop]
             _ -> 20
           end
         end
         """, [:integer, :relational, :arithmetic, :guard_drop],
         [{:run, [0]}, {:run, [2]}, {:run, [4]}]},
        {:binding_and_pipe,
         """
         def run(xs) do
           [a, b] = xs # mutare:ignore[pattern_swap] order is intentional
           a + b
         end
         def piped(xs) do
           xs |> Enum.take(2) # mutare:ignore[integer:zero] empty is covered elsewhere
         end
         """, [:pattern_swap, :arithmetic, :integer], [{:run, [[2, 3]]}, {:piped, [[1, 2, 3]]}]},
        {:hosted,
         """
         import Mutare.Test.HostDSL
         def run(n), do: filter([:ok], n > 1) # mutare:ignore[host_filter:boundary] boundary
         def raw(n), do: filter([:ok], n > 2) # mutare:ignore[host_filter] all flips
         """, [Mutare.Test.HostMutator],
         [{:run, [0]}, {:run, [1]}, {:run, [2]}, {:raw, [2]}, {:raw, [3]}]},
        {:attributed,
         """
         import Mutare.Test.QueryDSL
         def run(y) do
           query(
             where: 1 == y,
             select: 2 # mutare:ignore[attributed_query:drop] keep selection
           )
         end
         """, [Mutare.Test.AttributedQueryMutator], [{:run, [1]}]}
      ] do
    @body body
    @mutators mutators
    @calls calls
    test "#{name}: ignored sites keep their identity but emit no branches or coverage" do
      module = Module.concat(__MODULE__, "Fixture#{System.unique_integer([:positive])}")
      source = "defmodule #{inspect(module)} do\n#{@body}\nend\n"
      opts = [mutators: @mutators, start_id: 101, summarize_sites: true]
      unsuppressed = String.replace(source, "mutare:ignore", "disabled:ignore")

      {_full_meta, full_sites, full_next} =
        Transform.transform_string_with_sites(unsuppressed, opts)

      {meta, sites, next_id} = Transform.transform_string_with_sites(source, opts)
      {ignored, live} = Enum.split_with(sites, & &1.ignored)

      assert ignored != []
      assert live != []
      assert next_id == full_next
      assert Transform.count_string(source, opts) == length(sites)
      assert Enum.map(sites, &%{&1 | ignored: false, ignore_reason: nil}) == full_sites
      assert Transform.render_sites(source, opts) == sites
      assert emitted_ids(meta) == MapSet.new(live, & &1.id)
      assert coverage_ids(meta) == MapSet.new(live, & &1.id)

      # Turning every candidate off also removes dispatchers, hoists, and DSL scaffolding,
      # and preserves even the source's deliberately unformatted indentation byte for byte.
      all_ignored = "# mutare:ignore-file generated fixture\n" <> unsuppressed
      {unchanged, all_sites, all_next} = Transform.transform_string_with_sites(all_ignored, opts)
      assert unchanged == all_ignored
      assert all_next == next_id
      assert Enum.all?(all_sites, &(&1.ignored and &1.ignore_reason == "generated fixture"))

      assert [{^module, _}] = Mutare.Test.Compile.string(meta)

      on_exit(fn ->
        :code.purge(module)
        :code.delete(module)
      end)

      baseline = Enum.map(@calls, fn {fun, args} -> apply(module, fun, args) end)

      for site <- ignored do
        Selector.put(site.id)
        assert Enum.map(@calls, fn {fun, args} -> apply(module, fun, args) end) == baseline
      end
    end
  end

  test "ignored replacements cannot poison compilation in bodies or lifted guards" do
    module = Module.concat(__MODULE__, "Poison#{System.unique_integer([:positive])}")

    source = """
    # mutare:ignore-file[poison] invalid custom replacement
    defmodule #{inspect(module)} do
      def run(x), do: x + 2
      def guarded(x) when x + 2 > 3, do: x
      def guarded(_), do: 0
    end
    """

    opts = [mutators: [Mutare.Test.PoisonMutator, :arithmetic, :relational]]
    {meta, sites, _next} = Transform.transform_string_with_sites(source, opts)
    ignored = Enum.filter(sites, & &1.ignored)

    assert Enum.sort(Enum.map(ignored, & &1.kind)) == [:in_place, :lifted]
    assert Enum.all?(ignored, &(&1.mutated_code == "mutare_unbound_xyz" and not &1.poisoned))
    refute meta =~ "mutare_unbound_xyz"

    assert [{^module, _}] = Mutare.Test.Compile.string(meta)

    on_exit(fn ->
      :code.purge(module)
      :code.delete(module)
    end)

    assert apply(module, :run, [2]) == 4
    assert apply(module, :guarded, [2]) == 2
    assert apply(module, :guarded, [0]) == 0

    live = Enum.find(sites, &(&1.kind == :in_place and &1.mutator == :arithmetic))
    Selector.put(live.id)
    assert apply(module, :run, [2]) == 0
  end

  defp emitted_ids(source) do
    source
    |> Manifest.from_source()
    |> Map.fetch!(:regions)
    |> Enum.flat_map(& &1.ids)
    |> MapSet.new()
  end

  defp coverage_ids(source) do
    helper = Mutare.Coverage.Recorder.fixture_module()

    {_ast, ids} =
      source
      |> Code.string_to_quoted!()
      |> Macro.prewalk([], fn
        {{:., _, [^helper, :hit]}, _, [ids]} = node, acc -> {node, ids ++ acc}
        node, acc -> {node, acc}
      end)

    MapSet.new(ids)
  end
end
