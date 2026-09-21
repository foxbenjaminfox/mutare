defmodule Mutare.Transform.SelfCallsTest do
  use ExUnit.Case, async: true

  alias Mutare.Transform.SelfCalls

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
end
