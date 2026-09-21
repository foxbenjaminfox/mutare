defmodule Mutare.Site.ParenthesizeTest do
  # What `Mutare.Site.Parenthesize` decides about nodes no built-in mutator produces; the
  # patches real mutators make are checked in `source_patch_parens_test.exs`.
  use ExUnit.Case, async: true

  alias Mutare.Site.Parenthesize

  @variable {:x, [], nil}

  test "an original with no parentheses of its own, a bare keyword list, gets them" do
    sequence = Sourceror.parse_string!("a\nb")
    assert Parenthesize.in_position("a\nb", [asc: @variable], sequence) == "(a\nb)"
  end

  test "a clause or a definition is never parenthesized, whatever block call it holds" do
    block = Sourceror.parse_string!("(if a do 1 end)")
    assert Parenthesize.in_position("block", @variable, block) == "(block)"

    for mutated <- [
          {:->, [], [[@variable], block]},
          {:def, [], [{:f, [], nil}, [do: block]]},
          {:defp, [], [{:f, [], nil}, [do: block]]},
          {:defmacro, [], [{:f, [], nil}, [do: block]]},
          {:defmacrop, [], [{:f, [], nil}, [do: block]]}
        ] do
      assert Parenthesize.in_position("clause", @variable, mutated) == "clause"
    end
  end
end
