defmodule Mutare.Transform.SelfCallsTest do
  use ExUnit.Case, async: true

  alias Mutare.Transform.{Resolve, SelfCalls}

  for source <- [
        "quote(do: f(1))",
        "quote(do: 1 |> f())",
        "quote(unquote: false, do: unquote(f(1)))",
        "quote([unquote: false], do: unquote_splicing(f(1)))",
        "quote(bind_quoted: [x: 1], do: unquote(f(x)))",
        "quote(do: quote(do: unquote(f(1))))",
        "quote(do: quote(do: unquote(unquote(f(1)))))"
      ] do
    test "preserves quoted data: #{source}" do
      ast = Sourceror.parse_string!(unquote(source))
      assert SelfCalls.redirect(ast, {:f, 1}, :clean_f, []) == {ast, false}
    end
  end

  for {source, expected} <- [
        {"quote(do: f(unquote(f(1))))", "quote(do: f(unquote(clean_f(:extra, 1))))"},
        {"quote(do: [unquote_splicing(f(1))])",
         "quote(do: [unquote_splicing(clean_f(:extra, 1))])"},
        {"quote(bind_quoted: [x: f(1)], do: f(x))",
         "quote(bind_quoted: [x: clean_f(:extra, 1)], do: f(x))"},
        {"quote([bind_quoted: [x: f(1)], unquote: true], do: unquote(f(x)))",
         "quote([bind_quoted: [x: clean_f(:extra, 1)], unquote: true], do: unquote(clean_f(:extra, x)))"},
        {"quote(line: f(1), unquote: false, do: unquote(f(2)))",
         "quote(line: clean_f(:extra, 1), unquote: false, do: unquote(f(2)))"},
        {"quote(do: quote(bind_quoted: [x: unquote(f(1))], do: f(x)))",
         "quote(do: quote(bind_quoted: [x: unquote(clean_f(:extra, 1))], do: f(x)))"},
        {"quote(do: unquote(quote(do: f(unquote(f(1))))))",
         "quote(do: unquote(quote(do: f(unquote(clean_f(:extra, 1))))))"}
      ] do
    test "redirects executable calls: #{source}" do
      ast = Sourceror.parse_string!(unquote(source))
      leading = Mutare.AST.literal(:extra)
      assert {redirected, true} = SelfCalls.redirect(ast, {:f, 1}, :clean_f, [leading])

      assert redirected
             |> Sourceror.to_string()
             |> Code.string_to_quoted!()
             |> Macro.to_string() ==
               unquote(expected) |> Code.string_to_quoted!() |> Macro.to_string()
    end
  end

  test "unresolved pipes preserve both possible interpretations of the right operand" do
    for source <- ["n |> f(10)", "f(n) |> f(f(10))", "n |> f()", "n |> f"] do
      body = Code.string_to_quoted!(source)

      for arity <- [1, 2] do
        assert SelfCalls.redirect(body, {:f, arity}, :clean, []) == {body, false}
      end
    end
  end

  test "a preserved stage at another arity is not a self-call" do
    body = Code.string_to_quoted!("n |> f(10)")
    assert SelfCalls.redirect(body, {:f, 1}, :clean, []) == {body, false}
  end

  test "calls in the receiver and stage arguments keep their own arities" do
    body = Code.string_to_quoted!("f(n) |> f(f(10))") |> Resolve.annotate()
    assert {redirected, true} = SelfCalls.redirect(body, {:f, 1}, :clean, [])
    assert Macro.to_string(redirected) == "f(clean(n), clean(10))"
  end

  test "recursive stages include the receiver after any leading arguments" do
    for body <- ["n |> f()", "n |> f", "n |> f() |> f"] do
      ast = Code.string_to_quoted!(body) |> Resolve.annotate()
      leading = [Macro.var(:super, nil)]
      assert {redirected, true} = SelfCalls.redirect(ast, {:f, 1}, :clean, leading)

      expected =
        if body == "n |> f() |> f",
          do: "clean(super, clean(super, n))",
          else: "clean(super, n)"

      assert Macro.to_string(redirected) == expected
    end
  end

  test "nested recursive stages retain their explicit arguments" do
    body = Code.string_to_quoted!("f(n) |> f(n |> f(10))") |> Resolve.annotate()

    assert {redirected, true} =
             SelfCalls.redirect(body, {:f, 2}, :clean, [Macro.var(:super, nil)])

    assert Macro.to_string(redirected) == "clean(super, f(n), clean(super, n, 10))"
  end

  test "a displaced operator walks its right operand as an ordinary call" do
    body =
      """
      import Kernel, except: [|>: 2]
      import Mutare.Test.PairPipe
      n |> f(10)
      """
      |> Code.string_to_quoted!()
      |> Resolve.annotate()

    assert {{:__block__, _, [_, _, {:|>, _, [_, {:clean, _, [10]}]}]}, true} =
             SelfCalls.redirect(body, {:f, 1}, :clean, [])
  end
end
