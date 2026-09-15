defmodule Mutare.Transform.CleanFunctionTest do
  use ExUnit.Case, async: false
  import Mutare.Test.Metamutant

  alias Mutare.Coverage.Recorder
  alias Mutare.Test.SwitchingEnumerable
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

  test "pure clean self recursion bypasses the dispatcher while ordinary entries select afresh" do
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

  test "an effectful recursive body keeps fresh selection through its ordinary self entry" do
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
    assert result.metamutant =~ "_original("
    refute result.metamutant =~ "_original(rest, total)"
    compile_purging(@fixture, result.metamutant)

    # Enter clean, switch to a body mutant during the first step, then reach its
    # instrumented implementation at the next recursive activation.
    site = Enum.find(result.sites, &(&1.original_code == "total + 2"))
    Selector.put(result.next_id + 1)
    assert apply(@fixture, :sum, [[site.id, site.id], 0]) == 36
  end

  test "membership through a user Enumerable preserves selector changes between recursive steps" do
    source = """
    defmodule Mutare.CleanFunctionFixture do
      def sum(0, _values, total), do: total
      def sum(n, values, total) when n > 0 do
        if n in values do
          total = total + 2
          total = total + 3
          total = total + 4
          total = total + 5
          total = total + 6
          sum(n - 1, values, total)
        else
          total
        end
      end
    end
    """

    result = Transform.transform_string_with_sites(source, mutators: @mutators)
    assert result.metamutant =~ "_original("
    compile_purging(@fixture, result.metamutant)
    site = Enum.find(result.sites, &(&1.original_code == "total + 2"))
    Selector.put(result.next_id + 1)
    assert apply(@fixture, :sum, [2, %SwitchingEnumerable{id: site.id}, 0]) == 36
  end

  defp transform(opts \\ []),
    do: Transform.transform_string_with_sites(@source, Keyword.put(opts, :mutators, @mutators))

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
