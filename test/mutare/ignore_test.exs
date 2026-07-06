# Stub mutators exercising the variant opt-in contract (`Mutare.Mutator.Dispatch.opted_in?/1`): a
# mutator opts in by exporting `variants/0` (the vocabulary); it then assigns labels either via the
# `variant/2` callback or by tagging each `%Mutare.Mutator.Mutation{}` at production time.
defmodule Mutare.IgnoreTest.BothVariantMutator do
  # Vocabulary + the `variant/2` derivation path — opted in.
  @behaviour Mutare.Mutator
  def name, do: :both_variant
  def mutate(_node), do: :skip
  def variants, do: ~w(a b)
  def variant(_original, _mutated), do: "a"
end

defmodule Mutare.IgnoreTest.VocabOnlyMutator do
  # Declares the vocabulary but no `variant/2` — opted in (its mutations would tag at production via
  # `Mutare.Mutator.Mutation.tagged/2`). The vocabulary is exposed; how labels are assigned is an
  # implementation detail.
  @behaviour Mutare.Mutator
  def name, do: :vocab_only
  def mutate(_node), do: :skip
  def variants, do: ~w(a b)
end

defmodule Mutare.IgnoreTest.NoVocabMutator do
  # Exports `variant/2` but NO `variants/0` — *not* opted in: it declares no vocabulary, so any
  # label it produced would validate against nothing. Treated uniformly as bare-only (`:none`).
  @behaviour Mutare.Mutator
  def name, do: :no_vocab
  def mutate(_node), do: :skip
  def variant(_original, _mutated), do: "a"
end

defmodule Mutare.IgnoreTest.EmptyLabelVariantMutator do
  # Declares an EMPTY-string variant label — a mutator-authoring bug: `[empty_label:]` resolves to
  # the malformed empty-label entry that matches nothing, so an empty declared label could never be
  # selected. `Mutare.Mutators.vocabulary/1` must reject it as wire-unsafe, not produce it silently.
  @behaviour Mutare.Mutator
  def name, do: :empty_label
  def mutate(_node), do: :skip
  def variants, do: ["", "ok"]
  def variant(_original, _mutated), do: "ok"
end

defmodule Mutare.IgnoreTest do
  @moduledoc "`# mutare:ignore` suppresses a mutant: not run, out of the denominator."
  use ExUnit.Case, async: false

  alias Mutare.Result
  alias Mutare.Test.Project

  describe "transform marking" do
    test "a trailing comment ignores its line; a standalone ignores the next line" do
      source = """
      defmodule Ig do
        def a(x), do: x + 1   # mutare:ignore
        def b(x), do: x + 1
        # mutare:ignore
        def c(x), do: x + 2
      end
      """

      {meta, sites, _next_id} = Mutare.Transform.transform_string_with_sites(source)
      ignored? = Map.new(sites, &{&1.line, &1.ignored})

      assert ignored?[2] == true
      assert ignored?[3] == false
      assert ignored?[5] == true

      # ignored sites are still recorded (for the denominator), and the
      # metamutant still compiles.
      assert {:ok, _} = Code.string_to_quoted(meta)
    end

    test "a standalone directive reads through a comment block to the code below" do
      # The natural way to write a long justification is directive-first,
      # explanation continuing below — the directive must reach the code line.
      source = """
      defmodule Ig do
        # mutare:ignore[arithmetic] the +1 is a cursor advance;
        # any off-by-one here is caught by the property test
        def a(x), do: x + 1
      end
      """

      {_meta, sites, _next_id} = Mutare.Transform.transform_string_with_sites(source)

      arithmetic = Enum.filter(sites, &(&1.mutator == :arithmetic))
      assert arithmetic != []
      assert Enum.all?(arithmetic, & &1.ignored)

      assert Enum.all?(
               arithmetic,
               &(&1.ignore_reason ==
                   "the +1 is a cursor advance;")
             )
    end

    test "a trailing reason is captured on the site and suppresses the whole line" do
      source = """
      defmodule Ig do
        def a(x), do: x + 1   # mutare:ignore equivalent under integer math
      end
      """

      {_meta, sites, _next_id} = Mutare.Transform.transform_string_with_sites(source)

      assert sites != []
      assert Enum.all?(sites, & &1.ignored)
      assert Enum.all?(sites, &(&1.ignore_reason == "equivalent under integer math"))
    end

    test "a `[family]` filter suppresses only that family; siblings still run" do
      source = """
      defmodule Ig do
        def a(x), do: x + 1 > 2   # mutare:ignore[arithmetic] adding 1 is noise
      end
      """

      {_meta, sites, _next_id} = Mutare.Transform.transform_string_with_sites(source)
      by_mutator = Enum.group_by(sites, & &1.mutator)

      # The arithmetic mutant is ignored (with its reason)...
      assert Enum.all?(by_mutator[:arithmetic], & &1.ignored)
      assert Enum.all?(by_mutator[:arithmetic], &(&1.ignore_reason == "adding 1 is noise"))

      # ...while relational/conditional/literal mutants on the same line still run.
      others = Enum.flat_map(~w(relational conditional literal)a, &(by_mutator[&1] || []))
      assert others != []
      refute Enum.any?(others, & &1.ignored)
    end

    test "a `[a, b]` filter suppresses each listed family" do
      source = """
      defmodule Ig do
        def a(x), do: x + 1 > 2   # mutare:ignore[arithmetic, relational]
      end
      """

      {_meta, sites, _next_id} = Mutare.Transform.transform_string_with_sites(source)
      ignored = Enum.group_by(sites, & &1.ignored, & &1.mutator)

      assert MapSet.new(ignored[true]) == MapSet.new([:arithmetic, :relational])
      refute Enum.empty?(ignored[false])
    end

    test "a `[family:result]` qualifier suppresses one mutant, not the whole family" do
      # A qualifier targets exactly one of a family's variants: `[relational:>]`
      # suppresses only the `i > j` swap, while `i <= j` (and the rest of the family)
      # still runs. Ignoring the whole `[relational]` would lose both.
      source = """
      defmodule Ig do
        def f(i, j), do: i < j   # mutare:ignore[relational:>] reviewed
      end
      """

      {_meta, sites, _next_id} = Mutare.Transform.transform_string_with_sites(source)
      relational = Enum.filter(sites, &(&1.mutator == :relational))
      ignored? = Map.new(relational, &{&1.mutated_form, &1.ignored})

      # Both relational mutants exist; only the `>` swap is suppressed.
      assert ignored?[:>] == true
      assert ignored?[:<=] == false

      ignored = Enum.filter(relational, & &1.ignored)
      assert Enum.all?(ignored, &(&1.ignore_reason == "reviewed"))
    end

    test "a semantic label (not an operator) suppresses just that mutation kind" do
      # `return_value` declares the *semantic* labels `empty`/`sentinel`, not a rendered
      # value — so `[return_value:empty]` names the `nil`/`0`/`[]`/`""` half while the
      # `sentinel` half still runs. (The raw `[]` result could never be a filter token.)
      source = """
      defmodule Ig do
        def g(x), do: build(x)   # mutare:ignore[return_value:empty] presence is enough
      end
      """

      {_meta, sites, _next_id} = Mutare.Transform.transform_string_with_sites(source)
      returns = Enum.filter(sites, &(&1.mutator == :return_value))
      # Each return_value mutant carries exactly one label (`empty`/`sentinel` are disjoint).
      ignored? = Map.new(returns, &{List.first(&1.variant), &1.ignored})

      assert ignored?["empty"] == true
      assert ignored?["sentinel"] == false
    end

    test "an unknown family in a filter fails safe: it suppresses nothing" do
      source = """
      defmodule Ig do
        def a(x), do: x + 1   # mutare:ignore[arithmetc]
      end
      """

      {_meta, sites, _next_id} = Mutare.Transform.transform_string_with_sites(source)

      # Typo'd family matches no mutator, so the mutant runs rather than hides.
      refute Enum.any?(sites, & &1.ignored)
    end

    test "a [regex:laziness] qualifier suppresses only the lazy-suffix mutants" do
      source = """
      defmodule Ig do
        def scrub(s), do: Regex.replace(~r/a+b/, s, "")   # mutare:ignore[regex:laziness]
      end
      """

      {_meta, sites, _next_id} = Mutare.Transform.transform_string_with_sites(source)

      regex = Enum.filter(sites, &(&1.mutator == :regex))
      {lazy, others} = Enum.split_with(regex, &("laziness" in &1.variant))

      assert lazy != []
      assert Enum.all?(lazy, & &1.ignored)
      assert others != []
      refute Enum.any?(others, & &1.ignored)
    end

    test "an unknown [regex:<label>] is a hard error listing the regex vocabulary" do
      # RegexLiteral declares variants now, so a wrong label on it is a *certain*
      # mistake — a SpecError with a did-you-mean, not a silent no-op.
      source = """
      defmodule Ig do
        def f(s), do: Regex.match?(~r/a+/, s)  # mutare:ignore[regex:lazyness]
      end
      """

      error =
        assert_raise Mutare.Ignore.SpecError, fn ->
          Mutare.Transform.transform_string_with_sites(source)
        end

      assert error.message =~ ~s(did you mean "laziness"?)
      assert error.message =~ "quantifier"
    end

    test "a string literal that reads like the directive is not a directive" do
      # Directives come from parsed comment metadata, not a raw-text scan, so a
      # string that merely *contains* `# mutare:ignore` suppresses nothing.
      source = """
      defmodule Ig do
        def a(x), do: x + String.length("# mutare:ignore")
      end
      """

      # Pin to arithmetic so the lone site is the `+`; the default string mutator
      # would otherwise also mutate the "# mutare:ignore" *string literal*, which
      # is beside the point here (this test is about the comment directive).
      {_meta, sites, _next_id} =
        Mutare.Transform.transform_string_with_sites(source,
          mutators: [Mutare.Mutators.Arithmetic]
        )

      assert [%{line: 2, ignored: false}] = sites
    end
  end

  describe "directive parsing" do
    alias Mutare.Ignore
    alias Mutare.Ignore.Directive
    alias Mutare.Ignore.Directives

    test "a bare directive admits every mutator and carries no reason" do
      directives = Ignore.directives("x = 1 # mutare:ignore")
      assert %Directive{line: 1, mutators: :all, reason: nil} = directive_on(directives, 1)
      assert Ignore.directive_for(directives, 1, :anything)
    end

    test "directives/1 requires a binary (rejects a non-string source)" do
      assert_raise FunctionClauseError, fn -> Ignore.directives(:not_a_string) end
    end

    test "a directive trailing a block's closing `end` is found via Sourceror's :trailing_comments bucket" do
      # Almost every other trailing directive in this suite is, per Sourceror, actually a
      # *leading* comment of the following token (`x = 1 # mutare:ignore` attaches to the next
      # node with `previous_eol_count: 0`) — `previous_eol_count` is what marks it "trailing",
      # not which bucket it lands in (see `comments/1`'s moduledoc note). A comment after a
      # block's closing `end`, with nothing following it in the file, is the one shape that
      # really does land in Sourceror's `:trailing_comments` — exercising that code path for
      # real (rather than `:leading_comments` alone, which every other test here happens to hit).
      source = "if true do\n  1\nend # mutare:ignore\n"
      directives = Ignore.directives(source)
      assert %Directive{line: 3, mutators: :all} = directive_on(directives, 3)
    end

    test "a `[...]` filter only admits the listed mutators" do
      directives = Ignore.directives("x = 1 # mutare:ignore[arithmetic, literal]")

      assert Ignore.directive_for(directives, 1, :arithmetic)
      assert Ignore.directive_for(directives, 1, :literal)
      refute Ignore.directive_for(directives, 1, :relational)
    end

    test "the filter also matches non-family mutator names (clause_drop, custom)" do
      directives = Ignore.directives("x = 1 # mutare:ignore[clause_drop]")
      assert Ignore.directive_for(directives, 1, :clause_drop)
    end

    test "a reason survives alongside a filter" do
      directives = Ignore.directives("x = 1 # mutare:ignore[arithmetic]  documented on purpose")
      assert %Directive{reason: "documented on purpose"} = directive_on(directives, 1)
    end

    test "an empty `[]` filter admits nothing (fail-safe)" do
      directives = Ignore.directives("x = 1 # mutare:ignore[]")
      refute Ignore.directive_for(directives, 1, :arithmetic)
    end

    test "whitespace between the keyword and the `[` filter is tolerated" do
      # `# mutare:ignore [arithmetic]` (space before the bracket) is still a
      # filter, not a `:all` directive whose reason happens to start with `[`.
      directives = Ignore.directives("x = 1 # mutare:ignore [arithmetic] spaced out")

      assert %Directive{mutators: set, reason: "spaced out"} = directive_on(directives, 1)
      assert set == MapSet.new([{"arithmetic", :any}])
      assert Ignore.directive_for(directives, 1, :arithmetic)
      # The `:all` fallback would admit *every* family; the filter must not.
      refute Ignore.directive_for(directives, 1, :relational)
    end

    test "stray separators in the filter normalize away (no empty members)" do
      # A trailing comma/space must not leave a spurious `""` in the set.
      directives = Ignore.directives("x = 1 # mutare:ignore[arithmetic, ]")

      assert %Directive{mutators: set} = directive_on(directives, 1)
      assert set == MapSet.new([{"arithmetic", :any}])
    end

    test "family names in the filter are matched case-insensitively" do
      directives = Ignore.directives("x = 1 # mutare:ignore[ARITHMETIC]")
      assert %Directive{mutators: set} = directive_on(directives, 1)
      assert set == MapSet.new([{"arithmetic", :any}])
      assert Ignore.directive_for(directives, 1, :arithmetic)
    end

    test "a `[family:result]` qualifier admits only the matching result" do
      directives = Ignore.directives("x = 1 # mutare:ignore[relational:>]")
      assert %Directive{mutators: set} = directive_on(directives, 1)
      assert set == MapSet.new([{"relational", ">"}])

      # The `>` result is suppressed; the sibling `<=` (and the family at large) is not.
      assert Ignore.directive_for(directives, 1, :relational, [">"])
      refute Ignore.directive_for(directives, 1, :relational, ["<="])
      # ...but the family-level query (no result in hand) still finds it.
      assert Ignore.directive_for(directives, 1, :relational)
    end

    test "a multi-character label keeps the operator intact (split on the first `:` only)" do
      # `!==`/`>=` have no internal whitespace, so the split-on-`:` only fires once.
      directives = Ignore.directives("x = 1 # mutare:ignore[relational:!==, relational:>=]")
      assert %Directive{mutators: set} = directive_on(directives, 1)
      assert set == MapSet.new([{"relational", "!=="}, {"relational", ">="}])
    end

    test "a label containing a colon is split only on the FIRST `:` (parts: 2, not 3)" do
      # `parse_entry/1` splits on `:` with `parts: 2` precisely so a label itself containing a
      # `:` stays whole as everything after the first colon — `String.split(token, ":", parts:
      # 3)` would instead produce 3 pieces here, which matches neither `[family]` nor
      # `[family, label]` and would raise `CaseClauseError`.
      directives = Ignore.directives("x = 1 # mutare:ignore[custom:A:B]")
      assert %Directive{mutators: set} = directive_on(directives, 1)
      assert set == MapSet.new([{"custom", "a:b"}])
    end

    test "qualified and bare entries of the same family coexist" do
      directives = Ignore.directives("x = 1 # mutare:ignore[arithmetic, relational:>]")
      assert Ignore.directive_for(directives, 1, :arithmetic, ["-"])
      assert Ignore.directive_for(directives, 1, :relational, [">"])
      refute Ignore.directive_for(directives, 1, :relational, ["<="])
    end

    test "a malformed empty-label qualifier ([family:]) suppresses nothing, not the whole family" do
      # A trailing colon (`[relational:]`) or a stray space after the colon (`[relational: >]`)
      # must NOT silently collapse to a bare whole-family suppression — that would hide every
      # mutant the user meant to keep. The empty-label entry matches no real variant instead.
      for body <- ["relational:", "relational: >"] do
        directives = Ignore.directives("x = i < j # mutare:ignore[#{body}]")

        refute Ignore.directive_for(directives, 1, :relational, [">"]),
               "[#{body}] wrongly suppressed the > mutant"

        refute Ignore.directive_for(directives, 1, :relational, ["<="]),
               "[#{body}] wrongly suppressed the <= mutant"

        # ...and not even the *family-level* (`:any`) query: an empty-label entry suppresses
        # nothing, so it must not report as "involving" the family either.
        refute Ignore.directive_for(directives, 1, :relational),
               "[#{body}] wrongly matched the family-level query"
      end
    end

    test "a filter with no closing bracket suppresses nothing, not the whole line" do
      # `# mutare:ignore[relational` (missing `]`) must NOT degrade to `:all` — that would
      # silently hide every mutant on the line (the one dangerous direction). It is treated as
      # an empty filter (matches nothing), surfaced by `ineffective/2` as a soft warning.
      for body <- ["[relational", "[relational, arithmetic", "["] do
        %Directive{mutators: mutators, reason: reason} =
          directive_on(Ignore.directives("x = i < j # mutare:ignore#{body}"), 1)

        assert mutators == MapSet.new([]),
               "#{body} should be an empty filter, got #{inspect(mutators)}"

        assert reason == nil

        refute Ignore.directive_for(
                 %Directives{by_line: %{1 => [%Directive{line: 1, mutators: mutators}]}},
                 1,
                 :relational,
                 [">"]
               )
      end
    end

    test "a standalone directive targets the next line" do
      directives = Ignore.directives("# mutare:ignore[relational] why\nx = 1")
      assert %Directive{line: 2, comment_line: 1, reason: "why"} = directive_on(directives, 2)
    end

    test "a standalone directive reads through a contiguous comment block" do
      source = """
      # mutare:ignore[relational] reason starts here
      # and continues on a second comment line
      x = i < j
      """

      directives = Ignore.directives(source)
      # Suppresses the code line (3); `comment_line` stays where the text is (1).
      assert %Directive{line: 3, comment_line: 1} = directive_on(directives, 3)
      assert Ignore.directive_for(directives, 3, :relational)
    end

    test "a blank line ends the comment block (fail-safe: nothing reached)" do
      source = """
      # mutare:ignore[relational]
      # explanation

      x = i < j
      """

      directives = Ignore.directives(source)
      # The walk stops at the blank line (3) — the code on line 4 is NOT covered
      # (a detached block reads as unrelated; `ineffective/2` surfaces the miss).
      assert %Directive{line: 3} = directive_on(directives, 3)
      refute Map.has_key?(directives, 4)
    end

    test "a trailing comment's line carries code: the read-through stops there" do
      source = """
      # mutare:ignore[relational]
      x = i < j # an ordinary trailing comment
      y = i > j
      """

      directives = Ignore.directives(source)
      # Line 2 has code (the comment is trailing, not standalone), so it is the target.
      assert %Directive{line: 2} = directive_on(directives, 2)
      refute Map.has_key?(directives, 3)
    end

    test "stacked standalone directives all reach the code line below the block" do
      source = """
      # mutare:ignore[relational]
      # mutare:ignore[arithmetic]
      x = i < j
      """

      directives = Ignore.directives(source)
      # Each directive line is itself a standalone comment the other reads through.
      assert Ignore.directive_for(directives, 3, :relational)
      assert Ignore.directive_for(directives, 3, :arithmetic)
    end

    test "the most specific matching directive's reason wins (qualified beats bare)" do
      # A standalone bare directive (line 1 ⇒ line 2) and a trailing qualified directive both
      # land on line 2; the `>` mutant must record the qualifier's reason, not the bare one.
      source =
        "# mutare:ignore[relational] bare\nx = i < j # mutare:ignore[relational:>] specific"

      directives = Ignore.directives(source)

      assert %{reason: "specific"} = Ignore.directive_for(directives, 2, :relational, [">"])
      # A sibling variant the qualifier doesn't name still falls to the bare directive.
      assert %{reason: "bare"} = Ignore.directive_for(directives, 2, :relational, ["<="])
    end

    test "between two equal-specificity directives on a line, the source-first reason wins" do
      # A standalone bare directive (line 1 ⇒ line 2) and a trailing bare directive both land on
      # line 2 with equal specificity; the tie must resolve to source order (the first one
      # written), which `Mutare.Ignore.comments/1`'s document-order reversal guarantees.
      source = "# mutare:ignore[relational] first\nx = i < j # mutare:ignore[relational] second"

      directives = Ignore.directives(source)

      assert %{reason: "first"} = Ignore.directive_for(directives, 2, :relational, [">"])
    end

    defp directive_on(directives, line), do: directives.by_line |> Map.fetch!(line) |> hd()
  end

  describe "the reserved `mutare:` namespace (unknown_directives/1, verb_hint/1)" do
    alias Mutare.Ignore
    alias Mutare.Ignore.Directives

    test "a typo'd verb is reported with its comment line and head text" do
      assert Ignore.unknown_directives("x = 1 # mutare:ingore") == [{1, "mutare:ingore"}]
    end

    test "a colon-detached verb (`mutare: ignore`) is unknown, not a silent no-op" do
      source = """
      # mutare: ignore
      x = 1
      """

      assert Ignore.unknown_directives(source) == [{1, "mutare: ignore"}]
      # ...and it did not parse as a directive either — the space detaches the verb.
      assert Ignore.directives(source) == %Directives{}
    end

    test "a hyphen extends the verb, it never starts a reason" do
      # A plain `\b` boundary would read `# mutare:ignore-lines` as an ignore-everything
      # directive with reason `-lines` — silently suppressing the whole line. The
      # `(?![\w-])` boundary keeps it an unknown (future) verb, warned instead.
      source = "x = 1 # mutare:ignore-lines"

      assert Ignore.unknown_directives(source) == [{1, "mutare:ignore-lines"}]
      assert Ignore.directives(source) == %Directives{}
    end

    test "a recognized scoped verb extended by a trailing character is unknown, not a partial match" do
      # `ignore-startx` must not parse as `ignore-start` with reason `x` (nor `ignore-endless`
      # as `ignore-end` with reason `less`): the `(?![\w-])` lookahead after the suffix
      # alternation rejects both, and they land in the unknown-verb warning.
      for verb <- ~w(ignore-startx ignore-endless ignore-files) do
        source = "x = 1 # mutare:#{verb}"

        assert Ignore.unknown_directives(source) == [{1, "mutare:#{verb}"}], verb
        assert Ignore.directives(source) == %Directives{}, verb
      end
    end

    test "a bare `# mutare:` with no verb at all is reported" do
      assert Ignore.unknown_directives("x = 1 # mutare:") == [{1, "mutare:"}]
    end

    test "recognized directives and mid-comment prose don't match" do
      source = """
      x = 1 # mutare:ignore[arithmetic] real directive, reason and all
      # mutare:ignore
      y = 2
      # see mutare:ignore for details — prose, not anchored at the comment's start
      z = 3
      """

      assert Ignore.unknown_directives(source) == []
    end

    test "several unknowns are sorted by line" do
      source = """
      # mutare:ingore
      x = 1
      y = 2 # mutare:frobnicate
      """

      assert Ignore.unknown_directives(source) == [
               {1, "mutare:ingore"},
               {3, "mutare:frobnicate"}
             ]
    end

    test "verb_hint/1 suggests a near-miss verb, otherwise lists the recognized ones" do
      recognized =
        " (recognized: # mutare:ignore, # mutare:ignore-file, # mutare:ignore-start, " <>
          "# mutare:ignore-end)"

      assert Ignore.verb_hint("mutare:ingore") == "; did you mean # mutare:ignore?"
      assert Ignore.verb_hint("mutare: ignore") == "; did you mean # mutare:ignore?"
      assert Ignore.verb_hint("mutare:ignore-strat") == "; did you mean # mutare:ignore-start?"
      assert Ignore.verb_hint("mutare:ignore-fiel") == "; did you mean # mutare:ignore-file?"
      assert Ignore.verb_hint("mutare:frobnicate") == recognized
      assert Ignore.verb_hint("mutare:") == recognized
    end
  end

  describe "misplacement_hint/3 (the pipe's-first-line miss)" do
    alias Mutare.Ignore

    # A long pipe reads as one logical statement, so the instinct is to annotate
    # it "from the top" — but the mutated tokens live on a later `|>` step. The
    # hint names that step's line so the warning corrects the instinct.
    @pipe_source """
    def run(list) do
      # mutare:ignore[arithmetic]
      list
      |> Enum.map(fn x -> x + 1 end)
      |> Enum.sum()
    end
    """

    defp pipe_fixture do
      ast = Sourceror.parse_string!(@pipe_source)
      [directive] = @pipe_source |> Ignore.directives() |> Map.fetch!(:by_line) |> Map.fetch!(3)
      {ast, directive}
    end

    test "points at the pipe step carrying the mutants the directive named" do
      {ast, directive} = pipe_fixture()
      occupied = [{4, :arithmetic, []}, {5, :call, []}]

      assert Ignore.misplacement_hint(ast, directive, occupied) == 4
    end

    test "only mutants the directive's filter admits count" do
      {ast, directive} = pipe_fixture()
      # A `[arithmetic]` directive misplaced above a pipe with only other-family
      # mutants further down: no hint — the directive wouldn't have matched there.
      occupied = [{4, :relational, []}, {5, :call, []}]

      assert Ignore.misplacement_hint(ast, directive, occupied) == nil
    end

    test "the scan is bounded by the expression's own span" do
      {ast, directive} = pipe_fixture()
      # A matching mutant *below* the pipe (line 7+) must not be suggested — the
      # hint would point into an unrelated statement.
      occupied = [{8, :arithmetic, []}]

      assert Ignore.misplacement_hint(ast, directive, occupied) == nil
    end

    test "no hint when the suppressed line starts no multi-line expression" do
      source = """
      x = 1
      # mutare:ignore[arithmetic]
      y = 2
      """

      ast = Sourceror.parse_string!(source)
      [directive] = source |> Ignore.directives() |> Map.fetch!(:by_line) |> Map.fetch!(3)

      assert Ignore.misplacement_hint(ast, directive, [{5, :arithmetic, []}]) == nil
    end
  end

  describe "ineffective/2 (suppressed nothing)" do
    alias Mutare.Ignore

    test "a typo'd family is flagged (it matches no mutant on the line)" do
      directives = Ignore.directives("x = 1 # mutare:ignore[arithmatic]")
      occupied = [{1, :arithmetic, ["-"]}, {1, :literal, ["0"]}]

      assert [%{line: 1, mutators: set}] = Ignore.ineffective(directives, occupied)
      assert MapSet.member?(set, {"arithmatic", :any})
    end

    test "a valid label absent on the line is flagged (variant produced, not here)" do
      # `>` is a real relational variant, but this line produced only `<=`/`!=` — so the
      # qualifier is *ineffective* (not invalid; an unknown label is a hard validate! error).
      directives = Ignore.directives("x = 1 # mutare:ignore[relational:>]")
      occupied = [{1, :relational, ["<="]}, {1, :relational, ["!="]}]

      assert [%{line: 1, mutators: set}] = Ignore.ineffective(directives, occupied)
      assert MapSet.member?(set, {"relational", ">"})
    end

    test "a present label qualifier is not flagged" do
      directives = Ignore.directives("x = 1 # mutare:ignore[relational:>]")
      occupied = [{1, :relational, [">"]}, {1, :relational, ["<="]}]
      assert Ignore.ineffective(directives, occupied) == []
    end

    test "a malformed empty-label qualifier ([family:]) is flagged (it matched nothing)" do
      # The empty-label slip suppresses no real variant, so the user is warned rather than
      # silently over-suppressing the whole family.
      directives = Ignore.directives("x = 1 # mutare:ignore[relational:]")
      occupied = [{1, :relational, [">"]}, {1, :relational, ["<="]}]
      assert [%{line: 1}] = Ignore.ineffective(directives, occupied)
    end

    test "an empty `[]` filter is flagged" do
      directives = Ignore.directives("x = 1 # mutare:ignore[]")
      assert [%{line: 1}] = Ignore.ineffective(directives, [{1, :arithmetic, ["-"]}])
    end

    test "a bare directive on a line with no mutant is flagged (wrong line)" do
      directives = Ignore.directives("x = 1 # mutare:ignore")
      assert [%{line: 1}] = Ignore.ineffective(directives, [{2, :arithmetic, ["-"]}])
    end

    test "a bare directive on an occupied line is not flagged" do
      directives = Ignore.directives("x = 1 # mutare:ignore")
      assert Ignore.ineffective(directives, [{1, :arithmetic, ["-"]}]) == []
    end

    test "a filter matching a present family is not flagged" do
      directives = Ignore.directives("x = 1 # mutare:ignore[arithmetic]")
      assert Ignore.ineffective(directives, [{1, :arithmetic, ["-"]}, {1, :literal, ["0"]}]) == []
    end

    test "a real but absent family (present on the line, but a different one) is flagged" do
      directives = Ignore.directives("x = 1 # mutare:ignore[arithmetic]")

      assert [%{line: 1}] =
               Ignore.ineffective(directives, [{1, :relational, [">"]}, {1, :literal, ["0"]}])
    end

    test "results are sorted by line" do
      source = "a # mutare:ignore[x]\nb # mutare:ignore[y]\nc # mutare:ignore[z]"
      directives = Ignore.directives(source)
      # No site admits any of the filters → all three flagged, in line order.
      occupied = [{1, :arithmetic, ["-"]}, {2, :arithmetic, ["-"]}, {3, :arithmetic, ["-"]}]
      assert [1, 2, 3] == directives |> Ignore.ineffective(occupied) |> Enum.map(& &1.line)
    end

    test "results are sorted by line even when the directives map is large enough to hash-iterate" do
      # As in the `validate!/3` determinism test above: a small (<= 32 key) Elixir map happens
      # to enumerate in ascending key order regardless of the final `Enum.sort_by(& &1.line)`, so
      # 3 lines isn't enough to distinguish the sort from a no-op/dropped call. Force the large-map
      # representation with 40 distinct ineffective lines, scanned in a scrambled line order, and
      # check the result still comes back strictly ascending.
      lines = for n <- 1..40, do: "x#{n} = 1 # mutare:ignore[bogus#{n}]"
      source = Enum.join(lines, "\n")
      directives = Ignore.directives(source)
      assert map_size(directives.by_line) == 40

      occupied = for n <- 1..40, do: {n, :arithmetic, ["-"]}

      assert Enum.to_list(1..40) ==
               directives |> Ignore.ineffective(occupied) |> Enum.map(& &1.line)
    end
  end

  describe "scoped directives (ignore-file, ignore-start/ignore-end)" do
    alias Mutare.Ignore
    alias Mutare.Ignore.Directive
    alias Mutare.Ignore.Directives
    alias Mutare.Ignore.SpecError

    test "ignore-file takes the same filter/reason grammar and covers every line" do
      directives =
        Ignore.directives("""
        # mutare:ignore-file[arithmetic] generated table
        x = 1
        y = 2
        """)

      assert %Directives{by_line: by_line, scoped: [d], scope_errors: []} = directives
      assert by_line == %{}
      assert %Directive{scope: :file, comment_line: 1, reason: "generated table"} = d
      assert d.mutators == MapSet.new([{"arithmetic", :any}])

      assert Directive.covers?(d, 1)
      assert Directive.covers?(d, 999_999)
      # A site with no recorded line is still in the file — the one scope that
      # needs no line to decide.
      assert Directive.covers?(d, nil)
    end

    test "a start/end pair forms a region spanning both delimiter lines inclusive" do
      directives =
        Ignore.directives("""
        a = 1
        # mutare:ignore-start table is spot-checked
        b = 2
        c = 3
        # mutare:ignore-end
        d = 4
        """)

      assert %Directives{scoped: [d], scope_errors: []} = directives

      assert %Directive{
               scope: {:region, 2, 5},
               comment_line: 2,
               mutators: :all,
               reason: "table is spot-checked"
             } = d

      refute Directive.covers?(d, 1)
      assert Directive.covers?(d, 2)
      assert Directive.covers?(d, 4)
      assert Directive.covers?(d, 5)
      refute Directive.covers?(d, 6)
      refute Directive.covers?(d, nil)
    end

    test "trailing delimiters cover their own code lines" do
      directives =
        Ignore.directives("""
        a = 1 # mutare:ignore-start
        b = 2 # mutare:ignore-end
        c = 3
        """)

      assert %Directives{scoped: [%Directive{scope: {:region, 1, 2}}], scope_errors: []} =
               directives
    end

    test "text after ignore-end is prose — the filter and reason belong to the start" do
      directives =
        Ignore.directives("""
        # mutare:ignore-start[literal] the real reason
        x = 1
        # mutare:ignore-end of the lookup table
        """)

      assert %Directives{scoped: [d], scope_errors: []} = directives
      assert d.mutators == MapSet.new([{"literal", :any}])
      assert d.reason == "the real reason"
    end

    test "sequential regions pair independently" do
      directives =
        Ignore.directives("""
        # mutare:ignore-start first
        a = 1
        # mutare:ignore-end
        b = 2
        # mutare:ignore-start second
        c = 3
        # mutare:ignore-end
        """)

      assert %Directives{scoped: [first, second], scope_errors: []} = directives
      assert %Directive{scope: {:region, 1, 3}, reason: "first"} = first
      assert %Directive{scope: {:region, 5, 7}, reason: "second"} = second
    end

    test "directive_for prefers the narrower scope on a specificity tie" do
      # All three directives are unfiltered (specificity 0), so scope decides which
      # reason is recorded: line over region over file.
      directives =
        Ignore.directives("""
        # mutare:ignore-file file reason
        # mutare:ignore-start region reason
        x = 1 # mutare:ignore line reason
        y = 2
        # mutare:ignore-end
        """)

      assert %{reason: "line reason"} = Ignore.directive_for(directives, 3, :arithmetic, [])
      assert %{reason: "region reason"} = Ignore.directive_for(directives, 4, :arithmetic, [])
      assert %{reason: "file reason"} = Ignore.directive_for(directives, 99, :arithmetic, [])
    end

    test "filter specificity still beats scope: a qualified file directive over a bare line one" do
      directives =
        Ignore.directives("""
        # mutare:ignore-file[literal:zero] file reason
        x = 0 # mutare:ignore line reason
        """)

      assert %{reason: "file reason"} = Ignore.directive_for(directives, 2, :literal, ["zero"])
      assert %{reason: "line reason"} = Ignore.directive_for(directives, 2, :literal, ["succ"])
    end

    test "scoped directives are held to the ineffectiveness bar, with no misplacement hint" do
      source = """
      # mutare:ignore-start
      # mutare:ignore-end
      x = 1 > 0
      # mutare:ignore-file[relational]
      """

      ast = Sourceror.parse_string!(source)
      directives = Ignore.directives(source)
      # An arithmetic site on line 3: outside the (empty) region, and not admitted
      # by the `[relational]` file filter — both scoped directives suppress nothing.
      occupied = [{3, :arithmetic, []}]

      assert [%Directive{scope: {:region, 1, 2}} = region, %Directive{scope: :file} = file] =
               Ignore.ineffective(directives, occupied)

      assert Ignore.misplacement_hint(ast, region, occupied) == nil
      assert Ignore.misplacement_hint(ast, file, occupied) == nil

      # ...and an occupied line inside the region makes it effective.
      assert [%Directive{scope: :file}] =
               Ignore.ineffective(directives, [{2, :arithmetic, []}])
    end

    test "a bad qualified label on a scoped directive is the same hard validate! error" do
      vocab = Mutare.Mutators.vocabulary(Mutare.Mutators.resolve([:builtins]))
      directives = Ignore.directives("# mutare:ignore-file[relational:lte]\nx = 1")

      assert Ignore.any_qualified?(directives)

      err = assert_raise(SpecError, fn -> Ignore.validate!(directives, vocab, "lib/f.ex") end)
      assert err.reason == :unknown_variant
    end

    test "an ignore-end without an open region is a hard error" do
      directives =
        Ignore.directives("""
        x = 1
        # mutare:ignore-end
        """)

      assert %Directives{scope_errors: [{:unmatched_end, 2}]} = directives

      err = assert_raise(SpecError, fn -> Ignore.validate_scopes!(directives, "lib/a.ex") end)
      assert err.reason == :unmatched_end
      assert err.line == 2
      assert err.message =~ "lib/a.ex:2"
      assert err.message =~ "without a preceding # mutare:ignore-start"
    end

    test "a nested ignore-start is a hard error; the open region still closes" do
      directives =
        Ignore.directives("""
        # mutare:ignore-start
        x = 1
        # mutare:ignore-start
        y = 2
        # mutare:ignore-end
        """)

      # The outer region survives (soundness for anything that reads on), but the
      # nested delimiter is a hard error — never silently absorbed.
      assert %Directives{
               scoped: [%Directive{scope: {:region, 1, 5}}],
               scope_errors: [{:nested_region, 3, 1}]
             } = directives

      err = assert_raise(SpecError, fn -> Ignore.validate_scopes!(directives, "lib/a.ex") end)
      assert err.reason == :nested_region
      assert err.message =~ "opened at line 1"
    end

    test "an unterminated ignore-start is a hard error pointing at ignore-file" do
      directives =
        Ignore.directives("""
        # mutare:ignore-start
        x = 1
        """)

      assert %Directives{scoped: [], scope_errors: [{:unterminated_region, 1}]} = directives

      err = assert_raise(SpecError, fn -> Ignore.validate_scopes!(directives, "lib/a.ex") end)
      assert err.reason == :unterminated_region
      assert err.message =~ "never closed"
      assert err.message =~ "# mutare:ignore-file"
    end

    test "a broken pairing aborts both the render and the count transform paths" do
      source = """
      defmodule Ig do
        # mutare:ignore-end
        def a(x), do: x + 1
      end
      """

      err =
        assert_raise(SpecError, fn ->
          Mutare.Transform.transform_string_with_sites(source, file: "lib/ig.ex")
        end)

      assert err.reason == :unmatched_end
      assert err.message =~ "lib/ig.ex:2"

      assert_raise(SpecError, fn -> Mutare.Transform.count_string(source, file: "lib/ig.ex") end)
    end

    test "a region marks every site between its delimiters ignored, with the start's reason" do
      source = """
      defmodule Ig do
        def keep(x), do: x + 1
        # mutare:ignore-start table is spot-checked
        def enc(?A), do: ?B
        def enc(?B), do: ?C
        # mutare:ignore-end
        def also_keep(x), do: x - 1
      end
      """

      {meta, sites, _next_id} = Mutare.Transform.transform_string_with_sites(source)
      {in_region, outside} = Enum.split_with(sites, &(&1.line in 3..6))

      assert in_region != []
      assert Enum.all?(in_region, & &1.ignored)
      assert Enum.all?(in_region, &(&1.ignore_reason == "table is spot-checked"))

      assert outside != []
      refute Enum.any?(outside, & &1.ignored)

      # Ignored sites are still recorded, and the metamutant still compiles.
      assert {:ok, _} = Code.string_to_quoted(meta)
    end

    test "ignore-file marks every site in the file ignored" do
      source = """
      # mutare:ignore-file generated by mix gen.tables
      defmodule Ig do
        def a(x), do: x + 1

        def b(x), do: x - 1
      end
      """

      {_meta, sites, _next_id} = Mutare.Transform.transform_string_with_sites(source)

      assert sites != []
      assert Enum.all?(sites, & &1.ignored)
      assert Enum.all?(sites, &(&1.ignore_reason == "generated by mix gen.tables"))
    end

    test "a filtered region suppresses only the named family; siblings still run" do
      source = """
      defmodule Ig do
        # mutare:ignore-start[arithmetic] cursor math
        def a(x), do: x + 1 > 2
        # mutare:ignore-end
      end
      """

      {_meta, sites, _next_id} = Mutare.Transform.transform_string_with_sites(source)
      by_mutator = Enum.group_by(sites, & &1.mutator)

      assert Enum.all?(by_mutator[:arithmetic], & &1.ignored)
      assert Enum.all?(by_mutator[:arithmetic], &(&1.ignore_reason == "cursor math"))

      others = Enum.flat_map(~w(relational conditional literal)a, &(by_mutator[&1] || []))
      assert others != []
      refute Enum.any?(others, & &1.ignored)
    end
  end

  describe "qualified-filter validation (strict)" do
    alias Mutare.Ignore
    alias Mutare.Ignore.SpecError

    @vocab Mutare.Mutators.vocabulary(Mutare.Mutators.resolve([:builtins]))

    defp validate(text), do: Ignore.validate!(Ignore.directives(text), @vocab, "lib/f.ex")

    test "an unknown family in a qualifier is NOT a hard error (may be an excluded custom)" do
      # We can't tell a typo'd family from a `--mutators`-excluded custom one, so — like a bare
      # `[family]` typo — it stays lenient (a soft `ineffective` warning), never a hard abort.
      assert validate("x # mutare:ignore[bogus:foo]") == :ok
    end

    test "an unknown label on a KNOWN family raises, listing the known variants" do
      # `lte` shares no characters with any operator label, so there is no jaro near-miss; the
      # error still lists every known label as the actionable fallback (the suggestion clause is
      # covered separately below, where a near-miss exists). Pinned to the *exact* message (not
      # just `=~` substrings) — the pieces are string-concatenated in `validate_entry!/5`, and a
      # loose substring check can't tell a swapped concatenation order apart from the real thing.
      err = assert_raise(SpecError, fn -> validate("x # mutare:ignore[relational:lte]") end)
      assert err.reason == :unknown_variant

      assert err.message ==
               "lib/f.ex:1: \"lte\" is not a relational variant in # mutare:ignore[relational:lte]" <>
                 " (known: !=, !==, <, <=, ==, ===, >, >=)"
    end

    test "a near-miss label gets a 'did you mean' suggestion" do
      # `tru` is a near-miss of the declared `true`/`false` vocabulary (jaro > 0.8), so the
      # suggestion clause fires — exercising the jaro/threshold path the operator-symbol families
      # can't reach. This is the live test of `suggestion/2`. Exact match, for the same
      # string-concatenation-order reason as above.
      err = assert_raise(SpecError, fn -> validate("x # mutare:ignore[conditional:tru]") end)
      assert err.reason == :unknown_variant

      assert err.message ==
               "lib/f.ex:1: \"tru\" is not a conditional variant in # mutare:ignore[conditional:tru]" <>
                 "; did you mean \"true\"? (known: false, true)"
    end

    test "the suggestion is the CLOSEST near-miss by Jaro distance, not just any of them" do
      # `suggestion/2` filters candidates to Jaro distance >= 0.8, then picks the closest. Two
      # candidates both clear the threshold against the typo "abcde" but at different distances
      # ("abced" 0.933 > "abcdx" 0.867) — `Enum.max_by` must return the truly closest one; a
      # `Enum.min_by` (or a body that ignores `distance` entirely) would pick "abcdx" instead.
      vocabulary = %{"custom" => MapSet.new(["abced", "abcdx"])}
      directives = Ignore.directives("x # mutare:ignore[custom:abcde]")

      err =
        assert_raise(SpecError, fn -> Ignore.validate!(directives, vocabulary, "lib/f.ex") end)

      assert err.message =~ ~s(did you mean "abced"?)
      refute err.message =~ ~s(did you mean "abcdx"?)
    end

    test "the '(known: ...)' list is sorted even when the label set is large enough to hash-iterate" do
      # Same 32-element small-map/set threshold caveat as the two determinism tests above: the
      # built-in families used elsewhere in this file (2-8 labels) already enumerate in sorted
      # order regardless of `Enum.sort()` in `validate_entry!/5`'s message-building, which is
      # exactly why `Enum.sort() → Elixir.Function.identity()` survived against them. Force a
      # >32-label vocabulary via a synthetic family (`validate!/3` takes `vocabulary` as a plain
      # argument, so this doesn't need a real mutator).
      labels = for n <- 1..40, do: "z#{String.pad_leading(Integer.to_string(n), 2, "0")}"
      vocabulary = %{"custom" => MapSet.new(labels)}
      directives = Ignore.directives("x # mutare:ignore[custom:bogus]")

      err =
        assert_raise(SpecError, fn -> Ignore.validate!(directives, vocabulary, "lib/f.ex") end)

      expected = "(known: " <> Enum.join(Enum.sort(labels), ", ") <> ")"
      assert String.ends_with?(err.message, expected)
    end

    test "a family that declares no variants rejects any qualifier" do
      err = assert_raise(SpecError, fn -> validate("x # mutare:ignore[collection:map]") end)
      assert err.reason == :no_variants

      assert err.message ==
               "lib/f.ex:1: the collection mutator declares no variant labels, so " <>
                 "# mutare:ignore[collection:map] can't select one — use the bare " <>
                 "# mutare:ignore[collection] to suppress the whole family"
    end

    test "a valid qualifier validates, and neither bare nor unknown families are checked" do
      assert validate("x # mutare:ignore[relational:>]") == :ok
      # Bare unknown family and unknown qualified family both stay soft ineffective warnings.
      assert validate("x # mutare:ignore[bogus]") == :ok
      assert validate("x # mutare:ignore[bogus:foo]") == :ok
      assert validate("x # mutare:ignore equivalent prose") == :ok
    end

    test "a malformed empty-label qualifier is not a hard error (left to the soft warning)" do
      # `[relational:]` is a stray colon, not a *named*-but-wrong label — a missing label is a slip,
      # so it stays lenient (an `ineffective/2` warning), never a hard abort. It also no longer
      # over-suppresses the family (see the `directive_for` describe).
      assert validate("x # mutare:ignore[relational:]") == :ok
      assert validate("x # mutare:ignore[relational:, arithmetic:+]") == :ok
    end

    test "labels match case-insensitively (declared + filter both folded)" do
      assert validate("x # mutare:ignore[CONDITIONAL:TRUE]") == :ok
    end

    test "the transform raises on a bad qualifier (end-to-end through the scan)" do
      assert_raise SpecError, fn ->
        Mutare.Transform.transform_string_with_sites(
          "defmodule M do\n  def f, do: 1 # mutare:ignore[literal:huge]\nend\n"
        )
      end
    end

    test "count_string validates qualifiers too (a zero-site file is still caught)" do
      # With only arithmetic active, `a < b` produces no sites at all — so in the schema's
      # two-phase build this file is counted but never rendered (`transform_string/2`). The bad
      # relational qualifier must still be rejected, on the count path.
      bad = "defmodule Z do\n  def f(a, b), do: a < b # mutare:ignore[relational:bogus]\nend\n"
      clean = "defmodule Z do\n  def f(a, b), do: a < b\nend\n"
      opts = [mutators: [Mutare.Mutators.Arithmetic]]

      assert Mutare.Transform.count_string(clean, opts) == 0
      assert_raise SpecError, fn -> Mutare.Transform.count_string(bad, opts) end
    end

    test "the first bad qualifier raised is always the lowest source line, however the directives map iterates" do
      # `validate!/3` explicitly sorts by line before scanning so the *reported* error is
      # deterministic. Elixir maps with <= 32 keys happen to enumerate in ascending key order
      # regardless (a flat-list representation), which would make this pass even with the sort
      # dropped (`Enum.sort_by(directives, ...) → directives`/`Enum.reverse(directives)`, both
      # observed survivors of that mutation) — so build enough distinct directive-carrying lines
      # to force the large-map (HAMT) representation, whose iteration order is hash-based, not
      # insertion- or key-based. Picking just *two* bad lines isn't enough either: for some
      # arbitrary pairs, hash order happens to still visit the lower one first (observed
      # surviving with lines 7 and 33 specifically — bad luck, not a real kill). Making *every*
      # line bad and asserting on line 1 — the unambiguous minimum — removes that luck: line 1
      # would have to land first in hash order among all 40 for the dropped-sort mutant to
      # survive, which is not realistic.
      lines = for n <- 1..40, do: "x#{n} = 1 # mutare:ignore[relational:bogus#{n}]"

      source = Enum.join(lines, "\n")
      directives = Ignore.directives(source)
      assert map_size(directives.by_line) == 40

      err = assert_raise(SpecError, fn -> validate(source) end)
      assert err.line == 1
    end

    test "among several bad qualifiers on the SAME line, the alphabetically-first is raised, however the entry set iterates" do
      # The inner `Enum.sort(qualified_entries(directive))` exists for the identical reason as
      # the outer sort above — `qualified_entries/1` returns entries pulled from a `MapSet`
      # (unordered), so without the sort the raised entry would depend on `MapSet`/`Map` hash
      # iteration. Same 32-element threshold caveat: force it with 40 distinct qualified entries
      # on one line, zero-padded so lexicographic order matches the intended "first" (`q01`).
      labels =
        for n <- 1..40, do: "relational:q#{String.pad_leading(Integer.to_string(n), 2, "0")}"

      source = "x = 1 # mutare:ignore[#{Enum.join(labels, ", ")}]"

      directives = Ignore.directives(source)
      assert %{mutators: %MapSet{} = set} = directive_on(directives, 1)
      assert MapSet.size(set) == 40

      err = assert_raise(SpecError, fn -> validate(source) end)
      assert err.label == "q01"
    end
  end

  describe "any_qualified?/1" do
    alias Mutare.Ignore

    test "false when every directive is bare or :all" do
      directives = Ignore.directives("a = 1 # mutare:ignore\nb = 2 # mutare:ignore[arithmetic]")
      refute Ignore.any_qualified?(directives)
    end

    test "true when only ONE of several directives carries a qualified label (any, not all)" do
      source = """
      a = 1 # mutare:ignore[arithmetic]
      b = 2 # mutare:ignore[relational:>]
      c = 3 # mutare:ignore
      """

      assert Ignore.any_qualified?(Ignore.directives(source))
    end

    test "true when only the second directive on a shared line is qualified (any, not all)" do
      # Two directives land on the same line (a standalone one targeting it, plus its own
      # trailing directive); only the trailing one is qualified.
      source = "# mutare:ignore\nx = 1 # mutare:ignore[relational:>]"
      assert Ignore.any_qualified?(Ignore.directives(source))
    end
  end

  describe "variant vocabulary (Mutare.Mutators.vocabulary/1)" do
    @specs Mutare.Mutators.resolve([:builtins])
    @vocab Mutare.Mutators.vocabulary(@specs)

    test "opted-in families expose labels; others and clause_drop are :none" do
      assert @vocab["relational"] == MapSet.new(~w(> >= < <= == != === !==))
      assert @vocab["return_value"] == MapSet.new(~w(empty sentinel))
      assert @vocab["literal"] == MapSet.new(~w(zero succ pred negate))
      assert @vocab["collection"] == :none
      assert @vocab["clause_drop"] == :none
    end

    test "every declared built-in label is wire-safe (no [],() , whitespace, or quotes)" do
      # Use the same predicate the build enforces, so the rule has one source of truth.
      for {_family, labels} <- @vocab, labels != :none, label <- labels do
        assert Mutare.Mutators.wire_safe?(label), "label #{inspect(label)} is not wire-safe"
      end
    end

    test "the empty string is not a wire-safe label" do
      # `[family:]` parses to the malformed empty-label entry that matches nothing, so an empty
      # *declared* label could never be selected — it must be rejected at build, not produced.
      refute Mutare.Mutators.wire_safe?("")
    end

    test "a mutator declaring an empty-string label is rejected as wire-unsafe" do
      err =
        assert_raise Mutare.Ignore.SpecError, fn ->
          Mutare.Mutators.vocabulary(
            Mutare.Mutators.resolve([Mutare.IgnoreTest.EmptyLabelVariantMutator])
          )
        end

      assert err.reason == :wire_unsafe_label
      assert err.label == ""
      assert err.message =~ "may not be empty"
    end

    test "a custom family name containing a colon is rejected (unfilterable family)" do
      # `:` is the variant-qualifier separator, so `[ecto:query]` could never name a whole
      # `ecto:query` family — a colon family name is silently unsuppressable, so reject it.
      err =
        assert_raise Mutare.Ignore.SpecError, fn ->
          Mutare.Mutators.vocabulary(
            Mutare.Mutators.resolve([{Mutare.IgnoreTest.BothVariantMutator, as: :"ecto:query"}])
          )
        end

      assert err.reason == :unfilterable_family
      assert err.family == "ecto:query"
      assert err.message =~ "can't be written as a filter token"
    end

    test "opting in is declaring variants/0; label assignment (variant/2 or a tag) is separate" do
      alias Mutare.IgnoreTest.{BothVariantMutator, NoVocabMutator, VocabOnlyMutator}

      # variants/0 present → opted in, whether labels come from variant/2 or a production tag.
      assert Mutare.Mutator.Dispatch.opted_in?(BothVariantMutator)
      assert Mutare.Mutator.Dispatch.opted_in?(VocabOnlyMutator)
      # variant/2 without variants/0 declares no vocabulary → not opted in.
      refute Mutare.Mutator.Dispatch.opted_in?(NoVocabMutator)

      # The vocabulary is exposed exactly when variants/0 is declared — a label-less family
      # (NoVocabMutator) is `:none`, so a `[no_vocab:a]` qualifier is the clean `:no_variants` hard
      # error rather than a silently-unmatched label.
      assert Mutare.Mutators.vocabulary(Mutare.Mutators.resolve([BothVariantMutator]))[
               "both_variant"
             ] ==
               MapSet.new(~w(a b))

      assert Mutare.Mutators.vocabulary(Mutare.Mutators.resolve([VocabOnlyMutator]))["vocab_only"] ==
               MapSet.new(~w(a b))

      assert Mutare.Mutators.vocabulary(Mutare.Mutators.resolve([NoVocabMutator]))["no_vocab"] ==
               :none
    end

    test "every site's recorded variant is one its mutator declares (no drift)" do
      # Exercise the opted-in families and assert each recorded label is a member of the
      # producing family's declared vocabulary — the static guarantee `variant/2` ⊆ `variants/0`.
      # Includes bitwise (`&&&`/`|||`/`<<<`) and list (`++`/`[]`), plus the value-literal families
      # that label their two halves (float `succ`/`pred`/`zero`; string/charlist/word_list/
      # string_sigil `empty`/`sentinel`), so those families' membership is checked here too, not
      # just the non-empty completeness test below.
      source = """
      defmodule Drift do
        import Bitwise
        def f(i, j) do
          x = i < j && i > j
          y = (i + j) * 2 - 1
          z = i === j
          w = (i &&& j) ||| (i <<< 2)
          v = [i] ++ [j]
          fl = 1.5
          s = "hello"
          c = ~c"hi"
          wl = ~w(a b)
          ss = ~s(yo)
          if x, do: build(i), else: y
          {z, w, v, fl, s, c, wl, ss}
        end
      end
      """

      {_meta, sites, _} = Mutare.Transform.transform_string_with_sites(source)

      for site <- sites, label <- site.variant do
        case Map.fetch!(@vocab, to_string(site.mutator)) do
          %MapSet{} = labels ->
            assert MapSet.member?(labels, label),
                   "#{site.mutator} produced undeclared variant #{inspect(label)}"

          :none ->
            flunk("#{site.mutator} recorded a variant #{inspect(label)} but declares none")
        end
      end
    end

    test "every binary operator-swap mutant of an opted-in family is labeled (mutate/variant sync)" do
      # The completeness direction of the drift guarantee: a 2-arg op → 2-arg op swap by an
      # opted-in operator family MUST carry a variant. Catches a mutate/1 result operator missing
      # from the family's declared `@swap_ops` (which would silently record `nil`, unsuppressable
      # by `[family:op]`).
      op_families = [:relational, :arithmetic, :logical, :bitwise, :strict_equality, :list]

      source = """
      defmodule Ops do
        import Bitwise
        def f(a, b) do
          _ = a < b
          _ = a + b
          _ = a * b
          _ = a and b
          _ = a &&& b
          _ = a <<< b
          _ = a === b
          _ = a ++ b
          a
        end
      end
      """

      {_meta, sites, _} = Mutare.Transform.transform_string_with_sites(source)

      # `Mutare.Site` is a lean DTO (no stored AST nodes), so re-parse the recorded code to
      # recover each mutation's shape and keep only the 2-arg op → 2-arg op swaps.
      swaps =
        for site <- sites,
            site.mutator in op_families,
            match?({op, _, [_, _]} when is_atom(op), Mutare.AST.parse!(site.original_code)),
            match?({op, _, [_, _]} when is_atom(op), Mutare.AST.parse!(site.mutated_code)),
            do: site

      refute swaps == [], "expected operator-swap sites to exercise the families"

      for site <- swaps do
        assert site.variant != [],
               "#{site.mutator}: #{site.original_code} → #{site.mutated_code} recorded no variant"
      end
    end

    test "a Bitwise function-call swap is labeled with the same operator as its infix form" do
      # `Bitwise.band(a, b)` → `Bitwise.bor(a, b)` names the `|||` variant, just as `a &&& b` does
      # — so `[bitwise:|||]` suppresses the OR result in either spelling.
      {_meta, sites, _} =
        Mutare.Transform.transform_string_with_sites("""
        defmodule B do
          import Bitwise
          def f(a, b), do: Bitwise.band(a, b)
        end
        """)

      bitwise = Enum.filter(sites, &(&1.mutator == :bitwise))
      refute bitwise == []
      assert Enum.all?(bitwise, &(&1.variant == ["|||"]))
    end

    test "a Bitwise capture swap is labeled like its call form (so [bitwise:op] suppresses it)" do
      # `&Bitwise.band/2` → `&Bitwise.bor/2` is recorded as the `&` form, but the variant must still
      # be the call's `|||` (classified by unwrapping the capture to its inner ref), so a qualified
      # filter can suppress it. The alias-stamped form resolves identically.
      {_meta, sites, _} =
        Mutare.Transform.transform_string_with_sites("""
        defmodule B do
          alias Bitwise, as: Bw
          def f, do: &Bw.band/2 # mutare:ignore[bitwise:|||]
        end
        """)

      bitwise = Enum.filter(sites, &(&1.mutator == :bitwise))
      assert [site] = bitwise
      assert site.mutated_code == "&Bw.bor/2"
      assert site.variant == ["|||"]
      assert site.ignored
    end

    test "an imported Bitwise capture swap keeps its operator label for qualified ignores" do
      # A bare imported capture's ref is `{band, meta, nil}`, not call-shaped, so variant
      # derivation must normalize it before resolving the import stamp.
      {_meta, sites, _} =
        Mutare.Transform.transform_string_with_sites("""
        defmodule B do
          import Bitwise
          def f, do: &band/2 # mutare:ignore[bitwise:|||]
        end
        """)

      bitwise = Enum.filter(sites, &(&1.mutator == :bitwise))
      assert [site] = bitwise
      assert site.mutated_code == "&bor/2"
      assert site.variant == ["|||"]
      assert site.ignored
    end

    test "a literal off-by-one that collapses onto 0 carries BOTH the off-by-one and zero labels" do
      # `x - 1`: the `1` literal's `n - 1` mutant is `0`, merged with the zero sentinel into one
      # deduped mutant. It belongs to both kinds, so it advertises *both* labels — and a user
      # reasoning about the decrement (`pred`) or about the zero boundary (`zero`) each find it.
      {_meta, sites, _} =
        Mutare.Transform.transform_string_with_sites(
          "defmodule L do\n  def f(x), do: x - 1\nend\n"
        )

      zero_mutant = Enum.find(sites, &(&1.mutator == :literal and &1.mutated_code == "0"))
      assert zero_mutant, "expected a 1 -> 0 literal mutant"
      assert Enum.sort(zero_mutant.variant) == ["pred", "zero"]

      # The sibling `1 -> 2` succ mutant is a single, distinct kind.
      succ_mutant = Enum.find(sites, &(&1.mutator == :literal and &1.mutated_code == "2"))
      assert succ_mutant.variant == ["succ"]
    end

    test "either [literal:pred] or [literal:zero] suppresses the collapsed 1 -> 0 mutant" do
      # The payoff of the dual label: the merged mutant is selectable by *either* qualifier, while
      # the unrelated `succ` mutant on the same literal keeps running.
      for label <- ~w(pred zero) do
        src = "defmodule L do\n  def f(x), do: x - 1 # mutare:ignore[literal:#{label}]\nend\n"
        {_meta, sites, _} = Mutare.Transform.transform_string_with_sites(src)

        zero_mutant = Enum.find(sites, &(&1.mutator == :literal and &1.mutated_code == "0"))
        assert zero_mutant.ignored, "[literal:#{label}] should suppress the 1 -> 0 mutant"

        succ_mutant = Enum.find(sites, &(&1.mutator == :literal and &1.mutated_code == "2"))
        refute succ_mutant.ignored, "[literal:#{label}] must not touch the succ mutant"
      end
    end
  end

  describe "end to end" do
    @tag :runner
    @tag timeout: 180_000
    test "an ignored mutant is :ignored (not run) and kept out of the score" do
      %{project: project, sandbox: sandbox} =
        Project.build(:ig, %{
          "lib/ig.ex" => """
          defmodule Ig do
            def keep(x), do: x + 1
            def skip(x), do: x + 1 # mutare:ignore
          end
          """,
          "test/ig_test.exs" => """
          defmodule IgTest do
            use ExUnit.Case
            test "keep", do: assert(Ig.keep(1) == 2)
          end
          """
        })

      # Pin to a single operator-swap family so `skip/1` has exactly one mutant
      # (the test asserts a single ignored result); the default literal mutator
      # would add more, off-topic for what this checks.
      assert {:ok, run} =
               Mutare.run(project, sandbox: sandbox, mutators: [Mutare.Mutators.Arithmetic])

      ignored = Enum.filter(run.results, &(&1.status == :ignored))

      # `skip/1`'s mutant is suppressed — and ignore wins over no-coverage
      # (it's never run), so it's :ignored, not :no_coverage.
      assert [%Result{site: %{ignored: true}, duration_ms: 0}] = ignored
      assert Enum.all?(ignored, &(&1.site.line == skip_line()))

      # keep/1's mutant is covered and killed; with the other ignored, score is 100%.
      assert Mutare.Report.score(run.results) == 100.0
    end
  end

  defp skip_line, do: 3
end
