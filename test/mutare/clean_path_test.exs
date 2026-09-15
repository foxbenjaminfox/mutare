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
    refute eligible?("""
           import Kernel, except: [+: 2]
           import #{inspect(CallsFixture)}, only: [+: 2]
           def f(x), do: x + 2
           """)

    refute eligible?("""
           import Kernel, except: [if: 2]
           import #{inspect(CallsFixture)}, only: [if: 2]
           def f(x), do: if(x, do: x)
           """)
  end

  test "names of special forms and Kernel macros do not authorize arbitrary arities" do
    refute eligible?("def f(x), do: try(x, x)")
    refute eligible?("def f(x), do: if(x)")
  end

  test "the first relocation contract leaves defaults, super, captures, and new bindings alone" do
    for source <- [
          "def f(x \\\\ 1), do: x + 2",
          "def f(x \\\\ 1)\ndef f(x), do: x + 2",
          "def f(x), do: super(x)",
          "def f(x), do: &f/1",
          "def f(x), do: fn y -> y + x end",
          "def f(x), do: quote(do: unquote(x))",
          "def f(x), do: @value + x",
          "def f(x), do: (y = x + 2; y)",
          "def f(x), do: (defmodule Nested do\ndef g, do: 1\nend)",
          "def f(x), do: f(x, 1)"
        ] do
      refute eligible?(source), source
    end
  end

  test "an inner clause's newly introduced name is not assumed to be a variable elsewhere" do
    refute eligible?("""
           def f(x) do
             case x do
               {:value, local} -> local
               _ -> local
             end
           end
           """)
  end

  test "pure recursion permits head-variable rebinding and rejects side effects and callbacks" do
    assert """
           def f(0, x), do: x
           def f(n, x) when n > 0 do
             x = x + 2
             f(n - 1, x)
           end
           """
           |> plan()
           |> CleanPath.pure_self_recursive?()

    for source <- [
          "def f(x), do: x + 2",
          "def f(x), do: (Process.put(:active, 1); f(x - 1))",
          "def f(x), do: (#{inspect(CallsFixture)}.runtime(x); f(x - 1))",
          "def f(x), do: (receive do :next -> f(x - 1) end)",
          "def f(x), do: f(x, 1)"
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

  defp eligible?(source), do: source |> plan() |> CleanPath.eligible?()

  defp plan(source) do
    {:defmodule, _, [_, [{_do, body}]]} =
      "defmodule CleanPathSource do\n#{source}\nend"
      |> Sourceror.parse_string!()
      |> Resolve.annotate()

    clauses =
      case body do
        {:__block__, _, statements} -> statements
        clause -> [clause]
      end
      |> Enum.filter(&match?({:def, _, _}, &1))

    [first | _] = clauses
    {name, _, _args} = ClauseAST.clause_head_call(first)

    %FunctionPlan{
      signature: {:def, name, length(ClauseAST.head_args(first))},
      clauses: clauses
    }
  end
end
