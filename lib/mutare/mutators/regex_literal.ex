defmodule Mutare.Mutators.RegexLiteral do
  @moduledoc """
  Regex-sigil mutations. A `~r/…/` literal is mutated along several independent
  axes, each occurrence/flag yielding its own mutant:

    * **whole-pattern** — replace the pattern with both the empty pattern `~r//`
      (matches everywhere, so `Regex.match?/2` is always true) and a sentinel
      `~r/mutare/` (matches essentially no real input, always false), dropping
      whichever already equals the original. A contrasting pair, like
      `Mutare.Mutators.StringLiteral`: between them they catch a suite that never
      exercises what the pattern accepts or rejects.
    * **anchors** — drop a leading `^`/`\\A` (`~r/^abc/` → `~r/abc/`) or an
      unescaped trailing `$`/`\\z`/`\\Z` (`~r/abc$/` → `~r/abc/`), each
      independently. An unanchored pattern matches anywhere in the subject.
    * **anchor swaps** — swap an anchor for a *non-equivalent* sibling, at any real
      anchor position (escaped `\\^`/`\\$` and in-class `^`/`$` are skipped). The
      equivalences depend on the **`m` (multiline)** flag, read **positionally** via
      `Mutare.Mutators.RegexLiteral.Flags`: the sigil's own modifiers *and* any inline
      `(?m)` / `(?m:…)` / `(?-m)`, so `m` may be on at one anchor and off at another
      (`^a(?m)$` — the `^` is not multiline, the `$` is). A swap is offered *only*
      where the two anchors actually differ under the mode in force at that point,
      never as a guaranteed no-op:
        * `^` ↔ `\\A` — equivalent without `/m` (both = subject start), so offered
          **only under `/m`**, where `^` is a *line* start.
        * `$` ↔ `\\Z` — `\\Z` equals `$` without `/m`, so likewise offered **only
          under `/m`** (where `$` is a *line* end).
        * `$` ↔ `\\z` — `\\z` is the *strict* subject end (rejects a trailing
          newline that `$` accepts), so it differs regardless of `/m` and is
          **always** offered. Without `/m` it is killable only on a subject with a
          trailing newline, so a survivor is a suspected-equivalent /
          `# mutare:ignore[regex]` case (like `+`/`*`).
    * **character-class shorthands** — flip a `\\d`/`\\w`/`\\s` to its complement
      `\\D`/`\\W`/`\\S` (and back), anywhere, plus the word-boundary `\\b`↔`\\B`
      outside a class (inside `[…]` `\\b` is a backspace, so it is left alone).
    * **class negation** — toggle a bracketed character class between matching and
      not matching its members: `[abc]` ↔ `[^abc]`.
    * **character-class ranges** — nudge a class range's endpoints by one
      (`[a-z]` → `[b-z]`/`[a-y]`, `[0-9]` → `[1-9]`/`[0-8]`), the byte-walk analogue
      of the bounded-quantifier nudge. Only **alphanumeric** endpoints are mutated,
      each result kept ordered (`lo ≤ hi`) and within a safe printable-literal band
      (never a class metacharacter `] [ \\ ^ -`), so the rewrite is always a legal,
      non-empty class.
    * **literal dot** — `.` (any character) ↔ `\\.` (a literal dot), outside a class:
      `~r/a.b/` → `~r/a\\.b/` and `~r/a\\.b/` → `~r/a.b/`. The unescaped→escaped
      direction catches the classic "forgot to escape the dot" bug. Inside `[…]` a
      `.` is already a literal, so it is left alone (the swap there is a no-op).
    * **dotall dot** — `.` matches any character *except* a newline unless `s` (dotall)
      is active. Gated **positionally** on `s` (the same `Flags` resolver as the anchor
      swaps), flip the dot's newline-matching the *other* way than the mode in force, so
      the swap is never a no-op: where `s` is **off**, `.` → `(?s:.)` (now matches a
      newline); where `s` is **on**, `.` → `(?-s:.)` (now excludes one). The scoped
      `(?…:.)` confines the change to this one dot, so two dots under different inline
      modes (`a.b(?s).c`) each get their own correct swap. Killable on a subject with a
      newline at that point — without one in the test data, a survivor is a suspected
      equivalent (like `$`↔`\\z`). The force-non-dotall `(?-s:.)` is **suppressed** when
      it would duplicate dropping a sigil `s` (one dot, no inline modifier group — both
      then yield the same matcher), keeping the modifier-drop sibling instead.
    * **quantifiers** — swap `+`↔`*` (the cleanest complement: `+` is 1-or-more,
      `*` is 0-or-more, distinct under most uses — though *not* under
      `String.replace(s, _, "")` / `Regex.replace(s, _, "")`, where deleting the
      `\\s*` vs `\\s+` matches yields the same string: a context-dependent
      equivalent left to surface as a suspected survivor / `# mutare:ignore[regex]`,
      since recognising it would mean a node-local mutator inspecting its enclosing
      call); **collapse** a `+`/`*` to exactly-one by dropping it (`\\d+` → `\\d`);
      turn an optional `?` mandatory by dropping it (`colou?r` → `colour`) and
      raise it to `+` *and* `*` (`-?\\d` → `-+\\d`/`-*\\d`); add a **lazy** `?`
      suffix to a greedy quantifier (`a+` → `a+?`, `a{2,4}` → `a{2,4}?` — distinct
      wherever match *length* matters, e.g. a capture or `Regex.replace`; a boolean
      `Regex.match?/2` never observes greediness, so like `+`/`*` this can be a
      context-dependent equivalent → suspected survivor / `# mutare:ignore[regex]`;
      **not** offered on a *fixed*-count `{n}`/`{n,n}`, where the repetition can't vary
      so a lazy `?` is a guaranteed no-op);
      and nudge a bounded quantifier's counts by one (`{3}`→`{2}`/`{4}`, `{8,}`→
      `{7,}`/`{9,}`, `{2,4}`→`{1,4}`/`{3,4}`/`{2,3}`/`{2,5}`), staying within
      `0 ≤ n ≤ m`, *plus* dropping the upper bound (`{2,4}`→`{2,}`) and pinning to
      exact (`{2,4}`→`{2}`, `{8,}`→`{8}`; skipped when it would re-create the
      original, e.g. `{2,2}`→`{2}`). A `?`/`*`/`+` that is a group marker
      (`(?:…)`) is left alone, and a quantifier already carrying a lazy/possessive
      suffix is left **whole** — `a+?`/`a++` only `+`↔`*`-swap (no collapse/re-suffix),
      and a compound optional `a??`/`a?+` is offered nothing at all (dropping its first
      `?` would reinterpret the trailing `?`/`+` as the operator, e.g. `a?+`→`a+`). On a
      **zero-width** atom (a lookaround, or a `\\b`/`^`/`$`-style assertion) repetition is
      idempotent, so the variants that don't change the "always-passes vs requires-once"
      class are guaranteed-equivalent and dropped (`(?=a)+` offers only `(?=a)*`, never the
      collapse `(?=a)` or lazy `(?=a)+?`); the class-changing swap survives.
    * **alternation** — drop one branch of an alternation at the pattern's top
      level or inside a *capturing* group: `~r/^(GET|POST)$/` → `~r/^(GET)$/` and
      `~r/^(POST)$/`. Non-capturing/lookaround groups (`(?:…)`, `(?=…)`, …) are
      skipped, since rewriting them risks shifting capture semantics rather than
      just narrowing what matches.
    * **modifiers** — drop a present flag one at a time: `~r/x/uis` yields mutants
      `~r/x/is`, `~r/x/us`, `~r/x/ui`. Removing `i` (caseless), `s` (dotall), `u`
      (unicode), `m` (multiline), … each changes what the pattern accepts. The
      `u`-drop is emitted even on an all-ASCII pattern where it *looks* redundant:
      it is still **killable** — a `/u` regex raises on invalid UTF-8 where the
      no-`u` form byte-matches — so a surviving `u`-drop is a real finding (the `/u`
      is dead cruft, or its only effect — rejecting invalid UTF-8 — is untested),
      not an equivalent no-op to suppress. `# mutare:ignore[regex]` is the per-case
      opt-out.

  Every replacement is written to stay a legal regex (an escaped `\\$`/`\\d`/`\]` is
  left alone, a leading `]` in a class is literal, bound counts are kept ordered, class
  ranges stay within a safe literal band). As a final backstop, each candidate must pass
  **two** independent validity gates, since the mutant must be legal on both levels: it is
  compiled with `Regex.compile/2` (the *same* PCRE validity the rendered `~r/…/<mods>` is
  held to, so a byte-level edit that re-tokenizes — `{42+}` → `{42}` — is dropped), **and**
  it must render back to the same single-binary sigil as Elixir *source* — the two diverge
  on `\#{`, which PCRE reads as a literal `#`/`{` but Elixir reads as interpolation (a
  collapse of `#+{` → `\#{` passes PCRE yet would poison the metamutant). Either failing
  drops the candidate, so neither poisons the single compile. Every pass is a fold over
  **one** shared token stream (`tokens/2`),
  which owns all cross-cutting lexing — escapes (incl. a three-byte `\\cX` control escape),
  character classes (incl. a POSIX `[:alpha:]` whose inner `]` must not close the class),
  group structure + the `Flags` scope stack, and the spans where regex syntax does not
  apply. Those come in two flavours:
  an **ignored** `:comment` (an `x`-mode `#` line comment — ended at CR or LF, read
  **positionally** so an inline `(?x)` is honoured — or a `(?#…)` group), behind which a
  lazy/possessive quantifier suffix can still be seen; and an **inert** atom (`:inert` — a
  `\\Q…\\E` quote or a `(*VERB…)` control verb) whose body isn't regex. Neither's content
  is lexed, so no anchor/dot/quantifier/literal/alternation inside them is ever mutated,
  dropped, or split (and a quoted/commented/verb `(` or `|` cannot perturb the flag scope
  stack or read as alternation). Only non-interpolated patterns are touched: an interpolated
  `~r/\#{x}/` parses with multiple `<<>>` parts, not a single binary.
  """
  @behaviour Mutare.Mutator

  alias Mutare.AST
  alias Mutare.Mutators.RegexLiteral.Flags

  @sentinel AST.sentinel_string()

  # `\d`/`\w`/`\s` mean the same inside or outside a character class, so they can be
  # complemented anywhere; `\b` is a word boundary outside a class but a backspace
  # inside one, so it is only swapped outside a class (`@boundary`).
  @shorthand ~c"dDwWsS"
  @boundary ~c"bB"

  @impl Mutare.Mutator
  def name, do: :regex

  @impl Mutare.Mutator
  def mutate({:sigil_r, meta, [{:<<>>, bmeta, [pattern]}, modifiers]}) when is_binary(pattern) do
    # One lexical pass: the shared `tokens/2` reader owns all cross-cutting state —
    # escapes, character classes, group structure + the `Flags` scope stack, and the inert
    # (`\Q…\E` / `x`-comment) spans — and every pass below is a fold over its output, so the
    # escape/class/flag/inert handling lives in exactly one place.
    toks = tokens(pattern, MapSet.new(modifiers))

    pattern_variants =
      (["", @sentinel] ++
         anchor_patterns(pattern, toks) ++
         mode_aware_patterns(pattern, modifiers, toks) ++
         scan_patterns(pattern, toks) ++
         alternation_patterns(pattern, toks))
      |> Enum.map(&{&1, modifiers})

    modifier_variants = Enum.map(modifier_drops(modifiers), &{pattern, &1})

    (pattern_variants ++ modifier_variants)
    |> Enum.reject(&(&1 == {pattern, modifiers}))
    |> Enum.uniq()
    |> keep_compilable({pattern, modifiers})
    |> Enum.map(fn {p, m} -> {:sigil_r, meta, [{:<<>>, bmeta, [p]}, m]} end)
  end

  def mutate(_node), do: :skip

  # --- inert spans (shared `x`-aware reader) -------------------------------

  # The shared token reader. One positional walk produces the `[token]` stream every pass
  # folds over, so the cross-cutting lexical state lives here once: escape pairs, character
  # classes (`in_class`/`just_opened`), group structure with the `Flags` scope stack, and
  # the spans where regex syntax does not apply. A token is
  # `%{kind, text, offset, in_class, flags}` (a `:bound` also carries its parsed `bound`;
  # a `:group_open` its `removable?`). `text`/`offset` let a consumer splice a replacement
  # by `binary_part`; `flags` is the effective flag set at that point. Two flavours of
  # "syntax doesn't apply here" span, distinguished because they differ for quantifier
  # adjacency: a **`:comment`** is *ignored* by the engine (an `x`-mode `#` line comment or
  # a `(?#…)` group), so a lazy/possessive suffix can hide behind it; an **`:inert`** is a
  # zero-width *atom* whose body isn't regex (a `\Q…\E` quote, a `(*VERB…)` control verb).
  # Their content is not lexed, so every pass skips them by not matching the kind. Kinds:
  # `:char :escape :class_open :class_close :range :bound :group_open :group_close
  # :modifier :comment :inert`.
  defp tokens(pattern, baseline), do: lex(pattern, 0, false, false, Flags.initial(baseline), [])

  defp tok(kind, text, offset, in_class, stack),
    do: %{kind: kind, text: text, offset: offset, in_class: in_class, flags: hd(stack)}

  defp lex(<<>>, _i, _ic, _jo, _stack, acc), do: Enum.reverse(acc)

  # `\Q…\E` literal-quote span → one inert *atom* token (its body matches as text).
  defp lex(<<?\\, ?Q, rest::binary>>, i, ic, _jo, stack, acc) do
    {quoted, tail} = take_quoted(rest)
    text = "\\Q" <> quoted
    lex(tail, i + byte_size(text), ic, false, stack, [tok(:inert, text, i, ic, stack) | acc])
  end

  # A `\cX` control escape is a single three-byte escape — consume its argument too, so the
  # control character (which may be `(`/`)`/etc.) can't push a frame or close a class.
  defp lex(<<?\\, ?c, x::utf8, rest::binary>>, i, ic, _jo, stack, acc) do
    text = <<?\\, ?c, x::utf8>>
    lex(rest, i + byte_size(text), ic, false, stack, [tok(:escape, text, i, ic, stack) | acc])
  end

  # A PCRE backtracking control verb `(*VERB)` / `(*VERB:arg)` (outside a class). Its
  # argument is literal text that may contain `(`/`|`/etc., so the whole `(*…)` (to the
  # first `)`) is an inert atom — it must not push a frame or read as alternation.
  defp lex(<<?(, ?*, rest::binary>>, i, false, _jo, stack, acc) do
    {verb, tail} = take_verb(rest)
    text = "(*" <> verb

    lex(tail, i + byte_size(text), false, false, stack, [tok(:inert, text, i, false, stack) | acc])
  end

  # Escape pair.
  defp lex(<<?\\, c::utf8, rest::binary>>, i, ic, _jo, stack, acc) do
    text = <<?\\, c::utf8>>
    lex(rest, i + byte_size(text), ic, false, stack, [tok(:escape, text, i, ic, stack) | acc])
  end

  # Lone trailing backslash (invalid but consumed gracefully) — a literal char.
  defp lex(<<?\\>>, i, ic, _jo, stack, acc),
    do: lex(<<>>, i + 1, ic, false, stack, [tok(:char, "\\", i, ic, stack) | acc])

  # Character class open / close.
  defp lex(<<?[, ?^, rest::binary>>, i, false, _jo, stack, acc),
    do: lex(rest, i + 2, true, true, stack, [tok(:class_open, "[^", i, false, stack) | acc])

  defp lex(<<?[, rest::binary>>, i, false, _jo, stack, acc),
    do: lex(rest, i + 1, true, true, stack, [tok(:class_open, "[", i, false, stack) | acc])

  defp lex(<<?], rest::binary>>, i, true, false, stack, acc),
    do: lex(rest, i + 1, false, false, stack, [tok(:class_close, "]", i, true, stack) | acc])

  # A POSIX class `[:name:]` / `[:^name:]` *inside* a character class — consume it whole so
  # its internal `]` is never read as the outer class's close. A bare `[:…` with no closing
  # `:]` is not POSIX: the `[` is then an ordinary literal member.
  defp lex(<<?[, ?:, rest::binary>>, i, true, _jo, stack, acc) do
    case take_posix(rest) do
      {body, tail} ->
        text = "[:" <> body

        lex(tail, i + byte_size(text), true, false, stack, [
          tok(:char, text, i, true, stack) | acc
        ])

      :none ->
        lex(<<?:, rest::binary>>, i + 1, true, false, stack, [
          tok(:char, "[", i, true, stack) | acc
        ])
    end
  end

  # Character-class range `lo-hi` (alphanumeric endpoints) — a lexical unit so a consumer
  # never has to re-stitch one from single chars.
  defp lex(<<lo::utf8, ?-, hi::utf8, rest::binary>>, i, true, _jo, stack, acc)
       when (lo in ?0..?9 or lo in ?a..?z or lo in ?A..?Z) and
              (hi in ?0..?9 or hi in ?a..?z or hi in ?A..?Z) do
    text = <<lo::utf8, ?-, hi::utf8>>
    lex(rest, i + byte_size(text), true, false, stack, [tok(:range, text, i, true, stack) | acc])
  end

  # `x`-mode `#` comment (outside a class, `x` active) → an ignored `:comment` span.
  defp lex(<<?#, rest::binary>>, i, false, _jo, stack, acc) do
    if Flags.active?(stack, ?x) do
      {comment, tail} = take_comment_line(rest)
      text = "#" <> comment

      lex(tail, i + byte_size(text), false, false, stack, [
        tok(:comment, text, i, false, stack) | acc
      ])
    else
      lex(rest, i + 1, false, false, stack, [tok(:char, "#", i, false, stack) | acc])
    end
  end

  # Group open (outside a class) — `Flags.open/2` advances the flag scope and tells us
  # whether this is a real group (`:push`), a bare inline modifier (`:mutate`, no frame) or
  # a `(?#…)` comment (`:comment`). `removable?` (a plain capturing `(`, not `(?…`) is what
  # the alternation pass needs.
  defp lex(<<?(, rest::binary>>, i, false, _jo, stack, acc) do
    {action, consumed, tail, stack2} = Flags.open(rest, stack)
    text = "(" <> consumed
    next = i + byte_size(text)

    token =
      case action do
        :comment ->
          tok(:comment, text, i, false, stack)

        :mutate ->
          tok(:modifier, text, i, false, stack)

        :push ->
          tok(:group_open, text, i, false, stack)
          |> Map.put(:removable?, not modifier_open?(rest))
          |> Map.put(:zero_width?, lookaround?(rest))
          |> Map.put(:capturing?, capturing?(rest))
      end

    lex(tail, next, false, false, stack2, [token | acc])
  end

  defp lex(<<?), rest::binary>>, i, false, _jo, stack, acc),
    do:
      lex(rest, i + 1, false, false, Flags.close(stack), [
        tok(:group_close, ")", i, false, stack) | acc
      ])

  # Bounded quantifier `{n,m}` (a valid bound, outside a class) → one token carrying the
  # parsed bound; an invalid `{` is a literal char.
  defp lex(<<?{, rest::binary>>, i, false, _jo, stack, acc) do
    case parse_bound(rest) do
      {:ok, bound, tail} ->
        text = "{" <> binary_part(rest, 0, byte_size(rest) - byte_size(tail))
        token = Map.put(tok(:bound, text, i, false, stack), :bound, bound)
        lex(tail, i + byte_size(text), false, false, stack, [token | acc])

      :error ->
        lex(rest, i + 1, false, false, stack, [tok(:char, "{", i, false, stack) | acc])
    end
  end

  # Any other single codepoint (an anchor `^`/`$`, the dot, a quantifier `*`/`+`/`?`, a
  # pipe, a class member, a plain literal…). Consumers dispatch on `text`.
  defp lex(<<c::utf8, rest::binary>>, i, ic, _jo, stack, acc),
    do:
      lex(rest, i + byte_size(<<c::utf8>>), ic, false, stack, [
        tok(:char, <<c::utf8>>, i, ic, stack) | acc
      ])

  defp modifier_open?(<<??, _::binary>>), do: true
  defp modifier_open?(_), do: false

  # Is this group (the bytes after `(`) a zero-width *lookaround* assertion? Quantifying a
  # *capture-free* one is idempotent, which the scan pass uses to suppress guaranteed-
  # equivalent collapse/lazy/bound variants. (A named group `(?<n>…)` is *not* a lookbehind —
  # only `(?<=`/`(?<!` are.)
  defp lookaround?(<<??, ?=, _::binary>>), do: true
  defp lookaround?(<<??, ?!, _::binary>>), do: true
  defp lookaround?(<<??, ?<, ?=, _::binary>>), do: true
  defp lookaround?(<<??, ?<, ?!, _::binary>>), do: true
  defp lookaround?(_), do: false

  # Is this group a **capturing** group — a plain `(…)` or a *named* capture
  # (`(?<n>…)`/`(?'n'…)`/`(?P<n>…)`)? A capture inside a lookaround makes its repetition
  # observable (the captured text, or a later backreference, differs), so such a lookaround is
  # *not* idempotent. Everything else `(?:`, `(?=`, `(?>`, `(?#`, `(?flags…)`, `(?<=`/`(?<!`)
  # is non-capturing.
  defp capturing?(<<??, ?P, ?<, _::binary>>), do: true
  defp capturing?(<<??, ?<, ?=, _::binary>>), do: false
  defp capturing?(<<??, ?<, ?!, _::binary>>), do: false
  defp capturing?(<<??, ?<, _::binary>>), do: true
  defp capturing?(<<??, ?', _::binary>>), do: true
  defp capturing?(<<??, _::binary>>), do: false
  defp capturing?(_), do: true

  # --- splice helpers: rebuild the pattern with one token's text replaced ---

  defp before_tok(pattern, %{offset: o}), do: binary_part(pattern, 0, o)

  defp after_tok(pattern, %{offset: o, text: t}) do
    skip = o + byte_size(t)
    binary_part(pattern, skip, byte_size(pattern) - skip)
  end

  # Two independent compile-safety gates, since a mutant must be valid on *both* levels:
  #
  #   * **PCRE validity** (`regex_compilable?`). A byte-level edit can, in a pathological
  #     pattern, let neighbouring characters re-tokenize — `{42+}` (a literal brace, the `+`
  #     quantifying the `2`) collapses to `{42}`, now a real bound with nothing to repeat.
  #     Gated on the *original* compiling, so a future modifier letter `Regex.compile/2`
  #     doesn't accept can never silently drop every mutant.
  #   * **Elixir-source validity** (`renderable?`). The mutant is emitted as `~r/…/` source,
  #     which `Regex.compile/2` does *not* vet: the two diverge on `#{`, which PCRE reads as
  #     a literal `#` then `{` but Elixir reads as (here unterminated) interpolation. A
  #     collapse of `#+{` → `#{` thus passes PCRE yet poisons the metamutant. This is checked
  #     **unconditionally** (a non-rendering candidate poisons regardless of the original).
  defp keep_compilable(candidates, original) do
    candidates = Enum.filter(candidates, &renderable?/1)

    if regex_compilable?(original),
      do: Enum.filter(candidates, &regex_compilable?/1),
      else: candidates
  end

  defp regex_compilable?({pattern, modifiers}),
    do: match?({:ok, _}, Regex.compile(pattern, validation_opts(modifiers)))

  # A candidate that introduces an `#{` must render and parse back to the *same* single-binary
  # sigil (the metamutant is built the same way). `#{` is the only sigil-content sequence the
  # renderer leaves un-escaped, so a candidate free of it is renderable by construction.
  defp renderable?({pattern, modifiers}) do
    not String.contains?(pattern, <<?#, ?{>>) or round_trips?(pattern, modifiers)
  end

  defp round_trips?(pattern, modifiers) do
    node = {:sigil_r, [], [{:<<>>, [], [pattern]}, modifiers]}

    case node |> Sourceror.to_string() |> Code.string_to_quoted() do
      {:ok, {:sigil_r, _, [{:<<>>, _, [bin]}, _]}} -> bin == pattern
      _ -> false
    end
  end

  # Options for the *validation* compile only — the rendered mutant keeps the author's
  # modifiers verbatim. The deprecated `/r` (an exact alias of `/U`, same compiled form)
  # makes `Regex.compile/2` emit a deprecation warning *every call*, which — run once per
  # candidate — would flood a run; normalise it to `U` so the check is quiet.
  defp validation_opts(modifiers), do: modifiers |> List.to_string() |> String.replace("r", "U")

  # --- anchors -------------------------------------------------------------

  # A leading `^`/`\A` is at offset 0, which can never start (or sit inside) an inert span
  # — those begin with `\Q`/`#` — so only the *trailing* drop needs the inert guard (a
  # pattern can end inside an `x`-comment, `~r/a # $/x`).
  # Drop a leading start-anchor or a trailing end-anchor — now just "is the first/last
  # token an anchor?". The reader has already resolved escaping (a real `\z` is an
  # `:escape` token; an escaped-backslash-then-`z` ends in a `:char "z"`) and inertness (a
  # commented trailing `$` is *inside* an `:inert` token, never the last anchor token), so
  # the old `escaped?`/`in_inert?` string heuristics fall away.
  defp anchor_patterns(pattern, tokens),
    do: leading_drop(pattern, List.first(tokens)) ++ trailing_drop(pattern, List.last(tokens))

  defp leading_drop(pattern, %{kind: :char, text: "^"}), do: [chop_front(pattern, 1)]
  defp leading_drop(pattern, %{kind: :escape, text: "\\A"}), do: [chop_front(pattern, 2)]
  defp leading_drop(_pattern, _tok), do: []

  defp trailing_drop(pattern, %{kind: :char, text: "$"}), do: [chop_back(pattern, 1)]
  defp trailing_drop(pattern, %{kind: :escape, text: "\\z"}), do: [chop_back(pattern, 2)]
  defp trailing_drop(pattern, %{kind: :escape, text: "\\Z"}), do: [chop_back(pattern, 2)]
  defp trailing_drop(_pattern, _tok), do: []

  defp chop_front(s, n), do: binary_part(s, n, byte_size(s) - n)
  defp chop_back(s, n), do: binary_part(s, 0, byte_size(s) - n)

  # --- mode-aware construct swaps (anchors via `m`, the dot via `s`) -------

  # The mutations whose *equivalence* depends on an option flag — anchor swaps (via `m`),
  # the dot's dotall flip (via `s`). A fold over the token stream: each real anchor / dot
  # token carries the `flags` in force at its position (so an inline `(?m)`/`(?s:…)` is
  # honoured), and an escaped/in-class/inert construct simply isn't a token this matches.
  defp mode_aware_patterns(pattern, modifiers, tokens) do
    {swaps, _leading} =
      Enum.reduce(tokens, {[], true}, fn tok, {acc, leading?} ->
        {acc ++ mode_swaps(tok, pattern, leading?), leading? and not consumes_input?(tok)}
      end)

    swaps
    |> dedup_force_off(pattern, modifiers)
    |> Enum.map(&elem(&1, 0))
  end

  # A start-anchor is at the *match start* ("leading") iff only non-consuming tokens precede
  # it — other anchors/assertions, inline `(?…)` modifiers, and PCRE-ignored text (a comment
  # or, under `/x`, whitespace — shared with the scan pass via `scan_ignored?/1`, so `  ^a/fx`
  # still sees `^` as leading). Conservative: a group (even a zero-width lookaround) is treated
  # as consuming, so a `^` after one is offered the swap rather than wrongly suppressed (sound
  # — at worst a missed dedup, never a false drop).
  defp consumes_input?(token), do: not non_consuming?(token)

  defp non_consuming?(%{kind: :modifier}), do: true
  defp non_consuming?(%{kind: :char, text: t, in_class: false}) when t in ["^", "$"], do: true

  defp non_consuming?(%{kind: :escape, text: <<?\\, c::utf8>>, in_class: false})
       when c in ~c"bBAzZGK",
       do: true

  defp non_consuming?(token), do: scan_ignored?(token)

  defp mode_swaps(%{kind: :char, text: "^", in_class: false, flags: f} = t, pat, leading?),
    do:
      spliced_swaps(
        caret_swaps(MapSet.member?(f, ?m) and not firstline_anchored?(f, leading?)),
        pat,
        t
      )

  defp mode_swaps(%{kind: :char, text: "$", in_class: false, flags: f} = t, pat, _leading),
    do: spliced_swaps(dollar_swaps(MapSet.member?(f, ?m)), pat, t)

  defp mode_swaps(%{kind: :char, text: ".", in_class: false, flags: f} = t, pat, _leading),
    do: spliced_swaps(dot_swaps(MapSet.member?(f, ?s)), pat, t)

  # `\A`→`^` (the reverse caret swap) is likewise a no-op for a *leading* `\A` under `/fm`,
  # where firstline pins `^` to the subject start; the `\z`/`\Z`→`$` end swaps are unaffected
  # by firstline (it constrains the match *start*).
  defp mode_swaps(
         %{kind: :escape, text: <<?\\, c::utf8>>, in_class: false, flags: f} = t,
         pat,
         leading?
       ) do
    swaps = escaped_anchor_swaps(c, MapSet.member?(f, ?m))
    swaps = if c == ?A and firstline_anchored?(f, leading?), do: [], else: swaps
    spliced_swaps(swaps, pat, t)
  end

  defp mode_swaps(_token, _pat, _leading), do: []

  # Splice each `{replacement, tag}` over the token's text, keeping the tag.
  defp spliced_swaps(swaps, pattern, tok) do
    pre = before_tok(pattern, tok)
    post = after_tok(pattern, tok)
    Enum.map(swaps, fn {repl, tag} -> {pre <> repl <> post, tag} end)
  end

  # A **force-flag-off** swap forces one construct to behave as if a flag were off — the
  # dot's `(?-s:.)` (s off), `^`→`\A` and `$`→`\Z` (m off). Each is *semantically identical*
  # to dropping that sigil flag **when they touch the same construct set**: the sigil flag
  # is on, the pattern has no inline modifier group (so the construct's behaviour comes
  # solely from the sigil), and there is exactly one such swap (one construct). Both then
  # yield the same matcher for every input, so we drop the swap and keep the modifier-drop
  # sibling. Soundness guards: the pattern has no inline `(?…)` (an inline `(?s)`/`(?-m)`
  # could break the equivalence), and the flag appears **exactly once** in the modifiers —
  # `modifier_drops/1` removes one occurrence, so dropping `s` from `…/ss` leaves `/s` with
  # dotall still on (a *no-op* drop, *not* equivalent to `(?-s:.)`), in which case the swap
  # must be kept. Each mode swap is tagged `{:force_off, flag}` (or `:keep`).
  defp dedup_force_off(tagged, pattern, modifiers) do
    if String.contains?(pattern, "(?") do
      tagged
    else
      Enum.reduce(Enum.uniq(modifiers), tagged, fn flag, acc ->
        with true <- Enum.count(modifiers, &(&1 == flag)) == 1,
             [_one] = swap <- Enum.filter(acc, fn {_mutant, tag} -> tag == {:force_off, flag} end) do
          acc -- swap
        else
          _ -> acc
        end
      end)
    end
  end

  # Under `/f` (firstline) the match must *start* in the first line, so a *leading* anchor
  # (`^` or `\A`, with only non-consuming tokens before it) is pinned to the subject start
  # even under `/m` — making `^` and `\A` equivalent there, so the swap between them is a
  # guaranteed no-op. (A non-leading `^`/`\A` isn't the match start, so `/f` doesn't
  # constrain it; `leading?` under-approximates, so we only ever suppress a true no-op.)
  defp firstline_anchored?(flags, leading?), do: leading? and MapSet.member?(flags, ?f)

  # Each mode swap carries a tag: `{:force_off, flag}` when it forces a construct to behave
  # as if `flag` were off (a candidate to dedup against that flag's modifier-drop), else
  # `:keep`. `^`→`\A` and `$`→`\Z` force `m` off; the dot's `(?-s:.)` forces `s` off.
  # `^` ↔ `\A`: a no-op without `/m` (both = subject start), so only under `/m`.
  defp caret_swaps(true), do: [{"\\A", {:force_off, ?m}}]
  defp caret_swaps(false), do: []

  # `$` → `\z` always (`\z` is the strict end, never the m-off behaviour); `\Z` only under
  # `/m` (else `\Z` ≡ `$`), and it *is* the m-off behaviour.
  defp dollar_swaps(true), do: [{"\\z", :keep}, {"\\Z", {:force_off, ?m}}]
  defp dollar_swaps(false), do: [{"\\z", :keep}]

  # The escaped anchors swapping back toward `^`/`$` — never an m-off direction (they go
  # toward the m-*on* line anchors), so always `:keep`.
  defp escaped_anchor_swaps(?A, true), do: [{"^", :keep}]
  defp escaped_anchor_swaps(?z, _ml), do: [{"$", :keep}]
  defp escaped_anchor_swaps(?Z, true), do: [{"$", :keep}]
  defp escaped_anchor_swaps(_c, _ml), do: []

  # Force the dot's newline-matching the *other* way than the active mode (so the swap is
  # never a no-op): where `s` is on, `(?-s:.)` now excludes a newline (the s-off behaviour);
  # where it's off, `(?s:.)` now matches one. The scoped `(?…:.)` confines it to this dot.
  defp dot_swaps(true), do: [{"(?-s:.)", {:force_off, ?s}}]
  defp dot_swaps(false), do: [{"(?s:.)", :keep}]

  # --- modifiers -----------------------------------------------------------

  # One mutant per *distinct* present flag, with that flag removed (order preserved).
  defp modifier_drops(modifiers) do
    modifiers
    |> Enum.uniq()
    |> Enum.map(&(modifiers -- [&1]))
  end

  # --- per-token scan: shorthands, class negation/ranges, the dot, quantifiers/bounds ---

  # Shorthand/class/range/quantifier/bound/dot mutations: a fold over the token stream
  # threading `prev_quant` (so a lazy `a+?` / possessive `a++` suffix is not itself
  # mutated). The reader resolved escapes, class structure (a leading `]` is a member, not
  # a `:class_close`), ranges and bounds into single tokens, and dropped inert content — so
  # each clause is just "given this token, what mutants?". Reconstruction splices the
  # replacement over the token's text via `before_tok`/`after_tok`.
  defp scan_patterns(pattern, tokens), do: scan_fold(tokens, pattern, false, false, [], [])

  defp scan_fold([], _pat, _pq, _zw, _groups, acc), do: acc

  defp scan_fold([token | rest], pat, pq, zw, groups, acc) do
    # Text PCRE *ignores* — a `:comment` span or, under `/x`, unescaped whitespace — emits
    # nothing and carries the scan state (`prev_quant`, the preceding atom's zero-width-ness,
    # the group stack) through, so a lazy/possessive suffix hidden behind it (`a+ ?` /x,
    # `a+(?#c)?`) is still recognised as a suffix, not a fresh quantifier.
    if scan_ignored?(token) do
      scan_fold(rest, pat, pq, zw, groups, acc)
    else
      {new, pq2} = scan_token(token, rest, pat, pq, zw)
      {zw2, groups2} = advance_zero_width(token, groups)
      scan_fold(rest, pat, pq2, zw2, groups2, acc ++ new)
    end
  end

  defp scan_ignored?(%{kind: :comment}), do: true

  defp scan_ignored?(%{kind: :char, text: <<c>>, in_class: false, flags: f}),
    do: MapSet.member?(f, ?x) and c in [?\s, ?\t, ?\n, ?\r, ?\f, 0x0B]

  defp scan_ignored?(_token), do: false

  # The zero-width-ness of the atom this token *completes* (consulted by the next token's
  # quantifier), and the updated group stack. A quantifier on a zero-width atom (a
  # *capture-free* lookaround, or a `\b`/`^`/`$`-style assertion) is idempotent, so its
  # collapse/lazy/bound variants are guaranteed-equivalent. A lookaround that *captures*,
  # though, is observably non-idempotent (the captured text / a later backreference differs
  # with the repetition count), so it must not count as zero-width. The group stack pairs each
  # `:group_open` with its close as a `{lookaround?, capturing?, contains_capture?}` frame; on
  # close the frame's capture is propagated to its parent, so a capture nested at any depth
  # taints the enclosing lookaround.
  defp advance_zero_width(%{kind: :group_open, zero_width?: la, capturing?: cap}, groups),
    do: {false, [{la, cap, false} | groups]}

  defp advance_zero_width(%{kind: :group_close}, [{la, self_cap, inner_cap} | groups]),
    do: {la and not inner_cap, mark_capture(groups, self_cap or inner_cap)}

  defp advance_zero_width(%{kind: :group_close}, []), do: {false, []}

  defp advance_zero_width(%{kind: :escape, text: <<?\\, c::utf8>>}, groups) when c in ~c"bBAzZGK",
    do: {true, groups}

  defp advance_zero_width(%{kind: :char, text: t, in_class: false}, groups) when t in ["^", "$"],
    do: {true, groups}

  defp advance_zero_width(_token, groups), do: {false, groups}

  defp mark_capture([{la, self_cap, _} | rest], true), do: [{la, self_cap, true} | rest]
  defp mark_capture(groups, _captured), do: groups

  # Does a lazy (`?`) / possessive (`+`) suffix follow this quantifier, possibly across
  # ignored text? The first *non-ignored* token decides (a `\Q…\E`/verb atom in between
  # would stop the scan — it is not ignored, so it is not a suffix separator).
  defp suffix_follows?(rest) do
    case Enum.drop_while(rest, &scan_ignored?/1) do
      [%{kind: :char, text: t} | _] when t in ["?", "+"] -> true
      _ -> false
    end
  end

  # An escape: a `\d`/`\w`/`\s` shorthand (anywhere) or `\b` (outside a class) flips to its
  # complement; a `\.` (outside a class) unescapes to `.`.
  defp scan_token(
         %{kind: :escape, text: <<?\\, c::utf8>>, in_class: ic} = t,
         _rest,
         pat,
         _pq,
         _zw
       ) do
    pre = before_tok(pat, t)
    post = after_tok(pat, t)

    new =
      cond do
        c in @shorthand -> [pre <> <<?\\, flip(c)>> <> post]
        c in @boundary and not ic -> [pre <> <<?\\, flip(c)>> <> post]
        c == ?. and not ic -> [pre <> "." <> post]
        true -> []
      end

    {new, false}
  end

  # Class open → toggle the negation (`[…` ↔ `[^…`).
  defp scan_token(%{kind: :class_open, text: t_open} = t, _rest, pat, _pq, _zw) do
    repl = if t_open == "[", do: "[^", else: "["
    {[before_tok(pat, t) <> repl <> after_tok(pat, t)], false}
  end

  # Class range `lo-hi` → each in-range off-by-one neighbour (`class_range_mutations/2`).
  defp scan_token(%{kind: :range, text: <<lo::utf8, ?-, hi::utf8>>} = t, _rest, pat, _pq, _zw) do
    pre = before_tok(pat, t)
    post = after_tok(pat, t)
    {Enum.map(class_range_mutations(lo, hi), &(pre <> &1 <> post)), false}
  end

  # Quantifier `*`/`+` (outside a class) → complement swap, collapse-to-one, lazy suffix,
  # only as a real (postfix) quantifier. On a *zero-width* atom (a lookaround/assertion),
  # `+`-collapse (`Z+`→`Z`, both "requires") and the lazy suffix (greediness can't matter)
  # are guaranteed-equivalent and skipped; the `+`↔`*` swap (requires ↔ always-passes) and
  # `*`-collapse (`Z*`→`Z`, always-passes → requires) stay killable.
  defp scan_token(%{kind: :char, text: <<q>>, in_class: false} = t, rest, pat, pq, zw)
       when q in [?*, ?+] do
    pre = before_tok(pat, t)
    post = after_tok(pat, t)
    suffixed = suffix_follows?(rest)

    new =
      if postfix_quantifier?(pre, pq),
        do:
          [pre <> <<flip_quant(q)>> <> post] ++
            collapse_variant(pre, post, suffixed or (zw and q == ?+)) ++
            lazy_variant(pre, <<q>>, post, suffixed or zw),
        else: []

    {new, true}
  end

  # Optional `?` (outside a class) → drop / raise to `+` / raise to `*` / lazy `??`. Skipped
  # for a group marker (via `postfix_quantifier?/2`) or an already-suffixed compound
  # (`a??`/`a?+`, possibly across ignored text), where touching the first `?` would
  # reinterpret the trailing `?`/`+`.
  defp scan_token(%{kind: :char, text: "?", in_class: false} = t, rest, pat, pq, zw) do
    pre = before_tok(pat, t)
    post = after_tok(pat, t)

    new =
      if postfix_quantifier?(pre, pq) and not suffix_follows?(rest) do
        # drop (`Z`) and raise-to-`+` (`Z+`) flip an optional zero-width atom from
        # "always-passes" to "requires" → kept; raise-to-`*` (`Z*`) and the lazy `??` stay
        # "always-passes" → guaranteed-equivalent on a zero-width atom, so skipped there.
        base = [pre <> post, pre <> "+" <> post]
        extra = if zw, do: [], else: [pre <> "*" <> post, pre <> "??" <> post]
        base ++ extra
      else
        []
      end

    {new, true}
  end

  # Bounded quantifier → off-by-one / shape neighbours, plus a lazy `{…}?` for a *variable*
  # count only (a fixed `{n}`/`{n,n}` can't vary, nor can a lazy `?` on a zero-width atom, so
  # those are guaranteed no-ops). On a zero-width atom only the count mutations that cross
  # the "min-count 0 ↔ ≥1" boundary survive (`(?=a){1}`→`{0}` is killable; `{2}`→`{1}`/`{3}`
  # stay "requires" → equivalent).
  defp scan_token(%{kind: :bound, text: t_bound, bound: bound} = t, rest, pat, _pq, zw) do
    pre = before_tok(pat, t)
    post = after_tok(pat, t)

    counts = bound_mutations(bound)
    counts = if zw, do: Enum.filter(counts, &bound_class_changes?(&1, bound)), else: counts
    bounds = Enum.map(counts, &(pre <> "{" <> &1 <> "}" <> post))

    lazy =
      if variable_bound?(bound),
        do: lazy_variant(pre, t_bound, post, suffix_follows?(rest) or zw),
        else: []

    {bounds ++ lazy, true}
  end

  # Literal-dot swap: `.` (outside a class) → `\.` (a literal dot).
  defp scan_token(%{kind: :char, text: ".", in_class: false} = t, _rest, pat, _pq, _zw),
    do: {[before_tok(pat, t) <> "\\." <> after_tok(pat, t)], false}

  # Anything else (a plain char, anchor, pipe, group, modifier, inert atom): no scan
  # mutation, and the previous token is no longer a quantifier.
  defp scan_token(_token, _rest, _pat, _pq, _zw), do: {[], false}

  # A `*`/`+`/`?` is a real quantifier only after an atom: not at the start, not
  # right after a `(`/`|`, and not directly after another quantifier (a suffix).
  defp postfix_quantifier?("", _pq), do: false
  defp postfix_quantifier?(_prefix, true), do: false
  defp postfix_quantifier?(prefix, false), do: :binary.last(prefix) not in [?(, ?|]

  defp flip_quant(?*), do: ?+
  defp flip_quant(?+), do: ?*

  # Collapse a greedy `*`/`+` to exactly-one by dropping it (`\d+` → `\d`). Skipped
  # when a lazy/possessive suffix already follows (collapsing `a+?` would mean
  # reinterpreting its `?` as the quantifier — left to the base swap instead).
  defp collapse_variant(pre, post, suffixed), do: if(suffixed, do: [], else: [pre <> post])

  # Add a lazy `?` suffix to a greedy quantifier token (`a+` → `a+?`). Skipped when a
  # lazy/possessive suffix already follows, since a second one (`a+??`/`a+?+`) is invalid.
  defp lazy_variant(pre, quant, post, suffixed),
    do: if(suffixed, do: [], else: [pre <> quant <> "?" <> post])

  # Is the repetition count variable (so greedy vs. lazy can differ)? A fixed `{n}` or
  # `{n,n}` is not — a lazy `?` on it is a guaranteed no-op.
  defp variable_bound?({:exact, _}), do: false
  defp variable_bound?({:atleast, _}), do: true
  defp variable_bound?({:range, n, m}), do: n != m

  # On a zero-width atom a bound's only observable trait is whether its min count is 0
  # ("always-passes") or ≥1 ("requires"); a mutation matters iff it crosses that boundary.
  # `mutated` is a bound *body* string (`"3"`, `"2,"`, `"1,4"`) — its min is the leading int.
  defp bound_class_changes?(mutated, bound),
    do: bound_body_min(mutated) == 0 != (bound_min(bound) == 0)

  defp bound_min({:exact, n}), do: n
  defp bound_min({:atleast, n}), do: n
  defp bound_min({:range, n, _m}), do: n

  defp bound_body_min(body) do
    {min, _rest} = take_digits(body, "")
    String.to_integer(min)
  end

  # Consume a `\Q…\E` literal span (the bytes after `\Q`), up to and including the `\E`
  # (or to the pattern's end). Returns `{quoted, rest}`.
  defp take_quoted(bin), do: take_quoted(bin, "")
  defp take_quoted(<<?\\, ?E, rest::binary>>, acc), do: {acc <> "\\E", rest}
  defp take_quoted(<<>>, acc), do: {acc, ""}
  defp take_quoted(<<c::utf8, rest::binary>>, acc), do: take_quoted(rest, acc <> <<c::utf8>>)

  # Consume a control-verb body (the bytes after `(*`), up to and including the first `)`
  # (or to the pattern's end). The argument is literal, so `(`/`|` inside don't matter.
  defp take_verb(bin), do: take_verb(bin, "")
  defp take_verb(<<?), rest::binary>>, acc), do: {acc <> ")", rest}
  defp take_verb(<<>>, acc), do: {acc, ""}
  defp take_verb(<<c::utf8, rest::binary>>, acc), do: take_verb(rest, acc <> <<c::utf8>>)

  # Consume a POSIX-class body (the bytes after `[:`), up to and including the closing `:]`;
  # `:none` if there is no `:]` (then the leading `[` was an ordinary class member).
  defp take_posix(bin), do: take_posix(bin, "")
  defp take_posix(<<?:, ?], rest::binary>>, acc), do: {acc <> ":]", rest}
  defp take_posix(<<>>, _acc), do: :none
  defp take_posix(<<c::utf8, rest::binary>>, acc), do: take_posix(rest, acc <> <<c::utf8>>)

  # Consume an `x`-mode comment body up to (not including) the terminating newline. PCRE
  # ends the comment at the first CR *or* LF, so we stop at either (a following `.` is then
  # active, not swallowed).
  defp take_comment_line(bin), do: take_comment_line(bin, "")
  defp take_comment_line(<<c, _::binary>> = rest, acc) when c in [?\n, ?\r], do: {acc, rest}
  defp take_comment_line(<<>>, acc), do: {acc, ""}

  defp take_comment_line(<<c::utf8, rest::binary>>, acc),
    do: take_comment_line(rest, acc <> <<c::utf8>>)

  # In-range off-by-one neighbours of a class range's endpoints, kept ordered
  # (`lo ≤ hi`) and within a safe literal band so the rewrite stays a legal class.
  defp class_range_mutations(lo, hi) do
    for {lo2, hi2} <- [{lo - 1, hi}, {lo + 1, hi}, {lo, hi - 1}, {lo, hi + 1}],
        lo2 <= hi2,
        safe_class_char?(lo2),
        safe_class_char?(hi2),
        do: <<lo2::utf8, ?-, hi2::utf8>>
  end

  # A printable-ASCII character that is an unambiguous literal inside `[…]` — not a
  # class metacharacter that could close the class or start a negation/escape/range.
  defp safe_class_char?(c), do: c in 0x20..0x7E and c not in [?[, ?], ?\\, ?^, ?-]

  defp flip(c) when c in ?a..?z, do: c - 32
  defp flip(c) when c in ?A..?Z, do: c + 32

  # --- bound parsing -------------------------------------------------------

  defp parse_bound(s) do
    case take_digits(s, "") do
      {"", _rest} ->
        :error

      {n, <<?}, tail::binary>>} ->
        {:ok, {:exact, String.to_integer(n)}, tail}

      {n, <<?,, after_comma::binary>>} ->
        case take_digits(after_comma, "") do
          {"", <<?}, tail::binary>>} ->
            {:ok, {:atleast, String.to_integer(n)}, tail}

          {m, <<?}, tail::binary>>} ->
            {:ok, {:range, String.to_integer(n), String.to_integer(m)}, tail}

          _ ->
            :error
        end

      _ ->
        :error
    end
  end

  defp take_digits(<<d, rest::binary>>, acc) when d in ?0..?9, do: take_digits(rest, acc <> <<d>>)
  defp take_digits(s, acc), do: {acc, s}

  defp bound_mutations({:exact, n}) do
    [n - 1, n + 1]
    |> Enum.filter(&(&1 >= 0))
    |> Enum.map(&Integer.to_string/1)
  end

  defp bound_mutations({:atleast, n}) do
    offsets =
      [n - 1, n + 1]
      |> Enum.filter(&(&1 >= 0))
      |> Enum.map(&"#{&1},")

    # Pin the open upper bound to exact (`{n,}` → `{n}`); always a real change.
    offsets ++ ["#{n}"]
  end

  defp bound_mutations({:range, n, m}) do
    ns = Enum.filter([n - 1, n + 1], &(&1 >= 0 and &1 <= m))
    ms = Enum.filter([m - 1, m + 1], &(&1 >= n))
    offsets = Enum.map(ns, &"#{&1},#{m}") ++ Enum.map(ms, &"#{n},#{&1}")
    # Drop the upper bound (`{n,m}` → `{n,}`); pin to exact (`{n,m}` → `{n}`), unless
    # that just re-creates the original (`{n,n}` → `{n}`).
    drop_upper = ["#{n},"]
    exact = if n != m, do: ["#{n}"], else: []
    offsets ++ drop_upper ++ exact
  end

  # --- alternation: drop one branch of a top-level / capturing-group alt ----

  # Drop one branch of a top-level / capturing-group alternation: a fold over the tokens
  # tracking a stack of group frames (a *removable* frame is a plain capturing `(`). Each
  # removable frame with ≥1 top-level `|` yields one deletion span per branch (the branch
  # plus one adjacent pipe). The reader resolved escapes/classes/inert, so only real
  # `:group_open`/`:group_close`/`:char "|"` tokens reach the frames.
  defp alternation_patterns(pattern, tokens) do
    top = %{start: 0, removable: true, pipes: []}
    {frames, spans} = Enum.reduce(tokens, {[top], []}, &alt_token/2)

    final =
      Enum.reduce(frames, spans, fn frame, acc ->
        acc ++ frame_spans(frame, byte_size(pattern))
      end)

    Enum.map(final, fn {start, len} ->
      binary_part(pattern, 0, start) <>
        binary_part(pattern, start + len, byte_size(pattern) - start - len)
    end)
  end

  # Group open — push a frame whose content starts just past the opener; `removable?`
  # (a plain capturing `(`) was decided by the reader.
  defp alt_token(%{kind: :group_open, offset: o, text: t, removable?: rem?}, {frames, spans}),
    do: {[frame(o + byte_size(t), rem?) | frames], spans}

  # Group close — pop the frame and emit its branch-removal spans (content_end = the `)`).
  defp alt_token(%{kind: :group_close, offset: o}, {[frame | outer], spans}),
    do: {outer, spans ++ frame_spans(frame, o)}

  defp alt_token(%{kind: :group_close}, {[], spans}), do: {[], spans}

  # Top-level `|` — record the pipe position in the innermost frame.
  defp alt_token(%{kind: :char, text: "|", in_class: false, offset: o}, {[frame | outer], spans}),
    do: {[%{frame | pipes: frame.pipes ++ [o]} | outer], spans}

  defp alt_token(_token, acc), do: acc

  defp frame(start, removable), do: %{start: start, removable: removable, pipes: []}

  defp frame_spans(%{removable: false}, _content_end), do: []
  defp frame_spans(%{pipes: []}, _content_end), do: []

  defp frame_spans(%{start: start, pipes: pipes}, content_end) do
    # Branch 0: delete from the content start through the first pipe (inclusive).
    first = {start, hd(pipes) + 1 - start}
    # Branch i>0: delete the preceding pipe through the branch's end.
    ends = tl(pipes) ++ [content_end]
    rest = Enum.zip(pipes, ends) |> Enum.map(fn {pipe, stop} -> {pipe, stop - pipe} end)
    [first | rest]
  end
end
