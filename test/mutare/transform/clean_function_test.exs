defmodule Mutare.Transform.CleanFunctionTest do
  use ExUnit.Case, async: false
  import Mutare.Test.Metamutant

  alias Mutare.Coverage.Recorder
  alias Mutare.{Manifest, Report, Selector, Transform}

  @fixture Mutare.CleanFunctionFixture
  @source """
  defmodule Mutare.CleanFunctionFixture do
    def run(n) when n > 0 do
      Mutare.Transform.CleanFunctionTest.observe(n)
      n = n + 2
      n = n * 3
      n = n - 4
      n = n + 5
      n = n * 2
      n = n - 3
      div(n, n - 11)
    end
    def run(0), do: :zero
    def run(n), do: {:negative, n}

    def other(n), do: n + 7
  end
  """
  @mutators [:arithmetic, :relational, :clause_drop]

  defmodule Overridable do
    defmacro __using__(_opts) do
      quote do
        def count(n, acc), do: {:base, n, acc}
        defoverridable count: 2
      end
    end
  end

  defmodule Sink do
    def hit(ids) do
      Process.put(:clean_coverage, ids ++ Process.get(:clean_coverage, []))
      true
    end
  end

  # A runtime callee can itself enter another mutation-bearing function. The clean
  # copy must retain this call, with normal selection at that function's entry.
  def observe(value) do
    result = apply(@fixture, :other, [value])
    Process.put(:clean_events, [{value, result} | Process.get(:clean_events, [])])
  end

  setup do
    track = :persistent_term.get(Recorder.track_key(), false)
    Selector.put(0)
    :persistent_term.put(Recorder.track_key(), false)

    on_exit(fn ->
      Selector.put(0)
      :persistent_term.put(Recorder.track_key(), track)
      :code.purge(@fixture)
      :code.delete(@fixture)
    end)

    :ok
  end

  test "clean clauses contain original code and preserve every body and lifted mutant" do
    result = transform()
    control = transform(clean_functions: false)
    assert result.sites == control.sites
    assert result.next_id == control.next_id
    assert result.metamutant =~ "_original("

    originals =
      result.metamutant
      |> Code.string_to_quoted!()
      |> Macro.prewalk([], fn
        {:defp, _, [head | _]} = node, acc ->
          {name, _, _} = Mutare.Transform.ClauseAST.head_call(head)

          {node,
           if(String.ends_with?(Atom.to_string(name), "_original"), do: [node | acc], else: acc)}

        node, acc ->
          {node, acc}
      end)
      |> elem(1)

    assert length(originals) == 3
    text = Macro.to_string({:__block__, [], originals})
    refute text =~ "persistent_term"
    refute text =~ "mutare_active"
    refute text =~ "mutare_cov"

    assert manifest_ids(result) == manifest_ids(control)

    compile_purging(@fixture, result.metamutant)

    actual =
      for site <- result.sites, into: %{} do
        Selector.put(site.id)
        {site.id, outcomes()}
      end

    # Each selected mutant must agree with a separately patched source, including
    # side effects in a callee, clause misses, arithmetic errors and body variants.
    for site <- result.sites do
      Selector.put(0)
      Mutare.Test.Compile.string(Report.patch(site, @source))
      assert actual[site.id] == outcomes(), "mutant #{site.id}: #{site.mutated_code}"
    end
  end

  test "baseline coverage remains precise and a mutant elsewhere still reaches its callee" do
    result = transform()
    compile_observed(@fixture, result.metamutant, Sink)
    :persistent_term.put(Recorder.track_key(), true)
    Process.put(:clean_coverage, [])

    apply(@fixture, :run, [0])
    recorded = Process.get(:clean_coverage)
    body = Enum.find(result.sites, &(&1.line == 4))
    assert body
    refute body.id in recorded
    assert Enum.any?(result.sites, &(&1.kind == :lifted and &1.id in recorded))

    Process.put(:clean_coverage, [])
    other = Enum.find(result.sites, &(&1.line == 15))
    assert other
    Selector.put(other.id)
    assert {{:returned, _}, [{1, -6}]} = outcome(1)
    assert Process.get(:clean_coverage) == []
  end

  test "namespaced intervals use local ids and recover omitted mutations without losing identity" do
    opts = [runtime_namespace: "lib/clean.ex", start_id: 200]
    result = transform(opts)
    control = transform(Keyword.put(opts, :clean_functions, false))
    assert result.sites == control.sites
    assert result.metamutant =~ "_original("
    compile_purging(@fixture, result.metamutant)

    expected =
      for id <- [0, {"lib/elsewhere.ex", 1} | Enum.map(result.sites, & &1.runtime_id)],
          into: %{} do
        Selector.put(id)
        {id, outcomes()}
      end

    Mutare.Test.Compile.string(control.metamutant)

    for {id, expected} <- expected do
      Selector.put(id)
      assert outcomes() == expected
    end

    body = Enum.find(result.sites, &(&1.kind == :in_place and &1.line == 4))
    skipped = transform(opts ++ [skip_ids: MapSet.new([body.id])])
    assert skipped.next_id == result.next_id
    assert Enum.find(skipped.sites, &(&1.id == body.id)).poisoned
    Mutare.Test.Compile.string(skipped.metamutant)
    Selector.put(body.runtime_id)
    skipped_outcome = outcomes()
    Selector.put(0)
    assert outcomes() == skipped_outcome

    tiny = transform(opts ++ [emit_ids: MapSet.new([body.id])])
    refute tiny.metamutant =~ "_original("
  end

  test "clean self recursion bypasses the dispatcher while ordinary entries select afresh" do
    source = """
    defmodule Mutare.CleanFunctionFixture do
      def sum([], total), do: total
      def sum([n | rest], total) when n > 0 do
        total = total + n
        total = total + 2
        total = total + 3
        total = total + 4
        total = total + 5
        sum(rest, total)
      end
      def sum([_ | rest], total), do: sum(rest, total - 1)
    end
    """

    for source <- [source, String.replace(source, "sum(rest, total)", "rest |> sum(total)")] do
      result = Transform.transform_string_with_sites(source, mutators: @mutators)
      assert result.metamutant =~ "_original(rest, total)"
      compile_purging(@fixture, result.metamutant)

      Selector.put(result.next_id + 1)
      assert apply(@fixture, :sum, [List.duplicate(1, 10_000), 0]) == 150_000

      site = Enum.find(result.sites, &(&1.original_code == "total + n"))
      Selector.put(site.id)
      assert apply(@fixture, :sum, [[1, 2], 0]) == 25
      Selector.put(0)
      assert apply(@fixture, :sum, [[1, 2], 0]) == 31
    end
  end

  test "a same-name pipe at another arity compiles and preserves every mutant" do
    source = """
    defmodule Mutare.CleanFunctionFixture do
      def min(n) when n > 0 do
        n = n + 2
        n = n * 3
        n = n - 4
        n = n + 5
        n |> min(10)
      end
      def min(0), do: 0
    end
    """

    result = Transform.transform_string_with_sites(source, mutators: @mutators)

    control =
      Transform.transform_string_with_sites(source,
        mutators: @mutators,
        clean_functions: false
      )

    assert result.metamutant =~ "_original("
    assert result.sites == control.sites

    inputs = [0, 1, 2, 10]
    selections = [0, result.next_id + 1 | Enum.map(result.sites, & &1.id)]
    compile_purging(@fixture, control.metamutant)

    expected =
      for id <- selections, into: %{} do
        Selector.put(id)
        {id, Enum.map(inputs, &min_outcome/1)}
      end

    Mutare.Test.Compile.string(result.metamutant)

    for id <- selections do
      Selector.put(id)
      assert Enum.map(inputs, &min_outcome/1) == expected[id], "selection #{id}"
    end
  end

  test "a recursion under way finishes in the clean copy; the next entry selects afresh" do
    source = """
    defmodule Mutare.CleanFunctionFixture do
      def sum([], total), do: total
      def sum([n | rest], total) when n > 0 do
        Mutare.Selector.put(n)
        total = total + 2
        total = total + 3
        total = total + 4
        total = total + 5
        total = total + 6
        sum(rest, total)
      end
    end
    """

    result = Transform.transform_string_with_sites(source, mutators: @mutators)
    assert result.metamutant =~ "_original(rest, total)"
    compile_purging(@fixture, result.metamutant)

    # No purity is asked of a redirected self-call. Entered clean, the first step selects a
    # body mutant; the second step is already inside the clean copy and does not see it. A
    # mutant run never changes selection, which is what the redirect relies on.
    site = Enum.find(result.sites, &(&1.original_code == "total + 2"))
    Selector.put(result.next_id + 1)
    assert apply(@fixture, :sum, [[site.id, site.id], 0]) == 40
    assert Selector.active() == site.id
    assert apply(@fixture, :sum, [[site.id], 0]) == 16
  end

  test "a clean copy of an overriding function reaches super, and recurses with it" do
    source = """
    defmodule Mutare.CleanFunctionFixture do
      use Mutare.Transform.CleanFunctionTest.Overridable

      def count([n | rest], acc) when n > 3 do
        acc = acc + 2
        acc = acc * 3
        count(rest, acc)
      end

      def count(list, acc), do: super(list, acc - 1)
    end
    """

    result = Transform.transform_string_with_sites(source, mutators: @mutators)

    control =
      Transform.transform_string_with_sites(source, mutators: @mutators, clean_functions: false)

    assert result.sites == control.sites
    assert result.metamutant =~ "_original(mutare_super, rest, acc)"

    selections = [0, result.next_id + 1 | Enum.map(result.sites, & &1.id)]

    count = fn ->
      Enum.map([[5, 6, 1], [1], []], fn list ->
        try do
          apply(@fixture, :count, [list, 1])
        rescue
          error -> {:raised, error.__struct__}
        end
      end)
    end

    compile_purging(@fixture, control.metamutant)

    expected =
      for id <- selections, into: %{} do
        Selector.put(id)
        {id, count.()}
      end

    Mutare.Test.Compile.string(result.metamutant)

    for id <- selections do
      Selector.put(id)
      assert count.() == expected[id], "selection #{id}"
    end
  end

  describe "an in-place clean body" do
    # `total/2` stays in place (no head or guard mutant under these families) and exercises
    # what the first contract refused: fresh bindings, a closure, interpolation, a bitstring,
    # a sibling call, a default, and a `rescue` block beside the region. `scale/1` is lifted,
    # so a mutant inside it must still be reached through the clean caller.
    @in_place """
    defmodule Mutare.CleanFunctionFixture do
      def total(items, bonus \\\\ 1 + 1) do
        Mutare.Transform.CleanFunctionTest.observe(bonus)
        base = Enum.reduce(items, 0, fn item, acc -> acc + item * 2 end)
        scaled = scale(base + bonus)
        label = "total: \#{scaled - 1}"
        {scaled, label, <<scaled + 3>>}
      rescue
        ArithmeticError -> {:error, bonus - 100}
      end

      defp scale(n) when n > 10, do: n * 3
      defp scale(n), do: n + 4

      def other(n), do: n + 7
    end
    """

    test "holds the source itself, once, and changes no site" do
      result = transform_in_place()
      control = transform_in_place(clean_functions: false)
      assert result.sites == control.sites
      assert result.next_id == control.next_id
      assert manifest_ids(result) == manifest_ids(control)

      assert [
               %{verdict: :clean, function: {:total, 2}, delivery: :in_place},
               %{verdict: :clean, function: {:scale, 1}, delivery: :lifted},
               %{verdict: :clean, function: {:other, 1}, delivery: :in_place}
             ] = result.clean_decisions

      assert [_other, clean] = clean_bodies(result.metamutant)
      text = Macro.to_string(clean)
      refute text =~ "persistent_term"
      refute text =~ "mutare_active"
      refute text =~ "mutare_cov"
      assert text =~ "fn item, acc -> acc + item * 2 end"
      assert clean_bodies(control.metamutant) == []
    end

    test "preserves every mutant, in the region, beside it, and in its callee" do
      result = transform_in_place()
      assert Enum.any?(result.sites, &(&1.line == 9)), "the rescue block carries a mutant"
      assert Enum.any?(result.sites, &(&1.line == 2)), "the default carries a mutant"
      compile_purging(@fixture, result.metamutant)

      selections = [0, result.next_id + 1 | Enum.map(result.sites, & &1.id)]

      actual =
        for id <- selections, into: %{} do
          Selector.put(id)
          {id, total_outcomes()}
        end

      Selector.put(0)
      Mutare.Test.Compile.string(@in_place)
      original = total_outcomes()
      assert actual[0] == original
      assert actual[result.next_id + 1] == original

      for site <- result.sites do
        Mutare.Test.Compile.string(Report.patch(site, @in_place))
        assert actual[site.id] == total_outcomes(), "mutant #{site.id}: #{site.mutated_code}"
      end
    end

    test "records baseline coverage exactly as without it, and nothing on the clean path" do
      for opts <- [[], [clean_functions: false]] do
        result = transform_in_place(opts)
        compile_observed(@fixture, result.metamutant, Sink)
        :persistent_term.put(Recorder.track_key(), true)
        Process.put(:clean_coverage, [])
        apply(@fixture, :total, [[1, 2]])
        Process.put({:baseline_coverage, opts}, Enum.sort(Process.get(:clean_coverage)))

        Process.put(:clean_coverage, [])
        elsewhere = Enum.find(result.sites, &(&1.line == 15))
        Selector.put(elsewhere.id)
        apply(@fixture, :total, [[1, 2]])
        assert Process.get(:clean_coverage) == []
        Selector.put(0)
        :persistent_term.put(Recorder.track_key(), false)
      end

      assert Process.get({:baseline_coverage, []}) ==
               Process.get({:baseline_coverage, [clean_functions: false]})

      assert Process.get({:baseline_coverage, []}) != []
    end

    test "selects by file-local id under a namespace, and another file runs clean" do
      opts = [runtime_namespace: "lib/clean.ex", start_id: 300]
      result = transform_in_place(opts)
      control = transform_in_place(Keyword.put(opts, :clean_functions, false))
      assert result.sites == control.sites
      assert [_other, _total] = clean_bodies(result.metamutant)
      compile_purging(@fixture, result.metamutant)

      selections = [0, {"lib/elsewhere.ex", 1} | Enum.map(result.sites, & &1.runtime_id)]

      expected =
        for id <- selections, into: %{} do
          Selector.put(id)
          {id, total_outcomes()}
        end

      Mutare.Test.Compile.string(control.metamutant)

      for id <- selections do
        Selector.put(id)
        assert total_outcomes() == expected[id], "selection #{inspect(id)}"
      end
    end

    test "a region of one selector site has nothing to win" do
      source = """
      defmodule Mutare.CleanFunctionFixture do
        def one(x, y), do: x + y
        def two(x, y), do: x + y - y
      end
      """

      result = Transform.transform_string_with_sites(source, mutators: [:arithmetic])

      assert [
               %{function: {:one, 2}, sites: 1, verdict: :below_threshold},
               %{function: {:two, 2}, sites: 2, verdict: :clean}
             ] =
               result.clean_decisions

      every =
        Transform.transform_string_with_sites(source, mutators: [:arithmetic], clean_threshold: 1)

      assert Enum.map(every.clean_decisions, & &1.verdict) == [:clean, :clean]
    end

    test "any body is copied, whatever it calls" do
      # `binding/0` reads its caller's variables: a macro, which nothing here needs to know.
      source = """
      defmodule Mutare.CleanFunctionFixture do
        def f(x) do
          y = x + 2
          z = y * 3
          binding() |> Keyword.fetch!(:z)
        end
      end
      """

      result = Transform.transform_string_with_sites(source, mutators: [:arithmetic])
      assert [%{verdict: :clean, range: {1, 2}}] = result.clean_decisions
      assert [clean] = clean_bodies(result.metamutant)
      assert Macro.to_string(clean) =~ "binding()"

      compile_purging(@fixture, result.metamutant)
      Selector.put(result.next_id + 1)
      assert apply(@fixture, :f, [1]) == 9
    end

    test "a region poison recovery dropped keeps its instrumented body alone" do
      result = transform_in_place()

      assert [%{range: total}, %{range: scale}, %{range: other}] = result.clean_decisions

      dropped = transform_in_place(skip_regions: MapSet.new([total, scale]))
      assert dropped.sites == result.sites
      assert dropped.next_id == result.next_id

      assert [
               %{verdict: :dropped, range: ^total},
               %{verdict: :dropped, range: ^scale},
               %{verdict: :clean, range: ^other}
             ] = dropped.clean_decisions

      assert [_other] = clean_bodies(dropped.metamutant)
      refute dropped.metamutant =~ "_original("
      assert manifest_ids(dropped) == manifest_ids(result)
    end
  end

  describe "a relocated clean copy" do
    test "preserves quoted return data when an unrelated mutant selects the clean copy" do
      for expression <- [
            "quote(do: f(unquote(n + 1)))",
            "quote(do: unquote(n + 1) |> f())",
            "quote(unquote: false, do: unquote(f(n)))",
            "quote([bind_quoted: [x: n]], do: f(x))",
            "quote(do: quote(do: unquote(f(n))))",
            "quote(do: quote(do: unquote(unquote(f(n)))))",
            "quote(do: f(unquote(f(n - 1))))",
            "quote(do: [f(n), unquote_splicing([f(n - 1)])])",
            "quote(bind_quoted: [x: f(n - 1)], do: f(x))"
          ] do
        source = """
        defmodule Mutare.CleanFunctionFixture do
          def f(n) when n > 0, do: Macro.to_string(#{expression})
          def f(0), do: 1
          def other(n), do: n + 7
        end
        """

        compile_purging(@fixture, source)
        expected = apply(@fixture, :f, [1])
        result = Transform.transform_string_with_sites(source, mutators: @mutators)

        assert Enum.any?(
                 result.clean_decisions,
                 &match?(%{function: {:f, 1}, verdict: :clean}, &1)
               )

        other = Enum.find(result.sites, &(&1.original_code == "n + 7"))
        assert other
        Mutare.Test.Compile.string(result.metamutant)

        for selection <- [0, other.id] do
          Selector.put(selection)
          assert apply(@fixture, :f, [1]) == expected, expression
        end
      end
    end

    test "keeps defaults on the dispatcher and sibling calls at their ordinary entries" do
      source = """
      defmodule Mutare.CleanFunctionFixture do
        def run(n, step \\\\ 1 + 1)
        def run(n, step) when n > 0 do
          doubled = helper(n) + step
          tripled = doubled * 3
          tripled - helper(step)
        end
        def run(_n, step), do: step - 1

        defp helper(n) when n > 2, do: n * 2
        defp helper(n), do: n + 1
      end
      """

      result = Transform.transform_string_with_sites(source, mutators: @mutators)

      control =
        Transform.transform_string_with_sites(source, mutators: @mutators, clean_functions: false)

      assert result.sites == control.sites
      assert result.metamutant =~ "_original(n, step)"
      compile_purging(@fixture, result.metamutant)

      inputs = [[0], [1], [3], [5, 4], [-1, 0]]
      selections = [0, result.next_id + 1 | Enum.map(result.sites, & &1.id)]

      run = fn ->
        Enum.map(inputs, fn args ->
          try do
            {:returned, apply(@fixture, :run, args)}
          rescue
            error -> {:raised, error.__struct__}
          end
        end)
      end

      expected =
        for id <- selections, into: %{} do
          Selector.put(id)
          {id, run.()}
        end

      Selector.put(0)
      Mutare.Test.Compile.string(source)
      assert expected[0] == run.()

      for site <- result.sites do
        Mutare.Test.Compile.string(Report.patch(site, source))
        assert expected[site.id] == run.(), "mutant #{site.id}: #{site.mutated_code}"
      end
    end
  end

  defp transform(opts \\ []),
    do: Transform.transform_string_with_sites(@source, Keyword.put(opts, :mutators, @mutators))

  defp transform_in_place(opts \\ []) do
    Transform.transform_string_with_sites(
      @in_place,
      Keyword.put(opts, :mutators, [:arithmetic, :relational, :integer])
    )
  end

  defp total_outcomes do
    for args <- [[[1, 2]], [[5, 6], 3], [[], 0], [[:a]], [[200]]] do
      Process.put(:clean_events, [])

      result =
        try do
          {:returned, apply(@fixture, :total, args)}
        rescue
          error -> {:raised, error.__struct__}
        end

      {result, Enum.reverse(Process.get(:clean_events))}
    end
  end

  # The uninstrumented `:do` bodies of in-place clean regions: the second clause of a
  # region `case` whose first clause is a guarded wildcard on the dispatch variable.
  defp clean_bodies(metamutant) do
    metamutant
    |> Code.string_to_quoted!()
    |> Macro.prewalk([], fn
      {:case, _,
       [
         {:mutare_active, _, _},
         [do: [{:->, _, [[{:when, _, [{:_, _, _}, _]}], _]}, {:->, _, [[{:_, _, _}], clean]}]]
       ]} = node,
      acc ->
        {node, [clean | acc]}

      node, acc ->
        {node, acc}
    end)
    |> elem(1)
    |> Enum.reject(
      &(match?({name, _, args} when is_atom(name) and is_list(args), &1) and lifted_call?(&1))
    )
  end

  # A lifted dispatcher's region calls its relocated clean clauses instead of holding a body.
  defp lifted_call?({name, _, _args}), do: String.ends_with?(Atom.to_string(name), "_original")

  defp min_outcome(value) do
    {:returned, apply(@fixture, :min, [value])}
  rescue
    error -> {:raised, error.__struct__}
  end

  defp outcomes, do: Enum.map([-1, 0, 1, 2, 4], &outcome/1)

  defp manifest_ids(result) do
    result.metamutant
    |> Manifest.from_source(result.dispatch_var)
    |> Map.fetch!(:regions)
    |> Enum.flat_map(& &1.ids)
    |> MapSet.new()
  end

  defp outcome(value) do
    Process.put(:clean_events, [])

    result =
      try do
        {:returned, apply(@fixture, :run, [value])}
      rescue
        error -> {:raised, error.__struct__}
      catch
        kind, value -> {kind, value}
      end

    {result, Enum.reverse(Process.get(:clean_events))}
  end
end
