defmodule Mutare.LiftTest do
  @moduledoc """
  Function lifting and dispatchers deliver guard mutations by duplicating the
  clause group, proven end to end with one compile and runtime switching.
  """
  # persistent_term is global; the fixture is compiled once for all tests.
  use ExUnit.Case, async: false

  import ExUnit.CaptureLog

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
    {metamutant, sites, _next_id} = Mutare.transform_string(@source, file: "lift.ex")
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
      {meta, _, _} = Mutare.transform_string(@source)

      assert meta =~ "def classify(mutare_arg1) do"
      assert meta =~ ~r/defp __mutare_classify_1_g\d+_orig/
      assert meta =~ ~r/defp __mutare_classify_1_g\d+_m\d+/

      # Per function (each 2 clauses, clause 1 guarded): 2 guard swaps + 2 clause
      # drops = 4 lifted. Plus bump's body `n + 1` in place.
      assert Enum.count(sites, &(&1.operation == :replace and &1.kind == :lifted)) == 4
      assert Enum.count(sites, &(&1.mutator == :clause_drop)) == 4

      assert [%Site{kind: :in_place, original_op: :+}] =
               Enum.filter(sites, &(&1.kind == :in_place))
    end

    test "lifts an unguarded multi-clause function for clause-drop" do
      {meta, sites, _next_id} =
        Mutare.transform_string("defmodule M do\n  def g(0), do: :z\n  def g(_), do: :o\nend\n")

      assert meta =~ "def g(mutare_arg1) do"
      assert meta =~ ~r/defp __mutare_g_1_g\d+_orig/
      # two clauses → two clause-drop mutants, no guard mutants
      assert Enum.count(sites, &(&1.mutator == :clause_drop)) == 2
      assert {:ok, _} = Code.string_to_quoted(meta)
    end

    test "salts generated names when the target already defines a __mutare_ name" do
      # The target hand-writes the exact name the default scheme would generate
      # for classify/1's `__orig` copy (lift group 1). With a fixed prefix this
      # is a duplicate `defp` that sinks the single metamutant build; the scan
      # must shift the prefix so the generated copies dodge it.
      source = """
      defmodule Mutare.PrefixCollisionFixture do
        def __mutare_classify_1_g1_orig(_), do: :preexisting

        def classify(n) when n >= 0, do: :nonneg
        def classify(_), do: :neg
      end
      """

      {meta, _sites, _next_id} = Mutare.transform_string(source, file: "collision.ex")

      # The pre-existing target definition is left untouched...
      assert meta =~ "def __mutare_classify_1_g1_orig(_)"
      # ...and the generated copies move to a salted, still-`__mutare_` prefix.
      assert meta =~ ~r/defp __mutare_0_classify_1_g1_orig/
      assert meta =~ ~r/defp __mutare_0_classify_1_g1_m\d+/
      refute meta =~ ~r/defp __mutare_classify_1_g1_orig/

      # The real proof: it compiles. A fixed prefix would raise "def
      # __mutare_classify_1_g1_orig/1 already defined".
      assert [{Mutare.PrefixCollisionFixture, _}] = Code.compile_string(meta)
    end

    test "does not lift a function whose clauses are split by another definition" do
      source = """
      defmodule Mutare.NonConsecutiveLiftFixture do
        def f(x) when x > 0, do: :positive
        def g, do: :g
        def f(_), do: :other
      end
      """

      {{meta, sites, _next_id}, log} =
        with_log(fn -> Mutare.transform_string(source, file: "nc.ex") end)

      # Non-consecutive heads fall back to in-place: no dispatcher, no lifted
      # guard/clause-drop mutants. The clauses keep their original positions, so
      # `f/1` stays reachable across the intervening `def g`.
      refute meta =~ "__mutare_f"
      assert Enum.count(sites, &(&1.kind == :lifted)) == 0
      assert log =~ "nc.ex: clauses of f/1 are non-consecutive — not lifting"
      assert [{Mutare.NonConsecutiveLiftFixture, _}] = Code.compile_string(meta)

      Selector.put(Selector.baseline())
      assert apply(Mutare.NonConsecutiveLiftFixture, :f, [1]) == :positive
      assert apply(Mutare.NonConsecutiveLiftFixture, :f, [0]) == :other
      assert apply(Mutare.NonConsecutiveLiftFixture, :f, [-1]) == :other
      assert apply(Mutare.NonConsecutiveLiftFixture, :g, []) == :g
    end

    test "non-consecutive heads keep compile-time @attr reads in position" do
      # If `f/1`'s clauses were lifted into copies emitted at the dispatcher's
      # position, both bodies would read `@a` as its *last* value (2). Refusing to
      # lift keeps each `@a` read where it was written, so the values stay distinct.
      source = """
      defmodule Mutare.NonConsecutiveAttrFixture do
        @a 1
        def f(0), do: @a
        @a 2
        def f(1), do: @a
      end
      """

      {{meta, _sites, _next_id}, _log} =
        with_log(fn -> Mutare.transform_string(source) end)

      refute meta =~ "__mutare_f"
      assert [{Mutare.NonConsecutiveAttrFixture, _}] = Code.compile_string(meta)

      Selector.put(Selector.baseline())
      assert apply(Mutare.NonConsecutiveAttrFixture, :f, [0]) == 1
      assert apply(Mutare.NonConsecutiveAttrFixture, :f, [1]) == 2
    end

    test "lifts functions whose names end in ? or ! (sanitized private names)" do
      source = """
      defmodule Mutare.OkFixture do
        def ok?(n) when n > 0, do: true
        def ok?(_), do: false
      end
      """

      {meta, _sites, _next_id} = Mutare.transform_string(source)

      # public dispatcher keeps `ok?`; private copies sanitize the `?`
      assert meta =~ "def ok?(mutare_arg1) do"
      refute meta =~ ~r/defp __mutare_ok\?/
      assert {:ok, _} = Code.string_to_quoted(meta)
      assert [{_mod, _}] = Code.compile_string(meta)
    end

    test "falls back to in-place (no lift) for default args and operator names" do
      {defaulted, _, _} =
        Mutare.transform_string("defmodule M do\n  def h(a, b \\\\ 1) when a > b, do: a\nend\n")

      refute defaulted =~ "__mutare_h"

      {operator, _, _} =
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

  describe "clause drop" do
    defp drop_id(sites, line) do
      site = Enum.find(sites, &(&1.mutator == :clause_drop and &1.line == line))
      assert site, "no clause-drop site on line #{line}"
      site.id
    end

    test "dropping a clause sends its inputs to a later clause", %{sites: sites} do
      # drop `def classify(n) when n >= 0` (line 2)
      Selector.put(drop_id(sites, 2))
      assert F.classify(5) == :neg
    end

    test "dropping the catch-all makes the function non-exhaustive", %{sites: sites} do
      # drop `def classify(_)` (line 3)
      Selector.put(drop_id(sites, 3))
      assert F.classify(5) == :nonneg
      assert_raise FunctionClauseError, fn -> F.classify(-1) end
    end
  end

  test "report renders a lifted guard mutant as a one-line diff", %{sites: sites} do
    site =
      Enum.find(sites, &(&1.kind == :lifted and &1.original_op == :>= and &1.mutated_op == :>))

    assert Report.diff(site, @source) ==
             "-  def classify(n) when n >= 0, do: :nonneg\n" <>
               "+  def classify(n) when n > 0, do: :nonneg"
  end

  test "report renders a clause-drop mutant as removed lines", %{sites: sites} do
    site = Enum.find(sites, &(&1.mutator == :clause_drop and &1.line == 3))

    assert Report.header(site) == "lift.ex:3  [clause_drop, lifted]  SURVIVED"
    assert Report.diff(site, @source) == "-  def classify(_), do: :neg"
  end
end
