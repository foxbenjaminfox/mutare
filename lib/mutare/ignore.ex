defmodule Mutare.Ignore do
  @moduledoc """
  `# mutare:ignore` directives: which mutants they suppress, and why.

  A site is *ignored* when a directive applies to its line **and** that
  directive's filter admits the site's mutator. Two forms, by where the comment
  sits relative to the code:

    * **trailing** — `code # mutare:ignore` — suppresses its own line.
    * **standalone** — `# mutare:ignore` on its own line — suppresses the next.

  ## Grammar

  After the `# mutare:ignore` keyword, two optional parts may follow, in order:

      # mutare:ignore                              suppress every mutant on the line
      # mutare:ignore equivalent under int math    suppress all; reason = the trailing text
      # mutare:ignore[arithmetic]                  suppress only :arithmetic mutants
      # mutare:ignore[arithmetic, relational]      suppress two families
      # mutare:ignore[literal] off-by-one is fine  filter + reason together

    * A **filter** in `[...]` — a comma/space-separated list of mutator names
      (the family atoms in `Mutare.Mutators`, e.g. `arithmetic`, plus `clause_drop`
      and any custom mutator's `name/0`). A site is suppressed only if its
      `mutator` is in the list. With no brackets, *every* mutator is suppressed.
    * A free-text **reason** — anything after the keyword (or after the closing
      `]`). It is recorded on the site (`Site.ignore_reason`) and surfaced in the
      report, so an exclusion documents itself.

  Filtering fails **safe**: an unknown family name (a typo, or a `[]` empty list)
  simply matches nothing, so the mutant still runs rather than being silently
  hidden. The brackets are what make a token a filter — without them, trailing
  words are always prose, never a filter — so prose can never accidentally
  suppress a family.

  Directives are read from **Sourceror's parsed comment metadata**, not by
  scanning the raw source. Each comment carries its `line`, `text`, and a
  `previous_eol_count` (`0` ⇒ code precedes it on the line ⇒ trailing; `≥ 1` ⇒
  the comment stands alone). Because only genuine comments are considered, a
  literal string that merely *reads* like `"# mutare:ignore"` is never mistaken
  for a directive.

  Lines are in original-source line space, the same space `Mutare.Site` records
  its `line` in.
  """

  alias Mutare.Ignore.Directive

  # A comment whose content is the directive: `#`, optional whitespace, then
  # `mutare:ignore` on a word boundary. Anchored at the comment's start, so the
  # directive must be the comment's purpose — not text buried in prose. The
  # `rest` capture is everything after the keyword (the filter and/or reason).
  @directive ~r/\A#\s*mutare:ignore\b(?<rest>.*)/s

  # Inside `rest`, a leading `[...]` filter group and the trailing reason. The
  # filter body is everything up to the first `]`; the reason is whatever
  # follows. Only tried when `rest` starts with `[`.
  @filter ~r/\A\[(?<families>[^\]]*)\](?<reason>.*)/s

  @doc """
  The `# mutare:ignore` directives in `source`, grouped by suppressed line:
  `%{line => [%Directive{}]}`.
  """
  @spec directives(String.t()) :: %{pos_integer() => [Directive.t()]}
  def directives(source) when is_binary(source) do
    source
    |> Sourceror.parse_string!()
    |> directives_from_ast()
  end

  @doc """
  Like `directives/1`, but for an AST already parsed by `Sourceror`.

  `Mutare.Transform` parses each file once and passes that AST straight in,
  avoiding a second full `Sourceror.parse_string!` per file.
  """
  @spec directives_from_ast(Macro.t()) :: %{pos_integer() => [Directive.t()]}
  def directives_from_ast(ast) do
    ast
    |> comments()
    |> Enum.filter(&directive?/1)
    |> Enum.map(&to_directive/1)
    |> Enum.group_by(& &1.line)
  end

  @doc """
  The directive (if any) that suppresses a site at `line` produced by `mutator`.

  Returns the first matching `%Directive{}` — its `reason` is what the site
  records — or `nil` when the site is not ignored. The lookup `directives` is the
  map from `directives_from_ast/1`.
  """
  @spec directive_for(%{pos_integer() => [Directive.t()]}, pos_integer(), atom()) ::
          Directive.t() | nil
  def directive_for(directives, line, mutator) do
    directives
    |> Map.get(line, [])
    |> Enum.find(&Directive.applies_to?(&1, mutator))
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

  defp to_directive(%{text: text} = comment) do
    {mutators, reason} =
      @directive
      |> Regex.named_captures(text)
      |> Map.fetch!("rest")
      |> parse_rest()

    %Directive{line: suppressed_line(comment), mutators: mutators, reason: reason}
  end

  # Split the text after `mutare:ignore` into a mutator filter and a reason. A
  # leading `[...]` is the filter (otherwise the filter is `:all`); whatever
  # remains, trimmed, is the reason (or `nil` when blank).
  defp parse_rest(rest) do
    case Regex.named_captures(@filter, String.trim_leading(rest)) do
      %{"families" => families, "reason" => reason} ->
        {parse_filter(families), clean_reason(reason)}

      nil ->
        {:all, clean_reason(rest)}
    end
  end

  # The bracket body → a set of mutator names (downcased strings). Split on commas
  # and whitespace; an empty body yields an empty set, which matches nothing.
  defp parse_filter(families) do
    families
    |> String.split(~r/[,\s]+/, trim: true)
    |> Enum.map(&String.downcase/1)
    |> MapSet.new()
  end

  defp clean_reason(text) do
    case String.trim(text) do
      "" -> nil
      reason -> reason
    end
  end

  # A trailing directive (no newline before it ⇒ code shares its line) suppresses
  # its own line; a standalone one suppresses the next.
  defp suppressed_line(%{line: line, previous_eol_count: 0}), do: line
  defp suppressed_line(%{line: line}), do: line + 1
end
