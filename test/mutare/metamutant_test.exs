defmodule Mutare.MetamutantTest do
  use ExUnit.Case, async: true

  alias Mutare.{Metamutant, Selector}

  describe "subject_ast/0 and subject?/1" do
    test "subject_ast/0 builds the persistent_term.get node Transform splices in" do
      # Literal args are block-wrapped (clean-meta) so the node renders cleanly in
      # any position, including a lifted dispatcher's match RHS.
      assert Metamutant.subject_ast() ==
               {{:., [], [:persistent_term, :get]}, [],
                [{:__block__, [], [Selector.key()]}, {:__block__, [], [Selector.baseline()]}]}
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

      # A `<mod>.get(:mutare_active, 0)` whose module isn't `:persistent_term` must
      # be rejected — pins the `unwrap(mod) == :persistent_term` half of the guard,
      # which a `→ true` mutation would otherwise leave a (covered) survivor.
      refute Metamutant.subject?({{:., [], [:ets, :get]}, [], [Selector.key(), 0]})

      refute Metamutant.subject?(
               {{:., [], [{:__block__, [], [:persistent_term]}, :get]}, [],
                [{:__block__, [], [:other_key]}, {:__block__, [], [0]}]}
             )

      refute Metamutant.subject?({:foo, [], [1, 2]})
      refute Metamutant.subject?(:not_a_node)
    end

    test "subject?/2 recognises the hoisted bare-variable subject only when var is given" do
      # The hoisted read is a bare reference to the dispatch variable. Recognised only
      # when the (per-file, possibly salted) name is supplied — so a user's `case x do`
      # is never mistaken for a selector.
      assert Metamutant.subject?({:mutare_active, [line: 5], nil}, :mutare_active)
      assert Metamutant.subject?({:mutare_active_0, [], nil}, :mutare_active_0)

      # Without a var, only the inline `:persistent_term` read is a subject.
      refute Metamutant.subject?({:mutare_active, [], nil})
      # A different variable name (a user's scrutinee) is not the selector subject.
      refute Metamutant.subject?({:some_user_var, [], nil}, :mutare_active)
      # A call (`foo()`, list-context) is not a bare variable.
      refute Metamutant.subject?({:mutare_active, [], []}, :mutare_active)
    end

    test "pattern_subject?/2 recognises a tupled subject with either first element" do
      # The inline form (var-less) and the hoisted form (bare variable) both qualify a
      # tuple-the-scrutinee `case {<active>, <subject>}`.
      assert Metamutant.pattern_subject?({Metamutant.subject_ast(), {:x, [], nil}})

      assert Metamutant.pattern_subject?(
               {{:mutare_active, [], nil}, {:x, [], nil}},
               :mutare_active
             )

      refute Metamutant.pattern_subject?({{:mutare_active, [], nil}, {:x, [], nil}})
    end
  end
end
