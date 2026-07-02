defmodule Mutare.TransformBindingHoistTest do
  # Context routing for a condition that binds a variable escaping into the body:
  # cond-clause pruning and if/unless hoisting (the binding lifted so the decision can be
  # delivered). Split from transform_test.exs. `async: false` — runtime tests flip the
  # global selector.
  use ExUnit.Case, async: false

  alias Mutare.Site

  # Pin context-routing probes to the two operator-swap families (stable site counts).
  @probe [Mutare.Mutators.Arithmetic, Mutare.Mutators.Relational]

  describe "a condition that binds a variable escaping into the body" do
    # A binding made in an `if`/`unless`/`cond` condition (`(name = f()) != nil`)
    # *leaks* into the clause body. The in-place selector is a `case`, which would
    # scope that binding to one branch — leaving the body's reference unbound, a hard
    # compile error independent of the active mutant. So a node that is an *ancestor*
    # of the binding gets no in-place mutant, while binding-free siblings and the body
    # still mutate. (Regression: `mix mutare` on `Mutare.Transform.Aliases`.)
    @binding [
      Mutare.Mutators.Relational,
      Mutare.Mutators.Conditional,
      Mutare.Mutators.IfCondition,
      Mutare.Mutators.MapKeyword
    ]

    test "a cond clause's binding condition is left un-wrapped; siblings and the body still mutate" do
      source = """
      defmodule Bind do
        def f(opts, env) do
          cond do
            length(opts) > 0 -> env
            (name = Keyword.get(opts, :n)) != nil -> Map.put(env, name, 1)
            true -> env
          end
        end
      end
      """

      {meta, sites, _next_id} =
        Mutare.Transform.transform_string_with_sites(source, mutators: @binding)

      # The binding condition yields no site (any selector would trap `name`).
      refute Enum.any?(sites, &(&1.original_code =~ "name = Keyword"))
      # The binding-free sibling condition still mutates (Relational + Conditional).
      assert Enum.any?(sites, &(&1.original_code == "length(opts) > 0"))
      # The binding clause's body still mutates (MapKeyword put → put_new/…).
      assert Enum.any?(sites, &(&1.mutator == :map_keyword))
      # The metamutant compiles — the whole point.
      assert_compiles(meta)
    end

    test "an if condition with a nested binding is hoisted, not pruned (cond can't be)" do
      # Unlike `cond` (above), an `if`/`unless` condition is evaluated once and
      # unconditionally, so the binding is *hoisted* out and the now-binding-free
      # condition carries the decision (see the dedicated hoist describe below). The
      # decision diff still names the original condition.
      source = """
      defmodule BindIf do
        def f(opts, env) do
          if (name = Keyword.get(opts, :n)) != nil do
            Map.put(env, name, 1)
          else
            env
          end
        end
      end
      """

      {meta, sites, _next_id} =
        Mutare.Transform.transform_string_with_sites(source, mutators: @binding)

      assert Enum.filter(sites, &(&1.mutator == :if_condition))
             |> Enum.map(&{&1.original_code, &1.mutated_code}) ==
               [
                 {"(name = Keyword.get(opts, :n)) != nil", "true"},
                 {"(name = Keyword.get(opts, :n)) != nil", "false"}
               ]

      assert Enum.any?(sites, &(&1.mutator == :map_keyword))
      assert_compiles(meta)
    end

    test "a binding isolated inside a closure does not suppress the surrounding condition" do
      # The `fn` scopes `y`, so it never reaches the cond body — the surrounding
      # `Enum.any?(...)` condition is still a normal boolean decision and mutates.
      source = """
      defmodule BindClosure do
        def f(xs) do
          cond do
            Enum.any?(xs, fn x -> (y = abs(x)) > 0 end) -> :hit
            true -> :miss
          end
        end
      end
      """

      {meta, sites, _next_id} =
        Mutare.Transform.transform_string_with_sites(source,
          mutators: [Mutare.Mutators.IfCondition]
        )

      assert Enum.any?(sites, &(&1.mutator == :if_condition))
      assert_compiles(meta)
    end

    test "an if condition with a closure is a plain decision (the fn's binding is isolated)" do
      # A closure in an `if`/`unless` condition is common real code. Unlike the `cond`
      # above, an `if` condition runs the hoist analysis (`escaping_binding?`), which
      # must treat the `fn`'s internals as isolated — its `y` never escapes to the body
      # — so the condition stays a plain boolean decision (neither hoisted nor pruned)
      # and the metamutant compiles. (The `cond` path never reaches this clause; without
      # this case the if-hoist path's binding-isolating-form handling is untested.)
      source = """
      defmodule IfClosure do
        def f(xs) do
          if Enum.any?(xs, fn x -> (y = abs(x)) > 0 end) do
            :hit
          else
            :miss
          end
        end
      end
      """

      {meta, sites, _next_id} =
        Mutare.Transform.transform_string_with_sites(source,
          mutators: [Mutare.Mutators.IfCondition]
        )

      # The whole condition gets the IfCondition true/false pair — not hoisted, not pruned.
      assert Enum.map(sites, &{&1.mutator, &1.mutated_code}) ==
               [{:if_condition, "true"}, {:if_condition, "false"}]

      assert hd(sites).original_code == "Enum.any?(xs, fn x -> (y = abs(x)) > 0 end)"
      assert_compiles(meta)
    end
  end

  describe "if/unless condition hoisting (binding lifted so the decision can be delivered)" do
    alias Mutare.Selector

    test "a bare-variable binding is hoisted; the condition reads it and carries the decision" do
      source = """
      defmodule HoistBare do
        def f(opts) do
          if x = Keyword.get(opts, :n) do
            x
          else
            0
          end
        end
      end
      """

      {meta, sites, _} =
        Mutare.Transform.transform_string_with_sites(source,
          mutators: [Mutare.Mutators.IfCondition]
        )

      # The binding is lifted to a preceding statement; the decision selects on the bare var.
      assert meta =~ "x = Keyword.get(opts, :n)\n"

      assert Enum.map(sites, &{&1.original_code, &1.mutated_code}) ==
               [{"x = Keyword.get(opts, :n)", "true"}, {"x = Keyword.get(opts, :n)", "false"}]

      assert_compiles(meta)
    end

    test "a refutable pattern keeps MatchError semantics via a temp, and compiles" do
      source = """
      defmodule HoistRefutable do
        def f(opts) do
          if {:ok, v} = fetch(opts) do
            v
          else
            :none
          end
        end
        def fetch(o), do: o
      end
      """

      {meta, sites, _} =
        Mutare.Transform.transform_string_with_sites(source,
          mutators: [Mutare.Mutators.IfCondition]
        )

      # The match value is bound to a temp first, then the pattern re-matched against it
      # (so a non-match still raises MatchError exactly as the original `=` did); the
      # condition reads the temp. The decision diff still names the original condition.
      assert meta =~ "= fetch(opts)"
      assert meta =~ "{:ok, v} ="

      assert sites |> Enum.map(& &1.original_code) |> Enum.uniq() == ["{:ok, v} = fetch(opts)"]
      assert_compiles(meta)
    end

    test "multiple bare-variable spine bindings all hoist (distinct names, no temp)" do
      source = """
      defmodule HoistMulti do
        def f(a, b) do
          if (x = first(a)) != (y = first(b)) do
            {x, y}
          else
            :equal
          end
        end
        def first(z), do: hd(z)
      end
      """

      {meta, sites, _} =
        Mutare.Transform.transform_string_with_sites(source,
          mutators: [Mutare.Mutators.IfCondition]
        )

      # Both bindings lift to their own statements (operands of `!=`, both on the spine).
      assert meta =~ "x = first(a)"
      assert meta =~ "y = first(b)"

      assert Enum.map(sites, &{&1.original_code, &1.mutated_code}) ==
               [
                 {"(x = first(a)) != (y = first(b))", "true"},
                 {"(x = first(a)) != (y = first(b))", "false"}
               ]

      assert_compiles(meta)
    end

    test "the hoisted EXPR still mutates in its lifted statement" do
      source = """
      defmodule HoistExpr do
        def f(xs) do
          if (s = Enum.sort(xs)) != [] do
            s
          else
            []
          end
        end
      end
      """

      {_meta, sites, _} =
        Mutare.Transform.transform_string_with_sites(source,
          mutators: [Mutare.Mutators.IfCondition, Mutare.Mutators.CallRemoval]
        )

      # CallRemoval reaches Enum.sort in the lifted `s = Enum.sort(xs)` statement …
      assert Enum.any?(
               sites,
               &(&1.mutator == :call_removal and &1.original_code == "Enum.sort(xs)")
             )

      # … and the decision is still delivered on the (binding-free) condition.
      assert Enum.any?(sites, &(&1.mutator == :if_condition))
    end

    test "a binding under a short-circuit right operand is left in place (not hoisted)" do
      # `ok?` short-circuits, so `x = …` runs conditionally; hoisting it would change
      # *when* it evaluates. So the off-spine case falls back to the prune path — the
      # binding stays inside the condition. (Bound-but-unused in the body, so the source
      # itself is valid Elixir: a body that *read* `x` would be an unsafe-variable error.)
      source = """
      defmodule HoistOffspine do
        def f(opts) do
          if ok?(opts) and (x = Keyword.get(opts, :n)) != nil do
            :yes
          else
            :no
          end
        end
        def ok?(_), do: true
      end
      """

      {meta, sites, _} =
        Mutare.Transform.transform_string_with_sites(source,
          mutators: [Mutare.Mutators.IfCondition]
        )

      # Not hoisted: the binding stays inline in the condition (no lifted `x = …` stmt).
      assert meta =~ "(x = Keyword.get(opts, :n))"
      assert Enum.filter(sites, &(&1.mutator == :if_condition)) == []
      assert_compiles(meta)
    end

    test "a binding preceded by a side-effecting sibling is not hoisted (no reorder)" do
      # The binding is on the spine, but `check(state)` is evaluated *before* it in the
      # original. Hoisting `x = compute()` to before the `if` would move `compute()`
      # ahead of `check(state)`, changing the order of side effects on the baseline
      # (mutant 0 must match the original program). So this falls back to the sound prune
      # path: the binding stays inline and no decision mutant is delivered.
      source = """
      defmodule HoistReorder do
        def f(state) do
          if check(state) == (x = compute()) do
            x
          else
            :no
          end
        end
        def check(s), do: s
        def compute, do: 1
      end
      """

      {meta, sites, _} =
        Mutare.Transform.transform_string_with_sites(source,
          mutators: [Mutare.Mutators.IfCondition]
        )

      # Not hoisted: the binding stays inline (no lifted `x = …` statement, no selector).
      assert meta =~ "(x = compute())"
      refute meta =~ "persistent_term.get(:mutare_active"
      assert Enum.filter(sites, &(&1.mutator == :if_condition)) == []
      assert_compiles(meta)
    end

    test "runtime: the baseline preserves the original side-effect order" do
      # The regression for the reorder veto: a hoist would have evaluated the binding's
      # RHS before the LHS sibling. The baseline (mutant 0) must observe the *original*
      # order, so the side-effect log is `[:lhs, :binding]`, not `[:binding, :lhs]`.
      source = """
      defmodule Mutare.HoistOrderFixture do
        def run do
          if log(:lhs) == (x = log(:binding)) do
            x
          else
            :no
          end
        end

        def log(tag) do
          Process.put(:order, [tag | Process.get(:order, [])])
          tag
        end
      end
      """

      {meta, _sites, _} =
        Mutare.Transform.transform_string_with_sites(source,
          mutators: [Mutare.Mutators.IfCondition]
        )

      [{mod, _}] = assert_compiles(meta)

      Selector.put(Selector.baseline())
      Process.put(:order, [])
      mod.run()
      assert Enum.reverse(Process.get(:order)) == [:lhs, :binding]
    after
      Selector.put(Selector.baseline())
    end

    test "runtime: the hoisted binding stays bound while the decision is forced" do
      source = """
      defmodule Mutare.HoistRuntimeFixture do
        def classify(opts) do
          if v = Keyword.get(opts, :v) do
            {:has, v}
          else
            :none
          end
        end
      end
      """

      {meta, sites, _} =
        Mutare.Transform.transform_string_with_sites(source,
          mutators: [Mutare.Mutators.IfCondition]
        )

      [{mod, _}] = assert_compiles(meta)

      true_id = Enum.find(sites, &(&1.mutated_code == "true")).id
      false_id = Enum.find(sites, &(&1.mutated_code == "false")).id

      Selector.put(Selector.baseline())
      assert mod.classify(v: 7) == {:has, 7}
      assert mod.classify([]) == :none

      # Forcing the decision true always takes the then-branch — and `v` is still bound
      # (the hoist made it a real preceding statement), so there is no unbound-variable
      # crash; it is simply `nil` here.
      Selector.put(true_id)
      assert mod.classify([]) == {:has, nil}

      Selector.put(false_id)
      assert mod.classify(v: 7) == :none
    after
      Selector.put(Selector.baseline())
    end

    test "runtime: the binding leaks when the if is a match RHS (not a statement)" do
      # The hoist replaces the `if` with a `__block__`. When the `if` is the RHS of a
      # match (an expression position, not a bare statement), the block must still
      # evaluate to the `if`'s value *and* leak the condition's binding — a `__block__`
      # introduces no scope, so `x` is read after the match exactly as the source's was.
      source = """
      defmodule Mutare.HoistExprPosFixture do
        def f(opts) do
          y = if x = Keyword.get(opts, :n), do: x * 2, else: 0
          {y, x}
        end
      end
      """

      {meta, _sites, _} =
        Mutare.Transform.transform_string_with_sites(source,
          mutators: [Mutare.Mutators.IfCondition]
        )

      [{mod, _}] = assert_compiles(meta)

      Selector.put(Selector.baseline())
      assert mod.f(n: 5) == {10, 5}
      assert mod.f([]) == {0, nil}
    after
      Selector.put(Selector.baseline())
    end

    test "runtime: the binding leaks when the if is a call argument" do
      # Same as above for the other non-statement position: the `if` is an argument to
      # `wrap/1`, and `x` is read after the call. The block leaks `x` past the call.
      source = """
      defmodule Mutare.HoistArgPosFixture do
        def f(opts) do
          wrap(if x = Keyword.get(opts, :n), do: x, else: 0)
          x
        end
        def wrap(v), do: v
      end
      """

      {meta, _sites, _} =
        Mutare.Transform.transform_string_with_sites(source,
          mutators: [Mutare.Mutators.IfCondition]
        )

      [{mod, _}] = assert_compiles(meta)

      Selector.put(Selector.baseline())
      assert mod.f(n: 5) == 5
      assert mod.f([]) == nil
    after
      Selector.put(Selector.baseline())
    end
  end

  describe "if/unless hoisting — decision gate and spine-walk edge cases" do
    alias Mutare.Selector

    test "a binding condition is hoisted only when IfCondition is enabled" do
      # `hoist_if?/2` gates the whole hoist on IfCondition being on (it owns the delivered
      # decision). With IfCondition disabled the condition is left on the prune path —
      # inline, no lifted statement, no decision selector.
      source = """
      defmodule HoistGate do
        def f(o) do
          if x = get(o) do
            x
          else
            0
          end
        end
        def get(o), do: o
      end
      """

      {meta, sites, _} =
        Mutare.Transform.transform_string_with_sites(source,
          mutators: [Mutare.Mutators.CallRemoval]
        )

      assert meta =~ "if x = get(o)"
      refute meta =~ ":persistent_term.get(#{inspect(Selector.key())}"
      assert Enum.filter(sites, &(&1.mutator == :if_condition)) == []
    end

    test "two refutable spine bindings are not hoisted (kept on the prune path)" do
      # `refutable_spine_count/1 <= 1` caps the hoist at a single refutable binding (each
      # needs its own temp). Two refutable spine bindings fall back to the prune path, so no
      # decision is delivered.
      source = """
      defmodule HoistTwoRef do
        def f(a, b) do
          if ({:ok, x} = pa(a)) != ({:ok, y} = pb(b)) do
            x - y
          else
            0
          end
        end
        def pa(a), do: a
        def pb(b), do: b
      end
      """

      {meta, sites, _} =
        Mutare.Transform.transform_string_with_sites(source,
          mutators: [Mutare.Mutators.IfCondition]
        )

      assert Enum.filter(sites, &(&1.mutator == :if_condition)) == []
      # the bindings stay inline in the condition (no lifted `{:ok, x} = pa(a)` statement)
      assert meta =~ "({:ok, x} = pa(a))"
      assert_compiles(meta)
    end

    test "a bare binding nested in a call argument on the spine is hoisted" do
      # The spine walk recurses into call arguments, so a binding buried in one is still
      # lifted out (and the now-binding-free condition carries the decision).
      source = """
      defmodule HoistInCall do
        def f(o) do
          if wrap(x = compute(o)) do
            x
          else
            0
          end
        end
        def wrap(v), do: v
        def compute(o), do: o
      end
      """

      {meta, sites, _} =
        Mutare.Transform.transform_string_with_sites(source,
          mutators: [Mutare.Mutators.IfCondition]
        )

      assert meta =~ "x = compute(o)"
      assert Enum.any?(sites, &(&1.mutator == :if_condition))
      assert_compiles(meta)
    end

    test "a bare binding nested in a tuple on the spine is hoisted" do
      # The spine walk recurses into 2-tuples too.
      source = """
      defmodule HoistInTuple do
        def f(o) do
          if {x = first(o), :tag} == {1, :tag} do
            x
          else
            0
          end
        end
        def first(o), do: o
      end
      """

      {meta, sites, _} =
        Mutare.Transform.transform_string_with_sites(source,
          mutators: [Mutare.Mutators.IfCondition]
        )

      assert meta =~ "x = first(o)"
      assert Enum.any?(sites, &(&1.mutator == :if_condition))
      assert_compiles(meta)
    end

    test "runtime: a binding hoisted out of a call argument stays bound and the decision flips" do
      source = """
      defmodule Mutare.HoistInCallRuntime do
        def classify(o) do
          if wrap(v = lookup(o)) do
            {:has, v}
          else
            :none
          end
        end
        def wrap(x), do: x
        def lookup(o), do: o
      end
      """

      {meta, sites, _} =
        Mutare.Transform.transform_string_with_sites(source,
          mutators: [Mutare.Mutators.IfCondition]
        )

      [{mod, _}] = assert_compiles(meta)

      true_id = Enum.find(sites, &(&1.mutated_code == "true")).id
      false_id = Enum.find(sites, &(&1.mutated_code == "false")).id

      Selector.put(Selector.baseline())
      assert mod.classify(7) == {:has, 7}
      assert mod.classify(nil) == :none

      Selector.put(true_id)
      assert mod.classify(nil) == {:has, nil}

      Selector.put(false_id)
      assert mod.classify(7) == :none
    after
      Selector.put(Selector.baseline())
    end

    test "a bare binding under a short-circuit LEFT operand (on the spine) is hoisted" do
      # `x = compute(o)` is the left operand of `&&`, so it is unconditionally evaluated and on
      # the spine; the spine walk recurses through the short-circuit's left side.
      source = """
      defmodule HoistShortCircuit do
        def f(o) do
          if (x = compute(o)) && positive?(x) do
            x
          else
            0
          end
        end
        def compute(o), do: o
        def positive?(n), do: n > 0
      end
      """

      {meta, sites, _} =
        Mutare.Transform.transform_string_with_sites(source,
          mutators: [Mutare.Mutators.IfCondition]
        )

      assert meta =~ "x = compute(o)"
      assert Enum.any?(sites, &(&1.mutator == :if_condition))
      assert_compiles(meta)
    end

    test "a bare binding inside a list literal on the spine is hoisted" do
      # The spine walk recurses into list literals too.
      source = """
      defmodule HoistInList do
        def f(o) do
          if [x = first(o), 1] == [2, 1] do
            x
          else
            0
          end
        end
        def first(o), do: o
      end
      """

      {meta, sites, _} =
        Mutare.Transform.transform_string_with_sites(source,
          mutators: [Mutare.Mutators.IfCondition]
        )

      assert meta =~ "x = first(o)"
      assert Enum.any?(sites, &(&1.mutator == :if_condition))
      assert_compiles(meta)
    end

    test "a pure literal preceding a spine binding does not veto the hoist" do
      # `spine_reorders?/1` only vetoes when an *impure* (`:other`) expression is evaluated
      # before the binding. A literal is `:pure`, so `:ok == (x = compute(o))` still hoists —
      # this pins `eval_steps/1`'s `:pure` classification (misreading the literal as `:other`
      # would spuriously veto, dropping the decision via the prune path).
      source = """
      defmodule HoistPureBefore do
        def f(o) do
          if :ok == (x = compute(o)) do
            x
          else
            :no
          end
        end
        def compute(o), do: o
      end
      """

      {meta, sites, _} =
        Mutare.Transform.transform_string_with_sites(source,
          mutators: [Mutare.Mutators.IfCondition]
        )

      assert meta =~ "x = compute(o)\n"
      assert Enum.any?(sites, &(&1.mutator == :if_condition))
      assert_compiles(meta)
    end
  end

  test "with/else blocks are walked without corrupting the metamutant" do
    source = """
    defmodule W do
      def f(m) do
        with {:ok, n} <- m do
          n + 1
        else
          _ -> 0
        end
      end
    end
    """

    {meta, sites, _next_id} =
      Mutare.Transform.transform_string_with_sites(source, mutators: @probe)

    assert [%Site{mutator: :arithmetic, original_form: :+}] = sites
    assert {:ok, _} = Code.string_to_quoted(meta)
  end

  defp assert_compiles(meta) do
    assert [_ | _] = Mutare.Test.Compile.string(meta)
  end
end
