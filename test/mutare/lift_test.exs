defmodule Mutare.LiftTest do
  @moduledoc """
  Function lifting + dispatcher (M2): guard mutations delivered by duplicating
  the clause group, proven end to end with one compile and runtime switching.
  """
  # persistent_term is global; the fixture is compiled once for all tests.
  use ExUnit.Case, async: false

  alias Mutare.{Report, Selector, Site}

  @compile {:no_warn_undefined, Mutare.LiftFixture}

  @source """
  defmodule Mutare.LiftFixture do
    def classify(n) when n >= 0, do: :nonneg
    def classify(_), do: :neg

    def bump(n) when n > 0, do: n + 1
    def bump(n), do: n
  end
  """

  setup_all do
    {metamutant, sites} = Mutare.transform_string(@source, file: "lift.ex")
    [{_module, _binary}] = Code.compile_string(metamutant)
    %{sites: sites}
  end

  setup do
    Selector.put(Selector.baseline())
    on_exit(fn -> Selector.put(Selector.baseline()) end)
    :ok
  end

  alias Mutare.LiftFixture, as: F

  defp id(sites, from, to, line) do
    site =
      Enum.find(sites, &(&1.original_op == from and &1.mutated_op == to and &1.line == line))

    assert site, "no #{from} -> #{to} site on line #{line}"
    site.id
  end

  describe "structure" do
    test "lifts a guarded group into dispatcher + __orig + __mut copies", %{sites: sites} do
      {meta, _} = Mutare.transform_string(@source)

      assert meta =~ "def classify(mutare_arg1) do"
      assert meta =~ "defp __mutare_classify_1_orig"
      assert meta =~ "defp __mutare_classify_1_m"

      # classify guard >= -> {>, <=}, bump guard > -> {>=, <} = 4 lifted;
      # bump body n + 1 -> n - 1 = 1 in-place.
      assert Enum.count(sites, &(&1.kind == :lifted)) == 4

      assert [%Site{kind: :in_place, original_op: :+}] =
               Enum.filter(sites, &(&1.kind == :in_place))
    end

    test "does NOT lift an unguarded multi-clause function (M2a scope)" do
      {meta, sites} =
        Mutare.transform_string("defmodule M do\n  def g(0), do: :z\n  def g(_), do: :o\nend\n")

      refute meta =~ "__mutare_g"
      assert sites == []
    end

    test "falls back to in-place (no lift) for default args and operator names" do
      {defaulted, _} =
        Mutare.transform_string("defmodule M do\n  def h(a, b \\\\ 1) when a > b, do: a\nend\n")

      refute defaulted =~ "__mutare_h"

      {operator, _} =
        Mutare.transform_string("defmodule M do\n  def a ~> b when b > 0, do: a\nend\n")

      refute operator =~ "__mutare"
    end
  end

  describe "compiled metamutant" do
    test "baseline (id 0) behaves exactly like the original" do
      assert F.classify(5) == :nonneg
      assert F.classify(0) == :nonneg
      assert F.classify(-1) == :neg
      assert F.bump(3) == 4
      assert F.bump(0) == 0
      assert F.bump(-2) == -2
    end

    test "a guard mutation changes which clause dispatch lands on", %{sites: sites} do
      Selector.put(id(sites, :>=, :>, 2))

      # 0 >= 0 was true (:nonneg); 0 > 0 is false → falls through to catch-all
      assert F.classify(0) == :neg
      assert F.classify(1) == :nonneg
    end

    test "widening a guard flips the boundary the other way", %{sites: sites} do
      Selector.put(id(sites, :>, :>=, 5))

      # bump: 0 > 0 false (returns 0); 0 >= 0 true → 0 + 1
      assert F.bump(0) == 1
      assert F.bump(3) == 4
    end

    test "in-place body mutation inside a lifted function still works", %{sites: sites} do
      Selector.put(id(sites, :+, :-, 5))

      assert F.bump(3) == 2
      # the sibling function is behind a different selector id → unchanged
      assert F.classify(5) == :nonneg
    end

    test "an unknown id falls through to the original copy" do
      Selector.put(987_654)
      assert F.classify(0) == :nonneg
      assert F.bump(3) == 4
    end
  end

  test "report renders a lifted guard mutant as a one-line diff", %{sites: sites} do
    site =
      Enum.find(sites, &(&1.kind == :lifted and &1.original_op == :>= and &1.mutated_op == :>))

    assert Report.diff(site, @source) ==
             "-  def classify(n) when n >= 0, do: :nonneg\n" <>
               "+  def classify(n) when n > 0, do: :nonneg"
  end
end
