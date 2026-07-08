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

  # Default arguments, the hard case: a bodiless header with defaults *interleaved*
  # with required args (`b \\ 10` then required `c` then `d \\ 20` — a non-default
  # arg after a default), a head-literal clause (`f(0, …)`), a guard clause, and a
  # catch-all. So one fixture exercises default-value mutation (on the dispatcher),
  # head-literal lifting, guard lifting, and clause drops, while staying callable at
  # arities 2/3/4 — Elixir fills the *optional* positions (b, d) left-to-right as
  # args are omitted, which the lifted dispatcher must preserve exactly.
  @default_source """
  defmodule Mutare.DefaultArgFixture do
    def f(a, b \\\\ 10, c, d \\\\ 20)
    def f(0, b, c, d), do: {:zero, b, c, d}
    def f(a, b, c, d) when a > 5, do: {:big, a, b, c, d}
    def f(a, b, c, d), do: {:other, a, b, c, d}
  end
  """

  @compile {:no_warn_undefined, Mutare.DefaultArgFixture}

  # Pin to the operator-swap families: this fixture exercises lifting mechanics
  # (guard swaps, clause drops, in-place bodies), so the default literal mutator —
  # which would also lift `0`/`1` constants in the guards and bodies — is excluded
  # to keep the asserted site counts about lifting, not constants.
  @probe [Mutare.Mutators.Arithmetic, Mutare.Mutators.Relational]

  setup_all do
    {metamutant, sites, _next_id} =
      Mutare.Transform.transform_string_with_sites(@source, file: "lift.ex", mutators: @probe)

    [{_module, _binary}] = Mutare.Test.Compile.string(metamutant)

    # Compiled once and switched at runtime by the head-pattern describe block.
    {pattern_meta, pattern_sites, _next_id} =
      Mutare.Transform.transform_string_with_sites(@pattern_source, file: "pat.ex")

    [{_module, _binary}] = Mutare.Test.Compile.string(pattern_meta)

    {default_meta, default_sites, _next_id} =
      Mutare.Transform.transform_string_with_sites(@default_source, file: "default.ex")

    [{_module, _binary}] = Mutare.Test.Compile.string(default_meta)

    %{sites: sites, pattern_sites: pattern_sites, default_sites: default_sites}
  end

  setup do
    Selector.put(Selector.baseline())
    on_exit(fn -> Selector.put(Selector.baseline()) end)
    :ok
  end

  alias Mutare.LiftFixture, as: F

  defp id(sites, from, to, line) do
    site =
      Enum.find(sites, &(&1.original_form == from and &1.mutated_form == to and &1.line == line))

    assert site, "no #{from} -> #{to} site on line #{line}"
    site.id
  end

  describe "structure" do
    test "lifts a guarded group into a dispatcher + one guarded private function", %{sites: sites} do
      {meta, _, _} = Mutare.Transform.transform_string_with_sites(@source)

      assert meta =~ "def classify(mutare_arg1) do"
      assert meta =~ ~r/defp __mutare_classify_1_g\d+\(/
      assert meta =~ ~r/when mutare_active === \d+/

      # Per function (each 2 clauses, clause 1 guarded): 2 guard swaps + 2 clause
      # drops = 4 lifted. Plus bump's body `n + 1` in place.
      assert Enum.count(sites, &(&1.operation == :replace and &1.kind == :lifted)) == 4
      assert Enum.count(sites, &(&1.mutator == :clause_drop)) == 4

      assert [%Site{kind: :in_place, original_form: :+}] =
               Enum.filter(sites, &(&1.kind == :in_place))
    end

    test "lifts an unguarded multi-clause function for clause-drop" do
      {meta, sites, _next_id} =
        Mutare.Transform.transform_string_with_sites(
          "defmodule M do\n  def g(0), do: :z\n  def g(_), do: :o\nend\n"
        )

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

      {meta, sites, _next_id} = Mutare.Transform.transform_string_with_sites(source)

      refute Enum.any?(sites, &(&1.mutator == :clause_drop))
      assert [{Mutare.BodilessHeadFixture, _}] = Mutare.Test.Compile.string(meta)
    end

    test "a bodiless head with two impls drops only the impls, never the header" do
      source = """
      defmodule Mutare.BodilessHeadTwoFixture do
        def f(a)
        def f(0), do: :zero
        def f(n), do: :other
      end
      """

      {meta, sites, _next_id} = Mutare.Transform.transform_string_with_sites(source)

      # Two body-bearing clauses → two drops; the header (index 0) is never dropped.
      assert Enum.count(sites, &(&1.mutator == :clause_drop)) == 2
      assert [{Mutare.BodilessHeadTwoFixture, _}] = Mutare.Test.Compile.string(meta)
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

      {meta, _sites, _next_id} =
        Mutare.Transform.transform_string_with_sites(source, file: "collision.ex")

      # The pre-existing target definition is left untouched...
      assert meta =~ "def __mutare_classify_1_g1_orig(_)"
      # ...and the generated private group moves to a salted, still-`__mutare_` prefix.
      assert meta =~ ~r/defp __mutare_0_classify_1_g1\(/

      assert meta =~
               ~r/defp __mutare_0_classify_1_g1\(mutare_active, n\) when mutare_active === \d+/

      refute meta =~ ~r/defp __mutare_classify_1_g1\(/

      # The real proof: it compiles. A fixed prefix risks an "already defined" clash.
      assert [{Mutare.PrefixCollisionFixture, _}] = Mutare.Test.Compile.string(meta)
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

      {meta, sites, _next_id} =
        Mutare.Transform.transform_string_with_sites(source, file: "av.ex", mutators: @probe)

      # the dispatch variable salts to `mutare_active_0`; the user's `mutare_active`
      # stays its own variable, so the gate reads the id and the body reads the user value
      assert meta =~ "mutare_active_0 = :persistent_term.get"
      assert meta =~ ~r/when mutare_active_0 === \d+/
      assert [{Mutare.ActiveVarCollisionFixture, _}] = Mutare.Test.Compile.string(meta)

      # baseline behaves like the original…
      Selector.put(Selector.baseline())
      assert apply(Mutare.ActiveVarCollisionFixture, :f, [3]) == 6
      assert apply(Mutare.ActiveVarCollisionFixture, :f, [0]) == 0

      # …and a guard mutant (`>` → `<`) really flips dispatch: f(3) now falls through
      # to `f(_) -> 0`, proving the salted gate and the user variable coexist correctly.
      flip = Enum.find(sites, &(&1.original_form == :> and &1.mutated_form == :<))
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
        with_log(fn -> Mutare.Transform.transform_string_with_sites(source, file: "nc.ex") end)

      # Non-consecutive heads fall back to in-place: no dispatcher, no lifted
      # guard/clause-drop mutants. The clauses keep their original positions, so
      # `f/1` stays reachable across the intervening `def g`.
      refute meta =~ "__mutare_f"
      refute Enum.any?(sites, &(&1.kind == :lifted))
      assert log =~ "nc.ex: clauses of f/1 are non-consecutive — not lifting"
      assert [{Mutare.NonConsecutiveLiftFixture, _}] = Mutare.Test.Compile.string(meta)

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
        with_log(fn -> Mutare.Transform.transform_string_with_sites(source) end)

      refute meta =~ "__mutare_f"
      assert [{Mutare.NonConsecutiveAttrFixture, _}] = Mutare.Test.Compile.string(meta)

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
        with_log(fn -> Mutare.Transform.transform_string_with_sites(source, file: "meta.ex") end)

      refute meta =~ "__mutare_code"
      refute Enum.any?(sites, &(&1.kind == :lifted))
      assert log =~ "meta.ex: clauses of code/1 are augmented by compile-time metaprogramming"
      assert [{Mutare.MetaprogrammedLiftFixture, _}] = Mutare.Test.Compile.string(meta)

      Selector.put(Selector.baseline())
      assert apply(Mutare.MetaprogrammedLiftFixture, :code, [200]) == 200
      assert apply(Mutare.MetaprogrammedLiftFixture, :code, [:ok]) == 200
      assert apply(Mutare.MetaprogrammedLiftFixture, :code, [:not_found]) == 404
    end

    test "does not lift a clause that shares name/arity with a defdelegate" do
      # The delegate expands to a sibling `assign/2` clause, but its AST form is
      # `:defdelegate`, invisible to clause grouping. Lifting the explicit clause
      # would leave an *unconditional* public wrapper in its position, shadowing
      # the delegate — `assign(map, %{...})` (the delegate's whole reason to
      # exist) would raise FunctionClauseError at baseline, no mutant active.
      # The Phoenix.Controller.assign/2 shape that crashed the whole run.
      source = """
      defmodule Mutare.DefdelegateLiftFixture do
        def assign(map, fun) when is_function(fun, 1) do
          assign(map, fun.(map))
        end

        defdelegate assign(map, other), to: Map, as: :merge
      end
      """

      {{meta, sites, _next_id}, log} =
        with_log(fn -> Mutare.Transform.transform_string_with_sites(source, file: "dd.ex") end)

      refute meta =~ "__mutare_assign"
      refute Enum.any?(sites, &(&1.kind == :lifted))
      assert log =~ "dd.ex: assign/2 is also defined by a defdelegate — not lifting"
      assert [{Mutare.DefdelegateLiftFixture, _}] = Mutare.Test.Compile.string(meta)

      Selector.put(Selector.baseline())
      # the delegate clause stays reachable — this call crashed pre-fix
      assert apply(Mutare.DefdelegateLiftFixture, :assign, [%{a: 1}, %{b: 2}]) ==
               %{a: 1, b: 2}

      # and the explicit clause still handles its special case
      assert apply(Mutare.DefdelegateLiftFixture, :assign, [
               %{a: 1},
               fn m -> %{n: map_size(m)} end
             ]) ==
               %{a: 1, n: 1}
    end

    test "a metaprogrammed head blocks only its own arity" do
      # The `for` generates `list/1` clauses; the module's own `list/2` is an
      # ordinary, complete top-level function the metaprogramming can never
      # touch — it must keep its lifted guard/clause-drop mutants. (The
      # Phoenix.Presence collateral: `__using__` boilerplate reusing short names
      # at a shifted arity cost `list/2`/`get_by_key/3` their mutants.)
      source = """
      defmodule Mutare.ArityScopedMetaFixture do
        def list(a, b) when a > 0, do: {:pos, a, b}
        def list(a, b), do: {:other, a, b}

        for name <- [:topic, :presence] do
          def list(unquote(name)), do: :injected
        end
      end
      """

      {{meta, sites, _next_id}, log} =
        with_log(fn ->
          Mutare.Transform.transform_string_with_sites(source, file: "as.ex", mutators: @probe)
        end)

      assert meta =~ ~r/defp __mutare_list_2_g\d+/
      assert Enum.any?(sites, &(&1.kind == :lifted))
      refute log =~ "augmented by compile-time metaprogramming"
      assert [{Mutare.ArityScopedMetaFixture, _}] = Mutare.Test.Compile.string(meta)

      Selector.put(Selector.baseline())
      # the generated arity-1 clauses stay reachable beside the lifted list/2
      assert apply(Mutare.ArityScopedMetaFixture, :list, [:topic]) == :injected
      assert apply(Mutare.ArityScopedMetaFixture, :list, [1, :x]) == {:pos, 1, :x}
      assert apply(Mutare.ArityScopedMetaFixture, :list, [0, :x]) == {:other, 0, :x}
    end

    test "defs quoted in __using__/__before_compile__ do not block lifting" do
      # Boilerplate quoted inside the two compile-time callbacks targets the
      # modules that `use`/`@before_compile` this one — never this module itself
      # (invoking either requires it to already be compiled; `use __MODULE__`
      # cannot compile). Same name, same arity as the host's own function, and
      # the host must still lift. Covers both walks: a `def` in `__using__`, a
      # `defdelegate` in `__before_compile__`.
      source = """
      defmodule Mutare.UsingBoilerplateFixture do
        defmacro __using__(_opts) do
          quote do
            def rank(a, b), do: {:injected, a, b}
          end
        end

        defmacro __before_compile__(_env) do
          quote do
            defdelegate rank(map, key), to: Map, as: :get
          end
        end

        def rank(a, b) when a > 0, do: {:pos, a, b}
        def rank(a, b), do: {:other, a, b}
      end
      """

      {{meta, sites, _next_id}, log} =
        with_log(fn ->
          Mutare.Transform.transform_string_with_sites(source, file: "ub.ex", mutators: @probe)
        end)

      assert meta =~ ~r/defp __mutare_rank_2_g\d+/
      assert Enum.any?(sites, &(&1.kind == :lifted))
      refute log =~ "augmented by compile-time metaprogramming"
      refute log =~ "defdelegate"
      assert [{Mutare.UsingBoilerplateFixture, _}] = Mutare.Test.Compile.string(meta)

      Selector.put(Selector.baseline())
      assert apply(Mutare.UsingBoilerplateFixture, :rank, [1, :x]) == {:pos, 1, :x}
      assert apply(Mutare.UsingBoilerplateFixture, :rank, [0, :x]) == {:other, 0, :x}
    end

    test "defs quoted in any macro definition do not block lifting" do
      # Macro bodies are scope boundaries to the scan: their code runs only
      # where the macro is *invoked*, and no invocation can target this module's
      # own top level — a local macro call in the module body does not compile
      # (the module's own macros don't exist until it is compiled), and a
      # generated `def` inside a function body is illegal. So this def-generating
      # helper, meant for other modules, must not cost the host's own `code/1`
      # its lifted mutants. (Contrast: a `for`-generated def DOES execute at
      # this module's compile — the "does not lift a function whose clauses are
      # augmented by metaprogramming" test above pins that side.)
      source = """
      defmodule Mutare.MacroBodyLiftFixture do
        defmacro defstatus(atom, code) do
          quote do
            def code(unquote(atom)), do: unquote(code)
          end
        end

        def code(int) when int > 99, do: int
        def code(_), do: :error
      end
      """

      {{meta, sites, _next_id}, log} =
        with_log(fn ->
          Mutare.Transform.transform_string_with_sites(source, file: "mb.ex", mutators: @probe)
        end)

      assert meta =~ ~r/defp __mutare_code_1_g\d+/
      assert Enum.any?(sites, &(&1.kind == :lifted))
      refute log =~ "augmented by compile-time metaprogramming"
      assert [{Mutare.MacroBodyLiftFixture, _}] = Mutare.Test.Compile.string(meta)

      Selector.put(Selector.baseline())
      assert apply(Mutare.MacroBodyLiftFixture, :code, [200]) == 200
      assert apply(Mutare.MacroBodyLiftFixture, :code, [50]) == :error
    end

    test "a spliced generated head blocks the name at every arity" do
      # `unquote_splicing` makes the generated arity unknowable statically, so
      # the head degrades to a bare-name wildcard: `g/1` stays unlifted even
      # though the splice happens to generate `g/2` — conservative on purpose.
      source = """
      defmodule Mutare.SplicedMetaFixture do
        def g(x) when is_integer(x), do: {:int, x}
        def g(_), do: :other

        for n <- [2] do
          args = Macro.generate_arguments(n, __MODULE__)
          def g(unquote_splicing(args)), do: {:generated, unquote(n)}
        end
      end
      """

      {{meta, sites, _next_id}, log} =
        with_log(fn -> Mutare.Transform.transform_string_with_sites(source, file: "sp.ex") end)

      refute meta =~ "__mutare_g"
      refute Enum.any?(sites, &(&1.kind == :lifted))
      assert log =~ "sp.ex: clauses of g/1 are augmented by compile-time metaprogramming"
      assert [{Mutare.SplicedMetaFixture, _}] = Mutare.Test.Compile.string(meta)

      Selector.put(Selector.baseline())
      assert apply(Mutare.SplicedMetaFixture, :g, [1]) == {:int, 1}
      assert apply(Mutare.SplicedMetaFixture, :g, [:a]) == :other
      assert apply(Mutare.SplicedMetaFixture, :g, [:a, :b]) == {:generated, 2}
    end

    test "a defdelegate of a different arity does not block lifting" do
      # The delegate head's arity is statically visible, so the block is keyed by
      # {name, arity} — `f/2`'s delegate must not cost `f/1` its lifted mutants.
      source = """
      defmodule Mutare.DefdelegateArityFixture do
        def f(x) when x > 0, do: :positive
        def f(_), do: :other

        defdelegate f(map, key), to: Map, as: :get
      end
      """

      {{meta, sites, _next_id}, log} =
        with_log(fn ->
          Mutare.Transform.transform_string_with_sites(source, file: "dd2.ex", mutators: @probe)
        end)

      assert meta =~ "__mutare_f"
      assert Enum.any?(sites, &(&1.kind == :lifted))
      refute log =~ "defdelegate"
      assert [{Mutare.DefdelegateArityFixture, _}] = Mutare.Test.Compile.string(meta)

      Selector.put(Selector.baseline())
      assert apply(Mutare.DefdelegateArityFixture, :f, [1]) == :positive
      assert apply(Mutare.DefdelegateArityFixture, :f, [0]) == :other
      assert apply(Mutare.DefdelegateArityFixture, :f, [%{a: 1}, :a]) == 1
    end

    test ":skip_lifting keeps only the matching MFA in-place" do
      source = """
      defmodule Mutare.SkipLiftFixture do
        def f(x) when x > 0, do: x + 1
        def f(x), do: x - 1
      end

      defmodule Mutare.SkipLiftOtherFixture do
        def f(x) when x > 0, do: x + 1
        def f(x), do: x - 1
      end
      """

      {{meta, sites, _next_id}, log} =
        with_log(fn ->
          Mutare.Transform.transform_string_with_sites(source,
            file: "skip.ex",
            mutators: @probe,
            skip_lifting: [{Mutare.SkipLiftFixture, :f, 1}]
          )
        end)

      skipped_lines = 3..4
      other_lines = 8..9

      refute Enum.any?(sites, fn site -> site.kind == :lifted and site.line in skipped_lines end)

      assert Enum.any?(sites, fn site ->
               site.kind == :in_place and site.mutator == :arithmetic and
                 site.line in skipped_lines
             end)

      assert Enum.any?(sites, fn site -> site.kind == :lifted and site.line in other_lines end)
      assert log =~ "skip.ex: Mutare.SkipLiftFixture.f/1 matched :skip_lifting — not lifting"
      refute log =~ "Mutare.SkipLiftOtherFixture.f/1 matched :skip_lifting"

      compiled_modules = meta |> Mutare.Test.Compile.string() |> Enum.map(&elem(&1, 0))
      assert Mutare.SkipLiftFixture in compiled_modules
      assert Mutare.SkipLiftOtherFixture in compiled_modules

      Selector.put(Selector.baseline())
      assert apply(Mutare.SkipLiftFixture, :f, [2]) == 3
      assert apply(Mutare.SkipLiftFixture, :f, [0]) == -1
      assert apply(Mutare.SkipLiftOtherFixture, :f, [2]) == 3
      assert apply(Mutare.SkipLiftOtherFixture, :f, [0]) == -1
    end

    test ":skip_lifting resolves nested module aliases relative to the current module" do
      source = """
      defmodule Mutare.SkipLiftOuter do
        def f(x) when x > 0, do: x + 1
        def f(x), do: x - 1

        defmodule Inner do
          def f(x) when x > 0, do: x + 1
          def f(x), do: x - 1
        end
      end
      """

      {{meta, sites, _next_id}, log} =
        with_log(fn ->
          Mutare.Transform.transform_string_with_sites(source,
            file: "nested_skip.ex",
            mutators: @probe,
            skip_lifting: [{Mutare.SkipLiftOuter.Inner, :f, 1}]
          )
        end)

      outer_lines = 3..4
      skipped_inner_lines = 7..8

      assert Enum.any?(sites, fn site -> site.kind == :lifted and site.line in outer_lines end)

      refute Enum.any?(sites, fn site ->
               site.kind == :lifted and site.line in skipped_inner_lines
             end)

      assert log =~
               "nested_skip.ex: Mutare.SkipLiftOuter.Inner.f/1 matched :skip_lifting — not lifting"

      compiled_modules = meta |> Mutare.Test.Compile.string() |> Enum.map(&elem(&1, 0))
      assert Mutare.SkipLiftOuter in compiled_modules
      assert Mutare.SkipLiftOuter.Inner in compiled_modules

      Selector.put(Selector.baseline())
      assert apply(Mutare.SkipLiftOuter, :f, [2]) == 3
      assert apply(Mutare.SkipLiftOuter, :f, [0]) == -1
      assert apply(Mutare.SkipLiftOuter.Inner, :f, [2]) == 3
      assert apply(Mutare.SkipLiftOuter.Inner, :f, [0]) == -1
    end

    test ":skip_lifting resolves nested __MODULE__ module heads" do
      source = """
      defmodule Mutare.SkipLiftDynamicOuter do
        defmodule __MODULE__.Child do
          def f(x) when x > 0, do: x + 1
          def f(x), do: x - 1
        end
      end
      """

      {{meta, sites, _next_id}, log} =
        with_log(fn ->
          Mutare.Transform.transform_string_with_sites(source,
            file: "dynamic_nested_skip.ex",
            mutators: @probe,
            skip_lifting: [{Mutare.SkipLiftDynamicOuter.Child, :f, 1}]
          )
        end)

      skipped_lines = 3..4

      refute Enum.any?(sites, fn site ->
               site.kind == :lifted and site.line in skipped_lines
             end)

      assert Enum.any?(sites, fn site ->
               site.kind == :in_place and site.mutator == :arithmetic and
                 site.line in skipped_lines
             end)

      assert log =~
               "dynamic_nested_skip.ex: Mutare.SkipLiftDynamicOuter.Child.f/1 matched :skip_lifting — not lifting"

      compiled_modules = meta |> Mutare.Test.Compile.string() |> Enum.map(&elem(&1, 0))
      assert Mutare.SkipLiftDynamicOuter in compiled_modules
      assert Mutare.SkipLiftDynamicOuter.Child in compiled_modules

      Selector.put(Selector.baseline())
      assert apply(Mutare.SkipLiftDynamicOuter.Child, :f, [2]) == 3
      assert apply(Mutare.SkipLiftDynamicOuter.Child, :f, [0]) == -1
    end

    test ":skip_lifting resolves top-level __MODULE__ module heads" do
      source = """
      defmodule __MODULE__.SkipLiftTopDynamicChild do
        def f(x) when x > 0, do: x + 1
        def f(x), do: x - 1
      end
      """

      {{meta, sites, _next_id}, log} =
        with_log(fn ->
          Mutare.Transform.transform_string_with_sites(source,
            file: "dynamic_top_skip.ex",
            mutators: @probe,
            skip_lifting: [{SkipLiftTopDynamicChild, :f, 1}]
          )
        end)

      skipped_lines = 2..3

      refute Enum.any?(sites, fn site ->
               site.kind == :lifted and site.line in skipped_lines
             end)

      assert Enum.any?(sites, fn site ->
               site.kind == :in_place and site.mutator == :arithmetic and
                 site.line in skipped_lines
             end)

      assert log =~
               "dynamic_top_skip.ex: SkipLiftTopDynamicChild.f/1 matched :skip_lifting — not lifting"

      compiled_modules = meta |> Mutare.Test.Compile.string() |> Enum.map(&elem(&1, 0))
      assert SkipLiftTopDynamicChild in compiled_modules

      Selector.put(Selector.baseline())
      assert apply(SkipLiftTopDynamicChild, :f, [2]) == 3
      assert apply(SkipLiftTopDynamicChild, :f, [0]) == -1
    end

    test ":skip_lifting resolves top-level aliased module heads" do
      source = """
      alias Mutare.SkipLiftAliasTarget, as: SLAT

      defmodule SLAT.Child do
        def f(x) when x > 0, do: x + 1
        def f(x), do: x - 1
      end
      """

      # `alias Mutare.SkipLiftAliasTarget, as: SLAT; defmodule SLAT.Child` defines
      # `Mutare.SkipLiftAliasTarget.Child` — the skip target must name what Elixir defines,
      # not the written `SLAT.Child`.
      {{meta, sites, _next_id}, log} =
        with_log(fn ->
          Mutare.Transform.transform_string_with_sites(source,
            file: "alias_top_skip.ex",
            mutators: @probe,
            skip_lifting: [{Mutare.SkipLiftAliasTarget.Child, :f, 1}]
          )
        end)

      skipped_lines = 4..5

      refute Enum.any?(sites, fn site ->
               site.kind == :lifted and site.line in skipped_lines
             end)

      assert Enum.any?(sites, fn site ->
               site.kind == :in_place and site.mutator == :arithmetic and
                 site.line in skipped_lines
             end)

      assert log =~
               "alias_top_skip.ex: Mutare.SkipLiftAliasTarget.Child.f/1 matched :skip_lifting — not lifting"

      compiled_modules = meta |> Mutare.Test.Compile.string() |> Enum.map(&elem(&1, 0))
      assert Mutare.SkipLiftAliasTarget.Child in compiled_modules

      Selector.put(Selector.baseline())
      assert apply(Mutare.SkipLiftAliasTarget.Child, :f, [2]) == 3
      assert apply(Mutare.SkipLiftAliasTarget.Child, :f, [0]) == -1
    end

    test ":skip_lifting ignores an alias on a nested module head (Elixir nests it verbatim)" do
      source = """
      alias Mutare.SkipLiftNestedAliasTarget, as: SNAT

      defmodule Mutare.SkipLiftNestedAliasOuter do
        defmodule SNAT.Inner do
          def f(x) when x > 0, do: x + 1
          def f(x), do: x - 1
        end
      end
      """

      # A nested `defmodule SNAT.Inner` ignores the `SNAT` alias: Elixir nests the *written*
      # path under the enclosing module, defining `Mutare.SkipLiftNestedAliasOuter.SNAT.Inner`.
      {{meta, sites, _next_id}, log} =
        with_log(fn ->
          Mutare.Transform.transform_string_with_sites(source,
            file: "alias_nested_skip.ex",
            mutators: @probe,
            skip_lifting: [{Mutare.SkipLiftNestedAliasOuter.SNAT.Inner, :f, 1}]
          )
        end)

      skipped_lines = 5..6

      refute Enum.any?(sites, fn site ->
               site.kind == :lifted and site.line in skipped_lines
             end)

      assert Enum.any?(sites, fn site ->
               site.kind == :in_place and site.mutator == :arithmetic and
                 site.line in skipped_lines
             end)

      assert log =~
               "alias_nested_skip.ex: Mutare.SkipLiftNestedAliasOuter.SNAT.Inner.f/1 matched :skip_lifting — not lifting"

      compiled_modules = meta |> Mutare.Test.Compile.string() |> Enum.map(&elem(&1, 0))
      assert Mutare.SkipLiftNestedAliasOuter.SNAT.Inner in compiled_modules

      Selector.put(Selector.baseline())
      assert apply(Mutare.SkipLiftNestedAliasOuter.SNAT.Inner, :f, [2]) == 3
      assert apply(Mutare.SkipLiftNestedAliasOuter.SNAT.Inner, :f, [0]) == -1
    end

    test ":skip_lifting never matches a module nested under a dynamic head" do
      source = """
      alias Mutare.SkipLiftDynAliasTarget, as: SDAT

      defmodule Module.concat([Mutare, "SkipLiftDynParent"]) do
        defmodule Child do
          def f(x) when x > 0, do: x + 1
          def f(x), do: x - 1
        end

        defmodule SDAT.Kid do
          def g(x) when x > 0, do: x + 1
          def g(x), do: x - 1
        end
      end
      """

      # Elixir defines `Mutare.SkipLiftDynParent.Child` and `Mutare.SkipLiftDynParent.SDAT.Kid`.
      # Under an unresolvable (dynamic) parent a nested head must never resolve with the
      # top-level rules, so neither a bare `Child` entry (aimed at a genuine top-level module)
      # nor the alias-resolved `Mutare.SkipLiftDynAliasTarget.Kid` may match — both functions
      # keep their lifted mutants, and no misleading skip warning is printed.
      {{meta, sites, _next_id}, log} =
        with_log(fn ->
          Mutare.Transform.transform_string_with_sites(source,
            file: "dyn_parent_skip.ex",
            mutators: @probe,
            skip_lifting: [{Child, :f, 1}, {Mutare.SkipLiftDynAliasTarget.Kid, :g, 1}]
          )
        end)

      child_lines = 5..6
      kid_lines = 10..11

      assert Enum.any?(sites, fn site -> site.kind == :lifted and site.line in child_lines end)
      assert Enum.any?(sites, fn site -> site.kind == :lifted and site.line in kid_lines end)
      refute log =~ "matched :skip_lifting"

      compiled_modules = meta |> Mutare.Test.Compile.string() |> Enum.map(&elem(&1, 0))
      assert Mutare.SkipLiftDynParent.Child in compiled_modules
      assert Mutare.SkipLiftDynParent.SDAT.Kid in compiled_modules

      Selector.put(Selector.baseline())
      assert apply(Mutare.SkipLiftDynParent.Child, :f, [2]) == 3
      assert apply(Mutare.SkipLiftDynParent.SDAT.Kid, :g, [0]) == -1
    end

    test ":skip_lifting matches atom-named module heads" do
      source = """
      defmodule :mutare_skip_lift_atom_mod do
        def f(x) when x > 0, do: x + 1
        def f(x), do: x - 1
      end
      """

      {{meta, sites, _next_id}, log} =
        with_log(fn ->
          Mutare.Transform.transform_string_with_sites(source,
            file: "atom_skip.ex",
            mutators: @probe,
            skip_lifting: [{:mutare_skip_lift_atom_mod, :f, 1}]
          )
        end)

      skipped_lines = 2..3

      refute Enum.any?(sites, fn site ->
               site.kind == :lifted and site.line in skipped_lines
             end)

      assert Enum.any?(sites, fn site ->
               site.kind == :in_place and site.mutator == :arithmetic and
                 site.line in skipped_lines
             end)

      assert log =~
               "atom_skip.ex: :mutare_skip_lift_atom_mod.f/1 matched :skip_lifting — not lifting"

      compiled_modules = meta |> Mutare.Test.Compile.string() |> Enum.map(&elem(&1, 0))
      assert :mutare_skip_lift_atom_mod in compiled_modules

      Selector.put(Selector.baseline())
      assert apply(:mutare_skip_lift_atom_mod, :f, [2]) == 3
      assert apply(:mutare_skip_lift_atom_mod, :f, [0]) == -1
    end

    test ":skip_lifting keeps a doubled Elixir prefix whole (and folds a single one)" do
      source = """
      defmodule Elixir.Elixir.MutareSkipLiftDoubled do
        def f(x) when x > 0, do: x + 1
        def f(x), do: x - 1
      end

      defmodule Elixir.MutareSkipLiftSingle do
        def f(x) when x > 0, do: x + 1
        def f(x), do: x - 1
      end
      """

      # `defmodule Elixir.Elixir.X` defines `:"Elixir.Elixir.X"` (the compiler folds exactly
      # one canonical prefix — same rule `Module.concat/1` applies); `defmodule Elixir.X`
      # defines plain `X`. The entries name what Elixir defines; a plain
      # `MutareSkipLiftDoubled` entry would not (and must not) match the doubled module.
      {{meta, sites, _next_id}, log} =
        with_log(fn ->
          Mutare.Transform.transform_string_with_sites(source,
            file: "prefix_skip.ex",
            mutators: @probe,
            skip_lifting: [
              {:"Elixir.Elixir.MutareSkipLiftDoubled", :f, 1},
              {MutareSkipLiftSingle, :f, 1}
            ]
          )
        end)

      doubled_lines = 2..3
      single_lines = 7..8

      refute Enum.any?(sites, fn site ->
               site.kind == :lifted and (site.line in doubled_lines or site.line in single_lines)
             end)

      assert log =~
               "prefix_skip.ex: Elixir.Elixir.MutareSkipLiftDoubled.f/1 matched :skip_lifting"

      assert log =~ "prefix_skip.ex: MutareSkipLiftSingle.f/1 matched :skip_lifting"

      compiled_modules = meta |> Mutare.Test.Compile.string() |> Enum.map(&elem(&1, 0))
      assert :"Elixir.Elixir.MutareSkipLiftDoubled" in compiled_modules
      assert MutareSkipLiftSingle in compiled_modules

      Selector.put(Selector.baseline())
      assert apply(:"Elixir.Elixir.MutareSkipLiftDoubled", :f, [2]) == 3
      assert apply(MutareSkipLiftSingle, :f, [0]) == -1
    end

    test "warnings: false silences the lifting advisories but still applies the skip" do
      source = """
      defmodule Mutare.SkipLiftQuietFixture do
        def f(x) when x > 0, do: x + 1
        def f(x), do: x - 1
      end
      """

      {{_meta, sites, _next_id}, log} =
        with_log(fn ->
          Mutare.Transform.transform_string_with_sites(source,
            file: "quiet_skip.ex",
            mutators: @probe,
            warnings: false,
            skip_lifting: [{Mutare.SkipLiftQuietFixture, :f, 1}]
          )
        end)

      # The render pass / report-time re-derivation re-run the pipeline over an
      # already-warned source with `warnings: false` — the skip must still apply,
      # only the advisory is silenced (else every warning would print 2-3 times).
      refute Enum.any?(sites, fn site -> site.kind == :lifted end)
      refute log =~ "matched :skip_lifting"
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
      {meta, _sites, _next_id} =
        Mutare.Transform.transform_string_with_sites(source, mutators: @probe)

      # public dispatcher keeps `ok?`; private copies sanitize the `?`
      assert meta =~ "def ok?(mutare_arg1) do"
      refute meta =~ ~r/defp __mutare_ok\?/
      assert {:ok, _} = Code.string_to_quoted(meta)
      assert [{_mod, _}] = Mutare.Test.Compile.string(meta)
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

      probe = [Mutare.Mutators.IntegerCall, Mutare.Mutators.AliasLiteral]

      {meta, sites, _next_id} =
        Mutare.Transform.transform_string_with_sites(source, file: "intguard.ex", mutators: probe)

      # The guard swap is delivered by lifting...
      assert [%Site{kind: :lifted, mutator: :integer_call}] =
               Enum.filter(sites, &(&1.mutator == :integer_call))

      # ...and the `Integer` alias in the guard's call position is left untouched.
      assert Enum.filter(sites, &(&1.mutator == :alias)) == []

      # The real proof: it compiles. AliasLiteral firing in the guard would poison it.
      assert [{Mutare.IntegerGuardFixture, _}] = Mutare.Test.Compile.string(meta)

      # Runtime: flipping the lifted is_odd mutant flips the parity verdict.
      swap = Enum.find(sites, &(&1.mutator == :integer_call))
      Selector.put(Selector.baseline())
      assert apply(Mutare.IntegerGuardFixture, :parity, [2]) == :even
      Selector.put(swap.id)
      assert apply(Mutare.IntegerGuardFixture, :parity, [2]) == :odd
      Selector.put(Selector.baseline())
    end

    test "lifts a default-arg function: defaults ride on the dispatcher, base takes full arity" do
      {defaulted, sites, _} =
        Mutare.Transform.transform_string_with_sites(
          "defmodule M do\n  def h(a, b \\\\ 1) when a > b, do: a\nend\n"
        )

      # The guard is lifted (it now gets guard/clause mutants it never had before)...
      assert defaulted =~ "__mutare_h_2_g1"
      assert Enum.any?(sites, &(&1.kind == :lifted))

      # ...the public dispatcher keeps the `\\` default (preserving the multi-arity
      # contract: `h/1` and `h/2` both still resolve)...
      assert defaulted =~ ~r/def h\(mutare_arg1, mutare_arg2 \\\\ /

      # ...and the lifted base function takes the full arity with `\\` stripped.
      assert defaulted =~ ~r/defp __mutare_h_2_g1\(mutare_active, a, b\)/
      refute defaulted =~ ~r/defp __mutare_h_2_g1\([^)]*\\\\/

      assert [{M, _}] = Mutare.Test.Compile.string(defaulted)
    end

    test "falls back to in-place (no lift) for operator names" do
      {operator, _, _} =
        Mutare.Transform.transform_string_with_sites(
          "defmodule M do\n  def a ~> b when b > 0, do: a\nend\n"
        )

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
      Enum.find(
        sites,
        &(&1.kind == :lifted and &1.original_form == :>= and &1.mutated_form == :>)
      )

    assert Report.diff(site, @source) ==
             "-  def classify(n) when n >= 0, do: :nonneg\n" <>
               "+  def classify(n) when n > 0, do: :nonneg"
  end

  test "report renders a clause-drop mutant as removed lines", %{sites: sites} do
    site = Enum.find(sites, &(&1.mutator == :clause_drop and &1.line == 3))

    assert Report.header(site) == "lift.ex:3  [clause_drop, lifted]  SURVIVED"
    assert Report.diff(site, @source) == "-  def classify(_), do: :neg"
  end

  describe "compiled metamutant with default arguments" do
    alias Mutare.DefaultArgFixture, as: D

    defp default_id(sites, fun) do
      site = Enum.find(sites, fun)
      assert site, "no matching default-arg site"
      site.id
    end

    test "baseline fills the optional positions left-to-right at every arity" do
      # arity 2: a, c given; b, d default. arity 3: a, b, c given; d default.
      assert D.f(0, 7) == {:zero, 10, 7, 20}
      assert D.f(0, 2, 7) == {:zero, 2, 7, 20}
      assert D.f(0, 2, 7, 9) == {:zero, 2, 7, 9}
      assert D.f(9, 7) == {:big, 9, 10, 7, 20}
      assert D.f(3, 7) == {:other, 3, 10, 7, 20}
    end

    test "a default-value mutant changes only the defaulted call path", %{default_sites: sites} do
      # `b \\ 10` → `0`: observable only when `b` is left to the (mutated) default.
      Selector.put(
        default_id(
          sites,
          &(&1.kind == :in_place and &1.original_code == "10" and &1.mutated_code == "0")
        )
      )

      # arity 2 omits b → the mutated default fires; arity 3 supplies b → unchanged.
      assert D.f(0, 7) == {:zero, 0, 7, 20}
      assert D.f(0, 2, 7) == {:zero, 2, 7, 20}
    end

    test "a head-literal mutant changes which clause matches", %{default_sites: sites} do
      # `f(0, …)`'s head literal `0` → `1`: `f(0, …)` no longer hits the :zero clause,
      # while `f(1, …)` now does — delivered by lifting through the dispatcher.
      Selector.put(
        default_id(
          sites,
          &(&1.kind == :lifted and &1.original_code == "0" and &1.mutated_code == "1")
        )
      )

      assert D.f(0, 7) == {:other, 0, 10, 7, 20}
      assert D.f(1, 7) == {:zero, 10, 7, 20}
    end

    test "a lifted guard mutant changes dispatch", %{default_sites: sites} do
      # `a > 5` → `a < 5`.
      Selector.put(
        default_id(
          sites,
          &(&1.kind == :lifted and &1.original_form == :> and &1.mutated_form == :<)
        )
      )

      assert D.f(9, 7) == {:other, 9, 10, 7, 20}
      assert D.f(3, 7) == {:big, 3, 10, 7, 20}
    end

    test "a clause drop sends inputs to a later clause", %{default_sites: sites} do
      # drop `def f(0, b, c, d)` (line 3); `f(0, …)` now falls through to the catch-all.
      Selector.put(default_id(sites, &(&1.mutator == :clause_drop and &1.line == 3)))

      assert D.f(0, 7) == {:other, 0, 10, 7, 20}
    end
  end
end
