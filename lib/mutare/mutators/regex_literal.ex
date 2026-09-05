defmodule Mutare.Mutators.RegexLiteral do
  @moduledoc """
  Mutates non-interpolated `~r` sigils. Each changed token or modifier produces a separate mutant.

  ## Pattern replacements

    * Whole pattern: replace the pattern with `~r//` and `~r/mutare/`. A replacement equal to the original is omitted.
    * Anchors: remove a leading `^` or `\A`, or a trailing `$`, `\z`, or `\Z`. Escaped and character-class occurrences are ignored.
    * Anchor variants: exchange `^` and `\A`, or `$` and `\Z`, only where multiline mode makes them different. Exchange `$` and `\z` in either mode. Sigil modifiers and inline flag groups determine the mode at each anchor.
    * Character classes: complement `\d`, `\w`, and `\s`; exchange `\b` and `\B` outside classes; toggle class negation; and move an alphanumeric range endpoint by one. Range changes remain ordered and avoid class metacharacters.
    * Dots: exchange `.` and `\.` outside classes. A wildcard dot also gets a scoped variant that reverses its newline behavior: `(?s:.)` when dotall mode is off, or `(?-s:.)` when it is on. Inline flags are applied positionally. A force-off variant that duplicates dropping the sigil's `s` modifier is omitted.
    * Alternation: remove one top-level branch or one branch inside a capturing group. Non-capturing groups and lookarounds are not rewritten this way.
    * Modifiers: remove each sigil modifier separately. This includes `u`; its removal changes handling of invalid UTF-8 even when the pattern itself is ASCII.

  ## Quantifiers

    * Exchange `+` and `*`, and remove either to require exactly one occurrence.
    * Remove `?` to make an optional atom mandatory, or change it to `+` or `*`.
    * Add a lazy suffix to a greedy variable-count quantifier.
    * Move each legal bound by one. For example, `{2,4}` can become `{1,4}`, `{3,4}`, `{2,3}`, or `{2,5}`.
    * Remove an upper bound or pin a range to an exact count.

  Bounds remain non-negative and ordered. A fixed count does not receive a lazy variant. Group markers are not treated as quantifiers. Quantifiers with an existing lazy or possessive suffix receive only changes that cannot reinterpret that suffix. Repetition of zero-width assertions is limited to variants that change whether the assertion is required.

  ## Filterable variants

  Qualify a `# mutare:ignore` filter with `:label` to suppress just one kind (`c:Mutare.Mutator.variants/0`):

    * `pattern` — whole-pattern replacements (`~r//`, `~r/mutare/`)
    * `anchor` — anchor removals and exchanges
    * `class` — shorthand complements (`\\d`/`\\D`, …), `\\b`/`\\B`, class negation, range endpoints
    * `dot` — `.`/`\\.` exchanges and the scoped dotall variants
    * `quantifier` — quantifier exchanges, collapses, raises, and bound changes
    * `laziness` — added lazy suffixes (`a+` → `a+?`, `a?` → `a??`, `{n,m}` → `{n,m}?`)
    * `alternation` — branch removals
    * `modifier` — sigil modifier removals

  Some valid mutations are equivalent in a particular calling context. For example, greediness does not affect `Regex.match?/2`, and `+` and `*` may produce the same result when all matches are removed. These mutants remain visible and can be suppressed precisely with a variant qualifier — `# mutare:ignore[regex:laziness]` suppresses just the added-lazy-suffix mutants on its line, leaving the line's other regex mutants live.

  ## Safety and parsing

  Every candidate must compile with `Regex.compile/2` and render as a single-binary Elixir sigil. This checks both regex syntax and Elixir interpolation syntax before the candidate enters the metamutant.

  All mutations use one token stream that tracks escapes, character classes, group structure, and positional flags. Extended-mode comments, `(?#...)` comments, `\Q...\E` quoted spans, and control verbs are treated as non-pattern content. Tokens inside them are not mutated and do not affect grouping. Interpolated sigils are not mutated.
  """
  @behaviour Mutare.Mutator

  alias Mutare.AST
  alias Mutare.Mutator.Mutation
  alias Mutare.Mutators.RegexLiteral.Tokens

  @sentinel AST.sentinel_string()

  # `\d`/`\w`/`\s` mean the same inside or outside a character class, so they can be
  # complemented anywhere; `\b` is a word boundary outside a class but a backspace
  # inside one, so it is only swapped outside a class (`@boundary`).
  @shorthand ~c"dDwWsS"
  @boundary ~c"bB"

  @impl Mutare.Mutator
  def name, do: :regex

  # The `# mutare:ignore[regex:label]` vocabulary — one label per mutation kind, tagged at
  # production (each pass below labels what it emits; no `variant/2` re-derivation from the
  # rendered AST, which is exactly the token-matching the ignore grammar avoids).
  @impl Mutare.Mutator
  def variants, do: ~w(pattern anchor class dot quantifier laziness alternation modifier)

  @impl Mutare.Mutator
  def mutate({:sigil_r, meta, [{:<<>>, bmeta, [pattern]}, modifiers]}) when is_binary(pattern) do
    # One lexical pass: the shared `Tokens.tokens/2` reader owns all cross-cutting state —
    # escapes, character classes, group structure + the `Flags` scope stack, and the inert
    # (`\Q…\E` / `x`-comment) spans — and every pass below is a fold over its output, so the
    # escape/class/flag/inert handling lives in exactly one place. Each pass yields
    # `{pattern, label}` pairs; two passes producing the *same* candidate merge their labels
    # (`merge_labels/1`), so a mutant reachable two ways is suppressed by either qualifier.
    toks = Tokens.tokens(pattern, MapSet.new(modifiers))

    labeled_patterns =
      Enum.map(["", @sentinel], &{&1, "pattern"}) ++
        Enum.map(anchor_patterns(pattern, toks), &{&1, "anchor"}) ++
        mode_aware_patterns(pattern, modifiers, toks) ++
        scan_patterns(pattern, toks) ++
        Enum.map(alternation_patterns(pattern, toks), &{&1, "alternation"})

    candidates =
      Enum.map(labeled_patterns, fn {p, label} -> {{p, modifiers}, label} end) ++
        Enum.map(modifier_drops(modifiers), &{{pattern, &1}, "modifier"})

    candidates
    |> Enum.reject(fn {candidate, _label} -> candidate == {pattern, modifiers} end)
    |> merge_labels()
    |> keep_compilable({pattern, modifiers})
    |> Enum.map(fn {{p, m}, labels} ->
      Mutation.tagged({:sigil_r, meta, [{:<<>>, bmeta, [p]}, m]}, labels)
    end)
  end

  def mutate(_node), do: :skip

  # Collapse duplicate candidates (the old `Enum.uniq/1`, first-occurrence order preserved),
  # unioning their labels: a leading-`^` pattern's anchor drop and its whole-pattern `""`
  # replacement can coincide, and the shared mutant must answer to either qualifier.
  defp merge_labels(candidates) do
    labels_by_candidate =
      Enum.reduce(candidates, %{}, fn {candidate, label}, acc ->
        Map.update(acc, candidate, [label], &(&1 ++ [label]))
      end)

    candidates
    |> Enum.map(fn {candidate, _label} -> candidate end)
    |> Enum.uniq()
    |> Enum.map(&{&1, Enum.uniq(labels_by_candidate[&1])})
  end

  # --- token stream -------------------------------------------------------

  # The shared lexer lives in `Mutare.Mutators.RegexLiteral.Tokens`; every pass below folds over
  # its `[Tokens.t()]` output. See that module for the token-shape contract each pass reads.

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
    candidates = Enum.filter(candidates, fn {candidate, _labels} -> renderable?(candidate) end)

    if regex_compilable?(original),
      do: Enum.filter(candidates, fn {candidate, _labels} -> regex_compilable?(candidate) end),
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
  # Yields `{pattern, variant_label}` pairs ("anchor" for the anchor swaps, "dot" for the
  # dotall flips) — the label rides each swap from its `*_swaps` table.
  defp mode_aware_patterns(pattern, modifiers, tokens) do
    {swaps, _leading} =
      Enum.flat_map_reduce(tokens, true, fn tok, leading? ->
        {mode_swaps(tok, pattern, leading?), leading? and not consumes_input?(tok)}
      end)

    swaps
    |> dedup_force_off(pattern, modifiers)
    |> Enum.map(fn {mutant, _tag, label} -> {mutant, label} end)
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

  # Splice each `{replacement, tag, label}` over the token's text, keeping the tag and label.
  defp spliced_swaps(swaps, pattern, tok) do
    pre = before_tok(pattern, tok)
    post = after_tok(pattern, tok)
    Enum.map(swaps, fn {repl, tag, label} -> {pre <> repl <> post, tag, label} end)
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
             [_one] = swap <-
               Enum.filter(acc, fn {_mutant, tag, _label} -> tag == {:force_off, flag} end) do
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

  # Each mode swap carries a tag and its `# mutare:ignore[regex:…]` variant label. The tag:
  # `{:force_off, flag}` when it forces a construct to behave as if `flag` were off (a
  # candidate to dedup against that flag's modifier-drop), else `:keep`. `^`→`\A` and
  # `$`→`\Z` force `m` off; the dot's `(?-s:.)` forces `s` off.
  # `^` ↔ `\A`: a no-op without `/m` (both = subject start), so only under `/m`.
  defp caret_swaps(true), do: [{"\\A", {:force_off, ?m}, "anchor"}]
  defp caret_swaps(false), do: []

  # `$` → `\z` always (`\z` is the strict end, never the m-off behaviour); `\Z` only under
  # `/m` (else `\Z` ≡ `$`), and it *is* the m-off behaviour.
  defp dollar_swaps(true), do: [{"\\z", :keep, "anchor"}, {"\\Z", {:force_off, ?m}, "anchor"}]
  defp dollar_swaps(false), do: [{"\\z", :keep, "anchor"}]

  # The escaped anchors swapping back toward `^`/`$` — never an m-off direction (they go
  # toward the m-*on* line anchors), so always `:keep`.
  defp escaped_anchor_swaps(?A, true), do: [{"^", :keep, "anchor"}]
  defp escaped_anchor_swaps(?z, _ml), do: [{"$", :keep, "anchor"}]
  defp escaped_anchor_swaps(?Z, true), do: [{"$", :keep, "anchor"}]
  defp escaped_anchor_swaps(_c, _ml), do: []

  # Force the dot's newline-matching the *other* way than the active mode (so the swap is
  # never a no-op): where `s` is on, `(?-s:.)` now excludes a newline (the s-off behaviour);
  # where it's off, `(?s:.)` now matches one. The scoped `(?…:.)` confines it to this dot.
  defp dot_swaps(true), do: [{"(?-s:.)", {:force_off, ?s}, "dot"}]
  defp dot_swaps(false), do: [{"(?s:.)", :keep, "dot"}]

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
  # replacement over the token's text via `before_tok`/`after_tok`. Each clause labels its
  # `{pattern, label}` output with the mutation's `# mutare:ignore[regex:…]` variant.
  # `acc` accumulates each token's mutants as a list-of-lists in reverse token order,
  # flattened once at the end — `acc ++ new` per token would be O(n²) over the stream.
  defp scan_patterns(pattern, tokens) do
    tokens
    |> scan_fold(pattern, false, false, [], [])
    |> Enum.reverse()
    |> Enum.concat()
  end

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
      scan_fold(rest, pat, pq2, zw2, groups2, [new | acc])
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
        c in @shorthand -> [{pre <> <<?\\, flip(c)>> <> post, "class"}]
        c in @boundary and not ic -> [{pre <> <<?\\, flip(c)>> <> post, "class"}]
        c == ?. and not ic -> [{pre <> "." <> post, "dot"}]
        true -> []
      end

    {new, false}
  end

  # Class open → toggle the negation (`[…` ↔ `[^…`).
  defp scan_token(%{kind: :class_open, text: t_open} = t, _rest, pat, _pq, _zw) do
    repl = if t_open == "[", do: "[^", else: "["
    {[{before_tok(pat, t) <> repl <> after_tok(pat, t), "class"}], false}
  end

  # Class range `lo-hi` → each in-range off-by-one neighbour (`class_range_mutations/2`).
  defp scan_token(%{kind: :range, text: <<lo::utf8, ?-, hi::utf8>>} = t, _rest, pat, _pq, _zw) do
    pre = before_tok(pat, t)
    post = after_tok(pat, t)
    {Enum.map(class_range_mutations(lo, hi), &{pre <> &1 <> post, "class"}), false}
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
          [{pre <> <<flip_quant(q)>> <> post, "quantifier"}] ++
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
        base = [{pre <> post, "quantifier"}, {pre <> "+" <> post, "quantifier"}]

        extra =
          if zw,
            do: [],
            else: [{pre <> "*" <> post, "quantifier"}, {pre <> "??" <> post, "laziness"}]

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
    bounds = Enum.map(counts, &{pre <> "{" <> &1 <> "}" <> post, "quantifier"})

    lazy =
      if variable_bound?(bound),
        do: lazy_variant(pre, t_bound, post, suffix_follows?(rest) or zw),
        else: []

    {bounds ++ lazy, true}
  end

  # Literal-dot swap: `.` (outside a class) → `\.` (a literal dot).
  defp scan_token(%{kind: :char, text: ".", in_class: false} = t, _rest, pat, _pq, _zw),
    do: {[{before_tok(pat, t) <> "\\." <> after_tok(pat, t), "dot"}], false}

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
  defp collapse_variant(pre, post, suffixed),
    do: if(suffixed, do: [], else: [{pre <> post, "quantifier"}])

  # Add a lazy `?` suffix to a greedy quantifier token (`a+` → `a+?`). Skipped when a
  # lazy/possessive suffix already follows, since a second one (`a+??`/`a+?+`) is invalid.
  # The `laziness` label is the writeup-motivating one: greediness is unobservable through
  # `Regex.match?/2` and often provably equivalent, so this is the variant users need to
  # suppress *without* swallowing the line's real quantifier/class mutants.
  defp lazy_variant(pre, quant, post, suffixed),
    do: if(suffixed, do: [], else: [{pre <> quant <> "?" <> post, "laziness"}])

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

  # `body` is a bound body produced by `bound_mutations/1` — `"3"`, `"2,"`, `"1,4"` — so the min
  # count is the digits before any comma.
  defp bound_body_min(body),
    do: body |> String.split(",", parts: 2) |> hd() |> String.to_integer()

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
    # `span_lists` accumulates each closed frame's spans as a list-of-lists in reverse
    # walk order (prepended per group-close, not `spans ++ new`, which would be O(n²)).
    {frames, span_lists} = Enum.reduce(tokens, {[top], []}, &alt_token/2)

    # Unclosed (leftover) frames contribute their spans last, in stack order.
    leftover = Enum.map(frames, &frame_spans(&1, byte_size(pattern)))
    spans = Enum.concat(Enum.reverse(span_lists) ++ leftover)

    Enum.map(spans, fn {start, len} ->
      binary_part(pattern, 0, start) <>
        binary_part(pattern, start + len, byte_size(pattern) - start - len)
    end)
  end

  # Group open — push a frame whose content starts just past the opener; `removable?`
  # (a plain capturing `(`) was decided by the reader.
  defp alt_token(
         %{kind: :group_open, offset: o, text: t, removable?: rem?},
         {frames, span_lists}
       ),
       do: {[frame(o + byte_size(t), rem?) | frames], span_lists}

  # Group close — pop the frame and prepend its branch-removal spans (content_end = the `)`).
  defp alt_token(%{kind: :group_close, offset: o}, {[frame | outer], span_lists}),
    do: {outer, [frame_spans(frame, o) | span_lists]}

  defp alt_token(%{kind: :group_close}, {[], span_lists}), do: {[], span_lists}

  # Top-level `|` — record the pipe position in the innermost frame. Prepended (reversed in
  # `frame_spans`) so a many-branch alt isn't O(branches²) on `pipes ++ [o]`.
  defp alt_token(
         %{kind: :char, text: "|", in_class: false, offset: o},
         {[frame | outer], span_lists}
       ),
       do: {[%{frame | pipes: [o | frame.pipes]} | outer], span_lists}

  defp alt_token(_token, acc), do: acc

  defp frame(start, removable), do: %{start: start, removable: removable, pipes: []}

  defp frame_spans(%{removable: false}, _content_end), do: []
  defp frame_spans(%{pipes: []}, _content_end), do: []

  defp frame_spans(%{start: start, pipes: rev_pipes}, content_end) do
    # `pipes` are recorded reversed (newest-first); restore ascending offset order.
    pipes = Enum.reverse(rev_pipes)
    # Branch 0: delete from the content start through the first pipe (inclusive).
    first = {start, hd(pipes) + 1 - start}
    # Branch i>0: delete the preceding pipe through the branch's end.
    ends = tl(pipes) ++ [content_end]
    rest = Enum.zip(pipes, ends) |> Enum.map(fn {pipe, stop} -> {pipe, stop - pipe} end)
    [first | rest]
  end
end
