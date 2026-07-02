defmodule Mutare.Ignore do
  @moduledoc """
  Suppresses selected mutants with a source comment. Ignored mutants remain in the report but are excluded from the mutation score.

  A trailing directive applies to its own line. A standalone directive applies to the next line:

      expression() # mutare:ignore
      # mutare:ignore
      expression()

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
    ast
    |> comments()
    |> Enum.filter(&directive?/1)
    # Put the directives in document (source) order, then stamp each with that order as its
    # `source_order`. `comments/1` accumulates in `prewalk` *visit* order — not document order —
    # so sort by the comment's own physical line (stable, so the rare two comments sharing a line
    # keep their gathered order). The stamped index is what `directive_for/4` ranks ties on, so
    # the sort and the index that depends on it live together here, not three frames apart.
    |> Enum.sort_by(& &1.line)
    |> Enum.with_index()
    |> Enum.map(fn {comment, order} -> to_directive(comment, order) end)
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
      validate_entry!(family, label, directive.line, vocabulary, file)
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

  defp to_directive(%{text: text} = comment, source_order) do
    {mutators, reason} =
      @directive
      |> Regex.named_captures(text)
      |> Map.fetch!("rest")
      |> parse_rest()

    %Directive{
      line: suppressed_line(comment),
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
  # its own line; a standalone one suppresses the next.
  defp suppressed_line(%{line: line, previous_eol_count: 0}), do: line
  defp suppressed_line(%{line: line}), do: line + 1
end
