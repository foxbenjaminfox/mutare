defmodule Mutare.Transform.NodeRangeTest do
  use ExUnit.Case, async: true

  alias Mutare.Transform.NodeRange

  # The first arg's literal node from `foo(<literal>)`, so each atom is followed by
  # a `)` — the character the over-wide range used to eat.
  defp arg_node(literal) do
    {_, _, [arg]} = Sourceror.parse_string!("foo(#{literal})")
    arg
  end

  defp end_col(literal), do: NodeRange.get(arg_node(literal)).end[:column]

  # `foo(` is 4 chars, so an arg starting at column 5 of length n ends (exclusive) at
  # column 5 + n.
  test "bare true/false/nil report a range matching their written width (no phantom colon)" do
    assert end_col("true") == 9
    assert end_col("false") == 10
    assert end_col("nil") == 8
  end

  test "a written atom :foo keeps Sourceror's (correct) colon-inclusive width" do
    # `:foo` is 4 chars (5..8), end 9 — unchanged from `Sourceror.get_range/1`.
    assert end_col(":foo") == 9
    assert NodeRange.get(arg_node(":foo")) == Sourceror.get_range(arg_node(":foo"))
  end

  test "a true:/false:/nil: keyword key keeps the trailing colon (not trimmed)" do
    {_, _, [[pair]]} = Sourceror.parse_string!("foo(nil: 1)")
    {key, _value} = pair
    # `nil:` is 4 chars (5..8), end 9 — the +1 is the *real* trailing colon here,
    # so the keyword-key guard leaves it intact.
    assert NodeRange.get(key) == Sourceror.get_range(key)
    assert NodeRange.get(key).end[:column] == 9
  end

  test "is a passthrough for a non-atom node" do
    node = arg_node("1 + 2")
    assert NodeRange.get(node) == Sourceror.get_range(node)
  end
end
