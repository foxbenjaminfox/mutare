defmodule Mutare.CasePatternTest do
  @moduledoc """
  `case` clause patterns/guards are mutated **per clause** by the tuple-the-scrutinee rewrite
  (the C+M analogue of function-head lifting): the subject is tupled with the active mutant id
  and each mutant adds one gated clause before its original. Unlike a function head it is
  delivered *in place* (a `case` isn't a liftable function group, and a selector can't live in
  a pattern), but unlike `receive`/`fn` it avoids the whole-construct C×M copy. Proven with one
  compile and runtime switching.
  """
  # persistent_term is global; the fixture is compiled once for all tests.
  use ExUnit.Case, async: false

  alias Mutare.{Report, Selector}

  @source """
  defmodule Mutare.CasePatternFixture do
    def classify(n) do
      case n do
        1 -> :one
        x when x > 5 -> :big
        _ -> :other
      end
    end

    def swap(p) do
      case p do
        {x, y} -> x - y
        _ -> :nope
      end
    end

    def dup(t) do
      case t do
        {a, a} -> :same
        _ -> :diff
      end
    end

    def label(s) do
      case s do
        "go" -> :start
        _ -> :unknown
      end
    end

    def narrow(n) do
      case n do
        1 -> :one
        2 -> :two
      end
    end

    def chained(n) do
      case n do
        1 -> :one
        x = _ = y -> {x, y}
      end
    end
  end
  """

  @compile {:no_warn_undefined, Mutare.CasePatternFixture}

  setup_all do
    {metamutant, sites, _next_id} =
      Mutare.Transform.transform_string_with_sites(@source, file: "cp.ex")

    # Broadening a clause's pattern can make a later clause unreachable — a benign "cannot
    # match" warning (the metamutant still compiles); captured so it doesn't clutter output.
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

  alias Mutare.CasePatternFixture, as: F

  defp id(sites, mutator, mutated_code, line) do
    site =
      Enum.find(
        sites,
        &(&1.mutator == mutator and &1.mutated_code == mutated_code and &1.line == line)
      )

    assert site, "no #{mutator} site #{inspect(mutated_code)} on line #{line}"
    site.id
  end

  # The per-site active-id read is hoisted, so a tupled-case subject reads the bound
  # `mutare_active` variable, not the inline persistent_term read. The variable name
  # (unlike the persistent_term key) is independent of `Selector.suite_key/0`, so this
  # holds under dogfooding.
  defp selector_tuple(subject), do: "case {mutare_active, #{subject}}"

  test "case clause-pattern/guard mutants are delivered in place via tuple-the-scrutinee", %{
    sites: sites,
    meta: meta
  } do
    # Not lifted — no generated private functions for these defs.
    refute meta =~ "__mutare_classify"
    refute meta =~ "__mutare_swap"

    # The subject is tupled with the active id (the per-clause dispatch).
    assert meta =~ selector_tuple("n")

    clause_sites =
      Enum.filter(
        sites,
        &(&1.mutator in [:integer, :relational, :pattern_swap, :pattern_wildcard, :string])
      )

    assert clause_sites != []
    assert Enum.all?(clause_sites, &(&1.kind == :in_place))
  end

  test "a non-exhaustive case gets an unmatched fallback; exhaustive ones do not", %{meta: meta} do
    # Only `narrow` lacks a catch-all, so exactly one tupled `case` re-raises CaseClauseError on
    # the bare subject — the rest keep an unconditional catch-all and add none. `classify/swap/dup/
    # label` use a plain `_`; `chained` uses a **match chain** `x = _ = y`, which is just as
    # irrefutable, so it is recognised as exhaustive (not given a second fallback).
    assert meta =~ "Elixir.Kernel.raise(Elixir.CaseClauseError, term: mutare_unmatched)"
    assert length(Regex.scan(~r/Elixir\.Kernel\.raise\(Elixir\.CaseClauseError/, meta)) == 1
  end

  describe "behaviour under runtime switching" do
    test "baseline behaves like the original" do
      assert F.classify(1) == :one
      assert F.classify(7) == :big
      assert F.classify(3) == :other
      assert F.swap({5, 2}) == 3
      assert F.dup({1, 1}) == :same
      assert F.dup({1, 2}) == :diff
      assert F.label("go") == :start
      assert F.label("x") == :unknown
      assert F.narrow(1) == :one
      assert F.narrow(2) == :two
    end

    test "a match-chain catch-all (x = _ = y) is exhaustive — no CaseClauseError" do
      # The final clause binds every value (each operand of the `=` chain is a var/wildcard), so it
      # is a catch-all just like a plain `_` — `chained` never falls through and never raises.
      assert F.chained(1) == :one
      assert F.chained(3) == {3, 3}
    end

    test "a non-exhaustive case raises CaseClauseError on the bare subject, not the tuple" do
      # Without the unmatched fallback the tupled subject would raise on `{0, 3}`; the fallback
      # re-raises the original error on the bare `3`, and — load-bearing — records the case's
      # ids at baseline so a re-targeting mutant is not wrongly scored `:no_coverage`.
      error = assert_raise CaseClauseError, fn -> F.narrow(3) end
      assert error.term == 3
    end

    test "a re-targeting mutant makes a previously-unmatched value match", %{sites: sites} do
      # `2 -> :two` becomes `3 -> :two`, so `narrow(3)` now matches instead of raising.
      Selector.put(id(sites, :integer, "3", 34))
      assert F.narrow(3) == :two
    end

    test "a literal pattern mutant re-targets the clause", %{sites: sites} do
      Selector.put(id(sites, :integer, "2", 4))
      # Clause 1 now matches 2, not 1: 1 falls through, 2 hits :one.
      assert F.classify(1) == :other
      assert F.classify(2) == :one
    end

    test "a guard mutant changes the clause's match", %{sites: sites} do
      Selector.put(id(sites, :relational, "x >= 5", 5))
      assert F.classify(5) == :big
    end

    test "a string-literal pattern mutant re-targets the clause", %{sites: sites} do
      Selector.put(id(sites, :string, ~s("mutare"), 26))
      assert F.label("go") == :unknown
    end

    test "swapping a clause pattern binds the other value", %{sites: sites} do
      Selector.put(id(sites, :pattern_swap, "{y, x}", 12))
      assert F.swap({5, 2}) == 2 - 5
    end

    test "wildcarding a duplicate drops the equality match", %{sites: sites} do
      Selector.put(id(sites, :pattern_wildcard, "{_, _}", 19))
      assert F.dup({1, 2}) == :same
    end

    test "an unknown id falls through to every original clause" do
      Selector.put(987_654)
      assert F.classify(1) == :one
      assert F.classify(7) == :big
      assert F.classify(3) == :other
      assert F.swap({5, 2}) == 3
      assert F.dup({1, 2}) == :diff
      assert F.label("go") == :start
    end

    test "an active body mutant still fires through the gated original clause", %{sites: sites} do
      # `:big` (clause 2 body) → `:mutare`. Its in-place selector lives in the *original*
      # clause's (emitted) body, reached when no pattern mutant is active.
      Selector.put(id(sites, :atom, ":mutare", 5))
      assert F.classify(7) == :mutare
      assert F.classify(1) == :one
    end
  end

  test "renders a case-pattern literal swap as a focused one-line diff", %{sites: sites} do
    site = Enum.find(sites, &(&1.mutator == :integer and &1.line == 4 and &1.mutated_code == "2"))

    assert Report.header(site) == "cp.ex:4  [integer, in-place]  SURVIVED"
    assert Report.diff(site, @source) == "-      1 -> :one\n+      2 -> :one"
  end

  test "renders a case-guard swap as a focused one-line diff", %{sites: sites} do
    site =
      Enum.find(
        sites,
        &(&1.mutator == :relational and &1.line == 5 and &1.mutated_code == "x >= 5")
      )

    assert Report.header(site) == "cp.ex:5  [relational, in-place]  SURVIVED"

    assert Report.diff(site, @source) ==
             "-      x when x > 5 -> :big\n+      x when x >= 5 -> :big"
  end
end
