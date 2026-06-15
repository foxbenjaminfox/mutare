defmodule Mutare.MetamutantTest do
  use ExUnit.Case, async: true

  alias Mutare.{Metamutant, Selector}

  describe "subject_ast/0 and subject?/1" do
    test "subject_ast/0 builds the persistent_term.get node Transform splices in" do
      assert Metamutant.subject_ast() ==
               {{:., [], [:persistent_term, :get]}, [], [Selector.key(), Selector.baseline()]}
    end

    test "subject?/1 recognises the subject regardless of metadata" do
      assert Metamutant.subject?(Metamutant.subject_ast())

      # A parsed selector carries line/column metadata; the predicate ignores it.
      with_meta = {{:., [line: 2], [:persistent_term, :get]}, [line: 2], [Selector.key(), 0]}
      assert Metamutant.subject?(with_meta)
    end

    test "subject?/1 sees through Sourceror's :__block__ literal wrapping" do
      # `Mutare.Manifest` re-parses the rendered metamutant with Sourceror, which
      # wraps every literal — so `:persistent_term` and the key arrive wrapped.
      wrapped =
        {{:., [], [{:__block__, [], [:persistent_term]}, :get]}, [],
         [{:__block__, [], [Selector.key()]}, {:__block__, [], [Selector.baseline()]}]}

      assert Metamutant.subject?(wrapped)
    end

    test "subject?/1 rejects a different key and non-selectors" do
      refute Metamutant.subject?({{:., [], [:persistent_term, :get]}, [], [:other_key, 0]})

      refute Metamutant.subject?(
               {{:., [], [{:__block__, [], [:persistent_term]}, :get]}, [],
                [{:__block__, [], [:other_key]}, {:__block__, [], [0]}]}
             )

      refute Metamutant.subject?({:foo, [], [1, 2]})
      refute Metamutant.subject?(:not_a_node)
    end
  end
end
