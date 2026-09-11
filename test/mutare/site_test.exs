defmodule Mutare.SiteTest do
  use ExUnit.Case, async: true

  alias Mutare.Site

  doctest Mutare.Site

  defmodule DerivingDropVariantMutator do
    @behaviour Mutare.Mutator

    @impl Mutare.Mutator
    def name, do: :deriving_drop_variant

    @impl Mutare.Mutator
    def variants, do: ~w(derived)

    @impl Mutare.Mutator
    def variant(_original, _mutated), do: "derived"
  end

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
      # The clause is removed entirely — there is no replacement text.
      assert site.mutated_code == ""
      assert site.original_code == "def f(_), do: :ok"
    end
  end

  describe "comment metadata in the rendered code" do
    # Sourceror parks each comment on one node — a trailing `# …` on the leftmost *leaf* of its
    # line, a comment before `end` on the enclosing `def` — and renders whatever a subtree
    # carries. The code fields are the source *at the site*, and a swap reuses the original's
    # operands, so without `AST.strip_comments/1` both fields leak it (and the report, which
    # splices `mutated_code` over the range, would show the directive twice).
    test "a trailing `# mutare:ignore` on a comparison in a multi-line chain is not rendered" do
      source = """
      defmodule Mutare.SiteCommentFixture do
        def f(a, b, x, y) do
          a > x and # mutare:ignore[relational:<]
            b > y
        end
      end
      """

      %{sites: sites} =
        Mutare.Transform.transform_string_with_sites(source,
          mutators: [Mutare.Mutators.Relational, Mutare.Mutators.Logical]
        )

      codes = Enum.map(sites, &{&1.mutator, &1.original_code, &1.mutated_code})

      # The leaf-parked comment would surface at every ancestor: the comparison and the chain.
      assert {:relational, "a > x", "a >= x"} in codes
      assert {:logical, "a > x and\n  b > y", "a > x or\n  b > y"} in codes
      refute Enum.any?(codes, fn {_, original, mutated} -> original <> mutated =~ "#" end)
    end

    test "a comment before a dropped clause's `end` is not rendered" do
      clause = Sourceror.parse_string!("def f(x) do\n  x\n  # trailing\nend")
      site = Site.clause_drop(7, "lib/x.ex", @range, clause)

      assert site.original_code == "def f(x) do\n  x\nend"
    end
  end

  describe "in_place_drop/6 variant threading" do
    # An attribution `at_drop/1` (a whole-node rewrite reported as a clause deletion — e.g.
    # mutare_ecto's filter/bound drop) must carry its family/kind label onto the delete Site, so a
    # `# mutare:ignore[family:label]` keyed on the clause line can suppress it, just like a replace.
    test "threads and normalizes a carried variant label onto the delete site" do
      spec = Mutare.Mutator.Spec.for_module(Mutare.Mutators.Relational)
      site = Site.in_place_drop(1, "lib/x.ex", @range, clause(), spec, variant: ["Bound"])
      assert site.variant == ["bound"]
    end

    test "defaults to no label when the drop carries no variant" do
      spec = Mutare.Mutator.Spec.for_module(Mutare.Mutators.Relational)
      site = Site.in_place_drop(1, "lib/x.ex", @range, clause(), spec)
      assert site.variant == []
    end

    test "treats an explicit nil variant as no carried label for a drop" do
      spec = Mutare.Mutator.Spec.for_module(DerivingDropVariantMutator)
      site = Site.in_place_drop(1, "lib/x.ex", @range, clause(), spec, variant: nil)

      assert site.variant == []
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

    test "tolerates a non-tuple original/mutated (a bare keyword-list clause value)" do
      # A whole-node rewrite may attribute its site to a clause value that is a bare list — e.g.
      # `mutare_ecto` flipping an `order_by: [asc: p.id]` value via `Mutation.at/2`. Such a node
      # has no head tag, so the `*_form` fields record `nil` rather than crashing on `elem/2`.
      # A bare list, as an inner `order_by:` value is — not the `{:__block__, …}` a standalone
      # parse would wrap it in (which is itself a tuple and never hit the crash).
      {:__block__, _, [original]} = Sourceror.parse_string!("[asc: p.id]")
      {:__block__, _, [mutated]} = Sourceror.parse_string!("[desc: p.id]")
      spec = Mutare.Mutator.Spec.for_module(Mutare.Mutators.Relational)

      site = Site.in_place(1, "lib/x.ex", @range, original, mutated, spec)

      assert site.original_form == nil
      assert site.mutated_form == nil
      assert site.original_code == "[asc: p.id]"
      assert site.mutated_code == "[desc: p.id]"
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

  describe "rendered code width" do
    # `Sourceror.to_string/1` re-flows at 98 columns from column 0, blind to the splice column;
    # a one-line range must not come back multi-line (the report's `-` side is source bytes and
    # stays one line). A multi-line range keeps the default width.
    setup do
      long = fn op ->
        Sourceror.parse_string!(
          "(user_record.enabled and account_settings.active and " <>
            "notification_preferences.email_allowed) #{op} user_record.age > 18"
        )
      end

      %{
        original: long.("and"),
        mutated: long.("or"),
        spec: Mutare.Mutator.Spec.for_module(Mutare.Mutators.Logical)
      }
    end

    test "a single-line range renders without fits-based line breaks", ctx do
      range = %{start: [line: 3, column: 5], end: [line: 3, column: 120]}
      site = Site.in_place(1, "p.ex", range, ctx.original, ctx.mutated, ctx.spec)

      refute site.original_code =~ "\n"
      refute site.mutated_code =~ "\n"
      assert String.length(site.mutated_code) > 98
    end

    test "a multi-line range keeps the default 98-column width", ctx do
      range = %{start: [line: 3, column: 5], end: [line: 4, column: 30]}
      site = Site.in_place(1, "p.ex", range, ctx.original, ctx.mutated, ctx.spec)

      assert site.mutated_code =~ "\n"
    end

    test "a single-line range still keeps forced (structural) breaks" do
      range = %{start: [line: 3, column: 5], end: [line: 3, column: 40]}
      original = Sourceror.parse_string!("case x do 1 -> :a; 2 -> :b end")
      spec = Mutare.Mutator.Spec.for_module(Mutare.Mutators.ReturnValue)

      site = Site.return_value(1, "p.ex", range, original, Mutare.AST.literal(:mutare), spec)

      assert site.original_code == "case x do\n  1 -> :a\n  2 -> :b\nend"
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

  describe "live summary (summary?: true)" do
    setup do
      original = {:>=, [], [{:a, [], nil}, {:b, [], nil}]}
      mutated = {:>, [], [{:a, [], nil}, {:b, [], nil}]}

      %{
        spec: Mutare.Mutator.Spec.for_module(Mutare.Mutators.Relational),
        original: original,
        mutated: mutated
      }
    end

    test "builds the cheap Macro one-liner for a replacement", %{
      spec: spec,
      original: o,
      mutated: m
    } do
      site = Site.in_place(1, "lib/x.ex", @range, o, m, spec, summary?: true)
      assert site.summary == "relational  a >= b → a > b"
    end

    test "is off by default — no summary unless requested", %{spec: spec, original: o, mutated: m} do
      assert Site.in_place(1, "lib/x.ex", @range, o, m, spec).summary == nil
      assert Site.lifted_replace(1, "lib/x.ex", @range, o, m, spec).summary == nil
    end

    test "can be built independently of the Sourceror *_code (the deferred-scan case)",
         %{spec: spec, original: o, mutated: m} do
      # render?: false leaves *_code nil (deferred), but summary?: true still renders the live line.
      site = Site.in_place(1, "lib/x.ex", @range, o, m, spec, render?: false, summary?: true)
      assert site.original_code == nil
      assert site.mutated_code == nil
      assert site.summary == "relational  a >= b → a > b"
    end

    test "renders a return-value constant swap with the real tail expression" do
      spec = Mutare.Mutator.Spec.for_module(Mutare.Mutators.ReturnValue)
      tail = Sourceror.parse_string!("compute(a) + offset")
      empty = Mutare.AST.literal(0)
      site = Site.return_value(1, "lib/x.ex", @range, tail, empty, spec, summary?: true)
      assert site.summary == "return_value  compute(a) + offset → 0"
    end

    test "renders a clause drop as a (drop), collapsing a multi-line clause to one line" do
      node = Sourceror.parse_string!("def f(0) do\n  :z\nend")
      site = Site.clause_drop(1, "lib/x.ex", @range, node, summary?: true)
      refute site.summary =~ "\n"
      assert site.summary == "clause_drop  (drop) def f(0) do :z end"
    end
  end

  describe "summary_line/1" do
    test "prefers the summary when present" do
      site = %Site{mutator: :relational, summary: "relational  a >= b → a > b"}
      assert Site.summary_line(site) == "relational  a >= b → a > b"
    end

    test "falls back to describe/1 when there is no summary (the eager / hydrated site)" do
      site = %Site{
        mutator: :relational,
        operation: :replace,
        original_code: "a >= b",
        mutated_code: "a > b"
      }

      assert Site.summary_line(site) == "relational  a >= b → a > b"
    end

    test "does not crash on a wholly un-rendered site (regression: String.replace(nil, …))" do
      # A deferred scan under --quiet builds neither summary nor *_code. The reporter owns the
      # terminal, so reaching this site must never raise — it degrades to a bare mutator label.
      site = %Site{
        mutator: :return_value,
        operation: :replace,
        summary: nil,
        original_code: nil,
        mutated_code: nil
      }

      assert Site.summary_line(site) == "return_value   → "
    end
  end
end
