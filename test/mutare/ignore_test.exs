# Stub mutators exercising the variant opt-in contract (`Mutare.Mutator.Dispatch.opted_in?/1`): a mutator
# must export *both* `variants/0` and `variant/2` to participate in the variant-label system.
defmodule Mutare.IgnoreTest.BothVariantMutator do
  @behaviour Mutare.Mutator
  def name, do: :both_variant
  def mutate(_node), do: :skip
  def variants, do: ~w(a b)
  def variant(_original, _mutated), do: "a"
end

defmodule Mutare.IgnoreTest.HalfVariantMutator do
  # Declares the vocabulary but NOT the per-mutation tagging — a half-implementation that must be
  # treated as *not* opted in: it records no label, so it must also expose no vocabulary.
  @behaviour Mutare.Mutator
  def name, do: :half_variant
  def mutate(_node), do: :skip
  def variants, do: ~w(a b)
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

      {meta, sites, _next_id} = Mutare.transform_string(source)
      ignored? = Map.new(sites, &{&1.line, &1.ignored})

      assert ignored?[2] == true
      assert ignored?[3] == false
      assert ignored?[5] == true

      # ignored sites are still recorded (for the denominator), and the
      # metamutant still compiles.
      assert {:ok, _} = Code.string_to_quoted(meta)
    end

    test "a trailing reason is captured on the site and suppresses the whole line" do
      source = """
      defmodule Ig do
        def a(x), do: x + 1   # mutare:ignore equivalent under integer math
      end
      """

      {_meta, sites, _next_id} = Mutare.transform_string(source)

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

      {_meta, sites, _next_id} = Mutare.transform_string(source)
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

      {_meta, sites, _next_id} = Mutare.transform_string(source)
      ignored = Enum.group_by(sites, & &1.ignored, & &1.mutator)

      assert MapSet.new(ignored[true]) == MapSet.new([:arithmetic, :relational])
      refute Enum.empty?(ignored[false])
    end

    test "a `[family:result]` qualifier suppresses one mutant, not the whole family" do
      # `i` and `j` are symmetric, so `i > j` is an equivalent reflection of
      # `i < j` — but `i <= j` (cutting the diagonal) is a real, non-equivalent
      # mutant that must still run. Ignoring `[relational]` would lose both.
      source = """
      defmodule Ig do
        def f(i, j), do: i < j   # mutare:ignore[relational:>] symmetric
      end
      """

      {_meta, sites, _next_id} = Mutare.transform_string(source)
      relational = Enum.filter(sites, &(&1.mutator == :relational))
      ignored? = Map.new(relational, &{&1.mutated_form, &1.ignored})

      # Both relational mutants exist; only the `>` reflection is suppressed.
      assert ignored?[:>] == true
      assert ignored?[:<=] == false

      ignored = Enum.filter(relational, & &1.ignored)
      assert Enum.all?(ignored, &(&1.ignore_reason == "symmetric"))
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

      {_meta, sites, _next_id} = Mutare.transform_string(source)
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

      {_meta, sites, _next_id} = Mutare.transform_string(source)

      # Typo'd family matches no mutator, so the mutant runs rather than hides.
      refute Enum.any?(sites, & &1.ignored)
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
        Mutare.transform_string(source, mutators: [Mutare.Mutators.Arithmetic])

      assert [%{line: 2, ignored: false}] = sites
    end
  end

  describe "directive parsing" do
    alias Mutare.Ignore
    alias Mutare.Ignore.Directive

    test "a bare directive admits every mutator and carries no reason" do
      directives = Ignore.directives("x = 1 # mutare:ignore")
      assert %Directive{line: 1, mutators: :all, reason: nil} = directive_on(directives, 1)
      assert Ignore.directive_for(directives, 1, :anything)
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

    test "a standalone directive targets the next line" do
      directives = Ignore.directives("# mutare:ignore[relational] why\nx = 1")
      assert %Directive{line: 2, reason: "why"} = directive_on(directives, 2)
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

    defp directive_on(directives, line), do: directives |> Map.fetch!(line) |> hd()
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
      # covered separately below, where a near-miss exists).
      err = assert_raise(SpecError, fn -> validate("x # mutare:ignore[relational:lte]") end)
      assert err.reason == :unknown_variant
      assert err.message =~ ~s("lte" is not a relational variant)
      # the real labels are listed for the fix
      assert err.message =~ "<="
      # ...and no misleading "did you mean" for a word that resembles no operator symbol.
      refute err.message =~ "did you mean"
    end

    test "a near-miss label gets a 'did you mean' suggestion" do
      # `tru` is a near-miss of the declared `true`/`false` vocabulary (jaro > 0.8), so the
      # suggestion clause fires — exercising the jaro/threshold path the operator-symbol families
      # can't reach. This is the live test of `suggestion/2`.
      err = assert_raise(SpecError, fn -> validate("x # mutare:ignore[conditional:tru]") end)
      assert err.reason == :unknown_variant
      assert err.message =~ ~s(did you mean "true"?)
    end

    test "a family that declares no variants rejects any qualifier" do
      err = assert_raise(SpecError, fn -> validate("x # mutare:ignore[collection:map]") end)
      assert err.reason == :no_variants
      assert err.message =~ "declares no variant labels"
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
        Mutare.transform_string(
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

    test "the opt-in contract requires BOTH variants/0 and variant/2 (a half-impl is :none)" do
      alias Mutare.IgnoreTest.{BothVariantMutator, HalfVariantMutator}

      assert Mutare.Mutator.Dispatch.opted_in?(BothVariantMutator)
      refute Mutare.Mutator.Dispatch.opted_in?(HalfVariantMutator)

      # A mutator declaring only `variants/0` (no `variant/2`) exposes NO vocabulary, so the
      # validation side agrees with the recording side (which tags no label): a `[family:label]`
      # qualifier against it is the clean `:no_variants` hard error, never a silently-unmatched
      # label that validates-as-known but suppresses nothing.
      half = Mutare.Mutators.vocabulary(Mutare.Mutators.resolve([HalfVariantMutator]))
      assert half["half_variant"] == :none

      both = Mutare.Mutators.vocabulary(Mutare.Mutators.resolve([BothVariantMutator]))
      assert both["both_variant"] == MapSet.new(~w(a b))
    end

    test "every site's recorded variant is one its mutator declares (no drift)" do
      # Exercise the opted-in families and assert each recorded label is a member of the
      # producing family's declared vocabulary — the static guarantee `variant/2` ⊆ `variants/0`.
      # Includes bitwise (`&&&`/`|||`/`<<<`) and list (`++`/`[]`) so those families' membership is
      # checked here too, not just the non-empty completeness test below.
      source = """
      defmodule Drift do
        import Bitwise
        def f(i, j) do
          x = i < j && i > j
          y = (i + j) * 2 - 1
          z = i === j
          w = (i &&& j) ||| (i <<< 2)
          v = [i] ++ [j]
          if x, do: build(i), else: y
          {z, w, v}
        end
      end
      """

      {_meta, sites, _} = Mutare.transform_string(source)

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

      {_meta, sites, _} = Mutare.transform_string(source)

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
        Mutare.transform_string("""
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
        Mutare.transform_string("""
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

    test "a literal off-by-one that collapses onto 0 carries BOTH the off-by-one and zero labels" do
      # `x - 1`: the `1` literal's `n - 1` mutant is `0`, merged with the zero sentinel into one
      # deduped mutant. It belongs to both kinds, so it advertises *both* labels — and a user
      # reasoning about the decrement (`pred`) or about the zero boundary (`zero`) each find it.
      {_meta, sites, _} =
        Mutare.transform_string("defmodule L do\n  def f(x), do: x - 1\nend\n")

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
        {_meta, sites, _} = Mutare.transform_string(src)

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
