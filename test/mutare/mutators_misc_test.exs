defmodule Mutare.MutatorsMiscTest do
  # Direct calls into the fallback/edge clauses of a few small mutator and helper modules.
  # These arms are correctness-relevant (a wrong fallback would mis-mutate or crash) but are
  # only reached by inputs the integration fixtures don't naturally produce.
  use ExUnit.Case, async: true

  alias Mutare.Mutators.{Conditional, DateTimeLiteral, Helpers, StringCall}
  alias Mutare.Mutator.Spec

  describe "Conditional.boolean_op?/1" do
    test "true for a boolean operator atom, false for anything else" do
      assert Conditional.boolean_op?(:and)
      assert Conditional.boolean_op?(:==)
      # the non-atom fallback clause
      refute Conditional.boolean_op?(123)
      refute Conditional.boolean_op?("and")
      refute Conditional.boolean_op?({:and, [], []})
    end
  end

  describe "StringCall.mutate/1" do
    test "skips a String.equivalent? call whose arity isn't 1 or 2 (the substitution fallback)" do
      # `equivalent_substitution/1` only rewrites the /1 (piped) and /2 forms; any other arity
      # falls through to `:skip` rather than emitting a malformed `==`.
      node = Sourceror.parse_string!("String.equivalent?(a, b, c)")
      assert StringCall.mutate(node) == :skip
    end
  end

  describe "DateTimeLiteral.mutate/1" do
    test "skips a sigil whose content does not parse as a date (no invalid source)" do
      # A syntactically-valid sigil with an unparseable value: `Date.from_iso8601` fails, so the
      # mutator degrades to `:skip` instead of producing an invalid literal.
      node = {:sigil_D, [], [{:<<>>, [], ["2020-99-99"]}, []]}
      assert DateTimeLiteral.mutate(node) == :skip
    end
  end

  describe "Helpers.removed_call/2" do
    test "a piped removal becomes Function.identity/1" do
      [call] = Helpers.removed_call(:piped, [{:x, [], nil}])
      assert Sourceror.to_string(call) == "Elixir.Function.identity()"
    end

    test "an unpiped zero-arg call has nothing to return → :skip" do
      assert Helpers.removed_call(:unpiped, []) == :skip
    end

    test "an unpiped call returns its first argument" do
      assert Helpers.removed_call(:unpiped, [:first, :second]) == [:first]
    end
  end

  describe "Mutator.Spec.configured/2" do
    test "non-keyword opts are carried verbatim and the name comes from the module" do
      spec = Spec.configured(Mutare.Mutators.Arithmetic, %{custom: 1})

      assert spec.module == Mutare.Mutators.Arithmetic
      assert spec.name == :arithmetic
      assert spec.opts == %{custom: 1}
    end
  end
end
