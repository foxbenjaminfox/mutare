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

  describe "Mutare.Transform.Analyze.ClausePatterns mechanics" do
    test "a receive/fn clause body is analyzed as runtime (operators in it mutate)" do
      # `attach_clause_pattern_candidates/4` recurses the construct with the `:runtime`
      # context so body expressions still get in-place mutants (not just patterns/guards).
      fn_src = "defmodule T do\n  def h, do: fn x -> x + 1 end\nend\n"

      recv_src =
        "defmodule T do\n  def r do\n    receive do\n      x -> x + 1\n    end\n  end\nend\n"

      for src <- [fn_src, recv_src] do
        {_meta, sites, _} = Mutare.transform_string(src, mutators: [Mutare.Mutators.Arithmetic])
        assert Enum.any?(sites, &(&1.mutator == :arithmetic and &1.original_code == "x + 1"))
      end
    end

    test "a duplicate case-clause pattern thins (keeps the body-read binding), never `{_, _}`" do
      # `case_clause_parts/1` passes the names read in guard+body as `used_outside`, forcing the
      # wildcard family into *thin* mode; dropping that read-set would let it wildcard both
      # occurrences and strand the body's `a`.
      # Both an unguarded clause (`used_names([body])`) and a guarded one
      # (`used_names([guard, body])`) must keep the body/guard read-set so the wildcard stays thin.
      source = """
      defmodule T do
        def f(t) do
          case t do
            {a, a} -> a * 2
            _ -> 0
          end
        end

        def g(t) do
          case t do
            {b, b} when is_integer(b) -> b * 3
            _ -> 0
          end
        end
      end
      """

      {_meta, sites, _} =
        Mutare.transform_string(source, mutators: [Mutare.Mutators.PatternWildcard])

      codes =
        sites |> Enum.filter(&(&1.mutator == :pattern_wildcard)) |> Enum.map(& &1.mutated_code)

      assert Enum.sort(codes) == ["{_, a}", "{_, b}", "{a, _}", "{b, _}"]
    end

    test "a duplicate fn clause pattern thins too (clause_patterns/1 read-set)" do
      # The `case` twin above goes through `case_clause_parts/1`; `fn`/`receive` clauses go
      # through `clause_patterns/1`, which has its own `used_names([body])` (unguarded) and
      # `used_names([guard, body])` (guarded) read-sets. Both must keep the wildcard thin.
      source = """
      defmodule T do
        def h do
          fn {a, a} -> a * 2
             _ -> 0 end
        end

        def g do
          fn {b, b} when is_integer(b) -> b * 3
             _ -> 0 end
        end
      end
      """

      {_meta, sites, _} =
        Mutare.transform_string(source, mutators: [Mutare.Mutators.PatternWildcard])

      codes =
        sites |> Enum.filter(&(&1.mutator == :pattern_wildcard)) |> Enum.map(& &1.mutated_code)

      assert Enum.sort(codes) == ["{_, a}", "{_, b}", "{a, _}", "{b, _}"]
    end

    test "a guarded multi-pattern fn clause delivers pattern-swap and guard mutants at runtime" do
      # Exercises the full multi-pattern (`when_args == 3`) clause path: `clause_patterns/1`,
      # `clause_guard/1`, `put_clause_pattern_at/3`, and `put_clause_guard/2` — each gated on
      # `length(when_args) >= 2` and using `Enum.split(when_args, -1)`.
      source = """
      defmodule Mutare.FnGuardFixture do
        def run do
          fn {a, b}, c when c > a -> {a, b, c}
             _, _ -> :other end
        end
      end
      """

      {meta, sites, _} =
        Mutare.transform_string(source,
          mutators: [Mutare.Mutators.PatternSwap, Mutare.Mutators.Relational]
        )

      # Bind the module from the compile result (not a literal) so the compiler can't
      # constant-fold a reference to a not-yet-defined module into an "undefined" warning.
      [{mod, _}] = Mutare.Test.Compile.string(meta)

      swap = Enum.find(sites, &(&1.mutator == :pattern_swap and &1.mutated_code == "{b, a}"))
      lt = Enum.find(sites, &(&1.mutator == :relational and &1.mutated_code == "c < a"))
      assert swap && lt

      # `run/0` builds the fn under the active mutant, so call it fresh after each switch.
      Selector.put(Selector.baseline())
      assert mod.run().({1, 2}, 5) == {1, 2, 5}
      assert mod.run().({5, 2}, 1) == :other

      # swap `{a, b}` -> `{b, a}`: a binds the 2nd element; {1,2} -> b=1, a=2; c=5 > 2 -> {2,1,5}
      Selector.put(swap.id)
      assert mod.run().({1, 2}, 5) == {2, 1, 5}

      # guard `c > a` -> `c < a`: {5,2}, c=1 < a=5 -> {5,2,1}
      Selector.put(lt.id)
      assert mod.run().({5, 2}, 1) == {5, 2, 1}
    after
      Selector.put(Selector.baseline())
    end

    test "a single-pattern guarded fn clause swap keeps the guard (when_args == 2 path)" do
      # The multi-pattern test above exercises `when_args == 3`; this pins `when_args == 2` for
      # `put_clause_pattern_at/3` — a *structural swap on a single-pattern guarded clause*. A
      # mis-built replacement (e.g. the guard silently dropped) only shows at runtime: with the
      # guard kept, the swapped `{5, 2}` fails `a > b` and falls through to `:other`.
      source = """
      defmodule Mutare.FnGuard2Fixture do
        def run do
          fn {a, b} when a > b -> {a, b}
             _ -> :other end
        end
      end
      """

      {meta, sites, _} =
        Mutare.transform_string(source, mutators: [Mutare.Mutators.PatternSwap])

      # Bind the module from the compile result (not a literal) so the compiler can't
      # constant-fold a reference to a not-yet-defined module into an "undefined" warning.
      [{mod, _}] = Mutare.Test.Compile.string(meta)
      swap = Enum.find(sites, &(&1.mutator == :pattern_swap and &1.mutated_code == "{b, a}"))
      assert swap

      Selector.put(Selector.baseline())
      assert mod.run().({5, 2}) == {5, 2}
      assert mod.run().({2, 5}) == :other

      # swap `{a, b}` -> `{b, a}` with the guard intact: {5,2} -> b=5, a=2, `a > b` (2 > 5) is
      # false -> :other; {2,5} -> b=2, a=5, 5 > 2 -> {a, b} = {5, 2}.
      Selector.put(swap.id)
      assert mod.run().({5, 2}) == :other
      assert mod.run().({2, 5}) == {5, 2}
    after
      Selector.put(Selector.baseline())
    end
  end
end
