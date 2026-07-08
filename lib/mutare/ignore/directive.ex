defmodule Mutare.Ignore.Directive do
  @moduledoc false
  # One parsed suppression directive — a plain `# mutare:ignore` or a scoped
  # `# mutare:ignore-file` / `# mutare:ignore-start`…`# mutare:ignore-end` region — the internal
  # representation behind the user-facing grammar documented on `Mutare.Ignore`. Fields:
  #
  #   * `scope` — the lines the directive covers: `:line` (a plain `# mutare:ignore`, covering
  #     exactly `line`), `:file` (covering every line of the file), or `{:region, first, last}`
  #     (a paired `-start`/`-end`, covering the two delimiter comments' lines *inclusive*).
  #   * `line` — for `:line` scope, the suppressed source line (already resolved from
  #     trailing-vs-standalone, including a standalone directive's read-through of a contiguous
  #     comment block). For a scoped directive, the directive comment's own line (a region's
  #     `first`), so line-keyed sorts stay total across scopes.
  #   * `comment_line` — the line of the directive comment itself, for messages (warnings,
  #     `SpecError`s, `--list-ignores`): with the comment-block read-through, `line` may sit
  #     several lines below the text the user needs to find.
  #   * `mutators` — `:all` (no `[...]` filter), or a `MapSet` of `{family, label}` filter entries;
  #     `family` is a mutator-name string and `label` is `:any` (a bare `[relational]`) or a
  #     variant-label string (a qualified `[relational:>]`). A site matches when some entry's family
  #     equals its mutator *and* the entry's label is in the site's `variant` list (`:any` admits any).
  #   * `reason` — the free-text explanation, or `nil`.
  #   * `source_order` — the directive's 0-based document-order position, used to break specificity
  #     ties so the source-first directive's reason is the one recorded.

  @type target :: :any | String.t()
  @type entry :: {String.t(), target()}

  # The **query** side of a match: a site's recorded `variant` **label list** (`[]` when the mutant
  # is unlabeled, one or more labels otherwise — one mutant may be several kinds), *plus* `:any` for
  # the family-level "does any entry involve this family?" question. (An *entry*'s target is a single
  # `:any | String.t()` token — never a list — so it stays `target/0`; a query is the site-side list
  # or `:any`.)
  @type query :: :any | [String.t()]

  @type scope :: :line | :file | {:region, pos_integer(), pos_integer()}

  @type t :: %__MODULE__{
          scope: scope(),
          line: pos_integer(),
          comment_line: pos_integer() | nil,
          mutators: :all | MapSet.t(entry()),
          reason: String.t() | nil,
          source_order: non_neg_integer()
        }

  defstruct [:line, scope: :line, comment_line: nil, mutators: :all, reason: nil, source_order: 0]

  @doc """
  Whether this directive's scope covers source line `line`. A `:line` directive covers exactly
  its own resolved line; a `:file` directive covers every line; a region covers the inclusive
  `first..last` span of its delimiter comments (so a trailing `# mutare:ignore-start` or `-end`
  on a code line covers that line's mutants too). A site with no recorded line (`nil`) is
  covered only by a `:file` directive — the one scope that needs no line to decide.
  """
  @spec covers?(t(), pos_integer() | nil) :: boolean()
  def covers?(%__MODULE__{scope: :file}, _line), do: true
  def covers?(%__MODULE__{}, nil), do: false
  def covers?(%__MODULE__{scope: :line, line: own}, line), do: own == line

  def covers?(%__MODULE__{scope: {:region, first, last}}, line),
    do: line >= first and line <= last

  @doc """
  How narrowly the directive's scope targets, as an integer for ranking: `2` a single line,
  `1` a region, `0` the whole file. `Mutare.Ignore.directive_for/4` prefers the narrower scope
  (after match specificity) so the recorded `reason` is the most locally-written one.
  """
  @spec scope_rank(t()) :: 0..2
  def scope_rank(%__MODULE__{scope: :line}), do: 2
  def scope_rank(%__MODULE__{scope: {:region, _first, _last}}), do: 1
  def scope_rank(%__MODULE__{scope: :file}), do: 0

  @doc """
  The directive's verb as written in source — `ignore`, `ignore-file`, or `ignore-start` —
  for echoing the directive back in warnings and listings.
  """
  @spec verb(t()) :: String.t()
  def verb(%__MODULE__{scope: :line}), do: "ignore"
  def verb(%__MODULE__{scope: :file}), do: "ignore-file"
  def verb(%__MODULE__{scope: {:region, _first, _last}}), do: "ignore-start"

  @doc """
  Render one `{family, target}` filter entry back to its `# mutare:ignore` token — bare
  `arithmetic` for a whole-family entry, `relational:>` for a qualified one. The inverse of
  `Mutare.Ignore`'s filter parse, used to echo a directive's filter in warnings and `--list-ignores`
  so the report shows what the user wrote.
  """
  @spec entry_label(entry()) :: String.t()
  def entry_label({family, :any}), do: family
  def entry_label({family, target}), do: "#{family}:#{target}"

  @doc ~S"""
  The bracketed `[family, family:label]` filter for a directive's `mutators` — each entry via
  `entry_label/1`, sorted for a stable message — or `""` for an unfiltered (`:all`) directive. The
  single home for the aggregate rendering both a scan warning (`Mutare.CLI.Diagnostics`) and
  `--list-ignores` (`Mutare.CLI.Info`) echo, so the `[...]` format can't drift between them.
  """
  @spec filter_label(:all | MapSet.t(entry())) :: String.t()
  def filter_label(:all), do: ""

  def filter_label(%MapSet{} = set),
    do: "[" <> (set |> Enum.map(&entry_label/1) |> Enum.sort() |> Enum.join(", ")) <> "]"

  @doc """
  Whether this directive suppresses a mutant of family `mutator` whose variant is
  `target` (the site's declared `variant` label **list** — `[]` when unlabeled, one or
  more labels when the mutant belongs to one or more kinds).

  `:all` admits every mutant. A filter set admits the mutant iff some entry's
  family equals `mutator`'s name (`to_string/1`, downcased — so an uppercase custom
  `name/0` still matches the downcased filter token) *and* the entry's label admits
  `target` — a bare `:any` entry admits any variant, otherwise the entry's label must be
  a **member** of the site's label list (so the deduped `1 - 1`/`0` mutant, labeled both
  `pred` and `zero`, is suppressed by `[literal:pred]` *or* `[literal:zero]`). So an
  unknown family, an unknown label, or an empty filter admits nothing
  (filtering fails safe toward *running* the mutant).

  Pass `target: :any` to ask the **family-level** question — does this directive
  involve `mutator` for *some* result? — used where a concrete result is not in
  hand. It admits a bare *and* a qualified entry of the family alike.
  """
  @spec applies_to?(t(), atom(), query()) :: boolean()
  def applies_to?(directive, mutator, target \\ :any)

  def applies_to?(directive, mutator, target),
    do: match_specificity(directive, mutator, target) >= 0

  @doc """
  How **specifically** this directive matches a mutant of family `mutator`/variant `target`, as an
  integer for ranking — `-1` no match, `0` an `:all` (unfiltered) directive, `1` a bare `[family]`
  entry (or a family-level `:any` query), `2` an exact `[family:label]` entry. A malformed
  empty-label entry (`{family, ""}`) is always `-1` (it admits no variant, not even `:any`).
  `Mutare.Ignore`'s `directive_for/4` uses it to prefer the qualifier-specific directive's `reason`
  when both a bare and a qualified directive land on one line. `applies_to?/3` is `specificity >= 0`.
  """
  @spec match_specificity(t(), atom(), query()) :: integer()
  def match_specificity(directive, mutator, target \\ :any)

  def match_specificity(%__MODULE__{mutators: :all}, _mutator, _target), do: 0

  def match_specificity(%__MODULE__{mutators: %MapSet{} = set}, mutator, target) do
    name = Mutare.Mutator.normalize_label(mutator)

    Enum.reduce(set, -1, fn {family, entry_target}, best ->
      max(best, entry_specificity(family == name, entry_target, target))
    end)
  end

  # The match strength of a single `{family, entry_target}` filter entry against a query
  # `target` (the site's label list, or `:any` for the family-level question): a bare-family entry
  # (`:any`) or a family-level query (`:any`) is a loose match (1); a concrete entry label that is a
  # **member** of the site's label list is an exact match (2); anything else is no match (-1).
  defp entry_specificity(false, _entry_target, _target), do: -1
  defp entry_specificity(true, :any, _target), do: 1
  # A **malformed empty-label entry** (`{family, ""}`, from a `[family:]` slip) matches no real
  # variant — and, crucially, *not* the family-level `:any` query either. It must fall through to
  # `-1` rather than being caught by the loose `:any`-query clause below, or a `[family:]` directive
  # that suppresses nothing would report as "involving" the family (the dangerous direction
  # `Mutare.Ignore.parse_entry/1` deliberately avoids — a silent family-wide suppression).
  defp entry_specificity(true, "", _target), do: -1
  defp entry_specificity(true, _entry_target, :any), do: 1

  # A concrete entry label against the site's label list: an **exact** match (2) iff the label is one
  # of the site's variants, else no match. A mutant carrying several labels (`pred`+`zero`) is thus
  # selected by a qualifier naming *any* of them; an unlabeled mutant (`[]`) by none.
  defp entry_specificity(true, entry_target, labels) when is_list(labels),
    do: if(entry_target in labels, do: 2, else: -1)

  # Defensive: any other query shape (e.g. a stray `nil`) matches no concrete entry. Bare and
  # `:any`-query entries are already handled above, so this only ever rejects a qualified entry.
  defp entry_specificity(true, _entry_target, _target), do: -1
end
