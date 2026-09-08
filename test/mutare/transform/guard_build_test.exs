defmodule Mutare.Transform.GuardBuildTest do
  # Direct tests of the dispatch-guard builders, including the multi-alternative `when` and the
  # defensive multi-guard fold that the lifted path produces only rarely.
  use ExUnit.Case, async: true

  alias Mutare.Transform.GuardBuild

  describe "and_into/2" do
    test "no original guard leaves just the gate" do
      gate = {:===, [], [{:mutare_active, [], nil}, 1]}
      assert GuardBuild.and_into(gate, nil) == gate
    end

    test "ands the gate into a plain guard expression" do
      gate = {:===, [], [{:mutare_active, [], nil}, 1]}
      expr = {:>, [], [{:a, [], nil}, 0]}
      assert {{:., [], [:erlang, :andalso]}, [], [^gate, ^expr]} = GuardBuild.and_into(gate, expr)
    end

    test "distributes into each alternative of a `when a when b` node" do
      gate = {:===, [], [{:mutare_active, [], nil}, 1]}
      alts = [{:>, [], [{:a, [], nil}, 0]}, {:<, [], [{:a, [], nil}, 9]}]

      assert {:when, [], [first, second]} = GuardBuild.and_into(gate, {:when, [], alts})
      assert {{:., [], [:erlang, :andalso]}, [], [^gate, _]} = first
      assert {{:., [], [:erlang, :andalso]}, [], [^gate, _]} = second
    end
  end

  describe "combine/1" do
    test "[] → nil, [g] → g, and multiple → a left-folded `and`" do
      assert GuardBuild.combine([]) == nil

      g = {:>, [], [{:a, [], nil}, 0]}
      assert GuardBuild.combine([g]) == g

      a = {:>, [], [{:a, [], nil}, 0]}
      b = {:<, [], [{:a, [], nil}, 9]}
      assert {{:., [], [:erlang, :andalso]}, [], [^a, ^b]} = GuardBuild.combine([a, b])
    end
  end

  describe "exclusion/2" do
    test "empty and short runs retain compact strict comparisons" do
      assert GuardBuild.exclusion([], :active) == nil
      assert Macro.to_string(GuardBuild.exclusion([4], :active)) == ~s|:erlang."=/="(active, 4)|

      guard = GuardBuild.exclusion([6, 4, 5, 4], :active)
      refute Macro.to_string(guard) =~ "is_integer"
      assert Enum.all?([4, 5, 6], &(not accepts?(guard, &1)))
      assert accepts?(guard, 5.0)
    end

    test "compresses exact runs without excluding holes or non-integer selectors" do
      ids = Enum.to_list(101..180) ++ Enum.to_list(182..230) ++ [300, 302]
      guard = GuardBuild.exclusion(Enum.reverse(ids) ++ [101], :active)

      for active <- Enum.to_list(99..304) ++ [101.0, 150.5, nil, false, :active, [], {}, self()] do
        assert accepts?(guard, active) == Enum.all?(ids, &(active !== &1)),
               "wrong exclusion for #{inspect(active)}"
      end

      assert Macro.to_string(guard) =~ ":erlang.<(active, 101)"
      assert Macro.to_string(guard) =~ ":erlang.>(active, 180)"
      assert Macro.to_string(guard) =~ ":erlang.<(active, 182)"
      assert Macro.to_string(guard) =~ ":erlang.>(active, 230)"
      assert Macro.to_string(guard) =~ ~s|:erlang."=/="(active, 300)|
      assert Macro.to_string(guard) =~ ~s|:erlang."=/="(active, 302)|
    end

    test "a long run has constant size and scattered exclusions have logarithmic depth" do
      short = GuardBuild.exclusion(Enum.to_list(1..6), :active)
      refute Macro.to_string(short) =~ "is_integer"

      compressed = GuardBuild.exclusion(Enum.to_list(1..7), :active)

      uncompressed =
        Enum.map(1..7, &GuardBuild.exclusion([&1], :active))
        |> GuardBuild.combine()

      assert ast_size(compressed) < ast_size(uncompressed)

      assert ast_size(GuardBuild.exclusion(Enum.to_list(101..180), :active)) ==
               ast_size(GuardBuild.exclusion(Enum.to_list(101..1100), :active))

      scattered = GuardBuild.exclusion(Enum.map(1..1024, &(&1 * 2)), :active)
      assert and_depth(scattered) == 10
    end

    test "all exclusion operators and guard conjunctions survive displaced Kernel imports" do
      # Two intervals plus singleton exclusions exercise every generated operator.
      ids = Enum.to_list(101..180) ++ Enum.to_list(190..200) ++ [300, 302]
      exclusion = GuardBuild.exclusion(ids, :active)

      guard =
        GuardBuild.and_into(exclusion, GuardBuild.combine([quote(do: true), quote(do: true)]))
        |> Macro.to_string()

      module = Module.concat(__MODULE__, Displaced)

      Code.compile_string("""
      defmodule #{inspect(module)} do
        import Kernel, except: [not: 1, or: 2, and: 2, !==: 2, is_integer: 1, <: 2, >: 2]
        def accepts?(active) when #{guard}, do: true
        def accepts?(_active), do: false
      end
      """)

      for active <- Enum.to_list(99..304) ++ [120.0, 300.0, nil, false, :active] do
        assert apply(module, :accepts?, [active]) == Enum.all?(ids, &(active !== &1))
      end
    after
      module = Module.concat(__MODULE__, Displaced)
      :code.purge(module)
      :code.delete(module)
    end

    test "compressed exclusions work in every multi-when alternative" do
      guard = GuardBuild.exclusion(Enum.to_list(101..180), :active)
      alternatives = quote(do: is_atom(value) when is_number(value))
      gate = GuardBuild.and_into(guard, alternatives)
      active = Macro.var(:active, nil)
      value = Macro.var(:value, __MODULE__)

      {fun, _} =
        Code.eval_quoted(
          quote do
            fn
              unquote(active), unquote(value) when unquote(gate) -> true
              _, _ -> false
            end
          end
        )

      for value <- [:atom, 10] do
        refute fun.(120, value)
        assert fun.(181, value)
        assert fun.(120.0, value)
      end
    end
  end

  defp accepts?(guard, active) do
    {result, _} = Code.eval_quoted(guard, active: active)
    result
  end

  defp ast_size(ast) do
    {_ast, size} = Macro.prewalk(ast, 0, fn node, count -> {node, count + 1} end)
    size
  end

  defp and_depth({{:., _, [:erlang, :andalso]}, _, [left, right]}),
    do: 1 + max(and_depth(left), and_depth(right))

  defp and_depth(_), do: 0
end
