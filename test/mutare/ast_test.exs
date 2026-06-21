defmodule Mutare.ASTTest do
  use ExUnit.Case, async: true

  alias Mutare.AST

  doctest Mutare.AST

  describe "literal/1 (the clean-meta builder)" do
    test "a string literal renders as a double-quoted string, not a charlist" do
      # The footgun the helper exists for: a bare `{:__block__, [], ["x"]}` renders as `~c"x"`.
      assert Sourceror.to_string(AST.literal("x")) == ~s("x")
      assert AST.literal("x") == {:__block__, [delimiter: ~s(")], ["x"]}
    end

    test "non-string literals get fresh, empty meta (so they render from the value)" do
      assert AST.literal(0) == {:__block__, [], [0]}
      assert AST.literal(:ok) == {:__block__, [], [:ok]}
      assert Sourceror.to_string(AST.literal(42)) == "42"
    end
  end

  describe "the survivor sentinels" do
    test "match the marker the built-in families emit" do
      assert AST.sentinel_string() == "mutare"
      assert AST.sentinel_atom() == :mutare
      assert AST.sentinel_alias() == [:Mutare, :Mutant]
    end
  end

  describe "node predicates" do
    test "empty_collection_literal?/1 recognises empty list/map/word/charlist literals" do
      assert AST.empty_collection_literal?(AST.literal([]))
      assert AST.empty_collection_literal?({:%{}, [], []})
      assert AST.empty_collection_literal?(Sourceror.parse_string!("~w()"))
      assert AST.empty_collection_literal?(Sourceror.parse_string!(~S|~c""|))
      refute AST.empty_collection_literal?(Sourceror.parse_string!("~w(a b)"))
      refute AST.empty_collection_literal?(Sourceror.parse_string!("{}"))
    end

    test "nil_literal?/1 and key_atom/1" do
      assert AST.nil_literal?(AST.literal(nil))
      assert AST.nil_literal?(nil)
      refute AST.nil_literal?(AST.literal(0))
      assert AST.key_atom({:__block__, [], [:do]}) == :do
      assert AST.key_atom(:do) == :do
      assert AST.key_atom(AST.literal(1)) == nil
    end
  end
end
