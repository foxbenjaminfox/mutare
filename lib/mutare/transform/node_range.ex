defmodule Mutare.Transform.NodeRange do
  @moduledoc """
  `Sourceror.get_range/1` with corrections for three upstream quirks that would
  otherwise corrupt a survivor's reported location.

  **1. The bare-atom over-count.** Sourceror sizes an atom literal as its name
  **plus one column for a colon** — right for a written atom (`:foo`, leading
  colon) and for a keyword-list key (`foo:`, trailing colon). But the three
  reserved-word atoms `true`/`false`/`nil` are written *bare*, with no colon, so
  their range comes back one column too wide. A textual patch over that range then
  eats the following character — e.g. `String.split(re, trim: true)` with the
  `true` swapped renders as `…, trim: false` (closing paren swallowed). `get/1`
  trims that phantom column.

  **2. The escaped-delimiter under-count in sigils and interpolated strings.**
  Sourceror computes a sigil's end column from the **stored** content length
  (`range.ex` `get_end_pos_for_interpolation_segments/3`, `String.length` of the
  `<<>>` segments). The tokenizer keeps a sigil's content raw — `\\n`/`\\\\`/`\\t`
  stay two-character sequences — *except* it collapses an escaped **closing**
  delimiter (`\\/` → `/` in `~r/…/`, `\\}` → `}` in `~r{…}`), so the stored content
  is one byte shorter per such escape and the range falls short by that many
  columns. A textual patch over the short range leaves the sigil's tail in place —
  and when the mutation only drops a trailing flag (`~r/…/u` → `~r/…/`,
  RegexLiteral), the patch lands *exactly* on the dropped `u` and the diff shows
  **no change at all** (a survivor with an empty diff). `get/1` adds back one
  column per collapsed closing delimiter. (Escaped delimiters *before* the last
  interpolation are already accounted for — their absolute `closing` position is
  baked into the segment metadata — so only the trailing binary segments are
  counted; an opening delimiter escape `\\{` keeps its backslash and never
  collapses, so only the *closing* char is counted.)

  The same collapse hits the interpolated string family — `"a\\"\#{x}\\"b"` and
  its charlist / quoted-atom cousins also range from segment lengths, and the
  tokenizer collapses `\\"` → `"` (or `\\'` → `'`) there too, so an escaped quote
  after the last interpolation shortens the range and the patch leaves the
  original closing quote behind (`toast("…\\"\#{x}\\".")` mutated to `""` renders
  as `toast(\""")`). `get/1` applies the same trailing-segment count to those
  three container shapes. Non-interpolated strings are immune (their raw content
  keeps the backslash), and heredocs never escape their fence, so only the
  quote-delimited (non-heredoc), single-line, interpolated forms are corrected.

  **3. The multi-line unary-negation over-count.** Sourceror sizes a prefix
  `not X` / `!X` as if the operator's own width extended the operand, so a
  *multi-line* negation reports an end a few columns past the operand's real end
  (`not exists(\\n …\\n)` lands a few columns into whatever trails the closing
  delimiter; a single-line negation is exact). A prefix operator ends exactly
  where its operand does, so `get/1` clamps the node's end back to the operand's.
  Unlike quirks 1–2 this one never touches the human diff — that reads whole
  source *lines* by range and the over-count is in the column, not the line — but
  the machine reporters emit the raw `endColumn` (`Mutare.Report.Json` /
  `Mutare.Report.Sarif`), so it is corrected at the source. (A parenthesized
  `not(X)` carries no meta to distinguish it and takes this path too; there the
  clamp lands one column short of the outer paren — still far closer than the raw
  over-count, and never *past* the real end.)

  Only `Mutare.Report` reads the range, so the quirks are invisible at runtime:
  the metamutant is built from the AST, never the range. They corrupt only a
  surviving mutant's rendered location — the human diff (quirks 1–2) or a machine
  reporter's end column (quirk 3). See NOTES "Sourceror range".
  """

  # Atoms written without any colon. A *keyword key* `true:`/`false:`/`nil:`
  # (`format: :keyword`) is written with the trailing colon, so Sourceror's count
  # is right there — the guard in `correct/2` excludes it.
  @bare_atoms [true, false, nil]

  @doc "Like `Sourceror.get_range/1`, correcting the bare-atom and multi-line-negation over-counts and the sigil/interpolated-string under-count."
  @spec get(Macro.t()) :: Sourceror.Range.t() | nil
  def get(node), do: node |> Sourceror.get_range() |> correct(node)

  defp correct(%Sourceror.Range{} = range, {:__block__, meta, [atom]})
       when atom in @bare_atoms do
    bare_written? = meta[:format] != :keyword and meta[:delimiter] in [nil, ""]

    if bare_written? and range.start[:line] == range.end[:line] do
      %{range | end: Keyword.update!(range.end, :column, &(&1 - 1))}
    else
      range
    end
  end

  # A sigil: `{:sigil_x, meta, [{:<<>>, _, segments}, modifiers]}`. The head also
  # admits a plain `call(<<…>>, [..])` of the same shape, so `sigil_range/3`
  # re-checks the `sigil_` atom name and returns the range untouched otherwise.
  defp correct(%Sourceror.Range{} = range, {sigil, meta, [{:<<>>, _, segments}, modifiers]})
       when is_atom(sigil) and is_list(modifiers) do
    sigil_range(range, Atom.to_string(sigil), meta, segments)
  end

  # An interpolated string: `{:<<>>, meta, segments}` carrying a `delimiter` meta
  # key (a real `<<…>>` bitstring has none, and `interpolated_range/3` passes it
  # through untouched).
  defp correct(%Sourceror.Range{} = range, {:<<>>, meta, segments}) when is_list(segments) do
    interpolated_range(range, meta[:delimiter], segments)
  end

  # An interpolated charlist: `'a#{x}b'` parses to a `List.to_charlist` call whose
  # single argument is the segment list.
  defp correct(%Sourceror.Range{} = range, {{:., _, [List, :to_charlist]}, meta, [segments]})
       when is_list(segments) do
    interpolated_range(range, meta[:delimiter], segments)
  end

  # An interpolated quoted atom: `:"a#{x}b"` parses to an `:erlang.binary_to_atom`
  # call wrapping the segments in a `<<>>`; the delimiter rides on the call meta.
  # Written keyword-shorthand (`"k#{x}": v`, `format: :keyword`) it carries a trailing
  # colon that Sourceror's range stops short of — unlike a plain keyword key (`foo:`),
  # whose range includes it — so the colon is covered here and `Mutare.Site` renders
  # both diff sides in keyword form.
  defp correct(
         %Sourceror.Range{} = range,
         {{:., _, [:erlang, :binary_to_atom]}, meta, [{:<<>>, _, segments}, _encoding]}
       )
       when is_list(segments) do
    range = interpolated_range(range, meta[:delimiter], segments)

    if meta[:format] == :keyword,
      do: %{range | end: Keyword.update!(range.end, :column, &(&1 + 1))},
      else: range
  end

  # Quirk 3: a prefix `not X` / `!X` ends where its operand does, but Sourceror over-counts a
  # multi-line one past that (see moduledoc). Clamp the end back to the operand's — a strict
  # non-widening move (`before?/2` no-ops the already-exact single-line case, where the operand end
  # equals the node end). The operand is a child of a node that already ranged, so `operand_end/1`
  # returns a range in the common path; it still guards `nil`/raise for a synthesized negation node a
  # mutator might hand to `get/1`.
  defp correct(%Sourceror.Range{} = range, {op, _meta, [operand]}) when op in [:not, :!] do
    case operand_end(operand) do
      nil ->
        range

      operand_end ->
        if before?(operand_end, range.end), do: %{range | end: operand_end}, else: range
    end
  end

  defp correct(range, _node), do: range

  defp operand_end(node) do
    case Sourceror.get_range(node) do
      %Sourceror.Range{end: operand_end} -> operand_end
      _ -> nil
    end
  rescue
    _ -> nil
  end

  defp before?(a, b), do: {a[:line], a[:column]} < {b[:line], b[:column]}

  # The string-family analogue of `sigil_range/4`: the closing delimiter is the
  # quote itself, and the tokenizer collapses only its escape (`\"` → `"`), so the
  # trailing-segment count is exact for the same reason as in a sigil. A heredoc
  # fence (`"""`/`'''`) never needs an escaped quote at the tail and falls through,
  # as does a delimiter-less node (a real bitstring). Single-line only: Sourceror's
  # own end-column arithmetic for a multi-line tail is start-relative and off on its
  # own, so there is no stable base to correct against.
  defp interpolated_range(range, delimiter, segments) when delimiter in ["\"", "'"] do
    if range.start[:line] == range.end[:line] do
      case collapsed_closing_count(segments, delimiter) do
        0 -> range
        n -> %{range | end: Keyword.update!(range.end, :column, &(&1 + n))}
      end
    else
      range
    end
  end

  defp interpolated_range(range, _delimiter, _segments), do: range

  defp sigil_range(range, "sigil_" <> _, meta, segments) do
    close = close_delimiter(meta[:delimiter])

    # Single-line only: a multiline/heredoc sigil never escapes its delimiter, and
    # the end-column arithmetic below assumes the close sits on the start line.
    if close && range.start[:line] == range.end[:line] do
      case collapsed_closing_count(segments, close) do
        0 -> range
        n -> %{range | end: Keyword.update!(range.end, :column, &(&1 + n))}
      end
    else
      range
    end
  end

  defp sigil_range(range, _name, _meta, _segments), do: range

  # The character that *closes* a sigil, per delimiter. Elixir allows exactly these
  # eight single-char delimiters (the four paired ones plus four symmetric); a
  # heredoc `"""`/`'''` (or anything unexpected) returns `nil`, skipping correction.
  defp close_delimiter("("), do: ")"
  defp close_delimiter("["), do: "]"
  defp close_delimiter("{"), do: "}"
  defp close_delimiter("<"), do: ">"
  defp close_delimiter(d) when d in ["/", "|", "\"", "'"], do: d
  defp close_delimiter(_), do: nil

  # How many closing-delimiter escapes the tokenizer collapsed in the part of the
  # literal whose length feeds the end column: the binary (literal) segments after
  # the last interpolation — or all of them when there is none. In a *parseable*
  # sigil or string every bare closing-delimiter char in that text came from a
  # `\<close>` (an unescaped one would have ended the literal; Sourceror rejects
  # unescaped balanced pairs), so counting them is exact.
  defp collapsed_closing_count(segments, close) do
    segments
    |> Enum.reverse()
    |> Enum.take_while(&is_binary/1)
    |> Enum.reduce(0, fn part, acc -> acc + occurrences(part, close) end)
  end

  defp occurrences(string, char), do: length(String.split(string, char)) - 1
end
