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

  # A sigil whose body escapes its closing delimiter (`\/` in `~r/…/`) is stored
  # with that escape collapsed, so `Sourceror.get_range/1` ends one column short
  # per escape. `get/1` adds it back. The range starts at the `~`, so for a sigil
  # of length n starting at column c it ends (exclusive) at column c + n.
  defp sigil_end_col(literal) do
    node = Sourceror.parse_string!(literal)
    NodeRange.get(node).end[:column]
  end

  describe "sigil closing-delimiter under-count" do
    test "a regex with one escaped delimiter spans its full written width" do
      # `~r/a\/b/u` is 9 chars (1..9), so the corrected end is column 10 — one wider
      # than Sourceror's content-length count (the `\/` stored as `/`).
      assert sigil_end_col(~S|~r/a\/b/u|) == 10
      assert sigil_end_col(~S|~r/a\/b/u|) == String.length(~S|~r/a\/b/u|) + 1
    end

    test "the count scales with the number of escaped delimiters" do
      # Two `\/`: ~r/\/\//  → 8 chars, end 9. (Only `\/` collapses; `\\` etc. don't.)
      assert sigil_end_col(~S|~r/\/\//|) == String.length(~S|~r/\/\//|) + 1
      assert sigil_end_col(~S|~r/a\/b\/c/u|) == String.length(~S|~r/a\/b\/c/u|) + 1
    end

    test "a paired delimiter counts only the collapsed closing escape" do
      # `~r{a\}b}u` — the `\}` collapses (off by one); a `\{` would keep its backslash.
      assert sigil_end_col(~S|~r{a\}b}u|) == String.length(~S|~r{a\}b}u|) + 1
      assert sigil_end_col(~S|~r{a\{b\}c}u|) == String.length(~S|~r{a\{b\}c}u|) + 1
    end

    test "non-regex sigils with an escaped delimiter are corrected too" do
      assert sigil_end_col(~S|~s/a\/b/|) == String.length(~S|~s/a\/b/|) + 1
      assert sigil_end_col(~S|~w/a\/b c/|) == String.length(~S|~w/a\/b c/|) + 1
    end

    test "a sigil with no escaped delimiter is unchanged from Sourceror" do
      for literal <- [~S|~r/abc/u|, ~S|~r/a\\b/u|, ~S|~r/a\tb/u|, "~D[2020-01-01]"] do
        node = Sourceror.parse_string!(literal)
        assert NodeRange.get(node) == Sourceror.get_range(node)
      end
    end

    test "an interpolated sigil is unchanged (get_range already correct) except for a trailing escape" do
      # Sourceror is already right when the escape sits before the last interpolation
      # (its absolute `closing` position is baked in); only a *trailing* escaped
      # delimiter is under-counted, so only that one is added back.
      before = ~S|~r/a\/b#{x}c/u|

      assert NodeRange.get(Sourceror.parse_string!(before)) ==
               Sourceror.get_range(Sourceror.parse_string!(before))

      trailing = ~S|~r/a#{x}b\/c/u|
      assert sigil_end_col(trailing) == String.length(trailing) + 1
    end
  end
end
