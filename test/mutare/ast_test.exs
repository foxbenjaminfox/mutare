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
    test "empty_collection_literal?/1 recognises guard-legal empty collection literals" do
      assert AST.empty_collection_literal?(AST.literal([]))
      assert AST.empty_collection_literal?(Sourceror.parse_string!("~w()"))
      assert AST.empty_collection_literal?(Sourceror.parse_string!(~S|~c""|))
      refute AST.empty_collection_literal?({:%{}, [], []})
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

    test "empty_collection_literal?/1 also recognises a bare empty list" do
      # The bare `[]` clause (an integration site always arrives `{:__block__, _, [[]]}`-wrapped).
      assert AST.empty_collection_literal?([])
    end
  end

  describe "opts_get/3" do
    test "returns the value for a present key, the default otherwise" do
      opts = [{:a, 1}, {:b, 2}]
      assert AST.opts_get(opts, :a) == 1
      assert AST.opts_get(opts, :missing, :fallback) == :fallback
    end

    test "ignores a non-pair entry in the list (the fallback clause)" do
      assert AST.opts_get([:junk, {:a, 1}], :a) == 1
      assert AST.opts_get([:junk], :a, :default) == :default
    end
  end

  describe "update_do_block/2" do
    test "maps over the :do entry, passing non-:do entries and non-pairs through" do
      assert AST.update_do_block([:junk, {:do, 1}, {:other, 2}], &(&1 + 10)) ==
               [:junk, {:do, 11}, {:other, 2}]
    end

    test "a non-keyword node is returned unchanged (the fallback)" do
      assert AST.update_do_block(:not_a_list, & &1) == :not_a_list
    end
  end

  describe "update_do_block_reduce/3" do
    test "threads an accumulator through the :do entry, passing the rest through" do
      assert {result, acc} =
               AST.update_do_block_reduce([:junk, {:do, 1}, {:other, 2}], 0, fn v, a ->
                 {v + 10, a + 1}
               end)

      assert result == [:junk, {:do, 11}, {:other, 2}]
      assert acc == 1
    end

    test "a non-keyword node returns {node, acc} unchanged (the fallback)" do
      assert AST.update_do_block_reduce(:not_a_list, 5, fn v, a -> {v, a} end) == {:not_a_list, 5}
    end
  end
end
