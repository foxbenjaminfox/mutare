defmodule Mutare.Transform.NodeRange do
  @moduledoc """
  `Sourceror.get_range/1` with corrections for two upstream quirks that would
  otherwise corrupt a survivor's report diff.

  **1. The bare-atom over-count.** Sourceror sizes an atom literal as its name
  **plus one column for a colon** — right for a written atom (`:foo`, leading
  colon) and for a keyword-list key (`foo:`, trailing colon). But the three
  reserved-word atoms `true`/`false`/`nil` are written *bare*, with no colon, so
  their range comes back one column too wide. A textual patch over that range then
  eats the following character — e.g. `String.split(re, trim: true)` with the
  `true` swapped renders as `…, trim: false` (closing paren swallowed). `get/1`
  trims that phantom column.

  **2. The escaped-delimiter under-count in sigils.** Sourceror computes a sigil's
  end column from the **stored** content length (`range.ex`
  `get_end_pos_for_interpolation_segments/3`, `String.length` of the `<<>>`
  segments). The tokenizer keeps a sigil's content raw — `\\n`/`\\\\`/`\\t` stay
  two-character sequences — *except* it collapses an escaped **closing** delimiter
  (`\\/` → `/` in `~r/…/`, `\\}` → `}` in `~r{…}`), so the stored content is one
  byte shorter per such escape and the range falls short by that many columns. A
  textual patch over the short range leaves the sigil's tail in place — and when
  the mutation only drops a trailing flag (`~r/…/u` → `~r/…/`, RegexLiteral), the
  patch lands *exactly* on the dropped `u` and the diff shows **no change at all**
  (a survivor with an empty diff). `get/1` adds back one column per collapsed
  closing delimiter. (Escaped delimiters *before* the last interpolation are
  already accounted for — their absolute `closing` position is baked into the
  segment metadata — so only the trailing binary segments are counted; an opening
  delimiter escape `\\{` keeps its backslash and never collapses, so only the
  *closing* char is counted.)

  Only `Mutare.Report` reads the range, so the quirks are invisible at runtime:
  the metamutant is built from the AST, never the range. They corrupt only the
  diff a human reads for a surviving mutant. See NOTES "Sourceror range".
  """

  # Atoms written without any colon. A *keyword key* `true:`/`false:`/`nil:`
  # (`format: :keyword`) is written with the trailing colon, so Sourceror's count
  # is right there — the guard in `correct/2` excludes it.
  @bare_atoms [true, false, nil]

  @doc "Like `Sourceror.get_range/1`, correcting the bare-atom over-count and the sigil under-count."
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

  defp correct(range, _node), do: range

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
  # sigil whose length feeds the end column: the binary (literal) segments after
  # the last interpolation — or all of them when the sigil has none. In a
  # *parseable* sigil every bare closing-delimiter char in that text came from a
  # `\<close>` (an unescaped one would have ended the sigil; Sourceror rejects
  # unescaped balanced pairs), so counting them is exact.
  defp collapsed_closing_count(segments, close) do
    segments
    |> Enum.reverse()
    |> Enum.take_while(&is_binary/1)
    |> Enum.reduce(0, fn part, acc -> acc + occurrences(part, close) end)
  end

  defp occurrences(string, char), do: length(String.split(string, char)) - 1
end
