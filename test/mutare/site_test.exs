defmodule Mutare.SiteTest do
  use ExUnit.Case, async: true

  alias Mutare.Site

  doctest Mutare.Site

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
      assert site.original_form == nil
      assert site.mutated_form == nil
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
      spec = Mutare.Mutator.Spec.for_module(Mutare.Mutators.Relational)
      site = Site.in_place(1, "lib/x.ex", @range, original, mutated, spec)

      assert Site.describe(site) == "relational  a >= b → a > b"
    end

    test "collapses multi-line code to a single line (the activity line is one row)" do
      # A multi-line node (e.g. a dropped `case` clause) renders as multi-line code;
      # describe/1 must flatten it, or an embedded newline breaks the live block's
      # cursor accounting and leaves the description on screen after it moves on.
      site = %Site{
        mutator: :return_value,
        operation: :replace,
        original_code: "case x do\n  1 -> :a\n  2 -> :b\nend",
        mutated_code: ":mutare"
      }

      described = Site.describe(site)

      refute described =~ "\n"
      assert described == "return_value  case x do 1 -> :a 2 -> :b end → :mutare"
    end

    test "leaves spaces within a line (e.g. inside a string literal) intact" do
      site = %Site{
        mutator: :string_literal,
        operation: :replace,
        original_code: ~s("a  b"),
        mutated_code: ~s("")
      }

      assert Site.describe(site) == ~s(string_literal  "a  b" → "")
    end

    test "trims edge whitespace left after collapsing newlines" do
      # A node rendered with leading indentation or a trailing newline leaves
      # stray edge whitespace once the newlines collapse to spaces; one_line
      # trims it so the one-liner has no leading/trailing padding.
      site = %Site{
        mutator: :return_value,
        operation: :replace,
        original_code: "  foo\n  bar\n",
        mutated_code: "  :mutare  "
      }

      assert Site.describe(site) == "return_value  foo bar → :mutare"
    end
  end

  describe "lifted_replace/6 (no note)" do
    test "records a :lifted replacement with note nil" do
      original = {:>=, [], [{:a, [], nil}, {:b, [], nil}]}
      mutated = {:>, [], [{:a, [], nil}, {:b, [], nil}]}
      spec = Mutare.Mutator.Spec.for_module(Mutare.Mutators.Relational)

      site = Site.lifted_replace(8, "lib/x.ex", @range, original, mutated, spec)

      assert site.id == 8
      assert site.file == "lib/x.ex"
      assert site.kind == :lifted
      assert site.mutator == :relational
      assert site.note == nil
      assert site.original_code == "a >= b"
      assert site.mutated_code == "a > b"
    end
  end
end
