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

    test "non-string literals get fresh meta (so they render from the value)" do
      assert AST.literal(:ok) == {:__block__, [], [:ok]}
      assert Sourceror.to_string(AST.literal(42)) == "42"
    end

    test "numeric literals carry a token derived from the new value" do
      # The formatter fetches token metadata for every numeric literal; without one,
      # rendering can raise when the literal is woven into already-parsed source.
      assert AST.literal(0) == {:__block__, [token: "0"], [0]}
      assert AST.literal(1.5) == {:__block__, [token: "1.5"], [1.5]}
      assert AST.literal(-3) == {:-, [], [{:__block__, [token: "3"], [3]}]}

      # The reproduction: splice a fresh int into parsed source carrying line meta.
      original = Sourceror.parse_string!("def q, do: from(u in U, where: u.age > 1)")

      replaced =
        Macro.postwalk(original, fn
          {:__block__, meta, [1]} when is_list(meta) -> AST.literal(5)
          node -> node
        end)

      assert Sourceror.to_string(replaced) == "def q, do: from(u in U, where: u.age > 5)"
    end
  end

  describe "the emission constructors" do
    test "keyword_key/1 builds a key node the renderer emits as `key:`" do
      key = AST.keyword_key(:limit)
      assert key == {:__block__, [format: :keyword], [:limit]}
      assert AST.keyword_label?(key)
      assert Sourceror.to_string([{key, AST.literal(1)}]) == "[limit: 1]"
    end

    test "clean_var/1 drops source meta but keeps the hygiene context" do
      assert AST.clean_var({:user, [line: 3, column: 7, token: "user"], nil}) ==
               {:user, [], nil}

      assert AST.clean_var({:user, [line: 3], Some.Context}) == {:user, [], Some.Context}
    end

    test "remote_call/3 wraps a pre-built callee node; absolute_call/3 is the alias-path form" do
      callee = AST.absolute_alias([:Kernel])
      call = AST.remote_call(callee, :==, [AST.literal(1), AST.literal(2)])
      assert call == AST.absolute_call([:Kernel], :==, [AST.literal(1), AST.literal(2)])
      assert Sourceror.to_string(call) == "Elixir.Kernel.==(1, 2)"
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
