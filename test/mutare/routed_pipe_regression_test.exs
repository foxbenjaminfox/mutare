defmodule Mutare.RoutedPipeRegressionTest do
  use ExUnit.Case, async: false

  import Mutare.Test
  import Mutare.Test.SourcePatch

  for {label, operand, binding, routes} <- [
        {"dynamic remote callee", "(m = Map).get(%{x: 10}, :x)", "m", []},
        {"anonymous callee", "(f = &Kernel.abs/1).(-10)", "f.(1)", []},
        {"live unquote", "length(quote(do: [unquote(x = 10)]))", "x", []},
        {"live unquote splicing", "length(quote(do: [unquote_splicing(xs = [10])]))", "xs", []},
        {"quote options", "length(quote(bind_quoted: [v: x = 10], do: [v]) |> elem(2))", "x", []},
        {"skipped call", "abs(x = -10)", "x", [{Kernel, :abs, 1, :skip}]},
        {"skipped pipe stage", "(%{x: 10} |> Map.get(key = :x))", "key", [{Map, :get, 2, :skip}]},
        {"skipped unquote", "length(quote(do: [unquote(x = 10)]))", "x",
         [{Kernel.SpecialForms, :unquote, 1, :skip}]}
      ] do
    test "operand swapping exports bindings from #{label}" do
      source = """
      defmodule Binding do
        def run do
          result = #{unquote(operand)} |> div(2)
          {result, #{unquote(binding)}}
        end
      end
      """

      # Arithmetic's div/rem swap also exercises the split delivery: one selector
      # retains the operand in a closure, and the operand swap surrounds it.
      for mutators <- [[:operand_swap], [:operand_swap, :arithmetic]] do
        sites =
          assert_patches(source, mutators, [run: []], call_routes: unquote(Macro.escape(routes)))

        assert [%{mutator: :operand_swap}] = Enum.filter(sites, &(&1.mutator == :operand_swap))
      end
    end
  end

  test "pipe exports exclude assignments in quoted data and inactive unquotes" do
    for quoted <- [
          "quote(do: [hidden = 10])",
          "quote(unquote: false, do: [unquote(hidden = 10)])",
          "quote(bind_quoted: [v: 10], do: [unquote(hidden = 10)])",
          "quote(do: [quote(do: unquote(hidden = 10))])"
        ] do
      source = """
      defmodule Binding do
        def run do
          result = length(List.wrap(quote_value = #{quoted})) |> div(2)
          {result, is_list(quote_value)}
        end
      end
      """

      assert [_] = assert_patches(source, [:operand_swap], run: [])
    end
  end

  test "operand swapping exports bindings from inline routed-pipe branches" do
    source = """
    defmodule Binding do
      def run(x, y) do
        result = (left = x) |> MapSet.difference(right = y)
        {result, left, right}
      end
    end
    """

    for treatment <- [:expression, :interior] do
      assert [%{mutator: :operand_swap}] =
               assert_patches(
                 source,
                 [:operand_swap],
                 [{:run, [MapSet.new([1, 2]), MapSet.new([2, 3])]}],
                 call_routes: [{MapSet, :difference, 2, treatment}]
               )
    end
  end

  # A stage whose candidates disagree about argument 0: the ones that keep it ride inside the
  # bound closure, the ones that move or drop it in a selector around it
  # (`Mutare.Transform.PipeEmit`, `{:split, …}`). Unrouted, so this is every user's delivery.
  test "a split stage keeps bindings, evaluation order and evaluation count under every mutant" do
    source = """
    defmodule Split do
      def run(a, b) do
        Process.put(:pipe_order, [])
        result = (left = tick(a, :left)) |> DateTime.diff(tick(b, :right), :second)
        {result, left, Process.delete(:pipe_order)}
      end

      defp tick(value, label) do
        Process.put(:pipe_order, [label | Process.get(:pipe_order)])
        value
      end
    end
    """

    sites =
      assert_patches(source, [:operand_swap, :mode_swap], [
        {:run, [~U[2024-01-01 00:00:00Z], ~U[2024-01-01 00:01:00Z]]}
      ])

    assert Enum.any?(sites, &(&1.mutator == :operand_swap))
    assert Enum.any?(sites, &(&1.mutator == :mode_swap))
  end

  test "a tail stage's return-value mutants sit around its bound stage mutants" do
    source = """
    defmodule Tail do
      def run(xs, sink), do: tick(xs, sink) |> Enum.map(&(&1 + 1)) |> Enum.sort(:desc)

      defp tick(xs, sink) do
        send(sink, :evaluated)
        xs
      end
    end
    """

    sites =
      assert_patches(source, [:return_value, :collection_arity, :call_removal, :arithmetic], [
        {:run, [[1, 3, 2], self()]}
      ])

    for family <- [:return_value, :collection_arity, :call_removal, :arithmetic],
        do: assert(Enum.any?(sites, &(&1.mutator == family)), "no #{family} site")

    {[module], sites} =
      compile_metamutant(source, [:return_value, :collection_arity, :call_removal])

    # A mutant that keeps the chain evaluates its head once; one that replaces the whole
    # expression never evaluates it. (The patch runs above left their own ticks behind.)
    drain()

    # `run/2` is line 2; `tick/2`'s own return-value mutants are not the subject.
    for site <- sites, site.line == 2 do
      with_active_mutant(site.id, fn -> module.run([1, 3, 2], self()) end)
      evaluations = drain()

      if site.mutator == :return_value,
        do: assert(evaluations == 0, "#{site.mutated_code} evaluated the chain"),
        else: assert(evaluations == 1, "#{site.mutated_code}: #{evaluations} evaluations")
    end
  end

  defp drain(count \\ 0) do
    receive do
      :evaluated -> drain(count + 1)
    after
      0 -> count
    end
  end

  test "inline routed-pipe branches retain each mutant's evaluation order" do
    source = """
    defmodule Binding do
      def run(x, y) do
        Process.put(:pipe_order, [])
        result = (left = tick(x, :left)) |> MapSet.difference(tick(y, :right))
        {result, left, Process.delete(:pipe_order)}
      end

      defp tick(value, label) do
        Process.put(:pipe_order, [label | Process.get(:pipe_order)])
        value
      end
    end
    """

    assert [%{mutator: :operand_swap}] =
             assert_patches(
               source,
               [:operand_swap],
               [{:run, [MapSet.new([1, 2]), MapSet.new([2, 3])]}],
               call_routes: [{MapSet, :difference, 2, :expression}]
             )
  end

  test "inline exports include nested matches and scrutinees, but exclude clause bindings" do
    source = """
    defmodule Binding do
      def run(x, y) do
        result =
          MapSet.new(case {left, copy} = {x, x} do
            {local, _} -> local
          end)
          |> MapSet.difference(y)
          |> MapSet.difference(y)

        {result, left, copy}
      end
    end
    """

    sites =
      assert_patches(
        source,
        [:operand_swap],
        [{:run, [MapSet.new([1, 2]), MapSet.new([2, 3])]}],
        call_routes: [{MapSet, :difference, 2, :expression}]
      )

    assert length(sites) == 2
  end

  test "raw arguments and skipped calls preserve a pinned pipe's syntax" do
    source = """
    defmodule Syntax do
      defmacrop opaque({:|>, _, [{:^, _, [_]}, {:stage, _, []}]}), do: :pipe
      defmacrop opaque(_), do: :rewritten
      def run, do: {opaque((^x) |> stage()), 42}
    end
    """

    for treatment <- [:raw, :skip] do
      sites =
        assert_patches(source, [:integer], [run: []], call_routes: [{:*, :opaque, 1, treatment}])

      assert length(sites) == 3
    end
  end

  test "inline exports leave binding-shaped syntax inside routed operands alone" do
    source = """
    defmodule Binding do
      defmacrop opaque({:=, _, [_pattern, value]}), do: value

      def run(x, y) do
        result = ((hidden = x) |> opaque()) |> MapSet.difference(right = y)
        {result, right}
      end
    end
    """

    assert [%{mutator: :operand_swap}] =
             assert_patches(
               source,
               [:operand_swap],
               [{:run, [MapSet.new([1, 2]), MapSet.new([2, 3])]}],
               call_routes: [
                 {:*, :opaque, 1, :raw},
                 {MapSet, :difference, 2, :expression}
               ]
             )
  end

  test "call removal preserves a piped assignment's escaping binding" do
    source = """
    defmodule Binding do
      def run(xs) do
        (ys = xs) |> Enum.sort()
        ys
      end
    end
    """

    assert [%{mutator: :call_removal}] =
             assert_patches(source, [:call_removal], [{:run, [[3, 1, 2]]}],
               call_routes: [{Enum, :sort, 1, :expression}]
             )
  end

  test "a removed routed stage returns its operand and evaluates its bindings once" do
    source = """
    defmodule Binding do
      def run(xs, sink) do
        result = (ys = tick(xs, sink)) |> Enum.sort() |> Enum.reverse()
        {result, ys}
      end

      defp tick(xs, sink) do
        send(sink, :evaluated)
        xs
      end
    end
    """

    for treatment <- [:expression, :interior] do
      {[module], sites} =
        compile_metamutant(source, [:call_removal],
          call_routes: [{Enum, :sort, 1, treatment}, {Enum, :reverse, 1, :expression}]
        )

      assert length(sites) == 2

      for {id, expected} <- [
            {0, [3, 2, 1]} | Enum.zip(Enum.map(sites, & &1.id), [[2, 1, 3], [1, 2, 3]])
          ] do
        assert with_active_mutant(id, fn -> module.run([3, 1, 2], self()) end) ==
                 {expected, [3, 1, 2]}

        assert_received :evaluated
        refute_received :evaluated
      end
    end
  end

  for {kind, body} <- [
        function: """
        def run(x) when x |> is_map_key(:foo), do: 1
        def run(_), do: 0
        """,
        case: """
        def run(x) do
          case x do
            y when y |> is_map_key(:foo) -> 1
            _ -> 0
          end
        end
        """
      ] do
    test "#{kind} guards apply routed treatments to the complete piped call" do
      source = "defmodule Guard do\n  #{unquote(body)}\nend"

      for {treatments, count} <- [{[:expression, :raw], 0}, {[:raw, :expression], 1}] do
        sites =
          assert_patches(
            source,
            [:atom],
            [{:run, [%{foo: 1}]}, {:run, [%{mutare: 1}]}, {:run, [%{}]}],
            call_routes: [{Kernel, :is_map_key, 2, treatments}]
          )

        assert length(sites) == count
        assert Enum.all?(sites, &(&1.original_code == ":foo"))
      end
    end
  end

  test "guard routing also treats the piped operand as argument zero" do
    source = """
    defmodule Guard do
      def run(x) when :foo |> :erlang.is_map_key(x), do: 1
      def run(_), do: 0
    end
    """

    for {treatments, count} <- [{[:raw, :expression], 0}, {[:expression, :raw], 1}] do
      sites =
        assert_patches(
          source,
          [:atom],
          [{:run, [%{foo: 1}]}, {:run, [%{mutare: 1}]}, {:run, [%{}]}],
          call_routes: [{:erlang, :is_map_key, 2, treatments}]
        )

      assert length(sites) == count
      assert Enum.all?(sites, &(&1.original_code == ":foo"))
    end
  end

  test "a guard's whole-call mutant receives the complete routed pipe" do
    source = """
    defmodule Guard do
      def run(x) when (x |> abs()) > 1, do: 1
      def run(_), do: 0
    end
    """

    assert [%{original_code: "x |> abs()", mutated_code: "x"}] =
             assert_patches(source, [:call_removal], [{:run, [-2]}, {:run, [2]}, {:run, [0]}],
               call_routes: [{Kernel, :abs, 1, :expression}]
             )
  end
end
