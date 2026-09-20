defmodule Mutare.RoutedPipeRegressionTest do
  use ExUnit.Case, async: false

  import Mutare.Test
  import Mutare.Test.SourcePatch

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
