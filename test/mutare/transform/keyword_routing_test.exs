defmodule Mutare.Transform.KeywordRoutingTest do
  use ExUnit.Case, async: true

  alias Mutare.Transform.KeywordRouting

  for {leading, descendant} <- [
        expression: :expression,
        interior: :expression,
        raw: :raw,
        lazy_expression: :lazy_expression,
        pattern: :pattern,
        binding_pattern: :binding_pattern,
        interpolated: :interpolated,
        hosted: :hosted
      ] do
    test "keyed #{leading} assigns descendants before traversal" do
      for arg <- shapes("[named: 1, other: 2, do: 3]") do
        route = {:keyed, unquote(leading), [named: :raw, do: :interior]}
        assert {:pairs, pairs, _rewrap} = KeywordRouting.decode(arg, route)

        assert treatments(pairs) == [
                 {unquote(descendant), :raw},
                 {unquote(descendant), unquote(descendant)},
                 {:raw, :interior}
               ]

        assert_rebuild(arg, route)
      end
    end
  end

  test "all block labels stay raw, even with expression-valued refinements" do
    for arg <- shapes("[do: 1, else: 2, rescue: 3, catch: 4, after: 5]") do
      route = {:keyed, :expression, [do: :expression, else: :expression]}
      assert {:pairs, pairs, _rewrap} = KeywordRouting.decode(arg, route)
      assert treatments(pairs) == List.duplicate({:raw, :expression}, 5)
      assert_rebuild(arg, route)
    end
  end

  test "interpolated data keys inherit the descendant treatment" do
    for arg <- shapes(~S(["#{key}": value, named: other])) do
      route = {:keyed, :interior, [named: :raw]}
      assert {:pairs, pairs, _rewrap} = KeywordRouting.decode(arg, route)
      assert treatments(pairs) == [{:expression, :expression}, {:expression, :raw}]
      assert_rebuild(arg, route)
    end
  end

  test "positional keyword routing keeps keys raw and duplicate values distinct" do
    for arg <- shapes("[same: 1, same: 2, do: 3]") do
      route = {:keyword, [:expression, :raw, :lazy_expression]}
      assert {:pairs, pairs, _rewrap} = KeywordRouting.decode(arg, route)
      assert treatments(pairs) == [{:raw, :expression}, {:raw, :raw}, {:raw, :lazy_expression}]
      assert_rebuild(arg, route)
    end
  end

  test "nested treatments are returned intact, not interpreted ahead of their consumer" do
    nested = {:keyword, [:expression, {:hosted, [SomeHost]}]}
    keyed = {:keyed, :raw, [value: :expression]}

    for arg <- shapes("[first: [a: 1, b: 2], second: [value: 3]]"),
        route <- [{:keyed, :raw, [first: nested, second: keyed]}, {:keyword, [nested, keyed]}] do
      assert {:pairs, pairs, _rewrap} = KeywordRouting.decode(arg, route)
      assert treatments(pairs) == [{:raw, nested}, {:raw, keyed}]
      assert_rebuild(arg, route)
    end
  end

  test "a resolved host stamp can be the leading treatment too" do
    hosted = {:hosted, [SomeHost]}

    for arg <- shapes("[named: 1, other: 2, do: 3]") do
      route = {:keyed, hosted, [named: :expression]}
      assert {:pairs, pairs, _rewrap} = KeywordRouting.decode(arg, route)
      assert treatments(pairs) == [{hosted, :expression}, {hosted, hosted}, {:raw, hosted}]
      assert_rebuild(arg, route)
    end

    arg = Sourceror.parse_string!("options")
    assert KeywordRouting.decode(arg, {:keyed, hosted, [named: :expression]}) == {:whole, hosted}
  end

  test "non-keyword arguments use the declared fallback, including empty and mixed lists" do
    for source <- ["options", "Keyword.merge(a, b)", "%{a: 1}", "[]", "[1, a: 2]"],
        arg <- shapes(source) do
      assert KeywordRouting.decode(arg, {:keyword, [:expression]}) == {:whole, :raw}

      for leading <- [:raw, :interior, :expression, :lazy_expression] do
        assert KeywordRouting.decode(arg, {:keyed, leading, [a: :raw]}) == {:whole, leading}
      end
    end
  end

  # The written call the route was stamped on must fit it (`decode!/2`, what Resolve
  # applies); a rebuilt call whose pairs no longer fit the stamp it inherited is read as no
  # route (`decode/2`, what every later reader applies).
  test "positional keyword routing rejects both missing and surplus treatments where stamped" do
    for arg <- shapes("[a: 1, b: 2]"),
        values <- [[], [:raw], [:raw, :raw, :raw]] do
      assert_raise ArgumentError, ~r/exactly one treatment per pair/, fn ->
        KeywordRouting.decode!(arg, {:keyword, values})
      end

      assert KeywordRouting.decode(arg, {:keyword, values}) == {:whole, :raw}
    end

    for arg <- shapes("[a: 1, b: 2]") do
      assert {:pairs, _pairs, _rewrap} = KeywordRouting.decode!(arg, {:keyword, [:raw, :raw]})
    end
  end

  test "rewrap replaces pairs while preserving the original container metadata" do
    {:__block__, meta, [_]} = arg = Sourceror.parse_string!("[a: 1, b: 2]")
    assert {:pairs, _pairs, rewrap} = KeywordRouting.decode(arg, {:keyword, [:raw, :raw]})
    replacements = [changed: {:new_value, [line: 10], []}]
    assert rewrap.(replacements) == {:__block__, meta, [replacements]}

    assert {:pairs, _pairs, rewrap} = KeywordRouting.decode([a: 1], {:keyword, [:raw]})
    assert rewrap.(replacements) == replacements
  end

  defp shapes(source) do
    case Sourceror.parse_string!(source) do
      {:__block__, _, [list]} = wrapped when is_list(list) -> [wrapped, list]
      other -> [other]
    end
  end

  defp treatments(pairs),
    do:
      Enum.map(pairs, fn {{_key, key_treatment}, {_value, value_treatment}} ->
        {key_treatment, value_treatment}
      end)

  defp assert_rebuild(arg, route) do
    {:pairs, pairs, rewrap} = KeywordRouting.decode(arg, route)
    original_pairs = Enum.map(pairs, fn {{key, _}, {value, _}} -> {key, value} end)
    assert rewrap.(original_pairs) == arg
  end
end
