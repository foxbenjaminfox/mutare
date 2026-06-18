defmodule Mutare.MatchPatternTest do
  @moduledoc """
  The structural pattern families (variable swap, duplicate→wildcard) also mutate the LHS
  of a runtime `=` match **in statement position** (a non-final statement of a body block,
  where the match's value is discarded). A selector `case` can't wrap a match — its
  bindings would stop escaping — so the bound variables are re-exported through a tuple and
  rebound outside (`{vars} = case rhs do <pat> -> {vars} end`), the pattern hosted in a
  selector. Proven with one compile and runtime switching.
  """
  # persistent_term is global; the fixture is compiled once for all tests.
  use ExUnit.Case, async: false

  alias Mutare.{Report, Selector}

  @source """
  defmodule Mutare.MatchPatternFixture do
    def classify(point) do
      {x, y} = point
      x - y
    end

    def eq(t) do
      {a, a} = t
      a * 10
    end

    def mapped(m) do
      %{lat: la, lng: ln} = m
      la - ln
    end

    def listed(l) do
      [a, b] = l
      a - b
    end

    def inner(x) do
      {a, b} = {x + 1, x - 1}
      a - b
    end

    def bare(x) do
      y = x
      y + 1
    end

    def return_match(t) do
      :noop
      {a, b} = t
    end

    def for_pairs(list) do
      for p <- list, {hi, lo} = p do
        hi - lo
      end
    end

    def with_pairs(input) do
      with {:ok, payload} <- input,
           {key, val} = payload do
        val - key
      end
    end

    def underscored(t) do
      {_keep, y, z} = t
      _keep + y - z
    end
  end
  """

  @compile {:no_warn_undefined, Mutare.MatchPatternFixture}

  setup_all do
    {metamutant, sites, _next_id} = Mutare.transform_string(@source, file: "mp.ex")

    # `return_match/1`'s trailing `{a, b} = t` binds a/b unused (it returns the match
    # value); `underscored/1`'s re-exported `_keep` is read in the rewrite's inner-case
    # returns ("underscored variable used after being set"); plus any "cannot match"
    # broadening warning. All benign and captured so they do not clutter test output.
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

  alias Mutare.MatchPatternFixture, as: F

  defp id(sites, mutator, mutated_code, line) do
    site =
      Enum.find(
        sites,
        &(&1.mutator == mutator and &1.mutated_code == mutated_code and &1.line == line)
      )

    assert site, "no #{mutator} site #{inspect(mutated_code)} on line #{line}"
    site.id
  end

  test "match-pattern mutants are delivered in place (not lifted)", %{sites: sites, meta: meta} do
    refute meta =~ "__mutare_classify"
    refute meta =~ "__mutare_eq"
    refute meta =~ "__mutare_mapped"

    structural = Enum.filter(sites, &(&1.mutator in [:pattern_swap, :pattern_wildcard]))
    assert structural != []
    assert Enum.all?(structural, &(&1.kind == :in_place))
  end

  test "baseline behaves like the original" do
    assert F.classify({5, 2}) == 3
    assert F.eq({4, 4}) == 40
    assert F.mapped(%{lat: 9, lng: 4}) == 5
    assert F.listed([7, 2]) == 5
    assert F.inner(10) == 2
    assert F.bare(41) == 42
  end

  describe "tuple swap" do
    test "swapping a destructuring match binds the other value", %{sites: sites} do
      Selector.put(id(sites, :pattern_swap, "{y, x}", 3))
      assert F.classify({5, 2}) == 2 - 5
    end

    test "still binds and escapes to the rest of the scope", %{sites: sites} do
      # The export tuple rebinds x/y in the enclosing scope, so the trailing `x - y`
      # sees the swapped values rather than an unbound variable.
      Selector.put(id(sites, :pattern_swap, "{y, x}", 3))
      assert is_integer(F.classify({1, 9}))
    end
  end

  describe "list swap" do
    test "swapping a list match binds the other value", %{sites: sites} do
      Selector.put(id(sites, :pattern_swap, "[b, a]", 18))
      assert F.listed([7, 2]) == 2 - 7
    end
  end

  describe "map value swap" do
    test "swapping map values binds the other key's value", %{sites: sites} do
      Selector.put(id(sites, :pattern_swap, "%{lat: ln, lng: la}", 13))
      assert F.mapped(%{lat: 9, lng: 4}) == 4 - 9
    end
  end

  describe "for / with qualifiers (value-discarded matches)" do
    test "baseline for/with behave like the original" do
      assert F.for_pairs([{5, 2}, {9, 3}]) == [3, 6]
      assert F.with_pairs({:ok, {7, 2}}) == -5
      # a non-matching `<-` still routes (returns the unmatched value, no else)
      assert F.with_pairs(:error) == :error
    end

    test "a `for` `=` qualifier's pattern is mutated", %{sites: sites} do
      Selector.put(id(sites, :pattern_swap, "{lo, hi}", 38))
      assert F.for_pairs([{5, 2}, {9, 3}]) == [-3, -6]
    end

    test "a `with` `=` clause's pattern is mutated", %{sites: sites} do
      Selector.put(id(sites, :pattern_swap, "{val, key}", 45))
      assert F.with_pairs({:ok, {7, 2}}) == 5
    end
  end

  describe "underscore-prefixed bindings" do
    # Regression: `_keep` is a real binding read later (`_keep + y - z`). The export set
    # must include it — omitting it (as reusing `var_name/1` did) left `_keep` undefined
    # in the rest of the block, so the metamutant *failed to compile* (setup_all would
    # crash). Only bare `_` is dropped. The baseline value proves it both compiles and
    # rebinds `_keep` correctly.
    test "an `_name` binding is re-exported so later reads still resolve", %{sites: sites} do
      assert F.underscored({10, 5, 2}) == 10 + 5 - 2

      Selector.put(id(sites, :pattern_swap, "{_keep, z, y}", 51))
      assert F.underscored({10, 5, 2}) == 10 + 2 - 5
    end
  end

  describe "duplicate → wildcard" do
    test "thinning one occurrence drops the equality match (two mutants)", %{sites: sites} do
      first = id(sites, :pattern_wildcard, "{_, a}", 8)
      second = id(sites, :pattern_wildcard, "{a, _}", 8)
      refute first == second

      # `{_, a}` binds the second element; `{a, _}` the first. Either way the equality
      # assertion `{a, a}` enforced is gone, so an unequal tuple no longer raises.
      Selector.put(first)
      assert F.eq({4, 9}) == 90

      Selector.put(second)
      assert F.eq({4, 9}) == 40
    end

    test "never wildcards both occurrences (thin mode, binding preserved)", %{sites: sites} do
      refute Enum.any?(sites, &(&1.mutator == :pattern_wildcard and &1.mutated_code == "{_, _}"))
    end
  end

  describe "scope and position" do
    test "a final-statement match is not rewritten (its value is consumed)", %{sites: sites} do
      refute Enum.any?(
               sites,
               &(&1.line == 34 and &1.mutator in [:pattern_swap, :pattern_wildcard])
             )

      assert F.return_match({1, 2}) == {1, 2}
    end

    test "a bare `var = expr` match is never offered", %{sites: sites} do
      refute Enum.any?(
               sites,
               &(&1.line == 28 and &1.mutator in [:pattern_swap, :pattern_wildcard])
             )
    end

    test "a mutation in the matched expression still fires (baseline path)", %{sites: sites} do
      # `{a, b} = {x + 1, x - 1}` — the arithmetic in the rhs is mutated independently;
      # it lives on the selector catch-all's *emitted* rhs, so it fires when its id is
      # active (a non-match id, so the match selector takes its baseline branch).
      Selector.put(id(sites, :arithmetic, "x - 1", 23))
      # baseline `inner(10)` = (10+1) - (10-1) = 2; with `x + 1` → `x - 1` the rhs is
      # `{9, 9}`, so `a - b` = 0 — proving the rhs mutation is reachable post-rewrite.
      assert F.inner(10) == 0
    end
  end

  test "an unknown id falls through to every original match" do
    Selector.put(987_654)
    assert F.classify({5, 2}) == 3
    assert F.eq({4, 4}) == 40
    assert F.mapped(%{lat: 9, lng: 4}) == 5
    assert F.listed([7, 2]) == 5
  end

  test "renders a match-pattern swap as a focused one-line diff", %{sites: sites} do
    site = Enum.find(sites, &(&1.mutator == :pattern_swap and &1.line == 3))

    assert Report.header(site) == "mp.ex:3  [pattern_swap, in-place]  SURVIVED"

    assert Report.diff(site, @source) ==
             "-    {x, y} = point\n+    {y, x} = point"
  end
end
