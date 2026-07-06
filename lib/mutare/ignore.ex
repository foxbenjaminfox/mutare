defmodule Mutare.Ignore do
  @moduledoc """
  Suppresses selected mutants with a source comment. Ignored mutants remain in the report but are excluded from the mutation score.

  A trailing directive applies to its own line. A standalone directive applies to the next line of code, reading through any comment lines in between — so it works at either end of an explanatory comment block:

      expression() # mutare:ignore
      # mutare:ignore
      expression()
      # mutare:ignore[literal] checked by the boundary test;
      # any non-empty replacement is behaviorally equivalent
      expression()

  A blank line ends the comment block: the directive then targets the blank line and suppresses nothing (warned — see below).

  A directive covers exactly **one** line of code. For a multi-line expression, place it directly above the line that carries the mutated code — above the `|>` step containing it, not the pipe's first line:

      digested_files
      # mutare:ignore[atom] delivery order is discarded
      |> Task.async_stream(&write/1, ordered: false)
      |> Stream.run()

  A directive misplaced onto an earlier line of the same expression suppresses nothing; the resulting warning points at the line that has the matching mutants.

  A directive may include a family filter, a reason, or both:

      # mutare:ignore                              suppress every mutant on the line
      # mutare:ignore equivalent under int math    suppress all; record the reason
      # mutare:ignore[arithmetic]                  suppress only arithmetic mutants
      # mutare:ignore[arithmetic, relational]      suppress two families
      # mutare:ignore[relational:>]                suppress only the `i > j` swap
      # mutare:ignore[literal] off-by-one is fine  a filter and a reason together

  Filter entries are mutator family names from `Mutare.Mutators.families/0`, `clause_drop`, or a custom mutator's `c:Mutare.Mutator.name/0`. Without a filter, the directive suppresses every mutant on the line.

  Use `family:label` to select one variant from a family. For example, `[relational:<=]` suppresses the `<=` replacement but not the other relational replacements. Labels are declared by each family and matched case-insensitively. If a mutant has several labels, any matching label suppresses it. Run `mix mutare --list-mutators` for the complete built-in list.

  Text after the keyword or filter is stored as the ignore reason and shown in the report.

  ## A recognizable equivalent mutant: the re-stated delegate guard

  A pattern worth knowing when triaging `guard_drop`/`pattern_guard` survivors in wrapper-heavy code — a thin wrapper that re-states the guard of the function it delegates to:

      def sign(data, salt) when is_binary(salt),
        do: Plug.Crypto.sign(data, salt)   # Plug.Crypto.sign/2 has the identical guard

  Dropping the wrapper's guard is provably unobservable: a bad input still raises the same `FunctionClauseError`, one stack frame deeper, inside the delegate. Verify against the delegate's source (the guards must really be equivalent), then ignore with a reason naming it:

      # mutare:ignore[guard_drop] Plug.Crypto.sign/2 re-checks is_binary(salt)
      def sign(data, salt) when is_binary(salt), do: Plug.Crypto.sign(data, salt)

  This shape recurs constantly in real codebases (any module wrapping a well-guarded library); recognizing it saves convincing yourself a survivor is "just uncovered" when it is actually unreachable.

  ## When a directive errors or does nothing

  An unknown label for a built-in family, including a disabled one, or an active custom family is an error. Unknown families, bare-family typos, empty filters, and malformed filters match nothing. Any directive that suppresses no mutant produces a warning; `--strict-ignores` turns that warning into a non-zero exit.

  Only source comments are parsed. Text such as `"# mutare:ignore"` inside a string has no effect.
  """

  alias Mutare.Ignore.Directive
  alias Mutare.Ignore.SpecError
  alias Mutare.Mutator

  # A comment whose content is the directive: `#`, optional whitespace, then
  # `mutare:ignore` on a word boundary. Anchored at the comment's start, so the
  # directive must be the comment's purpose — not text buried in prose. The
  # `rest` capture is everything after the keyword (the filter and/or reason).
  @directive ~r/\A#\s*mutare:ignore\b(?<rest>.*)/s

  # Inside `rest`, a leading `[...]` filter group and the trailing reason. The
  # filter body is everything up to the first `]`; the reason is whatever
  # follows. Only tried when `rest` starts with `[`.
  @filter ~r/\A\[(?<families>[^\]]*)\](?<reason>.*)/s

  @doc false
  # The `# mutare:ignore` directives in `source`, grouped by suppressed line.
  @spec directives(String.t()) :: %{pos_integer() => [Directive.t()]}
  def directives(source) when is_binary(source) do
    source
    |> Sourceror.parse_string!()
    |> directives_from_ast()
  end

  @doc false
  # Like `directives/1`, but for an AST `Sourceror` already parsed — so `Mutare.Transform` reuses
  # the AST it parsed for the transform, avoiding a second `Sourceror.parse_string!` per file.
  @spec directives_from_ast(Macro.t()) :: %{pos_integer() => [Directive.t()]}
  def directives_from_ast(ast) do
    all = comments(ast)

    # The lines occupied by *standalone* comments (`previous_eol_count > 0` ⇒ nothing else on the
    # line): the contiguous block a standalone directive reads through to find its code line. A
    # trailing comment's line carries code, so it must NOT be read through — hence standalone only.
    comment_lines =
      all
      |> Enum.filter(&(&1.previous_eol_count > 0))
      |> MapSet.new(& &1.line)

    all
    |> Enum.filter(&directive?/1)
    # Put the directives in document (source) order, then stamp each with that order as its
    # `source_order`. `comments/1` accumulates in `prewalk` *visit* order — not document order —
    # so sort by the comment's own physical line (stable, so the rare two comments sharing a line
    # keep their gathered order). The stamped index is what `directive_for/4` ranks ties on, so
    # the sort and the index that depends on it live together here, not three frames apart.
    |> Enum.sort_by(& &1.line)
    |> Enum.with_index()
    |> Enum.map(fn {comment, order} -> to_directive(comment, order, comment_lines) end)
    |> Enum.group_by(& &1.line)
  end

  @doc false
  # The directive (if any) that suppresses a site at `line` for `mutator`/`target` (the site's
  # `variant` label list). Returns the most specific match — an exact `[family:label]` over a bare
  # `[family]`/`:all` — ties broken by source order, so the recorded `reason` is the one the user
  # wrote for this mutant. `target` defaults to `:any` (the family-level "does any directive admit
  # this family?" question).
  @spec directive_for(
          %{pos_integer() => [Directive.t()]},
          pos_integer(),
          atom(),
          Directive.query()
        ) ::
          Directive.t() | nil
  def directive_for(directives, line, mutator, target \\ :any) do
    case directives
         |> Map.get(line, [])
         |> Enum.filter(&Directive.applies_to?(&1, mutator, target)) do
      [] ->
        nil

      matches ->
        # Most specific wins; on a specificity tie, the source-first directive (lowest
        # `source_order`). Ranking on the *intrinsic* `source_order` — rather than relying on
        # `Enum.max_by` returning the first maximal element of a pre-sorted list — keeps the
        # tie-break self-contained: `directives_from_ast/1` stamps the order, this reads it.
        Enum.max_by(
          matches,
          &{Directive.match_specificity(&1, mutator, target), -&1.source_order}
        )
    end
  end

  @doc false
  # Strictly validate every qualified `[family:label]` filter against `vocabulary`, raising
  # `Mutare.Ignore.SpecError` on the first whose family is *known* but whose label can't be resolved
  # (with a "did you mean"). An unknown family is left to the soft `ineffective/2` warning, and a
  # bare `[family]` is never checked here. `file` locates the directive. Returns `:ok` otherwise.
  @spec validate!(
          %{pos_integer() => [Directive.t()]},
          %{String.t() => :none | MapSet.t(String.t())},
          String.t()
        ) :: :ok
  def validate!(directives, vocabulary, file) do
    # Iterate in a stable, top-to-bottom order so the *first* bad qualifier raised is deterministic
    # (the lowest line, then source order within the line, then a sorted scan of that filter's
    # entries). `directives` is a map and a filter's entries are a `MapSet` — both unordered — so
    # without these sorts the reported error would be whichever entry hash-iteration happened to
    # reach first, not the one nearest the top of the file.
    for {_line, ds} <- Enum.sort_by(directives, fn {line, _ds} -> line end),
        directive <- ds,
        {family, label} <- Enum.sort(qualified_entries(directive)) do
      # Located at the directive comment itself, not the suppressed line — the
      # two can be several lines apart when a comment block sits between them,
      # and the error is about the directive's own text.
      validate_entry!(family, label, directive.comment_line, vocabulary, file)
    end

    :ok
  end

  @doc false
  # Whether any directive carries a qualified `[family:label]` entry — the only kind `validate!/3`
  # checks, so the transform skips building the variant vocabulary when every filter is bare.
  @spec any_qualified?(%{pos_integer() => [Directive.t()]}) :: boolean()
  def any_qualified?(directives) do
    Enum.any?(directives, fn {_line, ds} -> Enum.any?(ds, &(qualified_entries(&1) != [])) end)
  end

  defp qualified_entries(%Directive{mutators: :all}), do: []

  # The qualified entries `validate!/3` checks: a real, *named* label. The whole-family `:any` and
  # the empty-label `""` (a malformed `[family:]` qualifier) are both excluded — the former is a
  # bare filter, the latter a slip left to the soft `ineffective/2` warning, never a hard abort.
  defp qualified_entries(%Directive{mutators: %MapSet{} = set}),
    do: for({family, label} <- set, label not in [:any, ""], do: {family, label})

  defp validate_entry!(family, label, line, vocabulary, file) do
    case Map.get(vocabulary, family) do
      # The family is not in the active vocabulary. We can't *prove* this is a typo — it is equally
      # an excluded custom family (a `--mutators` subset, a removed config entry), which we have no
      # way to enumerate. So, exactly like a bare `[family]` typo, it stays lenient: a soft
      # `ineffective/2` warning, never a hard abort. Hard errors are reserved for a *known* family
      # with a wrong/absent label (`:none`/`:unknown_variant` below), where the mistake is certain.
      nil ->
        :ok

      :none ->
        raise SpecError,
          reason: :no_variants,
          file: file,
          line: line,
          family: family,
          label: label,
          message:
            "#{file}:#{line}: the #{family} mutator declares no variant labels, so " <>
              "# mutare:ignore[#{family}:#{label}] can't select one — use the bare " <>
              "# mutare:ignore[#{family}] to suppress the whole family"

      %MapSet{} = labels ->
        unless MapSet.member?(labels, label) do
          raise SpecError,
            reason: :unknown_variant,
            file: file,
            line: line,
            family: family,
            label: label,
            message:
              "#{file}:#{line}: #{inspect(label)} is not a #{family} variant in " <>
                "# mutare:ignore[#{family}:#{label}]" <>
                suggestion(label, MapSet.to_list(labels)) <>
                " (known: #{labels |> Enum.sort() |> Enum.join(", ")})"
        end
    end
  end

  # A `; did you mean "x"?` clause for the closest candidate by Jaro distance, or "" when nothing
  # is close enough (the `>= 0.8` threshold avoids a misleading suggestion for a wild typo). This
  # fires for a *near-miss* of a declared label — `nagate` → `negate`, `tru` → `true`, or a symbol
  # slip like `>==` → `>=`. It deliberately stays silent for a cross-*spelling* miss (a word for a
  # symbol family, `lte` for `<=`), where no string distance is meaningful; the caller always
  # appends the full `(known: …)` list, which is the actionable fallback in that case.
  defp suggestion(name, candidates) do
    candidates
    |> Enum.map(&{&1, String.jaro_distance(name, &1)})
    |> Enum.filter(fn {_candidate, distance} -> distance >= 0.8 end)
    |> Enum.max_by(fn {_candidate, distance} -> distance end, fn -> nil end)
    |> case do
      {best, _distance} -> "; did you mean #{inspect(best)}?"
      nil -> ""
    end
  end

  @doc false
  # For an *ineffective* directive: the first following line — within the multi-line expression
  # that starts at the directive's suppressed line — carrying a mutant the directive would have
  # suppressed, or `nil`. Powers the misplacement hint in the warning: a directive covers exactly
  # one line, and a long pipe reads as one logical statement, so annotating it "from the top" (the
  # directive above `digested_files`, the mutated `ordered:`/`timeout:` two `|>` steps down) is the
  # most common miss. The scan is bounded by the expression's own span, so the hint never points
  # into an unrelated statement further down the file.
  @spec misplacement_hint(Macro.t(), Directive.t(), [
          {pos_integer() | nil, atom(), Directive.query()}
        ]) :: pos_integer() | nil
  def misplacement_hint(ast, %Directive{} = directive, occupied) do
    case expression_end_line(ast, directive.line) do
      end_line when is_integer(end_line) and end_line > directive.line ->
        occupied
        |> Enum.filter(fn {line, mutator, target} ->
          is_integer(line) and line > directive.line and line <= end_line and
            Directive.applies_to?(directive, mutator, target)
        end)
        |> Enum.map(fn {line, _mutator, _target} -> line end)
        |> Enum.min(fn -> nil end)

      _no_multi_line_expression ->
        nil
    end
  end

  # The last line of the widest expression that *starts* at `line`, or `nil` when no node does
  # (a blank line, a comment-only line, past EOF). `Sourceror.get_range/1` computes a node's start
  # from its leftmost token, so a pipe chain's node starts at its first operand's line even though
  # the `|>` operator meta sits further down.
  defp expression_end_line(ast, line) do
    {_ast, max_end} =
      Macro.prewalk(ast, nil, fn
        {_form, meta, _args} = node, acc when is_list(meta) ->
          case node_range(node) do
            %Sourceror.Range{start: start_pos, end: end_pos} ->
              if start_pos[:line] == line,
                do: {node, max(acc || end_pos[:line], end_pos[:line])},
                else: {node, acc}

            _no_range ->
              {node, acc}
          end

        node, acc ->
          {node, acc}
      end)

    max_end
  end

  # `Sourceror.get_range/1` is total over real source nodes but can return `nil` (and, defensively,
  # raise) on synthetic/degenerate shapes; a missing range just means no hint from that node.
  defp node_range(node) do
    Sourceror.get_range(node)
  rescue
    _ -> nil
  end

  @doc false
  # The directives in `directives` that suppressed *nothing* (sorted by line): a bare-family typo,
  # a valid variant label absent on this line, an empty `[]`, a standalone directive on the wrong
  # line, or a family that produced no mutant there — every directive `Directive.applies_to?/3`
  # rejects for every occupied `{mutator, variant}` on its line. (A qualified bad label on a *known*
  # family never reaches here — it is a hard `validate!/3` error.) `occupied` is the
  # `{line, mutator, variant}` (the `variant` label list) of each recorded site, passed as plain
  # tuples so this module stays unaware of the `Mutare.Site` representation. Detection reflects the
  # active config — a family disabled by `--mutators` produces no site, so a directive naming only
  # it is reported.
  @spec ineffective(%{pos_integer() => [Directive.t()]}, [
          {pos_integer() | nil, atom(), Directive.query()}
        ]) :: [Directive.t()]
  def ineffective(directives, occupied) do
    by_line =
      Enum.group_by(occupied, fn {line, _m, _t} -> line end, fn {_line, m, t} -> {m, t} end)

    directives
    |> Enum.flat_map(fn {_line, ds} -> ds end)
    |> Enum.reject(fn directive ->
      by_line
      |> Map.get(directive.line, [])
      |> Enum.any?(fn {mutator, result} -> Directive.applies_to?(directive, mutator, result) end)
    end)
    |> Enum.sort_by(& &1.line)
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

    # `prewalk` accumulates in a visit order that does *not* match document order (it prepends,
    # and folds a node's leading *before* its trailing comments). Ordering into true source order
    # — and stamping each directive's `source_order` for the `directive_for/4` tie-break — is
    # `directives_from_ast/1`'s job, kept next to the index that depends on it.
    acc
  end

  defp directive?(%{text: text}), do: Regex.match?(@directive, text)

  defp to_directive(%{text: text} = comment, source_order, comment_lines) do
    {mutators, reason} =
      @directive
      |> Regex.named_captures(text)
      |> Map.fetch!("rest")
      |> parse_rest()

    %Directive{
      line: suppressed_line(comment, comment_lines),
      comment_line: comment.line,
      mutators: mutators,
      reason: reason,
      source_order: source_order
    }
  end

  # Split the text after `mutare:ignore` into a mutator filter and a reason. A
  # leading `[...]` is the filter (otherwise the filter is `:all`); whatever
  # remains, trimmed, is the reason (or `nil` when blank).
  defp parse_rest(rest) do
    trimmed = String.trim_leading(rest)

    case Regex.named_captures(@filter, trimmed) do
      %{"families" => families, "reason" => reason} ->
        {parse_filter(families), clean_reason(reason)}

      nil ->
        # No `[...]` matched. A **malformed filter** — a leading `[` with no closing `]`
        # (`# mutare:ignore[relational`) — must NOT degrade to `:all`: that would silently
        # suppress *every* mutant on the line, the one dangerous direction. Treat it as an
        # empty filter (matches nothing, fail-safe toward running the mutant), surfaced by
        # `ineffective/2` as a soft warning. Text not starting with `[` is an ordinary reason.
        if String.starts_with?(trimmed, "[") do
          {MapSet.new([]), nil}
        else
          {:all, clean_reason(rest)}
        end
    end
  end

  # The bracket body → a set of `{family, target}` entries. Split on commas and
  # whitespace; an empty body yields an empty set, which matches nothing. Each
  # entry is `family` or `family:label`; both halves are folded by
  # `Mutare.Mutator.normalize_label/1` (case-insensitive matching — the *same* helper the
  # declaring/recording sides use, so the two can't drift), and the split is on the *first* `:`
  # only, so a multi-character operator label (`!==`) is kept whole. A bare `:` can't appear in a
  # family name.
  defp parse_filter(families) do
    families
    |> String.split(~r/[,\s]+/, trim: true)
    |> Enum.map(&parse_entry/1)
    |> MapSet.new()
  end

  # A bare `[family]` (no colon) is the whole-family entry `:any`. A `family:label` token is the
  # qualified entry `{family, label}`. A **trailing colon with no label** (`[relational:]`, or a
  # `[relational: >]` whose stray space splits the colon off its label) splits to `[family, ""]`
  # and so falls through to the general clause as the empty-label entry `{family, ""}` — a
  # *malformed qualifier*, not a bare family: it matches no real variant, so it suppresses
  # **nothing** and is surfaced by `ineffective/2` as a soft warning. This is deliberately *not*
  # whole-family suppression: a silent `:any` would hide every mutant the user meant to keep (the
  # dangerous direction, with no `validate!`/`ineffective` net). Nor is it a hard error — a
  # *missing* label is a slip, not a *named* wrong one, so (like a bare typo) it stays lenient.
  defp parse_entry(token) do
    case String.split(token, ":", parts: 2) do
      [family] -> {Mutator.normalize_label(family), :any}
      [family, label] -> {Mutator.normalize_label(family), Mutator.normalize_label(label)}
    end
  end

  defp clean_reason(text) do
    case String.trim(text) do
      "" -> nil
      reason -> reason
    end
  end

  # A trailing directive (no newline before it ⇒ code shares its line) suppresses
  # its own line; a standalone one suppresses the next line of *code*, reading
  # through the contiguous block of standalone comments below it — so a directive
  # works at either end of an explanatory comment block. A blank line is not a
  # comment line, so it ends the walk (the directive then targets the blank line,
  # suppresses nothing, and is surfaced by `ineffective/2` — the conservative
  # reading of a detached block).
  defp suppressed_line(%{line: line, previous_eol_count: 0}, _comment_lines), do: line
  defp suppressed_line(%{line: line}, comment_lines), do: next_code_line(line + 1, comment_lines)

  defp next_code_line(line, comment_lines) do
    if line in comment_lines,
      do: next_code_line(line + 1, comment_lines),
      else: line
  end
end
