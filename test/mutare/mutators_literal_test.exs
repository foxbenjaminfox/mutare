defmodule Mutare.MutatorsLiteralTest do
  # Unit tests of the literal-swap families' `mutate/1`: a literal → empty/sentinel/shifted
  # value, plus `name/0`. Clean-meta rendering and context routing (which positions admit a
  # literal swap) live in transform_test.exs; this file probes the swap logic directly.
  use ExUnit.Case, async: true

  alias Mutare.Mutators.{
    AliasLiteral,
    AtomLiteral,
    BitstringLiteral,
    CharlistLiteral,
    DateTimeLiteral,
    FloatLiteral,
    Literal,
    MapLiteral,
    RegexLiteral,
    StringLiteral,
    StringSigilLiteral,
    TupleLiteral,
    WordListLiteral
  }

  describe "Literal" do
    test "mutates an integer to n+1, n-1 and 0, deduped and never itself" do
      assert render(Literal.mutate(parse("2"))) == ["3", "1", "0"]
      assert render(Literal.mutate(parse("1"))) == ["2", "0"]
      assert render(Literal.mutate(parse("0"))) == ["1", "-1"]
    end

    test "flips a boolean" do
      assert render(Literal.mutate(parse("true"))) == ["false"]
      assert render(Literal.mutate(parse("false"))) == ["true"]
    end

    test "emits clean metadata so the new value renders (not the original token)" do
      # The original carries `token: \"1\"`; reusing it would render \"1\".
      assert render(Literal.mutate(parse("1"))) == ["2", "0"]
      assert Enum.all?(Literal.mutate(parse("1")), fn {:__block__, meta, _} -> meta == [] end)
    end

    test "skips non-integer, non-boolean literals and operators" do
      assert Literal.mutate(parse("1.5")) == :skip
      assert Literal.mutate(parse(~s("s"))) == :skip
      assert Literal.mutate({:+, [], [1, 2]}) == :skip
    end

    test "name" do
      assert Literal.name() == :literal
    end
  end

  describe "StringLiteral" do
    test "mutates a non-empty string into both the empty string and the sentinel" do
      assert render(StringLiteral.mutate(parse(~s("hello")))) == [~s(""), ~s("mutare")]
    end

    test "drops the replacement that already equals the original" do
      # "" can't become "" again; "mutare" can't become "mutare" again
      assert render(StringLiteral.mutate(parse(~s("")))) == [~s("mutare")]
      assert render(StringLiteral.mutate(parse(~s("mutare")))) == [~s("")]
    end

    test "mutates an interpolated string (a delimiter-marked <<>>) as a whole" do
      assert render(StringLiteral.mutate(parse(~S|"a#{x}b"|))) == [~s(""), ~s("mutare")]
      assert render(StringLiteral.mutate(parse(~S|"#{x}"|))) == [~s(""), ~s("mutare")]
    end

    test "skips a real bitstring (no delimiter) — BitstringLiteral's domain" do
      assert StringLiteral.mutate(parse("<<104, 105>>")) == :skip
      assert StringLiteral.mutate(parse(~S|<<"x"::utf8>>|)) == :skip
    end

    test "skips non-string literals" do
      assert StringLiteral.mutate(parse("1")) == :skip
      assert StringLiteral.mutate(parse(":atom")) == :skip
    end

    test "name" do
      assert StringLiteral.name() == :string
    end
  end

  describe "StringSigilLiteral" do
    test "mutates a non-empty ~s/~S sigil into both the empty string and the sentinel" do
      assert render(StringSigilLiteral.mutate(parse("~s(hello)"))) == [~s(""), ~s("mutare")]
      assert render(StringSigilLiteral.mutate(parse("~S(hello)"))) == [~s(""), ~s("mutare")]
    end

    test "drops the replacement that already equals the sigil's content" do
      # ~s() is already "" so only the sentinel is offered; ~s(mutare) only the empty string.
      assert render(StringSigilLiteral.mutate(parse("~s()"))) == [~s("mutare")]
      assert render(StringSigilLiteral.mutate(parse("~S()"))) == [~s("mutare")]
      assert render(StringSigilLiteral.mutate(parse("~s(mutare)"))) == [~s("")]
      assert render(StringSigilLiteral.mutate(parse("~S(mutare)"))) == [~s("")]
    end

    test "mutates an interpolated ~s as a whole (both variants always apply)" do
      assert render(StringSigilLiteral.mutate(parse("~s(a\#{x}b)"))) == [~s(""), ~s("mutare")]
      assert render(StringSigilLiteral.mutate(parse("~s(\#{x})"))) == [~s(""), ~s("mutare")]
    end

    test "skips plain strings (StringLiteral's domain) and other sigils" do
      assert StringSigilLiteral.mutate(parse(~s("hello"))) == :skip
      assert StringSigilLiteral.mutate(parse("~w(a b)")) == :skip
      assert StringSigilLiteral.mutate(parse(~S|~c"ab"|)) == :skip
      assert StringSigilLiteral.mutate(parse("~r/ab/")) == :skip
    end

    test "name" do
      assert StringSigilLiteral.name() == :string_sigil
    end
  end

  describe "FloatLiteral" do
    test "mutates a float to x+1.0, x-1.0 and 0.0, deduped and never itself" do
      assert render(FloatLiteral.mutate(parse("1.5"))) == ["2.5", "0.5", "0.0"]
      assert render(FloatLiteral.mutate(parse("0.0"))) == ["1.0", "-1.0"]
    end

    test "skips integers" do
      assert FloatLiteral.mutate(parse("1")) == :skip
    end

    test "name" do
      assert FloatLiteral.name() == :float
    end
  end

  describe "AtomLiteral" do
    test "mutates a literal atom into the sentinel atom" do
      assert render(AtomLiteral.mutate(parse(":waiting"))) == [":mutare"]
      assert render(AtomLiteral.mutate(parse(":some_status"))) == [":mutare"]
    end

    test "drops the replacement that already equals the sentinel" do
      assert AtomLiteral.mutate(parse(":mutare")) == :skip
    end

    test "skips convention atoms (owned by ConventionAtom, swapped to a sibling)" do
      assert AtomLiteral.mutate(parse(":ok")) == :skip
      assert AtomLiteral.mutate(parse(":error")) == :skip
      assert AtomLiteral.mutate(parse(":cont")) == :skip
      assert AtomLiteral.mutate(parse(":halt")) == :skip
      # `:eq` is *not* paired by ConventionAtom (the unpaired middle), so it keeps its sentinel.
      assert render(AtomLiteral.mutate(parse(":eq"))) == [":mutare"]
    end

    test "skips true/false/nil (handled by Literal / Conditional, or absence)" do
      assert AtomLiteral.mutate(parse("true")) == :skip
      assert AtomLiteral.mutate(parse("false")) == :skip
      assert AtomLiteral.mutate(parse("nil")) == :skip
    end

    test "skips non-atom literals and bare atoms (function names, etc.)" do
      assert AtomLiteral.mutate(parse("1")) == :skip
      assert AtomLiteral.mutate(parse(~s("str"))) == :skip
      # A bare (un-`__block__`-wrapped) atom is never a literal node the analyzer offers.
      assert AtomLiteral.mutate(:upcase) == :skip
    end

    test "name" do
      assert AtomLiteral.name() == :atom
    end
  end

  describe "CharlistLiteral" do
    test "mutates a ~c sigil into the empty charlist and the sentinel" do
      assert render(CharlistLiteral.mutate(parse(~S|~c"abc"|))) == [~S|~c""|, ~S|~c"mutare"|]
    end

    test "drops the replacement that already equals the original" do
      assert render(CharlistLiteral.mutate(parse(~S|~c""|))) == [~S|~c"mutare"|]
      assert render(CharlistLiteral.mutate(parse(~S|~c"mutare"|))) == [~S|~c""|]
    end

    test "leaves the legacy '...' form alone (owned by List, which empties it)" do
      assert CharlistLiteral.mutate(parse("'abc'")) == :skip
    end

    test "skips strings and other literals" do
      assert CharlistLiteral.mutate(parse(~s("abc"))) == :skip
      assert CharlistLiteral.mutate(parse(":abc")) == :skip
    end

    test "name" do
      assert CharlistLiteral.name() == :charlist
    end
  end

  describe "WordListLiteral" do
    test "mutates a ~w sigil into the empty word list and the sentinel" do
      assert render(WordListLiteral.mutate(parse("~w(foo bar baz)"))) == ["~w()", "~w(mutare)"]
    end

    test "mutates an uppercase ~W sigil the same way" do
      assert render(WordListLiteral.mutate(parse("~W(foo bar)"))) == ["~W()", "~W(mutare)"]
    end

    test "preserves the modifier so the element type is unchanged" do
      assert render(WordListLiteral.mutate(parse("~w(foo bar)a"))) == ["~w()a", "~w(mutare)a"]
      assert render(WordListLiteral.mutate(parse("~w(foo bar)c"))) == ["~w()c", "~w(mutare)c"]
    end

    test "drops the replacement that already equals the original (by words produced)" do
      assert render(WordListLiteral.mutate(parse("~w()"))) == ["~w(mutare)"]
      assert render(WordListLiteral.mutate(parse("~w(mutare)"))) == ["~w()"]
      # whitespace-only already produces [], so the empty mutant is not re-emitted
      assert render(WordListLiteral.mutate(parse("~w(   )"))) == ["~w(mutare)"]
    end

    test "skips an interpolated ~w (parsed as multiple <<>> parts, not a static binary)" do
      assert WordListLiteral.mutate(parse(~S|~w(foo #{x} bar)|)) == :skip
    end

    test "skips other sigils and list literals (owned elsewhere)" do
      assert WordListLiteral.mutate(parse(~S|~c"abc"|)) == :skip
      assert WordListLiteral.mutate(parse("[1, 2, 3]")) == :skip
    end

    test "name" do
      assert WordListLiteral.name() == :word_list
    end
  end

  describe "MapLiteral" do
    test "collapses a non-empty map literal to %{}" do
      assert render(MapLiteral.mutate(parse("%{a: 1, b: 2}"))) == ["%{}"]
      assert render(MapLiteral.mutate(parse("%{1 => 2}"))) == ["%{}"]
    end

    test "skips the empty map and a map update" do
      assert MapLiteral.mutate(parse("%{}")) == :skip
      assert MapLiteral.mutate(parse("%{m | a: 1}")) == :skip
    end

    test "name" do
      assert MapLiteral.name() == :map
    end
  end

  describe "TupleLiteral" do
    test "collapses a non-empty tuple literal to {} (both 2- and 3+-arity)" do
      assert render(TupleLiteral.mutate(parse("{1, 2}"))) == ["{}"]
      assert render(TupleLiteral.mutate(parse("{1, 2, 3}"))) == ["{}"]
      assert render(TupleLiteral.mutate(parse("{:ok}"))) == ["{}"]
    end

    test "skips the empty tuple" do
      assert TupleLiteral.mutate(parse("{}")) == :skip
    end

    test "name" do
      assert TupleLiteral.name() == :tuple
    end
  end

  describe "BitstringLiteral" do
    test "collapses a non-empty bitstring literal to <<>>" do
      assert render(BitstringLiteral.mutate(parse("<<1, 2, 3>>"))) == ["<<>>"]
      assert render(BitstringLiteral.mutate(parse(~S|<<"abc">>|))) == ["<<>>"]
    end

    test "skips the empty bitstring" do
      assert BitstringLiteral.mutate(parse("<<>>")) == :skip
    end

    test "skips an interpolated string (a `<<>>` written as a string)" do
      # `"a#{x}b"` parses as a `<<>>` carrying a delimiter — StringLiteral's domain.
      assert BitstringLiteral.mutate(parse(~S|"a#{x}b"|)) == :skip
      assert BitstringLiteral.mutate(parse(~S|"#{x}"|)) == :skip
    end

    test "skips a plain string and other literals" do
      assert BitstringLiteral.mutate(parse(~s("abc"))) == :skip
      assert BitstringLiteral.mutate(parse("[1, 2]")) == :skip
    end

    test "name" do
      assert BitstringLiteral.name() == :bitstring
    end
  end

  describe "RegexLiteral" do
    test "mutates a ~r pattern into the empty pattern and the sentinel" do
      assert render(RegexLiteral.mutate(parse(~S|~r/foo/|))) == [~S|~r//|, ~S|~r/mutare/|]
    end

    test "preserves modifier flags on the whole-pattern replacements" do
      assert render(RegexLiteral.mutate(parse(~S|~r/foo/i|))) ==
               [~S|~r//i|, ~S|~r/mutare/i|, ~S|~r/foo/|]
    end

    test "drops the replacement that already equals the original" do
      assert render(RegexLiteral.mutate(parse(~S|~r//|))) == [~S|~r/mutare/|]
    end

    test "drops a leading ^ anchor" do
      assert ~S|~r/abc/| in render(RegexLiteral.mutate(parse(~S|~r/^abc/|)))
    end

    test "drops an unescaped trailing $ anchor" do
      assert ~S|~r/abc/| in render(RegexLiteral.mutate(parse(~S|~r/abc$/|)))
    end

    test "drops each anchor of ^abc$ independently" do
      mutants = render(RegexLiteral.mutate(parse(~S|~r/^abc$/|)))
      assert ~S|~r/abc$/| in mutants
      assert ~S|~r/^abc/| in mutants
    end

    test "leaves an escaped trailing $ alone" do
      refute ~S|~r/abc\$/| in render(RegexLiteral.mutate(parse(~S|~r/abc\$/|)))
      assert render(RegexLiteral.mutate(parse(~S|~r/abc\$/|))) == [~S|~r//|, ~S|~r/mutare/|]
    end

    test "interleaves every per-token axis left-to-right, in source order" do
      # Each `\d` offers its shorthand flip; each `+` offers swap/collapse/lazy; the
      # `\.` offers its dot-unescape — all emitted in left-to-right source order.
      assert render(RegexLiteral.mutate(parse(~S|~r/\d+\.\d+/|))) ==
               [
                 ~S|~r//|,
                 ~S|~r/mutare/|,
                 ~S|~r/\D+\.\d+/|,
                 ~S|~r/\d*\.\d+/|,
                 ~S|~r/\d\.\d+/|,
                 ~S|~r/\d+?\.\d+/|,
                 ~S|~r/\d+.\d+/|,
                 ~S|~r/\d+\.\D+/|,
                 ~S|~r/\d+\.\d*/|,
                 ~S|~r/\d+\.\d/|,
                 ~S|~r/\d+\.\d+?/|
               ]

      assert ~S|~r/\d/| in render(RegexLiteral.mutate(parse(~S|~r/\D/|)))
    end

    test "complements a \\b word boundary only outside a character class" do
      assert ~S|~r/\B/| in render(RegexLiteral.mutate(parse(~S|~r/\b/|)))
      # inside a class \b is a backspace — only the class negation is offered
      assert render(RegexLiteral.mutate(parse(~S|~r/[\b]/|))) ==
               [~S|~r//|, ~S|~r/mutare/|, ~S|~r/[^\b]/|]
    end

    test "does not treat an escaped backslash as a shorthand" do
      assert render(RegexLiteral.mutate(parse(~S|~r/\\d/|))) == [~S|~r//|, ~S|~r/mutare/|]
    end

    test "toggles a character class between matching and negated" do
      assert ~S|~r/[^abc]/| in render(RegexLiteral.mutate(parse(~S|~r/[abc]/|)))
      assert ~S|~r/[abc]/| in render(RegexLiteral.mutate(parse(~S|~r/[^abc]/|)))
    end

    test "negates a class with a literal leading ] correctly" do
      assert ~S|~r/[^]a]/| in render(RegexLiteral.mutate(parse(~S|~r/[]a]/|)))
    end

    test "offers both negation and shorthand swaps inside one class" do
      mutants = render(RegexLiteral.mutate(parse(~S|~r/[\d]/|)))
      assert ~S|~r/[^\d]/| in mutants
      assert ~S|~r/[\D]/| in mutants
    end

    test "drops a leading \\A and a trailing \\z/\\Z anchor" do
      assert ~S|~r/start/| in render(RegexLiteral.mutate(parse(~S|~r/\Astart/|)))
      assert ~S|~r/end/| in render(RegexLiteral.mutate(parse(~S|~r/end\z/|)))
      assert ~S|~r/end/| in render(RegexLiteral.mutate(parse(~S|~r/end\Z/|)))
      # an escaped backslash before z is not an anchor
      assert render(RegexLiteral.mutate(parse(~S|~r/end\\z/|))) == [~S|~r//|, ~S|~r/mutare/|]
    end

    test "swaps $ for the strict \\z end-anchor regardless of /m (\\z differs from $)" do
      assert ~S|~r/abc\z/| in render(RegexLiteral.mutate(parse(~S|~r/abc$/|)))
      assert ~S|~r/\Aabc$/| in render(RegexLiteral.mutate(parse(~S|~r/\Aabc\z/|)))
    end

    test "offers ^<->\\A and $<->\\Z only under /m (they are equivalent otherwise)" do
      # without /m: `^`≡`\A` and `$`≡`\Z`, so neither swap is offered (only `$`→`\z`)
      without = render(RegexLiteral.mutate(parse(~S|~r/^abc$/|)))
      refute ~S|~r/\Aabc$/| in without
      refute ~S|~r/^abc\Z/| in without
      assert ~S|~r/^abc\z/| in without

      # with /m: `^` is a line start and `$` a line end — every swap is live
      with_m = render(RegexLiteral.mutate(parse(~S|~r/^abc$/m|)))
      assert ~S|~r/\Aabc$/m| in with_m
      assert ~S|~r/^abc\z/m| in with_m
      assert ~S|~r/^abc\Z/m| in with_m
    end

    test "swaps an anchor anywhere it is real (mid-pattern), under /m" do
      mutants = render(RegexLiteral.mutate(parse(~S"~r/(^a|b$)/m")))
      # the `^` after `(` and the `$` before `)` are both real anchors
      assert ~S"~r/(\Aa|b$)/m" in mutants
      assert ~S"~r/(^a|b\z)/m" in mutants
    end

    test "does not swap an escaped or in-class anchor" do
      # `\$` is a literal dollar; `\Z` here is preceded by an escaped backslash
      assert render(RegexLiteral.mutate(parse(~S|~r/a\$b/|))) == [~S|~r//|, ~S|~r/mutare/|]
      # `^`/`$` inside a class are literals — only the class negation is offered
      assert render(RegexLiteral.mutate(parse(~S|~r/[$^]/|))) ==
               [~S|~r//|, ~S|~r/mutare/|, ~S|~r/[^$^]/|]
    end

    test "reads the m flag positionally through an inline (?m)" do
      # a global (?m): both anchors are multiline, so `^`<->`\A` and `$`<->`\Z` are live
      assert ~S"~r/(?m)\Aa$/" in render(RegexLiteral.mutate(parse(~S"~r/(?m)^a$/")))

      # `^` *before* the (?m) is not multiline (no `\A` swap); the `$` *after* it is
      before_after = render(RegexLiteral.mutate(parse(~S"~r/^a(?m)$/")))
      refute ~S"~r/\Aa(?m)$/" in before_after
      assert ~S"~r/^a(?m)\Z/" in before_after

      # scoped (?m:…): only the in-scope `^` swaps; the one after the group does not
      scoped = render(RegexLiteral.mutate(parse(~S"~r/(?m:^a)^b/")))
      assert ~S"~r/(?m:\Aa)^b/" in scoped
      refute ~S"~r/(?m:^a)\Ab/" in scoped

      # a bare (?m) inside a group expires at the group's ) — `^c` is not multiline
      nested = render(RegexLiteral.mutate(parse(~S"~r/a((?m)^b)^c/")))
      assert ~S"~r/a((?m)\Ab)^c/" in nested
      refute ~S"~r/a((?m)^b)\Ac/" in nested

      # (?-m) turns multiline back off
      toggled = render(RegexLiteral.mutate(parse(~S"~r/(?m)^a(?-m)^b/")))
      assert ~S"~r/(?m)\Aa(?-m)^b/" in toggled
      refute ~S"~r/(?m)^a(?-m)\Ab/" in toggled

      # an unset combined with another flag (`(?-Xm)`, X being a real inline flag) still
      # disables `m`, so `^` stays non-multiline — no guaranteed-equivalent `\A` swap
      refute ~S"~r/(?-Xm)\Aa/m" in render(RegexLiteral.mutate(parse(~S"~r/(?-Xm)^a/m")))
    end

    test "an inline (?i) does not enable anchor multiline-ness, and a comment is skipped" do
      # `(?i)` changes case, not anchors — no `^`<->`\A`
      refute ~S"~r/(?i)\Aa/" in render(RegexLiteral.mutate(parse(~S"~r/(?i)^a/")))
      # a `^` inside a `(?#…)` comment is not an anchor at all
      assert render(RegexLiteral.mutate(parse(~S"~r/(?#^c)b/"))) == [~S"~r//", ~S"~r/mutare/"]
    end

    test "treats a \\Q…\\E span as an inert literal across every pass" do
      # quoted metacharacters are literals — `a+`/`.`/`(` inside must not be mutated (scan)
      assert render(RegexLiteral.mutate(parse(~S|~r/\Qa+.(\E/|))) == [~S|~r//|, ~S|~r/mutare/|]

      # the quoted `(` must NOT push a flag frame: `m` from `(?m:…)` must not leak past
      # the real `)` onto the outside `^b` (which would emit a guaranteed-equivalent `\A`)
      quoted = render(RegexLiteral.mutate(parse(~S"~r/(?m:\Q(\E^a)^b/")))
      assert ~S"~r/(?m:\Q(\E\Aa)^b/" in quoted
      refute ~S"~r/(?m:\Q(\E^a)\Ab/" in quoted

      # a quoted `|` is not alternation — only the *real* `|` (between `x` and `\Qa|b\Ey`)
      # yields a branch drop; nothing splits the quoted span
      alt = render(RegexLiteral.mutate(parse(~S"~r/x|\Qa|b\Ey/")))
      assert ~S"~r/\Qa|b\Ey/" in alt
      assert ~S"~r/x/" in alt
      refute Enum.any?(alt, &(&1 =~ ~r/\\Qa\\E|\\Qb\\E/))
    end

    test "ignores anchors, dots, quantifiers and flags hidden in an extended-mode comment" do
      # under /x an unescaped `#` starts a comment: the `$` there is inert (mode_walk swap)
      # *and* not a droppable trailing anchor (anchor_patterns) — so no `\z` and no `foo # `
      foo = render(RegexLiteral.mutate(parse(~S|~r/foo # $/x|)))
      refute Enum.any?(foo, &String.contains?(&1, "\\z"))
      refute ~S"~r/foo # /x" in foo

      # a quantifier inside an x-comment is not mutated (scan); the real dot on line 2 is
      node = {:sigil_r, [], [{:<<>>, [], ["a # b+\nc."]}, ~c"x"]}
      pats = Enum.map(RegexLiteral.mutate(node), fn {:sigil_r, _, [{:<<>>, _, [p]}, _]} -> p end)
      refute "a # b*\nc." in pats
      assert "a # b+\nc(?s:.)" in pats

      # a `(?s)` inside an x-comment must not activate dotall for the real dot after the
      # newline — that dot is non-dotall, so its swap is `(?s:.)`, never `(?-s:.)`
      node2 = {:sigil_r, [], [{:<<>>, [], ["# (?s) c\n."]}, ~c"x"]}

      pats2 =
        Enum.map(RegexLiteral.mutate(node2), fn {:sigil_r, _, [{:<<>>, _, [p]}, _]} -> p end)

      assert "# (?s) c\n(?s:.)" in pats2
      refute "# (?s) c\n(?-s:.)" in pats2
    end

    test "treats a (?#…) PCRE comment as inert in every pass" do
      # `(?#…)` content is ignored by the engine, so mutating it is guaranteed-equivalent —
      # the shared reader classifies it as a comment, so scan leaves `x+` inside it alone
      assert render(RegexLiteral.mutate(parse(~S"~r/a(?#x+y)b/"))) == [~S"~r//", ~S"~r/mutare/"]
    end

    test "consumes a POSIX class so its inner ] doesn't end the enclosing class" do
      # the `]` of `[:alpha:]` must not close the outer class; otherwise the `(` after it
      # would push a phantom frame and `m` would leak to the outside `^b` as a bogus `\A`
      mutants = render(RegexLiteral.mutate(parse(~S"~r/(?m:[[:alpha:](])^b/")))
      refute ~S"~r/(?m:[[:alpha:](])\Ab/" in mutants
      assert ~S"~r/(?m:[^[:alpha:](])^b/" in mutants
    end

    test "treats a (*VERB…) control verb as an inert atom" do
      # the verb's argument is literal — its `(`/`|` must not push a frame or read as
      # alternation, and `m` must not leak to the outside `^b`
      refute ~S"~r/(?m:(*MARK:()x)\Ab/" in render(
               RegexLiteral.mutate(parse(~S"~r/(?m:(*MARK:()x)^b/"))
             )

      assert render(RegexLiteral.mutate(parse(~S"~r/(*MARK:a|b)c/"))) == [
               ~S"~r//",
               ~S"~r/mutare/"
             ]
    end

    test "sees a quantifier suffix through ignored text (comment or x-whitespace)" do
      # `a+(?#c)?` is a lazy plus across a comment: only the `+`<->`*` swap; no collapse and
      # the trailing `?` is the suffix, not a fresh quantifier
      assert render(RegexLiteral.mutate(parse(~S"~r/a+(?#c)?/"))) ==
               [~S"~r//", ~S"~r/mutare/", ~S"~r/a*(?#c)?/"]

      # `a+ ?` under /x is `a+?` (the space is ignored) — same: swap only, no collapse
      ws = render(RegexLiteral.mutate(parse(~S"~r/a+ ?/x")))
      assert ~S"~r/a* ?/x" in ws
      refute ~S"~r/a ?/x" in ws
    end

    test "ends an x-mode comment at a carriage return, not just a line feed" do
      # PCRE ends the `#` comment at the CR, so the following dot is active and mutates
      node = {:sigil_r, [], [{:<<>>, [], ["# c\r."]}, ~c"x"]}
      pats = Enum.map(RegexLiteral.mutate(node), fn {:sigil_r, _, [{:<<>>, _, [p]}, _]} -> p end)
      assert "# c\r(?s:.)" in pats
      assert "# c\r\\." in pats
    end

    test "consumes the argument of a \\cX control escape" do
      # `\c(` is one escape; its `(` must not push a frame and leak `m` to the outside `^b`
      mutants = render(RegexLiteral.mutate(parse(~S"~r/(?m:\c(^a)^b/")))
      refute ~S"~r/(?m:\c(^a)\Ab/" in mutants
      assert ~S"~r/(?m:\c(\Aa)^b/" in mutants
    end

    test "skips guaranteed-equivalent quantifier variants on a zero-width atom" do
      # `(?=a)+` (1+ of a zero-width lookahead) ≡ `(?=a)` ≡ `(?=a)+?`, so only the
      # class-changing `+`<->`*` swap is offered; collapse and lazy are suppressed
      assert render(RegexLiteral.mutate(parse(~S"~r/(?=a)+/"))) ==
               [~S"~r//", ~S"~r/mutare/", ~S"~r/(?=a)*/"]

      # `(?=a)*` keeps the class-changing `*`->`+` swap and `*`-collapse, drops only lazy
      star = render(RegexLiteral.mutate(parse(~S"~r/(?=a)*/")))
      assert ~S"~r/(?=a)+/" in star
      assert ~S"~r/(?=a)/" in star
      refute ~S"~r/(?=a)*?/" in star

      # a *capturing* group is not zero-width — its quantifier keeps collapse + lazy
      cap = render(RegexLiteral.mutate(parse(~S"~r/(a)+/")))
      assert ~S"~r/(a)/" in cap
      assert ~S"~r/(a)+?/" in cap
    end

    test "skips equivalent bounded-quantifier counts on a zero-width atom" do
      # repeating a zero-width assertion a positive number of times is idempotent, so a
      # `{n}`/`{n,m}` mutation matters only if it crosses the min-count 0 ↔ ≥1 boundary
      assert render(RegexLiteral.mutate(parse(~S"~r/(?=a){2}/"))) == [~S"~r//", ~S"~r/mutare/"]
      assert ~S"~r/(?=a){0}/" in render(RegexLiteral.mutate(parse(~S"~r/(?=a){1}/")))
      assert ~S"~r/(?=a){1,2}/" in render(RegexLiteral.mutate(parse(~S"~r/(?=a){0,2}/")))

      # a normal (non-zero-width) bound keeps its off-by-one neighbours
      assert ~S"~r/a{1}/" in render(RegexLiteral.mutate(parse(~S"~r/a{2}/")))
    end

    test "skips leading anchor swaps (both directions) under firstline+multiline" do
      # `/f` requires the match to start in the first line, so a *leading* `^`/`\A` under
      # `/mf` is the subject start — `^` and `\A` are equivalent there, both swaps no-ops
      refute ~S"~r/\Aa$/mf" in render(RegexLiteral.mutate(parse(~S"~r/^a$/mf")))
      # a leading `^` need not be at offset 0 — `(?m)^a/f` has it after the inline modifier
      refute ~S"~r/(?m)\Aa/f" in render(RegexLiteral.mutate(parse(~S"~r/(?m)^a/f")))
      # the reverse `\A`->`^` swap is suppressed for a leading `\A` too
      refute ~S"~r/^a/fm" in render(RegexLiteral.mutate(parse(~S"~r/\Aa/fm")))
      # without `/f`, the `\A`<->`^` swap is still offered under `/m`
      assert ~S"~r/^a/m" in render(RegexLiteral.mutate(parse(~S"~r/\Aa/m")))
    end

    test "drops a quantifier-collapse that would render an interpolation marker" do
      # `Regex.compile/2` accepts `#{` (literal `#` then `{`), but rendered as `~r/#{/` it is
      # an unterminated Elixir interpolation that would poison the metamutant — so dropped
      mutants = render(RegexLiteral.mutate(parse(~S"~r/#+{/")))
      refute Enum.any?(mutants, &(&1 =~ ~r/~r.#\{/))
      # the other mutations of the same pattern still render fine
      assert ~S"~r/#*{/" in mutants
    end

    test "validates a /r (deprecated) regex without emitting deprecation warnings" do
      # `/r` is an alias of `/U`; the compile-safety check normalises it so the validation
      # (run once per candidate) doesn't flood the run with deprecation warnings
      out =
        ExUnit.CaptureIO.capture_io(:stderr, fn -> RegexLiteral.mutate(parse(~S"~r/a+b/r")) end)

      refute out =~ "deprecated"
      # and mutants are still produced (validation still works)
      assert ~S"~r/a*b/r" in render(RegexLiteral.mutate(parse(~S"~r/a+b/r")))
    end

    test "swaps a + quantifier to * and back" do
      assert ~S|~r/\d*/| in render(RegexLiteral.mutate(parse(~S|~r/\d+/|)))
      assert ~S|~r/a+/| in render(RegexLiteral.mutate(parse(~S|~r/a*/|)))
    end

    test "collapses a + / * quantifier to exactly-one, and adds a lazy suffix" do
      # `\d+` → swap `\d*`, collapse `\d`, lazy `\d+?`
      assert render(RegexLiteral.mutate(parse(~S|~r/\d+/|))) ==
               [~S|~r//|, ~S|~r/mutare/|, ~S|~r/\D+/|, ~S|~r/\d*/|, ~S|~r/\d/|, ~S|~r/\d+?/|]

      # `a*` → swap `a+`, collapse `a`, lazy `a*?`
      assert render(RegexLiteral.mutate(parse(~S|~r/a*/|))) ==
               [~S|~r//|, ~S|~r/mutare/|, ~S|~r/a+/|, ~S|~r/a/|, ~S|~r/a*?/|]
    end

    test "leaves a lazy/possessive suffix and a quantifier inside a class alone" do
      # the `+` swaps to `*`, but its lazy `?` suffix blocks both collapse and a second
      # suffix — so neither `a` (collapse) nor `a+??` (lazy) is offered, only `a*?`
      assert render(RegexLiteral.mutate(parse(~S|~r/a+?/|))) ==
               [~S|~r//|, ~S|~r/mutare/|, ~S|~r/a*?/|]

      # a possessive suffix `a++` likewise blocks collapse / re-suffix on the first `+`
      assert render(RegexLiteral.mutate(parse(~S|~r/a++/|))) ==
               [~S|~r//|, ~S|~r/mutare/|, ~S|~r/a*+/|]

      # `*`/`+` inside a class are literal — only the class negation is offered
      assert render(RegexLiteral.mutate(parse(~S|~r/[*+]/|))) ==
               [~S|~r//|, ~S|~r/mutare/|, ~S|~r/[^*+]/|]
    end

    test "does not reinterpret an already-suffixed optional quantifier" do
      # `a??` (lazy) / `a?+` (possessive): the first `?` is the base of a compound
      # quantifier, so dropping/raising it would turn the trailing `?`/`+` into the
      # operator (`a?+` → `a+`) — leave both whole, offering no quantifier mutation
      assert render(RegexLiteral.mutate(parse(~S|~r/a??/|))) == [~S|~r//|, ~S|~r/mutare/|]
      assert render(RegexLiteral.mutate(parse(~S|~r/a?+/|))) == [~S|~r//|, ~S|~r/mutare/|]
    end

    test "turns an optional ? mandatory (drop it, raise it to + and *, add a lazy ??)" do
      assert render(RegexLiteral.mutate(parse(~S|~r/colou?r/|))) ==
               [
                 ~S|~r//|,
                 ~S|~r/mutare/|,
                 ~S|~r/colour/|,
                 ~S|~r/colou+r/|,
                 ~S|~r/colou*r/|,
                 ~S|~r/colou??r/|
               ]
    end

    test "does not treat a ? group marker as an optional quantifier" do
      # the `?` in `(?:…)` is a group marker, not a quantifier — nothing to mutate here
      assert render(RegexLiteral.mutate(parse(~S|~r/(?:ab)/|))) == [~S|~r//|, ~S|~r/mutare/|]
    end

    test "nudges a bounded quantifier's counts by one, and reshapes it, staying in range" do
      # exact: ±1 neighbours only — no lazy `{n}?` (a fixed count makes `?` a no-op)
      assert render(RegexLiteral.mutate(parse(~S|~r/a{3}/|))) ==
               [~S|~r//|, ~S|~r/mutare/|, ~S|~r/a{2}/|, ~S|~r/a{4}/|]

      # a *fixed* range `{n,n}` is likewise no-lazy (and `{n}` exact-pin is skipped)
      assert render(RegexLiteral.mutate(parse(~S|~r/a{2,2}/|))) ==
               [~S|~r//|, ~S|~r/mutare/|, ~S|~r/a{1,2}/|, ~S|~r/a{2,3}/|, ~S|~r/a{2,}/|]

      # at-least: ±1 neighbours, pin-to-exact `{n}`, lazy `{n,}?`
      assert render(RegexLiteral.mutate(parse(~S|~r/a{8,}/|))) ==
               [
                 ~S|~r//|,
                 ~S|~r/mutare/|,
                 ~S|~r/a{7,}/|,
                 ~S|~r/a{9,}/|,
                 ~S|~r/a{8}/|,
                 ~S|~r/a{8,}?/|
               ]

      # range: each endpoint ±1, drop-upper `{n,}`, pin-to-exact `{n}`, lazy `{n,m}?`
      assert render(RegexLiteral.mutate(parse(~S|~r/a{2,4}/|))) ==
               [
                 ~S|~r//|,
                 ~S|~r/mutare/|,
                 ~S|~r/a{1,4}/|,
                 ~S|~r/a{3,4}/|,
                 ~S|~r/a{2,3}/|,
                 ~S|~r/a{2,5}/|,
                 ~S|~r/a{2,}/|,
                 ~S|~r/a{2}/|,
                 ~S|~r/a{2,4}?/|
               ]

      # a lower bound never goes below zero
      assert render(RegexLiteral.mutate(parse(~S|~r/a{0,2}/|))) ==
               [
                 ~S|~r//|,
                 ~S|~r/mutare/|,
                 ~S|~r/a{1,2}/|,
                 ~S|~r/a{0,1}/|,
                 ~S|~r/a{0,3}/|,
                 ~S|~r/a{0,}/|,
                 ~S|~r/a{0}/|,
                 ~S|~r/a{0,2}?/|
               ]

      # Boundary cases where a ±1 neighbour lands *exactly* on the clamp edge — the
      # only inputs that pin the inclusive `>= 0` / `>= n` / `<= m` filters (a
      # strict `>`/`<` would drop the edge value, an unconditional filter would
      # keep an out-of-range one).
      #   `a{1}` (exact): the lower neighbour is exactly 0 — kept (≥ 0), so `a{0}`.
      assert render(RegexLiteral.mutate(parse(~S|~r/a{1}/|))) ==
               [~S|~r//|, ~S|~r/mutare/|, ~S|~r/a{0}/|, ~S|~r/a{2}/|]

      #   `a{0}` (exact 0): the lower neighbour −1 is dropped (< 0), only `a{1}`.
      assert render(RegexLiteral.mutate(parse(~S|~r/a{0}/|))) ==
               [~S|~r//|, ~S|~r/mutare/|, ~S|~r/a{1}/|]

      #   `a{1,4}` (range): lower neighbour 0 kept (≥ 0 and ≤ m), so `a{0,4}`.
      assert render(RegexLiteral.mutate(parse(~S|~r/a{1,4}/|))) ==
               [
                 ~S|~r//|,
                 ~S|~r/mutare/|,
                 ~S|~r/a{0,4}/|,
                 ~S|~r/a{2,4}/|,
                 ~S|~r/a{1,3}/|,
                 ~S|~r/a{1,5}/|,
                 ~S|~r/a{1,}/|,
                 ~S|~r/a{1}/|,
                 ~S|~r/a{1,4}?/|
               ]

      #   `a{2,3}` (range): the upper's lower neighbour is exactly n (2) — kept
      #   (≥ n), so `a{2,2}`; the lower's upper neighbour 3 is ≤ m, so `a{3,3}`.
      assert render(RegexLiteral.mutate(parse(~S|~r/a{2,3}/|))) ==
               [
                 ~S|~r//|,
                 ~S|~r/mutare/|,
                 ~S|~r/a{1,3}/|,
                 ~S|~r/a{3,3}/|,
                 ~S|~r/a{2,2}/|,
                 ~S|~r/a{2,4}/|,
                 ~S|~r/a{2,}/|,
                 ~S|~r/a{2}/|,
                 ~S|~r/a{2,3}?/|
               ]
    end

    test "leaves a non-quantifier brace alone" do
      assert render(RegexLiteral.mutate(parse(~S|~r/a{b}/|))) == [~S|~r//|, ~S|~r/mutare/|]
    end

    test "drops one branch of a top-level alternation" do
      mutants = render(RegexLiteral.mutate(parse(~S"~r/a|b|c/")))
      assert ~S"~r/b|c/" in mutants
      assert ~S"~r/a|c/" in mutants
      assert ~S"~r/a|b/" in mutants
    end

    test "drops one branch of an alternation inside a capturing group" do
      mutants = render(RegexLiteral.mutate(parse(~S"~r/^(GET|POST)$/")))
      assert ~S"~r/^(POST)$/" in mutants
      assert ~S"~r/^(GET)$/" in mutants
    end

    test "does not touch alternation inside a non-capturing group" do
      refute ~S"~r/(?:a)/" in render(RegexLiteral.mutate(parse(~S"~r/(?:a|b)/")))
      refute ~S"~r/(?:b)/" in render(RegexLiteral.mutate(parse(~S"~r/(?:a|b)/")))
    end

    test "does not treat a pipe inside a character class as alternation" do
      # `|` is a literal inside `[…]`, so only the class negation is offered
      assert render(RegexLiteral.mutate(parse(~S"~r/[a|b]/"))) ==
               [~S"~r//", ~S"~r/mutare/", ~S"~r/[^a|b]/"]
    end

    test "swaps a dot between any-char and a literal dot, outside a class" do
      # the dotall swap `(?s:.)` (mode-aware) precedes the literal swap `\.` (scan)
      assert render(RegexLiteral.mutate(parse(~S|~r/a.b/|))) ==
               [~S|~r//|, ~S|~r/mutare/|, ~S|~r/a(?s:.)b/|, ~S|~r/a\.b/|]

      assert render(RegexLiteral.mutate(parse(~S|~r/a\.b/|))) ==
               [~S|~r//|, ~S|~r/mutare/|, ~S|~r/a.b/|]

      # inside a class a `.` is already a literal — swapping it would be a no-op
      assert render(RegexLiteral.mutate(parse(~S|~r/[a.b]/|))) ==
               [~S|~r//|, ~S|~r/mutare/|, ~S|~r/[^a.b]/|]
    end

    test "flips the dot's dotall-ness, gated positionally on the s flag" do
      # without /s: `.` excludes a newline, so force-dotall `(?s:.)` is the live swap
      without = render(RegexLiteral.mutate(parse(~S|~r/a.b/|)))
      assert ~S"~r/a(?s:.)b/" in without
      refute ~S"~r/a(?-s:.)b/" in without

      # with /s: `.` matches a newline, so force-non-dotall `(?-s:.)` is the live swap
      # (two dots, so neither coincides with dropping the sigil `s` — see the dedup test)
      with_s = render(RegexLiteral.mutate(parse(~S|~r/a.b.c/s|)))
      assert ~S"~r/a(?-s:.)b.c/s" in with_s
      refute ~S"~r/a(?s:.)b.c/s" in with_s

      # positional: an inline (?s) flips which swap each dot gets
      inline = render(RegexLiteral.mutate(parse(~S"~r/a.b(?s).c/")))
      assert ~S"~r/a(?s:.)b(?s).c/" in inline
      assert ~S"~r/a.b(?s)(?-s:.)c/" in inline

      # scoped (?s:…): the dot inside the scope is dotall, the one after is not
      scoped = render(RegexLiteral.mutate(parse(~S"~r/(?s:a.)b./")))
      assert ~S"~r/(?s:a(?-s:.))b./" in scoped
      assert ~S"~r/(?s:a.)b(?s:.)/" in scoped

      # a `.` inside a class is a literal — not offered the dotall swap
      refute Enum.any?(
               render(RegexLiteral.mutate(parse(~S|~r/[.]/|))),
               &String.contains?(&1, "(?")
             )
    end

    test "suppresses the force-non-dotall swap when it duplicates dropping sigil s" do
      # one dot under sigil /s: `a(?-s:.)b/s` ≡ `a.b/` (the s-drop), so only the s-drop is
      # kept — the dot swap would be a guaranteed-equivalent duplicate
      mutants = render(RegexLiteral.mutate(parse(~S|~r/a.b/s|)))
      refute ~S"~r/a(?-s:.)b/s" in mutants
      assert ~S"~r/a.b/" in mutants

      # two dots: the s-drop flips both, the dot swap flips one — not equivalent, so kept
      two = render(RegexLiteral.mutate(parse(~S|~r/a.b.c/s|)))
      assert ~S"~r/a(?-s:.)b.c/s" in two
      assert ~S"~r/a.b.c/" in two

      # an inline modifier group disables the dedup (it could change the equivalence)
      assert ~S"~r/(?i)a(?-s:.)b/s" in render(RegexLiteral.mutate(parse(~S"~r/(?i)a.b/s")))

      # a *duplicated* flag (`/ss`) disables the dedup: dropping one `s` leaves `/s` (still
      # dotall — a no-op drop, not equivalent to `(?-s:.)`), so the swap must be kept
      dup = render(RegexLiteral.mutate(parse(~S|~r/a./ss|)))
      assert ~S"~r/a(?-s:.)/ss" in dup
    end

    test "suppresses a force-m-off anchor swap when it duplicates dropping sigil m" do
      # one m-anchor under /m: `\Aa/m` ≡ `^a/` (the m-drop), so the `^`→`\A` swap is dropped
      caret = render(RegexLiteral.mutate(parse(~S|~r/^a/m|)))
      refute ~S"~r/\Aa/m" in caret
      assert ~S"~r/^a/" in caret

      # `$`→`\Z` likewise duplicates the m-drop, but `$`→`\z` (strict end) is kept
      dollar = render(RegexLiteral.mutate(parse(~S|~r/a$/m|)))
      refute ~S"~r/a\Z/m" in dollar
      assert ~S"~r/a\z/m" in dollar
      assert ~S"~r/a$/" in dollar

      # two m-anchors: a single swap no longer equals the m-drop, so both swaps are kept
      both = render(RegexLiteral.mutate(parse(~S|~r/^a$/m|)))
      assert ~S"~r/\Aa$/m" in both
      assert ~S"~r/^a\Z/m" in both
    end

    test "nudges a character-class range's endpoints by one, staying ordered and legal" do
      assert render(RegexLiteral.mutate(parse(~S|~r/[a-z]/|))) ==
               [
                 ~S|~r//|,
                 ~S|~r/mutare/|,
                 ~S|~r/[^a-z]/|,
                 ~S|~r/[`-z]/|,
                 ~S|~r/[b-z]/|,
                 ~S|~r/[a-y]/|,
                 ~S|~r/[a-{]/|
               ]

      assert ~S|~r/[1-9]/| in render(RegexLiteral.mutate(parse(~S|~r/[0-9]/|)))
      assert ~S|~r/[0-8]/| in render(RegexLiteral.mutate(parse(~S|~r/[0-9]/|)))
    end

    test "leaves a non-alphanumeric range and a literal dash alone" do
      # `[a-]` is `a` plus a literal trailing `-`, not a range
      assert render(RegexLiteral.mutate(parse(~S|~r/[a-]/|))) ==
               [~S|~r//|, ~S|~r/mutare/|, ~S|~r/[^a-]/|]

      # an escaped `\-` is a literal dash, never a range endpoint separator
      assert render(RegexLiteral.mutate(parse(~S|~r/[a\-z]/|))) ==
               [~S|~r//|, ~S|~r/mutare/|, ~S|~r/[^a\-z]/|]
    end

    test "drops each present modifier flag one at a time" do
      assert render(RegexLiteral.mutate(parse(~S|~r/foo/uis|))) ==
               [~S|~r//uis|, ~S|~r/mutare/uis|, ~S|~r/foo/is|, ~S|~r/foo/us|, ~S|~r/foo/ui|]
    end

    test "drops a candidate that a byte-level edit makes uncompilable" do
      # `{42+}` is a literal brace with the `+` quantifying the `2`; collapsing the `+`
      # would yield `{42}` — a real bound with nothing to repeat (a poison). The compile
      # backstop drops it, so every emitted mutant still compiles.
      for {:sigil_r, _, [{:<<>>, _, [p]}, mods]} <-
            RegexLiteral.mutate(parse(~S|~r/{42+}/|)) do
        assert {:ok, _} = Regex.compile(p, List.to_string(mods))
      end

      refute ~S|~r/{42}/| in render(RegexLiteral.mutate(parse(~S|~r/{42+}/|)))
    end

    test "skips an interpolated pattern" do
      assert RegexLiteral.mutate(parse(~S|~r/a#{b}c/|)) == :skip
    end

    test "name" do
      assert RegexLiteral.name() == :regex
    end
  end

  describe "DateTimeLiteral" do
    test "shifts each calendar sigil by one unit, staying valid" do
      assert render(DateTimeLiteral.mutate(parse("~D[2020-01-31]"))) == ["~D[2020-02-01]"]
      assert render(DateTimeLiteral.mutate(parse("~T[23:59:59]"))) == ["~T[00:00:00]"]

      assert render(DateTimeLiteral.mutate(parse("~N[2020-01-01 00:00:00]"))) ==
               ["~N[2020-01-02T00:00:00]"]

      assert render(DateTimeLiteral.mutate(parse("~U[2020-01-01 00:00:00Z]"))) ==
               ["~U[2020-01-02T00:00:00Z]"]
    end

    test "every shifted result is a real, re-parseable sigil" do
      for src <- [
            "~D[2020-12-31]",
            "~T[12:00:00]",
            "~N[2020-02-28 23:59:59]",
            "~U[1999-12-31 23:59:59Z]"
          ] do
        [mutated] = DateTimeLiteral.mutate(parse(src))
        assert {:ok, _} = Code.string_to_quoted(Sourceror.to_string(mutated))
      end
    end

    test "skips non-calendar sigils and other literals" do
      assert DateTimeLiteral.mutate(parse(~S|~r/foo/|)) == :skip
      assert DateTimeLiteral.mutate(parse("1")) == :skip
    end

    test "name" do
      assert DateTimeLiteral.name() == :datetime
    end
  end

  describe "AliasLiteral" do
    test "replaces a fully-literal alias with the sentinel alias" do
      assert render(AliasLiteral.mutate(parse("Foo"))) == ["Mutare.Mutant"]
      assert render(AliasLiteral.mutate(parse("Foo.Bar.Baz"))) == ["Mutare.Mutant"]
    end

    test "drops the replacement that already equals the sentinel" do
      assert AliasLiteral.mutate(parse("Mutare.Mutant")) == :skip
    end

    test "skips a dynamic alias (a segment that is not an atom)" do
      # `__MODULE__.Sub` — the first segment is `{:__MODULE__, _, nil}`, not an atom.
      assert AliasLiteral.mutate(parse("__MODULE__.Sub")) == :skip
    end

    test "skips non-alias nodes" do
      assert AliasLiteral.mutate(parse(":foo")) == :skip
      assert AliasLiteral.mutate(parse("foo")) == :skip
      assert AliasLiteral.mutate(parse("1")) == :skip
    end

    test "name" do
      assert AliasLiteral.name() == :alias
    end
  end

  defp parse(source), do: Sourceror.parse_string!(source)
  defp render(nodes), do: Enum.map(nodes, &Sourceror.to_string/1)
end
