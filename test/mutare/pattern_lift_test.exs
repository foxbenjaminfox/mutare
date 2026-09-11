defmodule Mutare.PatternLiftTest do
  @moduledoc """
  Pattern-structure mutants (variable swap, duplicate→wildcard) are delivered by the
  same lifting machinery as head-pattern literals — the clause group becomes one
  private function (taking the active id as an extra arg) behind a dispatcher, with
  each mutant a single guarded clause — proven with one compile and runtime switching.
  """
  # persistent_term is global; the fixture is compiled once for all tests.
  use ExUnit.Case, async: false
  import Mutare.Test.Metamutant

  alias Mutare.{Report, Selector}

  @source """
  defmodule Mutare.PatternStructFixture do
    def coord({x, y}), do: {x, y}

    def equal?(x, x), do: :eq
    def equal?(_, _), do: :neq

    def pick(a, a), do: a
    def pick(_, _), do: :other
  end
  """

  @compile {:no_warn_undefined, Mutare.PatternStructFixture}

  setup_all do
    {metamutant, sites, _next_id} =
      Mutare.Transform.transform_string_with_sites(@source, file: "pat.ex")

    # Wildcarding a duplicate in a multi-clause function broadens the clause, so the
    # later same-arity clause is unreachable — a benign "cannot match" warning here
    # (the metamutant compiles), but it would poison only under --warnings-as-errors.
    # Captured so it doesn't clutter test output.
    assert_compiles(metamutant)

    %{sites: sites, meta: metamutant}
  end

  setup do
    Selector.put(Selector.baseline())
    on_exit(fn -> Selector.put(Selector.baseline()) end)
    :ok
  end

  alias Mutare.PatternStructFixture, as: F

  defp id(sites, mutator, mutated_code) do
    site = Enum.find(sites, &(&1.mutator == mutator and &1.mutated_code == mutated_code))
    assert site, "no #{mutator} site with mutated_code #{inspect(mutated_code)}"
    site.id
  end

  test "the group is lifted into a dispatcher + one guarded private function", %{meta: meta} do
    assert meta =~ "def coord(mutare_arg1) do"
    # one private group taking the active id as an extra arg…
    assert meta =~ ~r/defp #{lifted_pattern(:coord, 1)}\(mutare_active,/
    # …with the swap mutant as a single clause gated by its id
    assert meta =~ ~r/when :erlang\."=:="\(mutare_active, \d+\)/
    assert {:ok, _} = Code.string_to_quoted(meta)
  end

  test "baseline dispatches exactly like the original" do
    assert F.coord({1, 2}) == {1, 2}
    assert F.equal?(1, 1) == :eq
    assert F.equal?(1, 2) == :neq
    assert F.pick(7, 7) == 7
    assert F.pick(7, 9) == :other
  end

  test "a variable swap changes which value binds where", %{sites: sites} do
    Selector.put(id(sites, :pattern_swap, "coord({y, x})"))
    assert F.coord({1, 2}) == {2, 1}
  end

  test "wildcarding a duplicate drops the equality constraint (orphan-fix)", %{sites: sites} do
    # `equal?(x, x)` → `equal?(_, _)`: the first clause now matches any two args.
    Selector.put(id(sites, :pattern_wildcard, "equal?(_, _)"))
    assert F.equal?(1, 2) == :eq
    assert F.equal?(1, 1) == :eq
  end

  test "wildcarding a read duplicate thins one occurrence (binding survives)", %{sites: sites} do
    # `pick(a, a), do: a` reads `a`, so each occurrence becomes a separate mutant that
    # keeps a binding. `pick(_, a)` binds the second argument.
    Selector.put(id(sites, :pattern_wildcard, "pick(_, a)"))
    assert F.pick(7, 9) == 9
    assert F.pick(7, 7) == 7

    Selector.put(id(sites, :pattern_wildcard, "pick(a, _)"))
    assert F.pick(7, 9) == 7
  end

  test "an unknown id falls through to the original copy" do
    Selector.put(987_654)
    assert F.coord({1, 2}) == {1, 2}
    assert F.equal?(1, 2) == :neq
  end

  describe "report" do
    test "renders a variable-swap mutant as a one-line diff", %{sites: sites} do
      site = Enum.find(sites, &(&1.mutator == :pattern_swap))

      assert Report.header(site) == "pat.ex:2  [pattern_swap, lifted]  SURVIVED"

      assert Report.diff(site, @source) ==
               "-  def coord({x, y}), do: {x, y}\n+  def coord({y, x}), do: {x, y}"
    end

    test "renders a wildcard mutant as a one-line diff", %{sites: sites} do
      site =
        Enum.find(sites, &(&1.mutator == :pattern_wildcard and &1.mutated_code == "equal?(_, _)"))

      assert Report.diff(site, @source) ==
               "-  def equal?(x, x), do: :eq\n+  def equal?(_, _), do: :eq"
    end
  end
end
