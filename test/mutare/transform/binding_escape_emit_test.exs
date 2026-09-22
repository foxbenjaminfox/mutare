defmodule Mutare.Transform.BindingEscapeEmitTest do
  use ExUnit.Case, async: true

  alias Mutare.CallRouting.Registry
  alias Mutare.Transform.{BindingEscapeEmit, Meta, Resolve}

  defp bindings(source),
    do: source |> Sourceror.parse_string!() |> BindingEscapeEmit.expression_bindings()

  for {source, treatment, expected} <- [
        {"[value: x = 1, other: y = 2]", {:keyed, :interior, [value: :expression]}, [:x, :y]},
        {"[value: x = 1, raw: hidden = 2]", {:keyed, :expression, [raw: :raw]}, [:x]},
        {"[raw: hidden = 1, value: x = 2]", {:keyed, :raw, [value: :expression]}, [:x]},
        {"[value: x = 1, lazy: hidden = 2]", {:keyword, [:expression, :lazy_expression]}, [:x]},
        {"[value: x = 1, raw: hidden = 2]", {:keyword, [:interior, :raw]}, [:x]},
        {"[nested: [value: x = 1, raw: hidden = 2]]",
         {:keyword, [{:keyed, :raw, [value: :expression]}]}, [:x]},
        {"[nested: [value: x = 1, raw: hidden = 2]]",
         {:keyed, :raw, [nested: {:keyword, [:expression, :raw]}]}, [:x]},
        {"[pattern: {x, y}]", {:keyword, [:binding_pattern]}, [:x, :y]},
        {"[pattern: {x, y}]", {:keyed, :raw, [pattern: :binding_pattern]}, [:x, :y]},
        {~S(["#{key = "value"}": n]), {:keyed, :expression, []}, [:key]},
        {~S(["#{key = "value"}": n]), {:keyed, :interior, []}, [:key]},
        {~S(["#{hidden = "value"}": n]), {:keyed, :raw, []}, []},
        {~S(["#{key = "k"}": value = 1]), {:keyed, :expression, []}, [:key, :value]},
        {"x = 1", {:keyed, :expression, [value: :raw]}, [:x]},
        {"x = 1", {:keyed, :raw, [value: :expression]}, []},
        {"x = 1", {:keyword, [:expression]}, []}
      ] do
    test "exports #{inspect(expected)} under #{inspect(treatment)} in #{source}" do
      arg = Sourceror.parse_string!(unquote(source))
      treatment = unquote(Macro.escape(treatment))

      # Keyword arguments can be wrapped literals or bare trailing keyword sugar.
      args =
        case arg do
          {:__block__, _, [pairs]} when is_list(pairs) -> [arg, pairs]
          _ -> [arg]
        end

      for arg <- args do
        node = {:consume, Meta.stamp_routing([], [treatment]), [arg]}
        assert BindingEscapeEmit.expression_bindings(node) == unquote(expected)
      end
    end
  end

  describe "each name once, in binding order" do
    for {source, expected} <- [
          {"x = y = 1", [:y, :x]},
          {"{a = 1, b = 2}", [:a, :b]},
          {"(a = m).f(b = 1)", [:a, :b]},
          {"{x = 1, x = 2}", [:x]}
        ] do
      test "#{source} exports #{inspect(expected)}" do
        assert bindings(unquote(source)) == unquote(expected)
      end
    end
  end

  describe "positions that may not run, or run in their own scope, export nothing" do
    for {source, expected} <- [
          {"(a = true) and (b = true)", [:a]},
          {"(a = true) or (b = true)", [:a]},
          {"(a = 1) && (b = 2)", [:a]},
          {"(a = 1) || (b = 2)", [:a]},
          {"for x <- [1], do: a = 1", []},
          {"with x <- (a = 1), do: b = x", []},
          {"try do a = 1 after b = 2 end", []},
          {"&foo(a = &1)", []},
          {"foo do x -> a = 1 end", []},
          {"quote", []}
        ] do
      test "#{source} exports #{inspect(expected)}" do
        assert bindings(unquote(source)) == unquote(expected)
      end
    end
  end

  describe "a quote exports what its escapes bind" do
    for {source, expected} <- [
          {"quote line: unquote(n = 1) do :ok end", [:n]},
          {"quote do: (quote line: unquote(n = 1) do :ok end)", [:n]},
          {"quote do: {unquote(a = 1), unquote(b = 2)}", [:a, :b]},
          {"quote do: unquote(a = m).f(unquote(b = 1))", [:a, :b]}
        ] do
      test "#{source} exports #{inspect(expected)}" do
        assert bindings(unquote(source)) == unquote(expected)
      end
    end
  end

  describe "a skipped call is read in the environment it retained" do
    # Inside a skipped call nothing is resolved, so whether its `|>` is Kernel's comes only from
    # the environment the call carries, advanced by the directives written before the pipe. A
    # displaced `|>` is an ordinary call, whose arguments both run; Kernel's would make
    # `b = 2` a conditional branch.
    defp skipped(source) do
      source
      |> Sourceror.parse_string!()
      |> Resolve.annotate(Registry.build([{Foo, :bar, 1, :skip}], []))
    end

    test "a directive before the call" do
      {:__block__, _, [_import, call]} =
        skipped("""
        import Kernel, except: [|>: 2]
        Foo.bar((a = 1) |> if(do: b = 2))
        """)

      assert BindingEscapeEmit.expression_bindings(call) == [:a, :b]
      assert BindingEscapeEmit.expression_bindings(Resolve.forget(call)) == [:a]
    end

    test "a directive earlier in a block inside the call" do
      call = skipped("Foo.bar((import Kernel, except: [|>: 2]; (a = 1) |> if(do: b = 2)))")

      assert BindingEscapeEmit.expression_bindings(call) == [:a, :b]
      assert BindingEscapeEmit.expression_bindings(Resolve.forget(call)) == [:a]
    end
  end
end
