defmodule Mutare.IntegrationTest do
  @moduledoc """
  The central bet, end to end: transform a module, compile the metamutant
  exactly ONCE, then change behavior purely by flipping the `:persistent_term`
  selector — no recompilation between mutants.
  """
  # persistent_term is global; the fixture module is compiled once for all tests.
  use ExUnit.Case, async: false

  # The fixture is compiled at runtime (in setup_all), so it is legitimately
  # undefined at test-compile time.
  @compile {:no_warn_undefined, Mutare.IntegrationFixture}

  alias Mutare.Selector

  @source """
  defmodule Mutare.IntegrationFixture do
    def classify(total, threshold) do
      if total >= threshold do
        :ok
      else
        :under
      end
    end

    def add(a, b), do: a + b

    def zero?(a, b), do: a + b == 0
  end
  """

  setup_all do
    {metamutant, sites} = Mutare.transform_string(@source, file: "fixture.ex")
    # THE compile. Once. Everything below only flips persistent_term.
    [{_module, _binary}] = Code.compile_string(metamutant)
    %{sites: sites}
  end

  setup do
    Selector.put(Selector.baseline())
    on_exit(fn -> Selector.put(Selector.baseline()) end)
    :ok
  end

  defp id(sites, mutator, from, to) do
    site =
      Enum.find(
        sites,
        &(&1.mutator == mutator and &1.original_op == from and &1.mutated_op == to)
      )

    assert site, "no #{mutator} site #{from} -> #{to}"
    site.id
  end

  defp id_on_line(sites, line, mutator, from, to) do
    site =
      Enum.find(
        sites,
        &(&1.line == line and &1.mutator == mutator and &1.original_op == from and
            &1.mutated_op == to)
      )

    assert site, "no #{mutator} site #{from} -> #{to} on line #{line}"
    site.id
  end

  alias Mutare.IntegrationFixture, as: F

  test "baseline (id 0) behaves exactly like the original source" do
    assert F.classify(5, 5) == :ok
    assert F.classify(4, 5) == :under
    assert F.add(2, 3) == 5
    assert F.zero?(1, -1) == true
    assert F.zero?(1, 1) == false
  end

  test "relational >= → > flips the boundary case", %{sites: sites} do
    Selector.put(id(sites, :relational, :>=, :>))

    # 5 >= 5 was true; 5 > 5 is false
    assert F.classify(5, 5) == :under
    # strictly-greater still classifies
    assert F.classify(6, 5) == :ok
  end

  test "relational >= → <= changes only the non-boundary direction", %{sites: sites} do
    Selector.put(id(sites, :relational, :>=, :<=))

    # at equality both >= and <= are true -> unchanged
    assert F.classify(5, 5) == :ok
    # above threshold: >= true, <= false -> changed
    assert F.classify(6, 5) == :under
  end

  test "arithmetic + → - changes add/2", %{sites: sites} do
    Selector.put(id(sites, :arithmetic, :+, :-))
    assert F.add(2, 3) == -1
  end

  test "only the active mutant changes; sibling sites stay at baseline", %{sites: sites} do
    Selector.put(id(sites, :relational, :>=, :>))
    # add lives behind a different selector id -> still original
    assert F.add(2, 3) == 5
  end

  test "nested selectors switch independently within one compiled function", %{sites: sites} do
    # `+ → -` occurs in both add/2 and zero?/2, so disambiguate by line: the
    # inner arithmetic site shares zero?/2's line with the outer `==` site.
    outer_site = Enum.find(sites, &(&1.mutator == :relational and &1.original_op == :==))
    inner = id_on_line(sites, outer_site.line, :arithmetic, :+, :-)
    outer = outer_site.id

    # baseline: 1 + (-1) == 0 -> true
    assert F.zero?(1, -1) == true

    # inner + → - : 1 - (-1) == 2, 2 == 0 -> false
    Selector.put(inner)
    assert F.zero?(1, -1) == false

    # outer == → != : 1 + (-1) == 0 becomes 0 != 0 -> false
    Selector.put(outer)
    assert F.zero?(1, -1) == false
    # and a case where != flips a false into true
    assert F.zero?(1, 1) == true
  end

  test "an unknown mutant id falls through to baseline" do
    Selector.put(999_999)
    assert F.classify(5, 5) == :ok
    assert F.add(2, 3) == 5
  end
end
