defmodule Mutare.SuperTest do
  @moduledoc """
  `super` in a lifted function. Lifting relocates a clause body into a private
  `defp`, where `super` (legal only in the overriding function) would not compile.
  `Mutare.Transform.Super` keeps the rewrite local: the public dispatcher (still the
  overriding function) binds a forwarding closure `<super_var> = fn … -> super(…) end`
  and threads it to the base, where each `super(args)` becomes `<super_var>.(args)`.

  Proven end to end — one compile, runtime mutant switching — against a real
  `defoverridable` base, plus the structural and edge-case guarantees.
  """
  # persistent_term is global; switch the active mutant serially.
  use ExUnit.Case, async: false

  alias Mutare.{Selector, Transform.Super}

  # A real base providing overridable callbacks the transformed children `use`. It
  # must be a compiled module so `Code.compile_string/1` can expand `use` against it.
  defmodule Base do
    @moduledoc false
    defmacro __using__(_) do
      quote do
        def greet(name), do: "base:" <> name
        def tag(x), do: {:base, x}
        def combine(a, b), do: {:base, a, b}
        defoverridable greet: 1, tag: 1, combine: 2
      end
    end
  end

  @base_mod inspect(__MODULE__.Base)

  setup do
    Selector.put(Selector.baseline())
    on_exit(fn -> Selector.put(Selector.baseline()) end)
    :ok
  end

  defp transform(body, mutators \\ nil) do
    source = """
    defmodule #{inspect(__MODULE__)}.Child do
      use #{@base_mod}

    #{body}
    end
    """

    opts = [file: "child.ex"]
    opts = if mutators, do: Keyword.put(opts, :mutators, mutators), else: opts

    {meta, sites, _next} = Mutare.transform_string(source, opts)
    [{module, _binary}] = Code.compile_string(meta)
    {meta, sites, module}
  end

  describe "structure" do
    test "a lifted body's super is forwarded through a dispatcher closure" do
      # Pinned mutator set: this test asserts the *exact* super-forwarding count, and
      # OperandSwap would mutate the `<>` operators wrapping `super(name)`, duplicating
      # it into selector branches (correctly forwarded, but perturbing the raw count).
      # clause_drop (structural, always on) still lifts the group and forwards super.
      {meta, _sites, _mod} =
        transform(
          """
            def greet(name) when is_binary(name), do: "[" <> super(name) <> "]"
            def greet(_), do: super("anon")
          """,
          [Mutare.Mutators.Relational]
        )

      # The dispatcher (the overriding function) binds the forwarding closure...
      assert meta =~ ~r/mutare_super = fn mutare_arg1 -> super\(mutare_arg1\) end/
      # ...and threads it to the base as the second argument.
      assert meta =~ ~r/__mutare_greet_1_g\d+\(mutare_active, mutare_super,/
      # The relocated base clauses call super *through* the closure, never directly —
      # one forwarded call per clause.
      assert meta =~ "mutare_super.(name)"
      assert length(String.split(meta, "mutare_super.(")) - 1 == 2
      # No base clause keeps a bare `super(` — every one was rewritten to the closure.
      refute Regex.match?(~r/defp __mutare_greet.*?\bsuper\(/s, meta)
    end

    test "a super-free lifted group emits no closure (common path unchanged)" do
      {meta, _sites, _mod} =
        transform("""
          def classify(n) when n >= 0, do: :nonneg
          def classify(_), do: :neg
        """)

      refute meta =~ "mutare_super"
      assert meta =~ ~r/__mutare_classify_1_g\d+\(mutare_active, n\)/
    end
  end

  describe "runtime" do
    test "every mutant of a lifted super function still forwards super" do
      {_meta, sites, mod} =
        transform("""
          def greet(name) when is_binary(name), do: "[" <> super(name) <> "]"
          def greet(_), do: super("anon")
        """)

      # Baseline: super resolves to the overridden Base.greet/1.
      assert mod.greet("bob") == "[base:bob]"
      assert mod.greet(:x) == "base:anon"

      # Under every single mutant the call still runs — super is forwarded in each
      # lifted clause (a missed clause would raise about an undefined super).
      for site <- sites do
        Selector.put(site.id)

        assert is_binary(mod.greet("bob")),
               "greet/1 crashed under mutant #{site.id} (#{site.mutator})"
      end
    end

    test "a clause-drop routing to a sibling clause forwards that clause's super" do
      {_meta, sites, mod} =
        transform("""
          def greet(name) when is_binary(name), do: "[" <> super(name) <> "]"
          def greet(_), do: super("anon")
        """)

      drop = Enum.find(sites, &(&1.mutator == :clause_drop and &1.line == 4))
      assert drop, "expected a clause-drop on the guarded clause"

      Selector.put(drop.id)
      # The binary clause is dropped, so greet("bob") falls to `super("anon")`.
      assert mod.greet("bob") == "base:anon"
    end
  end

  describe "edge cases" do
    test "default arguments: the closure forwards at super's only legal arity" do
      {meta, _sites, mod} =
        transform("""
          def combine(a, b \\\\ 99) when a > 0, do: super(a, b)
          def combine(a, b), do: super(b, a)
        """)

      # super's only legal arity is the full param count (2), so the closure is /2
      # and rides on the dispatcher; the default stays on the public head.
      assert meta =~
               ~r/mutare_super = fn mutare_arg1, mutare_arg2 -> super\(mutare_arg1, mutare_arg2\) end/

      assert mod.combine(1) == {:base, 1, 99}
      assert mod.combine(1, 2) == {:base, 1, 2}
      assert mod.combine(-1, 2) == {:base, 2, -1}
    end

    test "a super only inside quote is data, not rewritten, and adds no closure" do
      {meta, _sites, mod} =
        transform("""
          def tag(:keep), do: quote(do: super(:keep))
          def tag(x), do: x
        """)

      # The group lifts (two clauses + a head literal) but uses no live super: the
      # only `super` is quoted AST, so no closure is bound and it is left untouched.
      refute meta =~ "mutare_super"
      assert meta =~ "super(:keep)"

      # And the quoted super is preserved as a real `super` AST node at runtime —
      # not rewritten to a `<var>.()` call.
      assert {:super, _, [:keep]} = mod.tag(:keep)
    end

    test "an unused closure parameter on a super-free sibling clause is a bare `_`" do
      # One clause uses super, the other does not. Both base clauses share the
      # closure parameter (one base arity), so the super-free one must ignore it — a
      # bare `_` — or warn; the metamutant must compile warnings-clean.
      {meta, _sites, mod} =
        transform("""
          def tag(:wrap), do: {:wrapped, super(:wrap)}
          def tag(other), do: {:plain, other}
        """)

      assert meta =~ ~r/__mutare_tag_1_g\d+\(mutare_active, _, other\)/
      assert meta =~ ~r/__mutare_tag_1_g\d+\(mutare_active, mutare_super, :wrap\)/

      assert mod.tag(:wrap) == {:wrapped, {:base, :wrap}}
      assert mod.tag(:other) == {:plain, :other}
    end

    test "a super-free sibling clause already binding `_mutare_super` is not duplicated" do
      # The unused closure parameter must be a bare `_`, not `_<super_var>`: a salted
      # `_mutare_super` here would *duplicate* the source's own `_mutare_super` head
      # variable, warning *and* turning the head into an equality match (the closure
      # would have to equal the argument), so baseline dispatch raises
      # FunctionClauseError. `super_var` stays `mutare_super` (the source uses only the
      # underscore form), so the canonical clash is reachable.
      {meta, _sites, mod} =
        transform("""
          def tag(:wrap), do: {:wrapped, super(:wrap)}
          def tag(_mutare_super), do: {:plain, _mutare_super}
        """)

      # The super-free clause's head carries the bare `_` and its own `_mutare_super`,
      # not two `_mutare_super`.
      assert meta =~ ~r/__mutare_tag_1_g\d+\(mutare_active, _, _mutare_super\)/
      refute meta =~ ~r/mutare_active, _mutare_super, _mutare_super/

      # Baseline dispatch must not raise: with the bug the duplicated `_mutare_super`
      # makes the head an equality match (closure == arg), so this clause never matches.
      assert mod.tag(:wrap) == {:wrapped, {:base, :wrap}}
      assert mod.tag(:other) == {:plain, :other}
    end

    test "salts the closure variable when the source already uses `mutare_super`" do
      {meta, _sites, _mod} =
        transform("""
          def greet(name) when is_binary(name) do
            mutare_super = name
            "[" <> super(mutare_super) <> "]"
          end

          def greet(_), do: super("anon")
        """)

      # The generated closure variable must dodge the source's own `mutare_super`.
      assert meta =~ ~r/mutare_super_0 = fn/
      assert [{_module, _binary}] = Code.compile_string(meta)
    end
  end

  describe "Super module" do
    test "in_clauses?/1 detects a body super but ignores a quoted one" do
      assert Super.in_clauses?(clauses("def f(x), do: super(x)"))
      assert Super.in_clauses?(clauses("def f(x) do\n  g = fn -> super(x) end\n  g.()\nend"))
      refute Super.in_clauses?(clauses("def f(x), do: quote(do: super(x))"))
      refute Super.in_clauses?(clauses("def f(x), do: x"))
    end

    test "rewrite/2 reports found? and replaces only live supers" do
      [{:def, _, [_head | body]}] = clauses("def f(x), do: {super(x), x}")
      {rewritten, true} = Super.rewrite(body, :sup)
      assert Macro.to_string(rewritten) =~ "sup.(x)"
      refute Macro.to_string(rewritten) =~ "super("

      [{:def, _, [_head | quoted]}] = clauses("def f(x), do: quote(do: super(x))")
      {unchanged, false} = Super.rewrite(quoted, :sup)
      assert Macro.to_string(unchanged) =~ "super(x)"
    end
  end

  defp clauses(source), do: [Code.string_to_quoted!(source)]
end
