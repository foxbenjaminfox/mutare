defmodule Mutare.Ignore do
  @moduledoc """
  `# mutare:ignore` directives: which source lines they suppress.

  A site is *ignored* when a directive applies to its line. Two forms, by where
  the comment sits relative to the code:

    * **trailing** — `code # mutare:ignore` — suppresses its own line.
    * **standalone** — `# mutare:ignore` on its own line — suppresses the next.

  Directives are read from **Sourceror's parsed comment metadata**, not by
  scanning the raw source. Each comment carries its `line`, `text`, and a
  `previous_eol_count` (`0` ⇒ code precedes it on the line ⇒ trailing; `≥ 1` ⇒
  the comment stands alone). Because only genuine comments are considered, a
  literal string that merely *reads* like `"# mutare:ignore"` is never mistaken
  for a directive — the one false positive the old text scan accepted.

  The result is a plain set of line numbers in original-source line space, which
  is the same space `Mutare.Site` records its `line` in.
  """

  # A comment whose content is the directive: `#`, optional whitespace, then
  # `mutare:ignore` on a word boundary. Anchored at the comment's start, so the
  # directive must be the comment's purpose — not text buried in prose.
  @directive ~r/\A#\s*mutare:ignore\b/

  @doc """
  The set of source lines suppressed by a `# mutare:ignore` directive.

  `site.line in ignored_lines(source)` decides whether a site is ignored.
  """
  @spec ignored_lines(String.t()) :: MapSet.t(pos_integer())
  def ignored_lines(source) when is_binary(source) do
    source
    |> Sourceror.parse_string!()
    |> ignored_lines_from_ast()
  end

  @doc """
  Like `ignored_lines/1`, but for an AST already parsed by `Sourceror`.

  `Mutare.Transform` parses each file once and passes that AST straight in,
  avoiding a second full `Sourceror.parse_string!` per file.
  """
  @spec ignored_lines_from_ast(Macro.t()) :: MapSet.t(pos_integer())
  def ignored_lines_from_ast(ast) do
    ast
    |> comments()
    |> Enum.filter(&directive?/1)
    |> Enum.reduce(MapSet.new(), fn comment, acc ->
      MapSet.put(acc, suppressed_line(comment))
    end)
  end

  # Every comment Sourceror attached to a node, flattened. A comment lands in
  # exactly one node's `:leading_comments`/`:trailing_comments`, so no
  # deduplication is needed. (Which bucket it lands in is unreliable for the
  # trailing-vs-standalone question — `previous_eol_count` is the signal.)
  defp comments(ast) do
    {_ast, acc} =
      Macro.prewalk(ast, [], fn
        {_form, meta, _args} = node, acc when is_list(meta) ->
          leading = Keyword.get(meta, :leading_comments, [])
          trailing = Keyword.get(meta, :trailing_comments, [])
          {node, leading ++ trailing ++ acc}

        node, acc ->
          {node, acc}
      end)

    acc
  end

  defp directive?(%{text: text}), do: Regex.match?(@directive, text)

  # A trailing directive (no newline before it ⇒ code shares its line) suppresses
  # its own line; a standalone one suppresses the next.
  defp suppressed_line(%{line: line, previous_eol_count: 0}), do: line
  defp suppressed_line(%{line: line}), do: line + 1
end
