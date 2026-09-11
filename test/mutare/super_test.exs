defmodule Mutare.SuperTest do
  @moduledoc """
  `super` in a lifted function. Lifting relocates a clause body into a private
  `defp`, where `super` (legal only in the overriding function) would not compile.
  `Mutare.Transform.Super` keeps the rewrite local: the public dispatcher (still the
  overriding function) binds a forwarding closure `<super_var> = &super/arity` and
  threads it to the base, where each `super(args)` becomes `<super_var>.(args)`.

  Proven end to end — one compile, runtime mutant switching — against a real
  `defoverridable` base, plus the structural and edge-case guarantees.
  """
  # persistent_term is global; switch the active mutant serially.
  use ExUnit.Case, async: false
  import Mutare.Test.Metamutant

  alias Mutare.{Selector, Transform.Super}

  # A real base providing overridable callbacks the transformed children `use`. It
  # must be a compiled module so `Mutare.Test.Compile.string/1` can expand `use` against it.
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

    {meta, sites, _next} = Mutare.Transform.transform_string_with_sites(source, opts)
    [{module, _binary}] = Mutare.Test.Compile.string(meta)
    {meta, sites, module}
  end

  describe "structure" do
    test "a lifted body's super is forwarded through a dispatcher closure" do
      # Pinned mutator set: this test asserts the *exact* super-forwarding count, and
      # OperandSwap would mutate the `<>` operators wrapping `super(name)`, duplicating
      # it into selector branches (correctly forwarded, but perturbing the raw count).
      # clause_drop is what lifts the group here (the guard holds no relational operator), so it
      # must be in the pinned set; it forwards super like any other lifted mutant.
      {meta, _sites, _mod} =
        transform(
          """
            def greet(name) when is_binary(name), do: "[" <> super(name) <> "]"
            def greet(_), do: super("anon")
          """,
          [Mutare.Mutators.Relational, Mutare.Mutators.ClauseDrop]
        )

      # The dispatcher (the overriding function) binds the forwarding closure...
      assert meta =~ ~r{mutare_super = &super/1}
      # ...and threads it to the base as the second argument.
      assert meta =~ ~r/#{lifted_pattern(:greet, 1)}\(mutare_active, mutare_super,/
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
      assert meta =~ ~r/#{lifted_pattern(:classify, 1)}\(mutare_active, n\)/
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
      assert meta =~ ~r{mutare_super = &super/2}

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

      assert meta =~ ~r/#{lifted_pattern(:tag, 1)}\(mutare_active, _, other\)/
      assert meta =~ ~r/#{lifted_pattern(:tag, 1)}\(mutare_active, mutare_super, :wrap\)/

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
      assert meta =~ ~r/#{lifted_pattern(:tag, 1)}\(mutare_active, _, _mutare_super\)/
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
      assert meta =~ ~r{mutare_super_0 = &super/1}
      assert [{_module, _binary}] = Mutare.Test.Compile.string(meta)
    end

    test "a `&super/n` capture is rewritten to the bound closure variable" do
      # `super` captured (not called) at its only legal arity. The lifted base can't
      # host `&super/2`, but the dispatcher's closure already *is* that capture, so the
      # capture rewrites to the bare `mutare_super`. Both clauses only capture (never a
      # direct `super(...)`), so this also proves capture-only detection builds a closure.
      {meta, _sites, mod} =
        transform("""
          def combine(a, b) when is_integer(a), do: apply(&super/2, [a, b])
          def combine(a, b), do: apply(&super/2, [b, a])
        """)

      # A closure is bound (the group is detected as super-using despite no call)...
      assert meta =~ ~r{mutare_super = &super/2}
      # ...the capture became the bare variable (the `[a, b]` arg is itself wrapped in a
      # List/literal selector, so match only up to the variable)...
      assert meta =~ ~r{apply\(\s*mutare_super,}
      # ...and no base clause keeps a `&super/` capture.
      refute Regex.match?(~r{defp __mutare_combine.*?&super/}s, meta)

      assert mod.combine(1, 2) == {:base, 1, 2}
      assert mod.combine(:x, :y) == {:base, :y, :x}
    end

    test "a super evaluated while building a quote is rewritten, not pruned as data" do
      # `unquote(super(x))` and `bind_quoted: [r: super(...)]` both *run* `super` while
      # the quote is constructed, so it is live — pruning the whole quote would leave a
      # raw `super` in the relocated base and the metamutant would not compile. The two
      # `tag` clauses cover the unquote form (lifted via the guard); `combine` the
      # bind_quoted option form.
      {meta, _sites, mod} =
        transform("""
          def tag(x) when is_integer(x), do: quote(do: unquote(super(x)))
          def tag(x), do: quote(do: unquote(super(x)))

          def combine(a, b) when is_integer(a) do
            quote(bind_quoted: [r: super(a, b)], do: r)
          end

          def combine(a, b), do: super(b, a)
        """)

      # Both groups bound a closure and forward the live super — no raw `super(` left in
      # any relocated base clause.
      assert meta =~ ~r{mutare_super = &super/1}
      assert meta =~ ~r{mutare_super = &super/2}
      refute Regex.match?(~r/defp __mutare_(tag|combine).*?\bsuper\(/s, meta)

      # Runtime: `unquote(super(5))` evaluates super (`{:base, 5}`) and injects it.
      assert mod.tag(5) == {:base, 5}
      # `bind_quoted: [r: super(1, 2)]` binds the *evaluated* super (`{:base, 1, 2}`)
      # into the quoted body — so the returned AST embeds that value.
      assert Macro.to_string(mod.combine(1, 2)) =~ "{:base, 1, 2}"
    end

    test "a genuinely-quoted super (not unquoted) stays data even beside a live one" do
      # Mixed clause group: clause 1 has a live `unquote(super(x))`, clause 2 a quoted
      # `super(x)` (data). The closure is bound (clause 1), but clause 2's super must
      # ride along as a real `super` AST node, untouched.
      {_meta, _sites, mod} =
        transform("""
          def tag(x) when is_integer(x), do: quote(do: unquote(super(x)))
          def tag(x), do: quote(do: super(x))
        """)

      assert mod.tag(5) == {:base, 5}
      assert {:super, _, [{:x, _, _}]} = mod.tag(:a)
    end
  end

  describe "Super module" do
    test "in_clauses?/1 detects a body super but ignores a quoted one" do
      assert Super.in_clauses?(clauses("def f(x), do: super(x)"))
      assert Super.in_clauses?(clauses("def f(x) do\n  g = fn -> super(x) end\n  g.()\nend"))
      # A capture-only body (never a direct call) still counts as super-using.
      assert Super.in_clauses?(clauses("def f(x), do: apply(&super/1, [x])"))
      # A super *evaluated* while building a quote is live, so it is detected...
      assert Super.in_clauses?(clauses("def f(x), do: quote(do: unquote(super(x)))"))
      assert Super.in_clauses?(clauses("def f(x), do: quote(bind_quoted: [y: super(x)], do: y)"))
      # ...but a plain quoted super is data, and a doubly-quoted unquote is still data.
      refute Super.in_clauses?(clauses("def f(x), do: quote(do: super(x))"))
      refute Super.in_clauses?(clauses("def f(x), do: quote(do: quote(do: unquote(super(x))))"))
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

    test "rewrite/2 rewrites a `&super/n` capture to the bare closure variable" do
      [{:def, _, [_head | body]}] = clauses("def f(a, b), do: apply(&super/2, [a, b])")
      {rewritten, true} = Super.rewrite(body, :sup)
      rendered = Macro.to_string(rewritten)
      # The capture collapses to the variable holding the closure — not `&sup/2`,
      # which would (illegally) capture a local function rather than read the variable.
      assert rendered =~ "apply(sup, [a, b])"
      refute rendered =~ "super"
      refute rendered =~ ~r{&sup/}
    end

    test "rewrite/2 rewrites a live quoted super but leaves a deeper-quoted one as data" do
      # `unquote(super(x))` is live (escapes the quote) → rewritten; a `super` nested in
      # an inner quote (one unquote can't reach back out of two quotes) stays data.
      [{:def, _, [_head | body]}] =
        clauses("""
        def f(x) do
          quote do
            unquote(super(x))
            quote(do: unquote(super(x)))
          end
        end
        """)

      {rewritten, true} = Super.rewrite(body, :sup)
      rendered = Macro.to_string(rewritten)
      # Exactly one super became the closure call; one quoted super survives.
      assert length(String.split(rendered, "sup.(x)")) - 1 == 1
      assert length(String.split(rendered, "super(x)")) - 1 == 1
    end

    test "in_clauses?/1 frees a super only when both unquotes escape both quotes" do
      # Two nested quotes put the super at level 2; two stacked unquotes
      # (`unquote(unquote(super(x)))`) step the level back down to 0, so the super runs
      # at construction and is live. This pins that each unquote lowers the level by
      # *exactly one* (`level - 1`): with `1 - level` the second unquote would land at
      # -1 instead of 0 and the super would wrongly read as data.
      assert Super.in_clauses?(
               clauses("def f(x), do: quote(do: quote(do: unquote(unquote(super(x)))))")
             )

      # Contrast: a *single* unquote can only escape one of the two quotes, so the
      # super stays one level deep — data, not detected.
      refute Super.in_clauses?(clauses("def f(x), do: quote(do: quote(do: unquote(super(x))))"))
    end

    test "rewrite/2 descends a super's own arguments, rewriting a nested super" do
      # `super(super(x))`: the inner super is an *argument* of the outer one and must
      # also be forwarded. The outer call's args are descended at level 0 (still live),
      # so the inner super collapses to the closure too — shifting that level to ±1
      # would leave the inner `super(` raw.
      [{:def, _, [_head | body]}] = clauses("def f(x), do: super(super(x))")
      {rewritten, true} = Super.rewrite(body, :sup)
      rendered = Macro.to_string(rewritten)
      assert rendered =~ "sup.(sup.(x))"
      refute rendered =~ "super("
    end

    test "in_clauses?/1 sees a super freed by unquote_splicing, not only unquote" do
      # `unquote_splicing` escapes a quote level exactly like `unquote` (it splices an
      # *evaluated* list into the surrounding one), so a super inside it runs at
      # construction and is live. The escape set must hold both atoms — drop
      # `:unquote_splicing` and this super wrongly reads as quoted data.
      assert Super.in_clauses?(clauses("def f(x), do: quote(do: [unquote_splicing(super(x))])"))
    end

    test "in_clauses?/1 ignores a super wrapped in a quoted call (still data)" do
      # `quote(do: foo(super(x)))`: the super is a quoted argument of `foo`, never run,
      # so it is data. The unquote handler must match `:unquote`/`:unquote_splicing`
      # *specifically* — not any single-argument call — or it would wrongly free this
      # super by descending one level into it.
      refute Super.in_clauses?(clauses("def f(x), do: quote(do: foo(super(x)))"))
    end

    test "in_clauses?/1 treats an unquote at level 0 as a plain call, reaching its super" do
      # An `unquote` outside any quote (level 0) has nothing to escape, so it is just a
      # call: the walk descends into it and finds the live super. The `level > 0` guard
      # keeps the escape-one-level behaviour exclusive to *inside* a quote — without it
      # the level-0 unquote would descend to -1 and miss the super. (Not compilable
      # source, but the AST contract the clause's own comment promises.)
      assert Super.in_clauses?(clauses("def f(x), do: unquote(super(x))"))
    end

    test "in_clauses?/1 handles a variable named `quote` (not a quote call)" do
      # `quote` is a legal variable name; as a *variable* its node is `{:quote, _, ctx}`
      # with an atom context — not the keyword-list args of a `quote` *call*. The
      # `is_list(args)` guard keeps the quote handler off it (it would otherwise try to
      # walk a nil arg list and crash), so the surrounding super is still detected.
      assert Super.in_clauses?(clauses("def f(quote), do: super(quote)"))
    end

    test "a non-def-shaped clause is not a super body (the body_has_super? fallback)" do
      refute Super.in_clauses?([:not_a_clause])
      refute Super.in_clauses?([])
    end
  end

  defp clauses(source), do: [Code.string_to_quoted!(source)]
end
