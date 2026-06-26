defmodule Mutare.Transform.ClauseASTTest do
  # Direct tests of the clause-shape navigation primitives, focused on the fallback clauses an
  # integration fixture rarely produces (an unguarded clause's `nil` guard, a non-clause input).
  use ExUnit.Case, async: true

  alias Mutare.Transform.ClauseAST

  defp clause(src), do: Sourceror.parse_string!(src)

  describe "clause_when/1" do
    test "returns the when node of a guarded clause" do
      assert {:when, _, _} = ClauseAST.clause_when(clause("def f(a) when a > 0, do: a"))
    end

    test "returns nil for an unguarded clause (the fallback)" do
      assert ClauseAST.clause_when(clause("def f(a), do: a")) == nil
    end
  end

  describe "guards/1" do
    test "the guard list of a guarded clause, [] otherwise" do
      assert [_ | _] = ClauseAST.guards(clause("def f(a) when a > 0 and a < 9, do: a"))
      assert ClauseAST.guards(clause("def f(a), do: a")) == []
    end
  end

  describe "head_args/1" do
    test "the head pattern args of a clause" do
      assert [_a, _b] = ClauseAST.head_args(clause("def f(a, b), do: a"))
      assert ClauseAST.head_args(clause("def f, do: 1")) == []
    end

    test "[] for a non-clause node (the fallback)" do
      assert ClauseAST.head_args(:not_a_clause) == []
    end
  end
end
