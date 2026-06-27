defmodule Mutare.Ignore.Directive do
  @moduledoc """
  One parsed `# mutare:ignore` directive: the line it suppresses, the mutators it
  admits, and an optional human reason.

    * `line` — the suppressed source line (already resolved from trailing-vs-
      standalone by `Mutare.Ignore`).
    * `mutators` — `:all` (no `[...]` filter ⇒ every mutator), or a `MapSet` of
      `{family, label}` **filter entries** (the `[...]` filter contents). `family`
      is a mutator-name string; `label` is `:any` (a bare `[relational]` entry,
      admitting every variant) or a variant-label string (a qualified `[relational:>]`
      entry, admitting only the mutant tagged with that label). A site matches only
      if some entry's `family` equals its `mutator` *and* the entry's `label` admits
      the site's variant.
    * `reason` — the free-text explanation, or `nil`.
    * `source_order` — the directive's 0-based position in document (source) order,
      stamped by `Mutare.Ignore.directives_from_ast/1`. `Mutare.Ignore.directive_for/4`
      ranks ties on it so the *source-first* directive's `reason` is the one recorded.

  ## The variant label

  A single site (one `i < j`) can yield several mutants — for `relational`,
  `i <= j` and `i > j`. A bare `[relational]` filter can only suppress *all* of
  them; the qualifier names *one* by its **variant label**. The labels compared are
  the site's `variant` **list** — names the producing mutator *declares*
  (`c:Mutare.Mutator.variants/0`) and tags each mutation with
  (`c:Mutare.Mutator.variant/2`), **not** anything read off the rendered AST. A
  qualifier matches when its token is one of that list, so `relational` labels its
  results `>`/`<=`/… and `[relational:>]` ignores the symmetric `i > j` reflection
  while `i <= j` still runs; `return_value` labels its pair `empty`/`sentinel`. One
  mutant may carry **several** labels — `Mutare.Mutators.Literal`'s deduped `1 - 1`/`0`
  is both `pred` and `zero` — and either qualifier then suppresses it.

  Labels are **opt-in** and **validated**: a family declaring no vocabulary admits
  only the bare `[family]`, and a `[family:label]` naming an unknown family/label is
  a hard `Mutare.Ignore.SpecError` (see `Mutare.Ignore.validate!/3`), so a typo is
  caught statically rather than silently failing to match.
  """

  @type target :: :any | String.t()
  @type entry :: {String.t(), target()}

  # The **query** side of a match: a site's recorded `variant` **label list** (`[]` when the mutant
  # is unlabeled, one or more labels otherwise — one mutant may be several kinds), *plus* `:any` for
  # the family-level "does any entry involve this family?" question. (An *entry*'s target is a single
  # `:any | String.t()` token — never a list — so it stays `target/0`; a query is the site-side list
  # or `:any`.)
  @type query :: :any | [String.t()]

  @type t :: %__MODULE__{
          line: pos_integer(),
          mutators: :all | MapSet.t(entry()),
          reason: String.t() | nil,
          source_order: non_neg_integer()
        }

  defstruct [:line, mutators: :all, reason: nil, source_order: 0]

  @doc """
  Render one `{family, target}` filter entry back to its `# mutare:ignore` token — bare
  `arithmetic` for a whole-family entry, `relational:>` for a qualified one. The inverse of
  `Mutare.Ignore`'s filter parse, used to echo a directive's filter in warnings and `--list-ignores`
  so the report shows what the user wrote.
  """
  @spec entry_label(entry()) :: String.t()
  def entry_label({family, :any}), do: family
  def entry_label({family, target}), do: "#{family}:#{target}"

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
