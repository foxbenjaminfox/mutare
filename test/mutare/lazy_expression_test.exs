defmodule Mutare.LazyExpressionTest do
  # `:lazy_expression` differs from `:expression` in delivery alone: for analysis the two are one
  # word (`Mutare.CallRouting.Spec.expression?/1`). So wherever a route says one, saying the other
  # must produce the same mutants — as a plain position, as a keyed refinement's leading treatment
  # (whose container offer matches the word by name, in a body and in a guard), and inside
  # `{:keyword, …}`.
  use ExUnit.Case, async: true

  alias Mutare.CallRouting.{Registry, Spec}
  alias Mutare.Test.OptionsDSL

  @families [:integer, :arithmetic, :list, :map_keyword, :keyword_delete, :relational]

  defp mutants(source, routes) do
    Mutare.Transform.transform_string_with_sites(source,
      file: "lazy.ex",
      mutators: @families,
      call_routes: routes
    ).sites
    |> Enum.map(&{&1.mutator, &1.kind, &1.original_code, &1.mutated_code})
    |> Enum.sort()
  end

  defp assert_parity(source, route_with) do
    eager = mutants(source, route_with.(:expression))
    lazy = mutants(source, route_with.(:lazy_expression))

    assert eager != []
    assert lazy == eager
    eager
  end

  test "as a plain position" do
    source = """
    defmodule Plain do
      def f(n), do: keep(n + 1, [2, 3])
      defp keep(a, b), do: {a, b}
    end
    """

    assert_parity(source, fn word -> [{:*, :keep, 2, [word, word]}] end)
  end

  test "as a keyed refinement's leading treatment, in a body" do
    source = """
    defmodule Body do
      import Mutare.Test.OptionsDSL
      def f(n), do: total([base: n + 1, timeout: 5000])
    end
    """

    mutants =
      assert_parity(source, fn word -> [{OptionsDSL, :total, 1, [[word, timeout: :raw]]}] end)

    # The container itself is offered under an expression-like leading word, and only then.
    assert Enum.any?(mutants, fn {_family, _kind, original, _} -> original =~ "base:" end)
    refute Enum.any?(mutants, fn {_family, _kind, original, _} -> original == "5000" end)

    raw = mutants(source, [{OptionsDSL, :total, 1, [[:raw, timeout: :raw]]}])
    refute Enum.any?(raw, fn {_family, _kind, original, _} -> original =~ "base:" end)
  end

  test "as a keyed refinement's leading treatment, in a guard" do
    source = """
    defmodule Guarded do
      import Mutare.Test.OptionsDSL
      def f(x) when within(x, [min: 1, max: 5]), do: :in
      def f(_x), do: :out
    end
    """

    assert_parity(source, fn word ->
      [{OptionsDSL, :within, 2, [:expression, [word, min: :raw]]}]
    end)
  end

  test "is user-tier: a declarative route may use it, alone or in a refinement" do
    for args <- [:lazy_expression, [:lazy_expression, :raw], [[:lazy_expression, timeout: :raw]]] do
      spec = Spec.new(OptionsDSL, :total, :any, args)
      refute Spec.adapter_graded?(spec)
      assert %{} = Registry.build([{OptionsDSL, :total, :any, args}], [])
    end
  end

  test "reads back in the author's vocabulary" do
    defmodule Reader do
      @behaviour Mutare.Mutator
      def name, do: :treatment_reader

      def mutate(node, _context) do
        with treatments when is_list(treatments) <- Mutare.Calls.routed_treatments(node),
             do: send(self(), {:treatments, treatments})

        :skip
      end
    end

    Mutare.Transform.transform_string_with_sites(
      "defmodule R do\n  import Mutare.Test.OptionsDSL\n  def f(n), do: n |> within([min: 1, max: 2])\nend\n",
      file: "lazy.ex",
      mutators: [Reader],
      call_routes: [{OptionsDSL, :within, 2, [:lazy_expression, [:lazy_expression, min: :raw]]}]
    )

    assert_received {:treatments, [:lazy_expression, [:lazy_expression, min: :raw]]}
  end
end
