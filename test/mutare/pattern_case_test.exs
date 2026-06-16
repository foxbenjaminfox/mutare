defmodule Mutare.PatternCaseTest do
  @moduledoc """
  The structural pattern families (variable swap, duplicate→wildcard) also mutate `case`
  *clause* patterns. A `case` can't be lifted and a selector can't live in a pattern, so
  each mutant wraps the whole `case` in an in-place selector whose mutant branch is a copy
  with one clause's pattern restructured. Proven with one compile and runtime switching.
  """
  # persistent_term is global; the fixture is compiled once for all tests.
  use ExUnit.Case, async: false

  alias Mutare.{Report, Selector}

  @source """
  defmodule Mutare.PatternCaseFixture do
    def classify(point) do
      case point do
        {x, y} -> x - y
        _ -> :other
      end
    end

    def cmp(t) do
      case t do
        {a, a} -> :same
        _ -> :diff
      end
    end
  end
  """

  @compile {:no_warn_undefined, Mutare.PatternCaseFixture}

  setup_all do
    {metamutant, sites, _next_id} = Mutare.transform_string(@source, file: "cse.ex")

    # Broadening a case clause's pattern can make a later clause unreachable — a benign
    # "cannot match" warning (the metamutant compiles); captured so it doesn't clutter
    # test output.
    ExUnit.CaptureIO.capture_io(:stderr, fn ->
      [{_module, _binary}] = Code.compile_string(metamutant)
    end)

    %{sites: sites, meta: metamutant}
  end

  setup do
    Selector.put(Selector.baseline())
    on_exit(fn -> Selector.put(Selector.baseline()) end)
    :ok
  end

  alias Mutare.PatternCaseFixture, as: F

  defp id(sites, mutator, mutated_code) do
    site = Enum.find(sites, &(&1.mutator == mutator and &1.mutated_code == mutated_code))
    assert site, "no #{mutator} site with mutated_code #{inspect(mutated_code)}"
    site.id
  end

  test "case-pattern mutants are delivered in place (not lifted)", %{sites: sites, meta: meta} do
    # No dispatcher/private copies — the whole case is wrapped in a selector.
    refute meta =~ "__mutare_classify"
    assert meta =~ "case :persistent_term.get(:mutare_active, 0) do"

    structural = Enum.filter(sites, &(&1.mutator in [:pattern_swap, :pattern_wildcard]))
    assert structural != []
    assert Enum.all?(structural, &(&1.kind == :in_place))
  end

  test "baseline behaves exactly like the original" do
    assert F.classify({5, 2}) == 3
    assert F.classify(:nope) == :other
    assert F.cmp({1, 1}) == :same
    assert F.cmp({1, 2}) == :diff
  end

  test "swapping a case clause's pattern variables binds the other value", %{sites: sites} do
    # `{x, y}` → `{y, x}`: x now binds the second element, y the first.
    Selector.put(id(sites, :pattern_swap, "{y, x}"))
    assert F.classify({5, 2}) == 2 - 5
    assert F.classify(:nope) == :other
  end

  test "wildcarding a duplicate in a case clause drops the equality match", %{sites: sites} do
    # `{a, a}` → `{_, _}` (orphan-fix; body :same doesn't read a): now any 2-tuple matches.
    Selector.put(id(sites, :pattern_wildcard, "{_, _}"))
    assert F.cmp({1, 2}) == :same
    assert F.cmp({1, 1}) == :same
  end

  test "an unknown id falls through to the original case" do
    Selector.put(987_654)
    assert F.classify({5, 2}) == 3
    assert F.cmp({1, 2}) == :diff
  end

  test "renders a case-pattern swap as a focused one-line diff", %{sites: sites} do
    site = Enum.find(sites, &(&1.mutator == :pattern_swap))

    assert Report.header(site) == "cse.ex:4  [pattern_swap, in-place]  SURVIVED"

    assert Report.diff(site, @source) ==
             "-      {x, y} -> x - y\n+      {y, x} -> x - y"
  end
end
