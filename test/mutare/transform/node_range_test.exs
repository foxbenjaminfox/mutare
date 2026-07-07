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

  defp neg_end(code), do: NodeRange.get(Sourceror.parse_string!(code)).end

  describe "multi-line unary-negation over-count" do
    # A prefix `not X` / `!X` ends where its operand does, but Sourceror over-counts a *multi-line*
    # one past the operand's real end (it extends by the operator's width). `get/1` clamps it back.
    test "a multi-line `not X` ends at the operand's real end, not past it" do
      # The operand's `)` closes on line 3 column 1, so the exclusive end is column 2 — where
      # Sourceror reports column 5 (three past, the width of `not`).
      assert neg_end("not exists(\n  subq(a)\n)") == [line: 3, column: 2]

      raw = Sourceror.get_range(Sourceror.parse_string!("not exists(\n  subq(a)\n)")).end
      assert raw == [line: 3, column: 5]
    end

    test "a multi-line `!X` is clamped the same way (one column of over-count)" do
      assert neg_end("!valid?(\n  long(x)\n)") == [line: 3, column: 2]
    end

    test "a single-line negation is already exact → unchanged from Sourceror" do
      for code <- ["not exists(bar)", "!valid?(x)"] do
        node = Sourceror.parse_string!(code)
        assert NodeRange.get(node) == Sourceror.get_range(node)
      end
    end

    test "a parenthesized `not(X)` is clamped toward the operand, never past the real end" do
      # Sourceror over-counts to column 5; the real outer `)` ends at column 3. The clamp lands at
      # the operand's column 2 — one short of the paren but far closer than the raw over-count, and
      # the non-widening direction keeps a containment check safe (see the `Attach` span trim).
      node = Sourceror.parse_string!("not(exists(\n  a\n))")
      assert NodeRange.get(node).end == [line: 3, column: 2]
      assert Sourceror.get_range(node).end == [line: 3, column: 5]
    end

    test "another unary prefix operator (`-x`) is a passthrough, not clamped" do
      node = Sourceror.parse_string!("-value(\n  x\n)")
      assert NodeRange.get(node) == Sourceror.get_range(node)
    end
  end

  # A sigil whose body escapes its closing delimiter (`\/` in `~r/…/`) is stored
  # with that escape collapsed, so `Sourceror.get_range/1` ends one column short
  # per escape. `get/1` adds it back. The range starts at the `~`, so for a sigil
  # of length n starting at column c it ends (exclusive) at column c + n.
  defp literal_end_col(literal) do
    node = Sourceror.parse_string!(literal)
    NodeRange.get(node).end[:column]
  end

  describe "sigil closing-delimiter under-count" do
    test "a regex with one escaped delimiter spans its full written width" do
      # `~r/a\/b/u` is 9 chars (1..9), so the corrected end is column 10 — one wider
      # than Sourceror's content-length count (the `\/` stored as `/`).
      assert literal_end_col(~S|~r/a\/b/u|) == 10
      assert literal_end_col(~S|~r/a\/b/u|) == String.length(~S|~r/a\/b/u|) + 1
    end

    test "the count scales with the number of escaped delimiters" do
      # Two `\/`: ~r/\/\//  → 8 chars, end 9. (Only `\/` collapses; `\\` etc. don't.)
      assert literal_end_col(~S|~r/\/\//|) == String.length(~S|~r/\/\//|) + 1
      assert literal_end_col(~S|~r/a\/b\/c/u|) == String.length(~S|~r/a\/b\/c/u|) + 1
    end

    test "a paired delimiter counts only the collapsed closing escape" do
      # `~r{a\}b}u` — the `\}` collapses (off by one); a `\{` would keep its backslash.
      assert literal_end_col(~S|~r{a\}b}u|) == String.length(~S|~r{a\}b}u|) + 1
      assert literal_end_col(~S|~r{a\{b\}c}u|) == String.length(~S|~r{a\{b\}c}u|) + 1
    end

    test "non-regex sigils with an escaped delimiter are corrected too" do
      assert literal_end_col(~S|~s/a\/b/|) == String.length(~S|~s/a\/b/|) + 1
      assert literal_end_col(~S|~w/a\/b c/|) == String.length(~S|~w/a\/b c/|) + 1
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
      assert literal_end_col(trailing) == String.length(trailing) + 1
    end

    test "an angle-bracket delimiter is corrected like the other paired ones" do
      # Exercises the `<`→`>` close_delimiter clause; the escaped `>` collapses, so the range
      # widens by one just like the `{`/`(`/`[` cases.
      assert literal_end_col(~S|~r<a\>b>u|) == String.length(~S|~r<a\>b>u|) + 1
      # with no escape, close_delimiter(<) still runs but the range is unchanged
      node = Sourceror.parse_string!(~S|~r<abc>|)
      assert NodeRange.get(node) == Sourceror.get_range(node)
    end

    test "a heredoc sigil (delimiter \"\"\") has no single-char close → left unchanged" do
      # `close_delimiter/1` returns nil for the heredoc fence, so the correction is skipped
      # entirely (the else branch), leaving Sourceror's range untouched.
      node = Sourceror.parse_string!(~s|~s"""\nhi\n"""|)
      assert NodeRange.get(node) == Sourceror.get_range(node)
    end
  end

  # The same tokenizer collapse (`\"` stored as `"`) hits interpolated strings,
  # charlists, and quoted atoms — their ranges are also sized from stored segment
  # lengths, so an escaped quote after the last interpolation leaves the range one
  # column short per escape and a report patch leaves the closing quote behind
  # (`toast("…\"#{x}\".")` → `toast(""")`).
  describe "interpolated-string escaped-quote under-count" do
    test "an escaped quote after the last interpolation spans its full written width" do
      literal = ~S|"set to \"#{status}\"."|
      assert literal_end_col(literal) == String.length(literal) + 1
    end

    test "the count scales with the number of trailing escaped quotes" do
      literal = ~S|"a#{x}\"b\"c"|
      assert literal_end_col(literal) == String.length(literal) + 1
    end

    test "only the quote collapses — other escapes in the tail keep their backslash" do
      # `\\`, `\n`, `\t` are stored raw (two chars), so only the `\"` is added back.
      literal = ~S|"a#{x}\"b\nc\\d"|
      assert literal_end_col(literal) == String.length(literal) + 1
    end

    test "an escaped quote before the last interpolation is already correct" do
      # Its absolute `closing` position is baked into the interpolation metadata,
      # so Sourceror's range is right and the correction leaves it alone.
      node = Sourceror.parse_string!(~S|"a\"b#{x}c"|)
      assert NodeRange.get(node) == Sourceror.get_range(node)
    end

    test "an interpolated string with no escaped quote is unchanged from Sourceror" do
      node = Sourceror.parse_string!(~S|"a#{x}b"|)
      assert NodeRange.get(node) == Sourceror.get_range(node)
    end

    test "a plain (non-interpolated) string keeps its raw escapes → left unchanged" do
      # No interpolation → no `<<>>` node; the literal's stored content keeps the
      # backslash, so Sourceror's count is already right.
      literal = ~S|"a\"b"|
      node = Sourceror.parse_string!(literal)
      assert NodeRange.get(node) == Sourceror.get_range(node)
      assert NodeRange.get(node).end[:column] == String.length(literal) + 1
    end

    test "a real <<…>> bitstring (no delimiter meta) is a passthrough" do
      node = Sourceror.parse_string!(~S|<<1, x::binary>>|)
      assert NodeRange.get(node) == Sourceror.get_range(node)
    end

    test "an interpolated charlist with a trailing escaped quote is corrected too" do
      literal = ~S|'a#{x}b\'c'|
      assert literal_end_col(literal) == String.length(literal) + 1
    end

    test "an interpolated quoted atom with a trailing escaped quote is corrected too" do
      literal = ~S|:"a#{x}b\"c"|
      assert literal_end_col(literal) == String.length(literal) + 1
    end

    test "a keyword-shorthand interpolated atom key covers its trailing colon" do
      # `%{"k#{x}": 1}` — Sourceror's range stops before the written colon (a plain
      # `foo:` key includes it), so a key swap would patch `:mutare` and strand the
      # colon (`%{:mutare: 1}`). The correction covers it; `Mutare.Site` renders both
      # diff sides in keyword form to match.
      {:%{}, _, [{key, _value}]} = Sourceror.parse_string!(~S|%{"k#{x}": 1}|)
      # `"k#{x}":` spans columns 3..10 — the corrected end is one past the colon.
      assert NodeRange.get(key).end[:column] == Sourceror.get_range(key).end[:column] + 1
      assert NodeRange.get(key).end[:column] == 11
    end

    test "a value-form interpolated atom (no keyword shorthand) gets no colon bump" do
      node = Sourceror.parse_string!(~S|:"a#{x}b"|)
      assert NodeRange.get(node) == Sourceror.get_range(node)
    end

    test "an interpolated heredoc (fence delimiter) is left unchanged" do
      # The fence never needs an escaped quote at the tail; `interpolated_range/3`
      # falls through for the `"""` delimiter.
      node = Sourceror.parse_string!(~s|"""\na\#{x}b\n"""|)
      assert NodeRange.get(node) == Sourceror.get_range(node)
    end
  end
end
