defmodule Mutare.LiftTest do
  @moduledoc """
  Function lifting and dispatchers deliver guard mutations by routing the clause
  group through one private function (taking the active id as an extra arg), each
  mutant a single guarded clause — proven end to end with one compile and runtime
  switching.
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

  # The head-pattern fixture (exercised by the describe block far below). Defined
  # up here so the module-level `setup_all` can compile it once for all of that
  # block's tests — `setup_all` cannot live inside a `describe`, and a per-test
  # `setup` would recompile it for every test.
  @pattern_source """
  defmodule Mutare.PatternLiftFixture do
    def classify(%{1 => 2}), do: :exact
    def classify(_), do: :other

    def kind(:go), do: :going
    def kind(_), do: :stopped
  end
  """

  @compile {:no_warn_undefined, Mutare.PatternLiftFixture}

  # Pin to the operator-swap families: this fixture exercises lifting mechanics
  # (guard swaps, clause drops, in-place bodies), so the default literal mutator —
  # which would also lift `0`/`1` constants in the guards and bodies — is excluded
  # to keep the asserted site counts about lifting, not constants.
  @probe [Mutare.Mutators.Arithmetic, Mutare.Mutators.Relational]

  setup_all do
    {metamutant, sites, _next_id} =
      Mutare.transform_string(@source, file: "lift.ex", mutators: @probe)

    [{_module, _binary}] = Code.compile_string(metamutant)

    # Compiled once and switched at runtime by the head-pattern describe block.
    {pattern_meta, pattern_sites, _next_id} =
      Mutare.transform_string(@pattern_source, file: "pat.ex")

    [{_module, _binary}] = Code.compile_string(pattern_meta)

    %{sites: sites, pattern_sites: pattern_sites}
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
    test "lifts a guarded group into a dispatcher + one guarded private function", %{sites: sites} do
      {meta, _, _} = Mutare.transform_string(@source)

      assert meta =~ "def classify(mutare_arg1) do"
      assert meta =~ ~r/defp __mutare_classify_1_g\d+\(/
      assert meta =~ ~r/when mutare_active === \d+/

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
      assert meta =~ ~r/defp __mutare_g_1_g\d+\(mutare_active,/
      # two clauses → two clause-drop mutants, no guard mutants
      assert Enum.count(sites, &(&1.mutator == :clause_drop)) == 2
      assert {:ok, _} = Code.string_to_quoted(meta)
    end

    test "a bodiless function head is not a droppable clause" do
      # `def f(a, b, c)` with no body is a header declaration (default args / docs),
      # not a real clause. With one body-bearing clause the function is effectively
      # single-clause: no drop is offered. Dropping the impl while the header
      # remained would emit a bodiless `defp …(args)` → "implementation not provided"
      # (the plug `Plug.Conn.Utils.validate_utf8!/3` poison). Must compile.
      source = """
      defmodule Mutare.BodilessHeadFixture do
        def f(a, b, c)
        def f(<<x::binary>>, b, c), do: {byte_size(x), b, c}
      end
      """

      {meta, sites, _next_id} = Mutare.transform_string(source)

      assert Enum.count(sites, &(&1.mutator == :clause_drop)) == 0
      assert [{Mutare.BodilessHeadFixture, _}] = Code.compile_string(meta)
    end

    test "a bodiless head with two impls drops only the impls, never the header" do
      source = """
      defmodule Mutare.BodilessHeadTwoFixture do
        def f(a)
        def f(0), do: :zero
        def f(n), do: :other
      end
      """

      {meta, sites, _next_id} = Mutare.transform_string(source)

      # Two body-bearing clauses → two drops; the header (index 0) is never dropped.
      assert Enum.count(sites, &(&1.mutator == :clause_drop)) == 2
      assert [{Mutare.BodilessHeadTwoFixture, _}] = Code.compile_string(meta)
    end

    test "salts generated names when the target already defines a __mutare_ name" do
      # The target hand-writes a name under the `__mutare_` stem the default scheme
      # would generate into for classify/1 (lift group 1). With a fixed prefix the
      # generated private function could clash and sink the single metamutant build;
      # the scan must shift the prefix so the generated names dodge it.
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
      # ...and the generated private group moves to a salted, still-`__mutare_` prefix.
      assert meta =~ ~r/defp __mutare_0_classify_1_g1\(/

      assert meta =~
               ~r/defp __mutare_0_classify_1_g1\(mutare_active, n\) when mutare_active === \d+/

      refute meta =~ ~r/defp __mutare_classify_1_g1\(/

      # The real proof: it compiles. A fixed prefix risks an "already defined" clash.
      assert [{Mutare.PrefixCollisionFixture, _}] = Code.compile_string(meta)
    end

    test "salts the dispatch variable when the source uses `mutare_active` itself" do
      # A lifted function whose own variable is named `mutare_active` would clash with
      # the generated dispatch variable: the gated head `f(mutare_active, mutare_active)`
      # would silently mean "match when the id equals the user's value", and the guard
      # would read the wrong binding. The dispatch var must salt away from it.
      source = """
      defmodule Mutare.ActiveVarCollisionFixture do
        def f(mutare_active) when mutare_active > 0, do: mutare_active * 2
        def f(_), do: 0
      end
      """

      {meta, sites, _next_id} = Mutare.transform_string(source, file: "av.ex", mutators: @probe)

      # the dispatch variable salts to `mutare_active_0`; the user's `mutare_active`
      # stays its own variable, so the gate reads the id and the body reads the user value
      assert meta =~ "mutare_active_0 = :persistent_term.get"
      assert meta =~ ~r/when mutare_active_0 === \d+/
      assert [{Mutare.ActiveVarCollisionFixture, _}] = Code.compile_string(meta)

      # baseline behaves like the original…
      Selector.put(Selector.baseline())
      assert apply(Mutare.ActiveVarCollisionFixture, :f, [3]) == 6
      assert apply(Mutare.ActiveVarCollisionFixture, :f, [0]) == 0

      # …and a guard mutant (`>` → `<`) really flips dispatch: f(3) now falls through
      # to `f(_) -> 0`, proving the salted gate and the user variable coexist correctly.
      flip = Enum.find(sites, &(&1.original_op == :> and &1.mutated_op == :<))
      assert flip, "expected a `>` → `<` guard mutant"
      Selector.put(flip.id)
      assert apply(Mutare.ActiveVarCollisionFixture, :f, [3]) == 0
    after
      Selector.put(Selector.baseline())
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

    test "does not lift a function whose clauses are augmented by metaprogramming" do
      # `code/1`'s literal clauses are consecutive, but a module-level `for`
      # generates more `code/1` clauses at compile time. Lifting would install a
      # catch-all dispatcher that shadows the generated clauses and forwards to an
      # `__orig` missing them — `code(:ok)` would raise FunctionClauseError. The
      # mirror of the plug `Plug.Conn.Status.code/1` baseline failure.
      source = """
      defmodule Mutare.MetaprogrammedLiftFixture do
        @pairs [ok: 200, not_found: 404]

        def code(integer) when integer in 100..999, do: integer

        for {atom, code} <- @pairs do
          def code(unquote(atom)), do: unquote(code)
        end
      end
      """

      {{meta, sites, _next_id}, log} =
        with_log(fn -> Mutare.transform_string(source, file: "meta.ex") end)

      refute meta =~ "__mutare_code"
      assert Enum.count(sites, &(&1.kind == :lifted)) == 0
      assert log =~ "meta.ex: clauses of code/1 are augmented by compile-time metaprogramming"
      assert [{Mutare.MetaprogrammedLiftFixture, _}] = Code.compile_string(meta)

      Selector.put(Selector.baseline())
      assert apply(Mutare.MetaprogrammedLiftFixture, :code, [200]) == 200
      assert apply(Mutare.MetaprogrammedLiftFixture, :code, [:ok]) == 200
      assert apply(Mutare.MetaprogrammedLiftFixture, :code, [:not_found]) == 404
    end

    test "lifts functions whose names end in ? or ! (sanitized private names)" do
      source = """
      defmodule Mutare.OkFixture do
        def ok?(n) when n > 0, do: true
        def ok?(_), do: false
      end
      """

      # Pin to the operator-swap families: this checks private-name sanitization,
      # and the default conditional mutator would rewrite the guard to `when true`
      # (making the catch-all clause unreachable — a benign but noisy generated
      # warning when this metamutant is compiled below).
      {meta, _sites, _next_id} = Mutare.transform_string(source, mutators: @probe)

      # public dispatcher keeps `ok?`; private copies sanitize the `?`
      assert meta =~ "def ok?(mutare_arg1) do"
      refute meta =~ ~r/defp __mutare_ok\?/
      assert {:ok, _} = Code.string_to_quoted(meta)
      assert [{_mod, _}] = Code.compile_string(meta)
    end

    test "lifts a guard-safe qualified macro (Integer.is_even) without mutating its module alias" do
      # `Integer.is_even/1` is a guard-safe macro, so `Integer.is_even(n)` in a `when`
      # lifts like any guard swap (delivered as `Integer.is_odd(n)` in the `__mut`
      # copy). The regression this pins: the `Integer` alias sits in the call's *form*
      # position — a name, not a value — so `AliasLiteral` must NOT swap it. A
      # `when Mutare.Mutant.is_even(n)` copy is guard-illegal and would poison the
      # single build. The in-place analyzer keeps a remote call's module opaque; the
      # guard tagger must do the same (it once used a context-free `Macro.postwalk`).
      source = """
      defmodule Mutare.IntegerGuardFixture do
        require Integer
        def parity(n) when Integer.is_even(n), do: :even
        def parity(_n), do: :odd
      end
      """

      probe = [Mutare.Mutators.Integer, Mutare.Mutators.AliasLiteral]

      {meta, sites, _next_id} =
        Mutare.transform_string(source, file: "intguard.ex", mutators: probe)

      # The guard swap is delivered by lifting...
      assert [%Site{kind: :lifted, mutator: :integer}] =
               Enum.filter(sites, &(&1.mutator == :integer))

      # ...and the `Integer` alias in the guard's call position is left untouched.
      assert Enum.filter(sites, &(&1.mutator == :alias)) == []

      # The real proof: it compiles. AliasLiteral firing in the guard would poison it.
      assert [{Mutare.IntegerGuardFixture, _}] = Code.compile_string(meta)

      # Runtime: flipping the lifted is_odd mutant flips the parity verdict.
      swap = Enum.find(sites, &(&1.mutator == :integer))
      Selector.put(Selector.baseline())
      assert apply(Mutare.IntegerGuardFixture, :parity, [2]) == :even
      Selector.put(swap.id)
      assert apply(Mutare.IntegerGuardFixture, :parity, [2]) == :odd
      Selector.put(Selector.baseline())
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

  describe "head-pattern literal mutants (compiled, switched at runtime)" do
    defp pattern_id(sites, from, to) do
      site =
        Enum.find(
          sites,
          &(&1.kind == :lifted and &1.original_code == from and &1.mutated_code == to)
        )

      assert site, "no lifted #{from} -> #{to} pattern site"
      site.id
    end

    test "baseline dispatches exactly like the original" do
      Selector.put(Selector.baseline())
      assert apply(Mutare.PatternLiftFixture, :classify, [%{1 => 2}]) == :exact
      assert apply(Mutare.PatternLiftFixture, :classify, [%{1 => 3}]) == :other
      assert apply(Mutare.PatternLiftFixture, :kind, [:go]) == :going
      assert apply(Mutare.PatternLiftFixture, :kind, [:nope]) == :stopped
    end

    test "mutating a map key in the head changes which clause matches", %{pattern_sites: sites} do
      # `%{1 => 2}` → `%{0 => 2}`: the original input no longer hits the first clause.
      Selector.put(pattern_id(sites, "1", "0"))
      assert apply(Mutare.PatternLiftFixture, :classify, [%{1 => 2}]) == :other
      assert apply(Mutare.PatternLiftFixture, :classify, [%{0 => 2}]) == :exact
    end

    test "mutating an atom in the head changes which clause matches", %{pattern_sites: sites} do
      # `:go` → `:mutare`: `kind(:go)` now falls through to the catch-all.
      Selector.put(pattern_id(sites, ":go", ":mutare"))
      assert apply(Mutare.PatternLiftFixture, :kind, [:go]) == :stopped
      assert apply(Mutare.PatternLiftFixture, :kind, [:mutare]) == :going
    end

    test "the report renders a head-literal mutant as a one-line diff", %{pattern_sites: sites} do
      site = Enum.find(sites, &(&1.original_code == ":go" and &1.kind == :lifted))

      assert Report.header(site) == "pat.ex:5  [atom, lifted]  SURVIVED"

      assert Report.diff(site, @pattern_source) ==
               "-  def kind(:go), do: :going\n+  def kind(:mutare), do: :going"
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
