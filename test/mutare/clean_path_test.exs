defmodule Mutare.Transform.CleanPathTest do
  use ExUnit.Case, async: true

  alias Mutare.Transform.{CleanPath, ClauseAST, FunctionPlan, Resolve}

  defmodule CallsFixture do
    def runtime(value), do: value
    defmacro caller(value), do: {__CALLER__.function, value}

    defmacro left + right do
      quote do: {unquote(Macro.escape(__CALLER__.function)), unquote(left), unquote(right)}
    end

    # This fixture deliberately defines a replacement for Kernel.if/2.
    # credo:disable-for-next-line Credo.Check.Readability.ParenthesesInCondition
    defmacro if(value, options) do
      quote do: {unquote(Macro.escape(__CALLER__.function)), unquote(value), unquote(options)}
    end
  end

  test "ordinary recursive clauses, guards, tuples, and maps may use a clean copy" do
    assert eligible?("""
           def f(0, state), do: state
           def f(n, {x, y}) when is_integer(n) and n > 0 do
             f(n - 1, {x + 1, y * 2})
           end
           """)

    assert eligible?("""
           def f(x) when x >= 10 do
             if x > 20, do: %{value: x + 2}, else: %{value: x - 2}
           end
           """)
  end

  test "resolved runtime calls preserve their ordinary entry points" do
    assert eligible?("""
           alias String, as: S
           import #{inspect(CallsFixture)}, only: [runtime: 1]
           def f(x), do: runtime(S.length(x))
           """)

    assert eligible?("def f(x), do: x |> String.trim() |> String.length()")
    assert eligible?("def f(x), do: :erlang.element(1, x)")
  end

  test "unresolved or macro calls do not qualify as runtime calls" do
    for body <- [
          "some_macro(x)",
          "#{inspect(CallsFixture)}.caller(x)",
          "NotLoadedForCleanPath.runtime(x)",
          "some_macro",
          "__ENV__.function",
          "__CALLER__",
          "binding()",
          "__STACKTRACE__",
          "Process.info(self(), :current_stacktrace)"
        ] do
      refute eligible?("def f(x), do: #{body}"), body
    end
  end

  test "imported replacements for Kernel operations cannot acquire a clean copy" do
    assert {:ineligible, {:remote, _call}} =
             check("""
             import Kernel, except: [+: 2]
             import #{inspect(CallsFixture)}, only: [+: 2]
             def f(x), do: x + 2
             """)

    assert {:ineligible, {:displaced, {:if, 2}}} =
             check("""
             import Kernel, except: [if: 2]
             import #{inspect(CallsFixture)}, only: [if: 2]
             def f(x), do: if(x, do: x)
             """)
  end

  test "names of special forms and Kernel macros do not authorize arbitrary arities" do
    refute eligible?("def f(x), do: try(x, x)")
    refute eligible?("def f(x), do: if(x)")
  end

  test "super, quoting, directives, nested modules, and unknown locals keep the existing path" do
    for source <- [
          "def f(x), do: super(x)",
          "def f(x), do: quote(do: unquote(x))",
          "def f(x), do: (require Logger; x)",
          "def f(x), do: (alias String, as: S; S.length(x))",
          "def f(x), do: (defmodule Nested do\ndef g, do: 1\nend)",
          "def f(x), do: f(x, 1)",
          "def f(x), do: @value 1",
          "def f(x), do: ^x"
        ] do
      refute eligible?(source), source
    end
  end

  describe "lexical scope" do
    test "sequential bindings, rebinding, and nested matches reach what follows" do
      assert eligible?("""
             def f(x) do
               adjusted = x + 2
               {a, b} = c = {adjusted, x}
               adjusted = adjusted * a
               {adjusted, b, c}
             end
             """)
    end

    test "an inner clause's newly introduced name is not assumed to be a variable elsewhere" do
      assert {:ineligible, {:unbound, :local}} =
               check("""
               def f(x) do
                 case x do
                   {:value, local} -> local
                   _ -> local
                 end
               end
               """)
    end

    test "sibling operands do not see each other's bindings, but what follows does" do
      assert {:ineligible, {:unbound, :a}} = check("def f(x), do: {a = x, a}")
      assert {:ineligible, {:unbound, :a}} = check("def f(x), do: [a = x, a]")
      assert {:ineligible, {:unbound, :a}} = check("def f(x), do: (a = x) + a")
      assert {:ineligible, {:unbound, :a}} = check("def f(x), do: (a = x) |> max(a)")
      assert eligible?("def f(x), do: (max(a = x, 1); a)")
      assert eligible?("def f(x), do: (y = (z = x); {y, z})")
    end

    test "a scrutinee's or condition's bindings reach its clauses and what follows" do
      assert eligible?("def f(x), do: (case (y = x) do _ -> y end; y)")
      assert eligible?("def f(x), do: (if (y = x), do: y, else: y; y)")
      assert eligible?("def f(x), do: (cond do y = x -> y; true -> x end)")
      assert eligible?("def f(x), do: ((y = x) && y; y)")
    end

    test "nothing escapes a clause body, a comprehension, a closure, or a try" do
      for {name, source} <- [
            z: "def f(x), do: (case x do z -> z end; z)",
            z: "def f(x), do: (if x, do: (z = 1; z); z)",
            z: "def f(x), do: (x && (z = 1); z)",
            y: "def f(x), do: (cond do y = x -> y; true -> x end; y)",
            v: "def f(x), do: (with {:ok, v} <- x do v end; v)",
            v: "def f(x), do: (with {:ok, v} <- x, {:ok, w} <- v do w else _ -> v end)",
            i: "def f(x), do: (for i <- x, do: i; i)",
            i: "def f(x), do: (fn i -> i end; i)",
            y: "def f(x), do: (try do y = x; y rescue _ -> y end)",
            y: "def f(x), do: (try do y = x; y after y end)",
            e: "def f(x), do: (try do x rescue e -> e end; e)",
            z: "def f(x), do: (receive do z -> z after 0 -> x end; z)"
          ] do
        assert {:ineligible, {:unbound, ^name}} = check(source), source
      end
    end

    test "with, for, fn, try, and receive bind within their own extent" do
      assert eligible?("""
             def f(x, ys) do
               with {:ok, a} <- x,
                    b = a + 1,
                    {:ok, c} when c > b <- {:ok, b + 1} do
                 for y <- ys, z = y + c, z > 0, into: %{}, do: {y, z}
               else
                 {:error, reason} -> reason
                 other -> other
               end
             end
             """)

      assert eligible?("""
             def f(xs, seed) do
               total = for x <- xs, reduce: seed do
                 acc -> acc + x
               end
               double = fn
                 n when n > total -> n * 2
                 n -> n + seed
               end
               try do
                 double.(total)
               rescue
                 e in [ArithmeticError, ArgumentError] -> {:error, e}
                 KeyError -> :key
                 other -> {:other, other}
               catch
                 :exit, reason -> {:exit, reason}
                 thrown -> {:thrown, thrown}
               else
                 value when value > seed -> value
                 value -> -value
               after
                 send(self(), :done)
               end
             end
             """)

      assert eligible?("""
             def f(timeout) do
               receive do
                 {:value, v} when v > timeout -> v
                 other -> other
               after
                 timeout -> :timeout
               end
             end
             """)

      assert eligible?("def f(xs), do: for(x <- xs, reduce: 0, do: (acc -> acc + x))")
    end

    test "a pin reads the enclosing scope, never the pattern it sits in" do
      assert eligible?("def f(k, m), do: (%{^k => v} = m; v)")
      assert eligible?("def f(k, m), do: (case m do {^k, v} -> v; _ -> nil end)")
      assert {:ineligible, {:unbound, :k}} = check("def f(m), do: ({k, ^k} = m; k)")
    end

    test "a guard sees its head's bindings; a head default contributes only its pattern" do
      assert eligible?("def f(x, y) when x > y and is_integer(y), do: x - y")
      assert eligible?("def f(x, opts \\\\ []), do: {x, opts}")
      assert eligible?("def f(x, y \\\\ 1)\ndef f(x, y), do: x + y")
    end
  end

  describe "bitstrings" do
    test "construction and matching, with sizes that read earlier segments" do
      assert eligible?(
               "def f(acc, v), do: <<acc::binary, v + 1, v::16-little, 0::size(v)-unit(8)>>"
             )

      assert eligible?("def f(<<n::8, data::binary-size(n), rest::bits>>), do: {data, rest}")

      assert eligible?(
               "def f(bin, n), do: (<<head::binary-size(^n - 1), _::binary>> = bin; head)"
             )

      assert eligible?(~S|def f("prefix:" <> rest), do: rest|)
      assert eligible?(~S|def f(bin), do: for(<<c <- bin>>, c > 32, into: "", do: <<c>>)|)
    end

    test "interpolation is an ordinary expression; sigils follow suit" do
      assert eligible?(~S|def f(x), do: "value: #{x + 1}!"|)
      assert eligible?(~S|def f(x), do: ~w(a b #{x})a|)
      assert eligible?(~S|def f(x), do: Regex.match?(~r/^a+$/i, x)|)
      assert {:ineligible, {:unbound, :y}} = check(~S|def f(x), do: "#{y} #{x}"|)
    end

    test "a segment modifier is recognized by name, so a custom type macro is refused" do
      assert {:ineligible, {:bitstring, :modifier}} = check("def f(x), do: <<x::custom_type>>")
      assert {:ineligible, {:unbound, :n}} = check("def f(<<d::binary-size(n), n::8>>), do: d")
    end
  end

  describe "local functions" do
    test "a literal def or defp in the module is a known runtime function" do
      assert eligible?("""
             def f(x), do: helper(x, 1) |> other()
             defp helper(a, b), do: a + b
             def other(a), do: a
             """)
    end

    test "default arguments define the lower arities too" do
      assert eligible?("""
             def f(x), do: helper(x)
             defp helper(a, b \\\\ 1, c \\\\ 2), do: a + b + c
             """)

      assert {:ineligible, {:call, {:helper, 0}}} =
               check("""
               def f(_x), do: helper()
               defp helper(a, b \\\\ 1), do: a + b
               """)
    end

    test "local macros, guards, and generated definitions are not in the inventory" do
      for {call, definition} <- [
            {{:twice, 1}, "defmacrop twice(x), do: quote(do: unquote(x) * 2)"},
            {{:is_small, 1}, "defguardp is_small(x) when x < 10"},
            {{:generated, 1}, "for n <- [:generated], do: def(unquote(n)(x), do: x)"}
          ] do
        {name, _arity} = call
        source = "#{definition}\ndef f(x), do: #{name}(x)"
        assert {:ineligible, {:call, ^call}} = check(source), source
      end
    end

    test "the inventory lists exactly the literal definitions" do
      {:defmodule, _, [_, [{_, {:__block__, _, statements}}]]} =
        Sourceror.parse_string!("""
        defmodule Inventory do
          def a(x), do: x
          defp b(x, y \\\\ 1), do: x + y
          defmacro c(x), do: x
          def unquote(:d)(x), do: x
          def unquote(whole_head), do: :ok
          def e(unquote_splicing([1, 2])), do: :ok
          @attr 1
        end
        """)

      assert CleanPath.local_functions(statements) == MapSet.new(a: 1, b: 1, b: 2)
    end
  end

  describe "closures, captures, and dynamic calls" do
    test "a closure's clauses scope like any clause; captures name functions" do
      assert eligible?("def f(xs, k), do: Enum.map(xs, fn x -> x + k end)")
      assert eligible?("def f(xs), do: Enum.map(xs, &(&1 * 2 + 1))")
      assert eligible?("def f(xs), do: Enum.map(xs, &String.length/1)")
      assert eligible?("def f(xs), do: Enum.filter(xs, &is_nil/1)")
      assert eligible?("def f(xs), do: Enum.map(xs, &helper/1)\ndefp helper(x), do: x")

      assert {:ineligible, {:call, {:helper, 1}}} =
               check("def f(xs), do: Enum.map(xs, &helper/1)")

      assert {:ineligible, {:remote, _call}} =
               check("def f(xs), do: Enum.map(xs, &#{inspect(CallsFixture)}.caller/1)")
    end

    test "a receiver that is no module name is dispatched at runtime" do
      assert eligible?("def f(user, mod, fun), do: {user.name, mod.run(user), fun.(1), user[:k]}")
      assert eligible?("def f(x), do: __MODULE__.g(x)")

      assert eligible?(
               "def f(state, v), do: put_in(state.items[v], update_in(state.n, &(&1 + 1)))"
             )
    end
  end

  describe "allowed macros and reads" do
    test "Kernel macros that depend only on their arguments" do
      assert eligible?(~S"""
             def f(x, m) do
               if is_nil(x) or x not in 1..10//2, do: raise(ArgumentError, "bad: #{to_string(x)}")
               unless match?({:ok, v} when v > x, m), do: raise("no match")
               x |> then(&(&1 + 1)) |> tap(&send(self(), &1))
             end
             """)
    end

    test "a macro's arguments bind nothing outward" do
      assert {:ineligible, {:unbound, :y}} = check("def f(x), do: (to_string(y = x); y)")
      assert {:ineligible, {:unbound, :v}} = check("def f(x), do: (match?({:ok, v}, x); v)")
    end

    test "module attribute reads, struct literals, and struct patterns" do
      assert eligible?("def f(x), do: @limit + x")
      assert eligible?("def f(@limit = x), do: x")
      assert eligible?(~S'def f(%URI{host: h} = u), do: %URI{u | host: h <> "!"}')
      assert eligible?("def f(%mod{} = s), do: {mod, %{s | a: 1}, %__MODULE__{}}")
    end

    test "Logger reports under a generated name already, so its macros may move" do
      assert eligible?(~S"""
             require Logger
             def f(x), do: (Logger.warning("x: #{x}"); x)
             """)

      assert {:ineligible, {:unbound, :y}} =
               check("require Logger\ndef f(x), do: (Logger.info(y = x); y)")
    end
  end

  describe "an in-place body" do
    test "is checked alone: the head supplies bindings and sibling blocks stay single" do
      assert :ok = body("def f(x, opts \\\\ []), do: {x + 1, opts}")
      assert :ok = body("def f(x) do\n x + 1\nrescue\n _ -> __STACKTRACE__\nend")
      assert {:ineligible, {:unbound, :y}} = body("def f(x), do: x + y")
      assert {:ineligible, {:clause, :bodiless}} = body("def f(x, y \\\\ 1)")
    end
  end

  describe "pure self recursion" do
    test "permits bindings and rejects side effects, callbacks, and sibling calls" do
      assert """
             def f(0, x), do: x
             def f(n, x) when n > 0 do
               x = x + 2
               step =
                 case rem(n, 2) do
                   0 -> x * 2
                   _ -> x
                 end
               f(n - 1, step)
             end
             """
             |> plan()
             |> CleanPath.pure_self_recursive?()

      for source <- [
            "def f(x), do: x + 2",
            "def f(x), do: (Process.put(:active, 1); f(x - 1))",
            "def f(x), do: (#{inspect(CallsFixture)}.runtime(x); f(x - 1))",
            "def f(x), do: (receive do :next -> f(x - 1) end)",
            "def f(x), do: f(x, 1)",
            "def f(x), do: f(helper(x))\ndefp helper(x), do: x - 1",
            "def f(x), do: f((fn y -> y - 1 end).(x))",
            "def f(x), do: (for y <- [x], do: y; f(x - 1))",
            ~S|def f(x), do: ("#{x}"; f(x - 1))|,
            "def f(x), do: f(x.next)",
            "def f(x), do: (if x < 0, do: raise(\"negative\"); f(x - 1))"
          ] do
        refute source |> plan() |> CleanPath.pure_self_recursive?(), source
      end
    end

    test "self-call redirection leaves remote and other-arity calls at ordinary entries" do
      body =
        "f(x - 1) + Other.f(x) + f(x, 1)"
        |> Code.string_to_quoted!()
        |> Resolve.annotate()

      redirected = CleanPath.redirect_self_calls(body, {:f, 1}, :clean_f, [])
      assert Macro.to_string(redirected) == "clean_f(x - 1) + Other.f(x) + f(x, 1)"

      args = [{:active, [], nil}]
      redirected = CleanPath.redirect_self_calls(body, {:f, 1}, :base_f, args)
      assert Macro.to_string(redirected) == "base_f(active, x - 1) + Other.f(x) + f(x, 1)"
    end

    test "recursion detection uses the effective arity of pipe stages" do
      refute plan("def min(n), do: n |> min(10)") |> CleanPath.pure_self_recursive?()
      assert plan("def f(n), do: (n - 1) |> f()") |> CleanPath.pure_self_recursive?()
      assert plan("def f(n, x), do: (n - 1) |> f(x)") |> CleanPath.pure_self_recursive?()
    end

    test "pipe redirection preserves arities and puts leading arguments before the receiver" do
      for {source, signature, expected} <- [
            {"n |> min(10)", {:min, 1}, "n |> min(10)"},
            {"(n - 1) |> f() |> f()", {:f, 1}, "clean(active, clean(active, n - 1))"},
            {"n |> f(f(n, x))", {:f, 2}, "clean(active, n, clean(active, n, x))"},
            {"f(n) |> Other.f(f(n))", {:f, 1}, "clean(active, n) |> Other.f(clean(active, n))"},
            {"n |> min(min(n))", {:min, 1}, "n |> min(clean(active, n))"}
          ] do
        body = source |> Code.string_to_quoted!() |> Resolve.annotate()
        redirected = CleanPath.redirect_self_calls(body, signature, :clean, [{:active, [], nil}])
        assert Macro.to_string(redirected) == expected
      end
    end

    test "membership may call an effectful Enumerable implementation before recursion" do
      plan =
        plan("""
        def f(0, values), do: values
        def f(n, values) when n > 0 do
          n in values
          f(n - 1, values)
        end
        """)

      assert CleanPath.eligible?(plan)
      refute CleanPath.pure_self_recursive?(plan)
    end
  end

  defp eligible?(source), do: check(source) == :ok

  defp check(source) do
    {statements, clauses} = definitions(source)
    CleanPath.check_function(plan_of(clauses), CleanPath.local_functions(statements))
  end

  defp body(source) do
    {statements, [clause | _]} = definitions(source)
    CleanPath.check_body(clause, CleanPath.local_functions(statements))
  end

  defp plan(source) do
    {_statements, clauses} = definitions(source)
    plan_of(clauses)
  end

  defp plan_of([first | _] = clauses) do
    {name, _, _args} = ClauseAST.clause_head_call(first)

    %FunctionPlan{
      signature: {:def, name, length(ClauseAST.head_args(first))},
      clauses: clauses
    }
  end

  # The module's statements, and the clauses of the group its first `def` begins.
  defp definitions(source) do
    {:defmodule, _, [_, [{_do, body}]]} =
      "defmodule CleanPathSource do\n#{source}\nend"
      |> Sourceror.parse_string!()
      |> Resolve.annotate()

    statements =
      case body do
        {:__block__, _, statements} -> statements
        clause -> [clause]
      end

    [first | _] = definitions = Enum.filter(statements, &match?({:def, _, _}, &1))
    arity = length(ClauseAST.head_args(first))
    {name, _, _args} = ClauseAST.clause_head_call(first)

    clauses =
      Enum.filter(definitions, fn clause ->
        {clause_name, _, _} = ClauseAST.clause_head_call(clause)
        clause_name == name and length(ClauseAST.head_args(clause)) == arity
      end)

    {statements, clauses}
  end
end
