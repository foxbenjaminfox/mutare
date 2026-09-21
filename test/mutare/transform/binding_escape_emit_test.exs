defmodule Mutare.Transform.BindingEscapeEmitTest do
  use ExUnit.Case, async: true

  alias Mutare.Transform.{BindingEscapeEmit, Meta}

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
end
