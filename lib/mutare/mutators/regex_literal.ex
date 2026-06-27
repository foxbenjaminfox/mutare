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
      `?` would reinterpret the trailing `?`/`+` as the operator, e.g. `a?+`→`a+`).
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
  ranges stay within a safe literal band). As a final backstop, each candidate is
  compiled with `Regex.compile/2` — the *same* PCRE validity the rendered `~r/…/<mods>`
  is held to — and any that does not compile is dropped, so a byte-level edit that lets
  neighbouring characters re-tokenize (`{42+}` → `{42}`) can never poison the single
  metamutant compile. A `\\Q…\\E` literal-quote span is consumed whole (its
  metacharacters are inert, and its quoted `(` must not perturb the flag scope stack).
  Only non-interpolated patterns are touched: an interpolated `~r/\#{x}/` parses with
  multiple `<<>>` parts, not a single binary.

  > #### Extended (`/x`) mode {: .info}
  > The flag-aware walk (anchors, the dot) honours `x`-mode `#` comments positionally,
  > so a construct hidden in a comment is correctly ignored. The two flag-*un*aware
  > passes — the leading/trailing anchor *drop* and `scan/6` (literals, quantifiers,
  > classes) — do **not** track `x`, so content inside an `x`-mode comment can still
  > yield a guaranteed-equivalent mutant there; this is the residual limitation a shared
  > `x`-aware token reader would close (see `NOTES.md`).
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
    pattern_variants =
      (["", @sentinel] ++
         anchor_patterns(pattern) ++
         mode_aware_patterns(pattern, modifiers) ++
         scan_patterns(pattern) ++
         alternation_patterns(pattern))
      |> Enum.map(&{&1, modifiers})

    modifier_variants = Enum.map(modifier_drops(modifiers), &{pattern, &1})

    (pattern_variants ++ modifier_variants)
    |> Enum.reject(&(&1 == {pattern, modifiers}))
    |> Enum.uniq()
    |> keep_compilable({pattern, modifiers})
    |> Enum.map(fn {p, m} -> {:sigil_r, meta, [{:<<>>, bmeta, [p]}, m]} end)
  end

  def mutate(_node), do: :skip

  # Every rewrite above is built to stay a legal regex, but a *byte-level* edit can, in
  # a pathological pattern, let neighbouring characters re-tokenize — `{42+}` (a literal
  # brace, the `+` quantifying the `2`) collapses to `{42}`, now a real bound with
  # nothing to repeat. Such a mutant would poison the single metamutant compile, so we
  # drop any candidate that does not compile under the *same* PCRE validity the rendered
  # `~r/…/<mods>` is held to. Guarded on the original compiling, so a future modifier
  # letter `Regex.compile/2` doesn't accept can never silently drop every mutant.
  defp keep_compilable(candidates, original) do
    if compilable?(original),
      do: Enum.filter(candidates, &compilable?/1),
      else: candidates
  end

  defp compilable?({pattern, modifiers}) do
    match?({:ok, _}, Regex.compile(pattern, List.to_string(modifiers)))
  end

  # --- anchors -------------------------------------------------------------

  defp anchor_patterns(pattern), do: leading_anchors(pattern) ++ trailing_anchors(pattern)

  defp leading_anchors(pattern) do
    cond do
      String.starts_with?(pattern, "^") -> [chop_front(pattern, 1)]
      String.starts_with?(pattern, "\\A") -> [chop_front(pattern, 2)]
      true -> []
    end
  end

  defp trailing_anchors(pattern) do
    cond do
      # `$` is an anchor unless an odd run of backslashes escapes it.
      String.ends_with?(pattern, "$") and not escaped?(chop_back(pattern, 1)) ->
        [chop_back(pattern, 1)]

      # `\z`/`\Z` are anchors only when the backslash genuinely escapes the letter.
      String.ends_with?(pattern, "\\z") and escaped?(chop_back(pattern, 1)) ->
        [chop_back(pattern, 2)]

      String.ends_with?(pattern, "\\Z") and escaped?(chop_back(pattern, 1)) ->
        [chop_back(pattern, 2)]

      true ->
        []
    end
  end

  # Does the metacharacter that *follows* `str` sit behind an odd run of backslashes?
  defp escaped?(str), do: rem(trailing_backslashes(str), 2) == 1

  defp trailing_backslashes(str),
    do: byte_size(str) - byte_size(String.trim_trailing(str, "\\"))

  defp chop_front(s, n), do: binary_part(s, n, byte_size(s) - n)
  defp chop_back(s, n), do: binary_part(s, 0, byte_size(s) - n)

  # --- mode-aware construct swaps (anchors via `m`, the dot via `s`) -------

  # A focused walk (like `alt_walk/6`, not `scan/6`) for the mutations whose
  # *equivalence* depends on an option flag: it tracks escape pairs and character-class
  # nesting to tell a *real* construct from an escaped (`\^`/`\.`) or in-class (`[$.]`)
  # literal, plus a `Flags` scope stack so the flag is read **positionally** — an inline
  # `(?m)` / `(?s:…)` / `(?-m)` makes the relevant mode vary along the pattern. Each
  # construct offers only the swap that is non-equivalent under the mode in force here.
  defp mode_aware_patterns(pattern, modifiers) do
    pattern
    |> mode_walk("", false, false, Flags.initial(MapSet.new(modifiers)), [])
    |> drop_redundant_force_nondotall(pattern, modifiers)
  end

  # A force-non-dotall dot swap `(?-s:.)` is semantically identical to dropping a
  # sigil-level `s` *when they touch the same dot set* — i.e. when sigil `s` is on, the
  # pattern has no inline modifier group (so every dot's dotall comes solely from the
  # sigil), and there is exactly one such swap (one dot). Both then yield the same matcher
  # for every input, so we drop the dot swap and keep the modifier-drop sibling. Guarding
  # on the *absence* of any `(?…)` keeps this sound: an inline `(?s)`/`(?-s)` could make
  # the two differ, and is simply left un-deduped (a kept redundancy, never a wrong drop).
  defp drop_redundant_force_nondotall(mutants, pattern, modifiers) do
    if ?s in modifiers and not String.contains?(pattern, "(?") do
      case Enum.filter(mutants, &String.contains?(&1, "(?-s:.)")) do
        [_one] = swap -> mutants -- swap
        _ -> mutants
      end
    else
      mutants
    end
  end

  defp mode_walk(<<>>, _prefix, _ic, _jo, _stack, acc), do: acc

  # `\Q…\E` quotes a literal span: its `(`/`)`/`^`/`$` are inert, so consuming it whole is
  # both a correctness *and* a soundness fix — a quoted `(` must not push a phantom flag
  # frame (which would leak the mode past the real `)` and mis-gate a later anchor).
  defp mode_walk(<<?\\, ?Q, rest::binary>>, prefix, in_class, _jo, stack, acc) do
    {quoted, tail} = take_quoted(rest)
    mode_walk(tail, prefix <> "\\Q" <> quoted, in_class, false, stack, acc)
  end

  # Escape pair — `\A`/`\z`/`\Z` are anchors; any other escape (incl. `\^`/`\$`) is a
  # literal, so it offers nothing.
  defp mode_walk(<<?\\, c::utf8, rest::binary>>, prefix, in_class, _jo, stack, acc) do
    new =
      if in_class,
        do: [],
        else: Enum.map(escaped_anchor_swaps(c, multiline?(stack)), &(prefix <> &1 <> rest))

    mode_walk(rest, prefix <> <<?\\, c::utf8>>, in_class, false, stack, acc ++ new)
  end

  defp mode_walk(<<?\\>>, prefix, ic, jo, stack, acc),
    do: mode_walk(<<>>, prefix <> "\\", ic, jo, stack, acc)

  # Character class — `^`/`$` inside it are literals, so swallow it whole (the leading
  # `^` is the negation, the leading `]` a literal member). Flags don't change in a class.
  defp mode_walk(<<?[, ?^, rest::binary>>, prefix, false, _jo, stack, acc),
    do: mode_walk(rest, prefix <> "[^", true, true, stack, acc)

  defp mode_walk(<<?[, rest::binary>>, prefix, false, _jo, stack, acc),
    do: mode_walk(rest, prefix <> "[", true, true, stack, acc)

  defp mode_walk(<<?], rest::binary>>, prefix, true, false, stack, acc),
    do: mode_walk(rest, prefix <> "]", false, false, stack, acc)

  # Group open / close (outside a class) — drive the flag scope stack. A modifier group
  # (`(?m)` / `(?m:…)`) updates flags; an ordinary group just pushes/pops a frame.
  defp mode_walk(<<?(, rest::binary>>, prefix, false, _jo, stack, acc) do
    {consumed, rest2, stack2} = Flags.open(rest, stack)
    mode_walk(rest2, prefix <> "(" <> consumed, false, false, stack2, acc)
  end

  defp mode_walk(<<?), rest::binary>>, prefix, false, _jo, stack, acc),
    do: mode_walk(rest, prefix <> ")", false, false, Flags.close(stack), acc)

  # In `x` (extended) mode an unescaped `#` (outside a class) starts a comment running to
  # end-of-line: its anchors/dots are inert and any `(`/`(?…)` inside must NOT touch the
  # flag stack. Skip it whole. `x` is itself read positionally, so an inline `(?x)` (or
  # `(?-x)`) is honoured — a `#` before `(?x)` stays a literal.
  defp mode_walk(<<?#, rest::binary>>, prefix, false, _jo, stack, acc) do
    if Flags.active?(stack, ?x) do
      {comment, tail} = take_comment_line(rest)
      mode_walk(tail, prefix <> "#" <> comment, false, false, stack, acc)
    else
      mode_walk(rest, prefix <> "#", false, false, stack, acc)
    end
  end

  # `^` outside a class — a start anchor.
  defp mode_walk(<<?^, rest::binary>>, prefix, false, _jo, stack, acc) do
    new = Enum.map(caret_swaps(multiline?(stack)), &(prefix <> &1 <> rest))
    mode_walk(rest, prefix <> "^", false, false, stack, acc ++ new)
  end

  # `$` outside a class — an end anchor.
  defp mode_walk(<<?$, rest::binary>>, prefix, false, _jo, stack, acc) do
    new = Enum.map(dollar_swaps(multiline?(stack)), &(prefix <> &1 <> rest))
    mode_walk(rest, prefix <> "$", false, false, stack, acc ++ new)
  end

  # `.` outside a class — the any-char metacharacter, whose newline-matching is governed
  # by `s` (dotall). The `.` → `\.` literal swap is `scan/6`'s (mode-independent); here we
  # flip its *dotall-ness*.
  defp mode_walk(<<?., rest::binary>>, prefix, false, _jo, stack, acc) do
    new = Enum.map(dot_swaps(dotall?(stack)), &(prefix <> &1 <> rest))
    mode_walk(rest, prefix <> ".", false, false, stack, acc ++ new)
  end

  defp mode_walk(<<c::utf8, rest::binary>>, prefix, in_class, _jo, stack, acc),
    do: mode_walk(rest, prefix <> <<c::utf8>>, in_class, false, stack, acc)

  defp multiline?(stack), do: Flags.active?(stack, ?m)
  defp dotall?(stack), do: Flags.active?(stack, ?s)

  # `^` ↔ `\A`: a no-op without `/m` (both = subject start), so only under `/m`.
  defp caret_swaps(true), do: ["\\A"]
  defp caret_swaps(false), do: []

  # `$` → `\z` always (`\z` is the strict end), `\Z` only under `/m` (else `\Z` ≡ `$`).
  defp dollar_swaps(true), do: ["\\z", "\\Z"]
  defp dollar_swaps(false), do: ["\\z"]

  # The escaped anchors swapping back toward `^`/`$`, mirroring the above.
  defp escaped_anchor_swaps(?A, true), do: ["^"]
  defp escaped_anchor_swaps(?z, _ml), do: ["$"]
  defp escaped_anchor_swaps(?Z, true), do: ["$"]
  defp escaped_anchor_swaps(_c, _ml), do: []

  # Force the dot's newline-matching the *other* way than the active mode (so the swap is
  # never a no-op): where `s` is on, `(?-s:.)` now excludes a newline; where it's off,
  # `(?s:.)` now matches one. The scoped `(?…:.)` confines the change to this one dot.
  defp dot_swaps(true), do: ["(?-s:.)"]
  defp dot_swaps(false), do: ["(?s:.)"]

  # --- modifiers -----------------------------------------------------------

  # One mutant per *distinct* present flag, with that flag removed (order preserved).
  defp modifier_drops(modifiers) do
    modifiers
    |> Enum.uniq()
    |> Enum.map(&(modifiers -- [&1]))
  end

  # --- per-token scan: shorthands, class negation/ranges, the dot, quantifiers/bounds ---

  # Walk the pattern left-to-right, tracking escape pairs, character-class nesting
  # (`in_class`/`just_opened`, the latter so a leading `]` is read as a literal
  # member) and whether the previous token was a quantifier (`prev_quant`, so a lazy
  # `a+?` / possessive `a++` suffix is not itself swapped). Each swap site appends
  # one or more fully-rewritten patterns.
  defp scan_patterns(pattern), do: scan(pattern, "", false, false, false, [])

  defp scan(<<>>, _prefix, _in_class, _jo, _pq, acc), do: acc

  # `\Q…\E` quotes a literal span — every metacharacter inside is inert, so consume it
  # whole and offer nothing (else a quoted `a+`/`.`/`[` would be mutated as if syntax).
  defp scan(<<?\\, ?Q, rest::binary>>, prefix, in_class, _jo, _pq, acc) do
    {quoted, tail} = take_quoted(rest)
    scan(tail, prefix <> "\\Q" <> quoted, in_class, false, false, acc)
  end

  # An escape sequence: backslash + the codepoint it escapes (consumed as a unit, so
  # `\\d` — an escaped backslash then `d` — is never mistaken for the `\d` shorthand).
  defp scan(<<?\\, c::utf8, rest::binary>>, prefix, in_class, _jo, _pq, acc) do
    new =
      cond do
        c in @shorthand -> [prefix <> <<?\\, flip(c)>> <> rest]
        c in @boundary and not in_class -> [prefix <> <<?\\, flip(c)>> <> rest]
        # `\.` (a literal dot) → `.` (any char). Inside a class both are the same
        # literal, so only swap outside one.
        c == ?. and not in_class -> [prefix <> "." <> rest]
        true -> []
      end

    scan(rest, prefix <> <<?\\, c::utf8>>, in_class, false, false, acc ++ new)
  end

  # A lone trailing backslash (invalid regex, but consume gracefully).
  defp scan(<<?\\>>, prefix, in_class, jo, pq, acc),
    do: scan(<<>>, prefix <> "\\", in_class, jo, pq, acc)

  # Class open, already negated: `[^…` → `[…` (drop the negation).
  defp scan(<<?[, ?^, rest::binary>>, prefix, false, _jo, _pq, acc),
    do: scan(rest, prefix <> "[^", true, true, false, acc ++ [prefix <> "[" <> rest])

  # Class open, not negated: `[…` → `[^…` (add the negation).
  defp scan(<<?[, rest::binary>>, prefix, false, _jo, _pq, acc),
    do: scan(rest, prefix <> "[", true, true, false, acc ++ [prefix <> "[^" <> rest])

  # Class close (a leading `]` is literal, so only closes when not just opened).
  defp scan(<<?], rest::binary>>, prefix, true, false, _pq, acc),
    do: scan(rest, prefix <> "]", false, false, false, acc)

  # Character-class range `lo-hi` (alphanumeric endpoints) → each in-range off-by-one
  # neighbour, kept ordered and within a safe literal band (`class_range_mutations/2`).
  # The first member of a class can itself be a range start, so `just_opened` is allowed.
  defp scan(<<lo::utf8, ?-, hi::utf8, rest::binary>>, prefix, true, _jo, _pq, acc)
       when (lo in ?0..?9 or lo in ?a..?z or lo in ?A..?Z) and
              (hi in ?0..?9 or hi in ?a..?z or hi in ?A..?Z) do
    new = Enum.map(class_range_mutations(lo, hi), &(prefix <> &1 <> rest))
    scan(rest, prefix <> <<lo::utf8, ?-, hi::utf8>>, true, false, false, acc ++ new)
  end

  # Quantifier `*`/`+` → its complement, plus collapse-to-one and a lazy suffix, only
  # as a real (postfix) quantifier.
  defp scan(<<q, rest::binary>>, prefix, false, _jo, pq, acc) when q in [?*, ?+] do
    new =
      if postfix_quantifier?(prefix, pq),
        do:
          [prefix <> <<flip_quant(q)>> <> rest] ++
            collapse_variant(prefix, rest) ++ lazy_variant(prefix, <<q>>, rest),
        else: []

    scan(rest, prefix <> <<q>>, false, false, true, acc ++ new)
  end

  # Optional `?` → mandatory: drop it, raise it to `+` and to `*`, and add a lazy `??`.
  # Skipped when it is a group marker (`(?…`, via `postfix_quantifier?/2`) *or* already
  # carries a lazy/possessive suffix (`a??`/`a?+`): there the `?` is the base of a
  # compound quantifier, so dropping/raising it would reinterpret the trailing `?`/`+`
  # as the operator (`a?+` → `a+`) rather than touch the optional — leave it whole.
  defp scan(<<??, rest::binary>>, prefix, false, _jo, pq, acc) do
    new =
      if postfix_quantifier?(prefix, pq) and not suffixed?(rest),
        do: [prefix <> rest, prefix <> "+" <> rest, prefix <> "*" <> rest, prefix <> "??" <> rest],
        else: []

    scan(rest, prefix <> "?", false, false, true, acc ++ new)
  end

  # Bounded quantifier `{n}` / `{n,}` / `{n,m}` → its off-by-one / shape neighbours,
  # plus a lazy `{…}?` suffix — but *only* for a variable count. For a fixed count
  # (`{n}` or `{n,n}`) the repetition is exact, so a lazy `?` can never change what
  # matches: `a{3}?` ≡ `a{3}` in every context (a guaranteed-equivalent that would
  # permanently survive), so it is not offered.
  defp scan(<<?{, rest::binary>>, prefix, false, _jo, _pq, acc) do
    case parse_bound(rest) do
      {:ok, bound, tail} ->
        consumed = binary_part(rest, 0, byte_size(rest) - byte_size(tail))
        bounds = Enum.map(bound_mutations(bound), &(prefix <> "{" <> &1 <> "}" <> tail))

        lazy =
          if variable_bound?(bound), do: lazy_variant(prefix, "{" <> consumed, tail), else: []

        scan(tail, prefix <> "{" <> consumed, false, false, true, acc ++ bounds ++ lazy)

      :error ->
        scan(rest, prefix <> "{", false, false, false, acc)
    end
  end

  # Literal-dot swap: `.` (any char) → `\.` (a literal dot), outside a character class
  # (inside one a `.` is already literal). The `.` is an atom, so a following quantifier
  # is still a real one (prev-quant reset to false).
  defp scan(<<?., rest::binary>>, prefix, false, _jo, _pq, acc),
    do: scan(rest, prefix <> ".", false, false, false, acc ++ [prefix <> "\\." <> rest])

  # Any other codepoint: consume it (a class is no longer "just opened" afterwards,
  # and the previous token is no longer a quantifier).
  defp scan(<<c::utf8, rest::binary>>, prefix, in_class, _jo, _pq, acc),
    do: scan(rest, prefix <> <<c::utf8>>, in_class, false, false, acc)

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
  defp collapse_variant(prefix, rest) do
    if suffixed?(rest), do: [], else: [prefix <> rest]
  end

  # Add a lazy `?` suffix to a greedy quantifier token (`a+` → `a+?`). Skipped when a
  # lazy/possessive suffix already follows, since a second one (`a+??`/`a+?+`) is
  # invalid.
  defp lazy_variant(prefix, quant, rest) do
    if suffixed?(rest), do: [], else: [prefix <> quant <> "?" <> rest]
  end

  # Does a lazy (`?`) or possessive (`+`) suffix immediately follow this quantifier?
  defp suffixed?(<<c, _::binary>>) when c in [??, ?+], do: true
  defp suffixed?(_), do: false

  # Is the repetition count variable (so greedy vs. lazy can differ)? A fixed `{n}` or
  # `{n,n}` is not — a lazy `?` on it is a guaranteed no-op.
  defp variable_bound?({:exact, _}), do: false
  defp variable_bound?({:atleast, _}), do: true
  defp variable_bound?({:range, n, m}), do: n != m

  # Consume a `\Q…\E` literal span (the bytes after `\Q`), up to and including the `\E`
  # (or to the pattern's end). Returns `{quoted, rest}`.
  defp take_quoted(bin), do: take_quoted(bin, "")
  defp take_quoted(<<?\\, ?E, rest::binary>>, acc), do: {acc <> "\\E", rest}
  defp take_quoted(<<>>, acc), do: {acc, ""}
  defp take_quoted(<<c::utf8, rest::binary>>, acc), do: take_quoted(rest, acc <> <<c::utf8>>)

  # Consume an `x`-mode comment body up to (not including) the terminating newline.
  defp take_comment_line(bin), do: take_comment_line(bin, "")
  defp take_comment_line(<<?\n, _::binary>> = rest, acc), do: {acc, rest}
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

  # A second, index-based walk (it tracks byte offsets and a stack of group frames,
  # which the prefix-string `scan/6` cannot). Each removable frame with ≥1 top-level
  # `|` yields one deletion span per branch (the branch plus one adjacent pipe).
  defp alternation_patterns(pattern) do
    top = %{start: 0, removable: true, pipes: []}

    pattern
    |> alt_walk(0, false, false, [top], [])
    |> Enum.map(fn {start, len} ->
      binary_part(pattern, 0, start) <>
        binary_part(pattern, start + len, byte_size(pattern) - start - len)
    end)
  end

  # End: finalise every still-open frame at the current offset (the whole-pattern
  # frame for balanced input; any leftover inner frame is malformed and harmless).
  defp alt_walk(<<>>, i, _ic, _jo, frames, spans),
    do: Enum.reduce(frames, spans, fn frame, acc -> acc ++ frame_spans(frame, i) end)

  # Escape pair — the escaped char is literal, so `\(`/`\|`/`\[` never affect frames.
  defp alt_walk(<<?\\, c::utf8, rest::binary>>, i, ic, jo, frames, spans),
    do: alt_walk(rest, i + 1 + byte_size(<<c::utf8>>), ic, jo, frames, spans)

  defp alt_walk(<<?\\>>, i, ic, jo, frames, spans),
    do: alt_walk(<<>>, i + 1, ic, jo, frames, spans)

  # Character class — `(`/`)`/`|` inside it are literal, so swallow it whole.
  defp alt_walk(<<?[, ?^, rest::binary>>, i, false, _jo, frames, spans),
    do: alt_walk(rest, i + 2, true, true, frames, spans)

  defp alt_walk(<<?[, rest::binary>>, i, false, _jo, frames, spans),
    do: alt_walk(rest, i + 1, true, true, frames, spans)

  defp alt_walk(<<?], rest::binary>>, i, true, false, frames, spans),
    do: alt_walk(rest, i + 1, false, false, frames, spans)

  defp alt_walk(<<c::utf8, rest::binary>>, i, true, _jo, frames, spans),
    do: alt_walk(rest, i + byte_size(<<c::utf8>>), true, false, frames, spans)

  # Group open — `(?…` is non-capturing/lookaround (not removable); `(` is capturing.
  defp alt_walk(<<?(, ??, rest::binary>>, i, false, _jo, frames, spans),
    do: alt_walk(rest, i + 2, false, false, [frame(i + 2, false) | frames], spans)

  defp alt_walk(<<?(, rest::binary>>, i, false, _jo, frames, spans),
    do: alt_walk(rest, i + 1, false, false, [frame(i + 1, true) | frames], spans)

  # Group close — pop the frame and emit its branch-removal spans (content_end = `)`).
  defp alt_walk(<<?), rest::binary>>, i, false, _jo, [frame | outer], spans),
    do: alt_walk(rest, i + 1, false, false, outer, spans ++ frame_spans(frame, i))

  defp alt_walk(<<?), rest::binary>>, i, false, _jo, [], spans),
    do: alt_walk(rest, i + 1, false, false, [], spans)

  # Top-level `|` — record the pipe position in the innermost frame.
  defp alt_walk(<<?|, rest::binary>>, i, false, _jo, [frame | outer], spans),
    do: alt_walk(rest, i + 1, false, false, [%{frame | pipes: frame.pipes ++ [i]} | outer], spans)

  defp alt_walk(<<c::utf8, rest::binary>>, i, false, _jo, frames, spans),
    do: alt_walk(rest, i + byte_size(<<c::utf8>>), false, false, frames, spans)

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
