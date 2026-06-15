defmodule Mutare.SiteTest do
  use ExUnit.Case, async: true

  alias Mutare.Site

  @range %{start: [line: 2, column: 3], end: [line: 2, column: 20]}

  defp clause, do: Sourceror.parse_string!("def f(_), do: :ok")

  describe "clause_drop/4" do
    test "records a :delete with no mutated node, ops, or code" do
      site = Site.clause_drop(7, "lib/x.ex", @range, clause())

      assert site.id == 7
      assert site.file == "lib/x.ex"
      assert site.line == 2
      assert site.column == 3
      assert site.mutator == :clause_drop
      assert site.kind == :lifted
      assert site.operation == :delete
      assert site.original_op == nil
      assert site.mutated_op == nil
      assert site.mutated_node == nil
      # The clause is removed entirely — there is no replacement text.
      assert site.mutated_code == ""
      assert site.original_code == "def f(_), do: :ok"
    end
  end

  describe "describe/1" do
    test "renders a clause-drop as a (drop) of the original clause" do
      site = Site.clause_drop(7, "lib/x.ex", @range, clause())
      assert Site.describe(site) == "clause_drop  (drop) def f(_), do: :ok"
    end

    test "renders an operator swap as original → mutated" do
      original = {:>=, [], [{:a, [], nil}, {:b, [], nil}]}
      mutated = {:>, [], [{:a, [], nil}, {:b, [], nil}]}
      site = Site.in_place(1, "lib/x.ex", @range, original, mutated, Mutare.Mutators.Relational)

      assert Site.describe(site) == "relational  a >= b → a > b"
    end
  end
end
