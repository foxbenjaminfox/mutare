defmodule Mutare.HostedPipeSyntaxTest do
  use ExUnit.Case, async: false

  alias Mutare.Test.{ForeignPipeHost, SubcontractHostMutator}
  alias Mutare.Transform
  import Mutare.Test.SourcePatch

  defmodule SyntaxProbe do
    @behaviour Mutare.Mutator
    @behaviour Mutare.Mutator.MacroHost
    @behaviour Mutare.CallRouting

    def name, do: :syntax_probe
    def hosted_macros, do: [{:*, :box, 1}, {:*, :keyed, 1}, {:*, :nested, 1}]

    def call_routes do
      [
        {:*, :box, 1, :hosted},
        {:*, :keyed, 1, [[:raw, value: :hosted, live: :expression]]},
        {:*, :nested, 1, [{:keyword, [{:keyword, [:hosted]}]}]},
        {:*, :forbidden, :any, :routing}
      ]
    end

    def route_arguments(_), do: raise("a classifier ran inside foreign syntax")

    def host(call, _context) do
      send(self(), {:syntax, call.name, Enum.map(call.arguments, &Macro.to_string/1)})
      []
    end
  end

  defmodule ReceiverMutation do
    @behaviour Mutare.Mutator
    def name, do: :receiver
    def mutate({{:., _, [_receiver, :read]}, _, []}), do: [Mutare.AST.literal(0)]
    def mutate(_), do: :skip
  end

  defmodule ParallelHost do
    @behaviour Mutare.Mutator
    @behaviour Mutare.Mutator.MacroHost
    @behaviour Mutare.CallRouting

    def name, do: :parallel_host
    defdelegate call_routes(), to: SubcontractHostMutator
    defdelegate hosted_macros(), to: SubcontractHostMutator
    defdelegate route_arguments(call), to: SubcontractHostMutator

    def host(call, context) do
      Task.async(fn -> SubcontractHostMutator.host(call, context) end) |> Task.await()
    end
  end

  test "resolution environments do not escape into a dynamic receiver's report form" do
    source = """
    defmodule Receiver do
      def run(mod), do: opaque(mod).read()
      defp opaque(mod), do: mod
    end
    """

    Transform.transform_string_with_sites(source,
      mutators: [ReceiverMutation],
      call_routes: [{:*, :opaque, 1, :raw}],
      verify_invariants: true
    )
  end

  test "static, keyed and nested keyword hosts preserve syntax at the declared boundary" do
    source = """
    defmodule Syntax do
      def run(n) do
        box(n |> forbidden(2))
        keyed(value: n |> forbidden(2), live: n |> abs())
        nested(outer: [inner: n |> forbidden(2)])
      end
    end
    """

    report = Transform.count_report(source, mutators: [SyntaxProbe])
    refute {:*, :forbidden, :any} in report.matches.routes
    assert_received {:syntax, :box, ["n |> forbidden(2)"]}
    assert_received {:syntax, :keyed, ["[value: n |> forbidden(2), live: abs(n)]"]}
    assert_received {:syntax, :nested, ["[outer: [inner: n |> forbidden(2)]]"]}
  end

  test "a classifier and its host read the DSL pipe, while the enclosing Elixir pipe normalizes" do
    for call <- ["D.run(n + 1, 8 |> stage(3))", "(n + 1) |> D.run(8 |> stage(3))"] do
      source = """
      defmodule ForeignPipe do
        alias Mutare.Test.ForeignPipeDSL, as: D
        require D
        def run(n), do: #{call}
      end
      """

      sites = assert_patches(source, [ForeignPipeHost, :arithmetic], run: [4])
      assert Enum.any?(sites, &(&1.mutator == :arithmetic and &1.original_code == "n + 1"))

      assert [%{original_code: "8 |> stage(3)", mutated_code: "8 |> sum(3)"}] =
               Enum.filter(sites, &(&1.mutator == :foreign_pipe))
    end
  end

  test "an Elixir island resolves aliases, imports, pipes and nested routes at re-entry" do
    source = """
    defmodule Island do
      import Mutare.Test.HostDSL
      alias Enum, as: E
      import Enum, only: [count: 1]
      def run(xs), do: filter(xs, 10 > (xs |> E.reverse() |> count()))
    end
    """

    sites =
      assert_patches(source, [SubcontractHostMutator, :collection, :call_removal], run: [[1, 2]])

    assert Enum.any?(
             sites,
             &(&1.mutator == :call_removal and &1.mutated_code == "10 > xs |> count()")
           )
  end

  test "island unit returns are classified using resolved conditional semantics" do
    for {imports, expected_count} <- [
          {"import Kernel, except: [if: 2]; import Mutare.Test.TupleConditional", 2},
          {"", 0}
        ] do
      source = """
      defmodule IslandUnitReturn do
        import Mutare.Test.HostDSL
        #{imports}
        def run(x), do: filter([:kept], {:ok, :ok} > (fn x -> if x, do: :ok, else: :ok end).(x))
      end
      """

      sites =
        assert_patches(source, [SubcontractHostMutator, :convention], run: [true], run: [false])

      assert Enum.count(sites, &(&1.mutator == :convention)) == expected_count
    end
  end

  test "count diagnostics include a routed island even when it produces no mutant" do
    source = """
    defmodule IslandMatches do
      import Mutare.Test.HostDSL
      alias Process, as: P
      def run, do: filter([], 10 > (1000 |> P.sleep()))
    end
    """

    for host <- [SubcontractHostMutator, ParallelHost] do
      report =
        Transform.count_report(source,
          mutators: [host, :integer],
          call_routes: [{Process, :sleep, 1, [:expression]}]
        )

      assert {[:Process], :sleep, 1} in report.matches.routes
      assert {[:Process], :sleep, 1} in report.matches.marks
      assert report.mutants == 1
    end
  end

  test "an island retains a displaced pipe and routes its operands using the caller's imports" do
    source = """
    defmodule CustomPipeIsland do
      import Mutare.Test.HostDSL
      import Kernel, except: [|>: 2]
      import Mutare.Test.BindPipe
      def run(xs), do: filter([], 10 > (xs |> Enum.count()))
    end
    """

    sites =
      assert_patches(
        source,
        [SubcontractHostMutator, :integer, :collection],
        [run: [{:ok, [1, 2]}], run: [:error]],
        call_routes: [{Mutare.Test.BindPipe, :|>, 2, [:expression, :interior]}]
      )

    assert [%{mutator: :sub_host}] = sites
  end
end
