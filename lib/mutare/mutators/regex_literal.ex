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
    * **character-class shorthands** — flip a `\\d`/`\\w`/`\\s` to its complement
      `\\D`/`\\W`/`\\S` (and back), anywhere, plus the word-boundary `\\b`↔`\\B`
      outside a class (inside `[…]` `\\b` is a backspace, so it is left alone).
    * **class negation** — toggle a bracketed character class between matching and
      not matching its members: `[abc]` ↔ `[^abc]`.
    * **quantifiers** — swap `+`↔`*` (the cleanest complement: `+` is 1-or-more,
      `*` is 0-or-more, non-equivalent even under `Regex.match?/2`); turn an
      optional `?` mandatory by dropping it (`colou?r` → `colour`) *and* by
      raising it to `+` (`-?\\d` → `-+\\d`); and nudge a bounded quantifier's
      counts by one (`{3}`→`{2}`/`{4}`, `{8,}`→`{7,}`/`{9,}`, `{2,4}`→
      `{1,4}`/`{3,4}`/`{2,3}`/`{2,5}`), staying within `0 ≤ n ≤ m`. A `?`/`*`/`+`
      that is a group marker (`(?:…)`) or a lazy/possessive suffix (`a+?`) is left
      alone.
    * **alternation** — drop one branch of an alternation at the pattern's top
      level or inside a *capturing* group: `~r/^(GET|POST)$/` → `~r/^(GET)$/` and
      `~r/^(POST)$/`. Non-capturing/lookaround groups (`(?:…)`, `(?=…)`, …) are
      skipped, since rewriting them risks shifting capture semantics rather than
      just narrowing what matches.
    * **modifiers** — drop a present flag one at a time: `~r/x/uis` yields mutants
      `~r/x/is`, `~r/x/us`, `~r/x/ui`. Removing `i` (caseless), `s` (dotall), `u`
      (unicode), `m` (multiline), … each changes what the pattern accepts.

  In-place and compile-safe: every replacement is written to stay a legal regex
  wherever the original was (an escaped `\\$`/`\\d`/`\]` is left alone, a leading
  `]` in a class is literal, bound counts are kept ordered). The metamutant
  validates each static regex at *compile* time, so the rare pathological mutant
  is caught by the poison pre-filter rather than shipped. Only non-interpolated
  patterns are touched: an interpolated `~r/\#{x}/` parses with multiple `<<>>`
  parts (not a single binary), so the pattern operand is always static.
  """
  @behaviour Mutare.Mutator

  @sentinel "mutare"

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
         scan_patterns(pattern) ++
         alternation_patterns(pattern))
      |> Enum.map(&{&1, modifiers})

    modifier_variants = Enum.map(modifier_drops(modifiers), &{pattern, &1})

    (pattern_variants ++ modifier_variants)
    |> Enum.reject(&(&1 == {pattern, modifiers}))
    |> Enum.uniq()
    |> Enum.map(fn {p, m} -> {:sigil_r, meta, [{:<<>>, bmeta, [p]}, m]} end)
  end

  def mutate(_node), do: :skip

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

  # --- modifiers -----------------------------------------------------------

  # One mutant per *distinct* present flag, with that flag removed (order preserved).
  defp modifier_drops(modifiers) do
    modifiers
    |> Enum.uniq()
    |> Enum.map(&(modifiers -- [&1]))
  end

  # --- per-token scan: shorthands, class negation, quantifiers, bounds -----

  # Walk the pattern left-to-right, tracking escape pairs, character-class nesting
  # (`in_class`/`just_opened`, the latter so a leading `]` is read as a literal
  # member) and whether the previous token was a quantifier (`prev_quant`, so a lazy
  # `a+?` / possessive `a++` suffix is not itself swapped). Each swap site appends
  # one or more fully-rewritten patterns.
  defp scan_patterns(pattern), do: scan(pattern, "", false, false, false, [])

  defp scan(<<>>, _prefix, _in_class, _jo, _pq, acc), do: acc

  # An escape sequence: backslash + the codepoint it escapes (consumed as a unit, so
  # `\\d` — an escaped backslash then `d` — is never mistaken for the `\d` shorthand).
  defp scan(<<?\\, c::utf8, rest::binary>>, prefix, in_class, _jo, _pq, acc) do
    new =
      cond do
        c in @shorthand -> [prefix <> <<?\\, flip(c)>> <> rest]
        c in @boundary and not in_class -> [prefix <> <<?\\, flip(c)>> <> rest]
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

  # Quantifier `*`/`+` → its complement, only as a real (postfix) quantifier.
  defp scan(<<q, rest::binary>>, prefix, false, _jo, pq, acc) when q in [?*, ?+] do
    new =
      if postfix_quantifier?(prefix, pq),
        do: [prefix <> <<flip_quant(q)>> <> rest],
        else: []

    scan(rest, prefix <> <<q>>, false, false, true, acc ++ new)
  end

  # Optional `?` → mandatory: drop it, and raise it to `+`. Skipped when it is a
  # group marker (`(?…`) or a lazy suffix (`postfix_quantifier?/2` covers both).
  defp scan(<<??, rest::binary>>, prefix, false, _jo, pq, acc) do
    new =
      if postfix_quantifier?(prefix, pq),
        do: [prefix <> rest, prefix <> "+" <> rest],
        else: []

    scan(rest, prefix <> "?", false, false, true, acc ++ new)
  end

  # Bounded quantifier `{n}` / `{n,}` / `{n,m}` → each in-range off-by-one neighbour.
  defp scan(<<?{, rest::binary>>, prefix, false, _jo, _pq, acc) do
    case parse_bound(rest) do
      {:ok, bound, tail} ->
        consumed = binary_part(rest, 0, byte_size(rest) - byte_size(tail))
        new = Enum.map(bound_mutations(bound), &(prefix <> "{" <> &1 <> "}" <> tail))
        scan(tail, prefix <> "{" <> consumed, false, false, true, acc ++ new)

      :error ->
        scan(rest, prefix <> "{", false, false, false, acc)
    end
  end

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
    [n - 1, n + 1]
    |> Enum.filter(&(&1 >= 0))
    |> Enum.map(&"#{&1},")
  end

  defp bound_mutations({:range, n, m}) do
    ns = Enum.filter([n - 1, n + 1], &(&1 >= 0 and &1 <= m))
    ms = Enum.filter([m - 1, m + 1], &(&1 >= n))
    Enum.map(ns, &"#{&1},#{m}") ++ Enum.map(ms, &"#{n},#{&1}")
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
