defmodule Mutare.PatternClauseTest do
  @moduledoc """
  The structural pattern families (variable swap, duplicate→wildcard) mutate the *clause
  patterns* of the in-place clause-list constructs — `case`, `receive`, and `fn`. None can
  be lifted (a `case` isn't a function clause group) and a selector can't live in a
  pattern, so each mutant wraps the whole construct in an in-place selector whose mutant
  branch is a copy with one clause's pattern restructured (sound — these clause bindings
  never escape their body). Proven with one compile and runtime switching.
  """
  # persistent_term is global; the fixture is compiled once for all tests.
  use ExUnit.Case, async: false

  alias Mutare.{Report, Selector}

  @source """
  defmodule Mutare.PatternClauseFixture do
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

    def take do
      receive do
        {x, y} -> x - y
      after
        50 -> :timeout
      end
    end

    def sub, do: fn {x, y} -> x - y end

    def fn_eq, do: fn {a, a} -> :same
                     _ -> :diff end

    def recv_num do
      receive do
        1 -> :one
        n when n > 5 -> :big
      end
    end

    def pick do
      fn 1 -> :one
         n when n > 5 -> :big
         _ -> :other end
    end
  end
  """

  @compile {:no_warn_undefined, Mutare.PatternClauseFixture}

  setup_all do
    {metamutant, sites, _next_id} = Mutare.transform_string(@source, file: "cl.ex")

    # Broadening a clause's pattern can make a later clause unreachable — a benign "cannot
    # match" warning (the metamutant compiles); captured so it doesn't clutter test output.
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

  alias Mutare.PatternClauseFixture, as: F

  defp id(sites, mutator, mutated_code, line) do
    site =
      Enum.find(
        sites,
        &(&1.mutator == mutator and &1.mutated_code == mutated_code and &1.line == line)
      )

    assert site, "no #{mutator} site #{inspect(mutated_code)} on line #{line}"
    site.id
  end

  test "clause-pattern mutants are delivered in place (not lifted)", %{sites: sites, meta: meta} do
    refute meta =~ "__mutare_classify"
    refute meta =~ "__mutare_take"

    structural = Enum.filter(sites, &(&1.mutator in [:pattern_swap, :pattern_wildcard]))
    assert structural != []
    assert Enum.all?(structural, &(&1.kind == :in_place))
  end

  describe "case" do
    test "baseline behaves like the original" do
      assert F.classify({5, 2}) == 3
      assert F.classify(:nope) == :other
      assert F.cmp({1, 1}) == :same
      assert F.cmp({1, 2}) == :diff
    end

    test "swapping a clause pattern binds the other value", %{sites: sites} do
      Selector.put(id(sites, :pattern_swap, "{y, x}", 4))
      assert F.classify({5, 2}) == 2 - 5
    end

    test "wildcarding a duplicate drops the equality match", %{sites: sites} do
      Selector.put(id(sites, :pattern_wildcard, "{_, _}", 11))
      assert F.cmp({1, 2}) == :same
    end
  end

  describe "receive" do
    test "baseline receives and matches like the original" do
      send(self(), {5, 2})
      assert F.take() == 3
    end

    test "swapping a receive clause pattern binds the other value", %{sites: sites} do
      Selector.put(id(sites, :pattern_swap, "{y, x}", 18))
      send(self(), {5, 2})
      assert F.take() == 2 - 5
    end

    test "the after-block timeout is never offered as a pattern", %{sites: sites} do
      refute Enum.any?(
               sites,
               &(&1.line == 20 and &1.mutator in [:pattern_swap, :pattern_wildcard])
             )
    end

    test "a receive clause literal pattern re-targets the clause", %{sites: sites} do
      Selector.put(id(sites, :literal, "2", 31))
      send(self(), 2)
      assert F.recv_num() == :one
    end

    test "a receive clause guard mutant changes the match", %{sites: sites} do
      Selector.put(id(sites, :relational, "n >= 5", 32))
      send(self(), 5)
      assert F.recv_num() == :big
    end
  end

  describe "fn" do
    test "baseline anonymous functions behave like the original" do
      assert F.sub().({5, 2}) == 3
      assert F.fn_eq().({1, 1}) == :same
      assert F.fn_eq().({1, 2}) == :diff
    end

    test "swapping an fn clause pattern binds the other value", %{sites: sites} do
      Selector.put(id(sites, :pattern_swap, "{y, x}", 24))
      assert F.sub().({5, 2}) == 2 - 5
    end

    test "wildcarding a duplicate in an fn clause drops the equality match", %{sites: sites} do
      Selector.put(id(sites, :pattern_wildcard, "{_, _}", 26))
      assert F.fn_eq().({1, 2}) == :same
    end

    test "baseline literal/guard fn behaves like the original" do
      assert F.pick().(1) == :one
      assert F.pick().(7) == :big
      assert F.pick().(3) == :other
    end

    test "an fn clause literal pattern re-targets the clause", %{sites: sites} do
      Selector.put(id(sites, :literal, "2", 37))
      assert F.pick().(2) == :one
      assert F.pick().(1) == :other
    end

    test "an fn clause guard mutant changes the match", %{sites: sites} do
      Selector.put(id(sites, :relational, "n >= 5", 38))
      assert F.pick().(5) == :big
    end
  end

  test "an unknown id falls through to every original construct" do
    Selector.put(987_654)
    assert F.classify({5, 2}) == 3
    send(self(), {5, 2})
    assert F.take() == 3
    assert F.sub().({5, 2}) == 3
  end

  test "renders a case-pattern swap as a focused one-line diff", %{sites: sites} do
    site = Enum.find(sites, &(&1.mutator == :pattern_swap and &1.line == 4))

    assert Report.header(site) == "cl.ex:4  [pattern_swap, in-place]  SURVIVED"

    assert Report.diff(site, @source) ==
             "-      {x, y} -> x - y\n+      {y, x} -> x - y"
  end
end
