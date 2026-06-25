defmodule Mutare.Transform.MetaKeys do
  @moduledoc false
  # Single source of truth for the internal `:mutare_*` keys the transform stamps onto a
  # node's `meta` keyword list. These are bookkeeping the families and emit read; none may
  # reach the rendered metamutant source. Two aggregators derive their strip lists from here,
  # so neither can silently drift from a stamp site (the bug this module exists to prevent —
  # before it, `Mutare.Transform.Render`'s list and `Mutare.Transform.strip_candidates`'s
  # list were maintained by hand and `:mutare_hosted` had already gone missing from the
  # former):
  #
  #   * `Mutare.Transform.Render` strips **all** of them (`all/0`) just before rendering —
  #     the belt-and-suspenders final scrub.
  #   * `Mutare.Transform` strips the **candidate-delivery** subset (`delivery/0`) during emit,
  #     once a node's candidates are consumed and before the bare node is rebuilt.
  #
  # Only node-`meta` keys belong here. The other `:mutare_*` atoms are **not** metadata and
  # stay owned by their modules: runtime-contract identifiers (`:mutare_active`/`:mutare_track`
  # persistent_term keys in `Mutare.Selector`; the `:mutare_cov*` ETS tables in
  # `Mutare.Coverage.Recorder`), generated variable-name bases (`:mutare_piped`/`:mutare_cond`/
  # `:mutare_super`/`:mutare_capture_arg` in `Mutare.Transform.Names`/`Ctx`), the
  # `:mutare_unmatched` placeholder var, and the `{:mutare_behaviour, mod}` tagged tuple in
  # `Mutare.Transform.Uses.Harvest`.

  # Candidate-delivery keys — each holds a list of `Mutare.Transform.Candidate` structs that an
  # emit path consumes, then strips from the node before building it:
  #   * `:mutare`        — in-place / lifted candidates, the node-wrapping selector  (Analyze)
  #   * `:mutare_case`   — `case` tuple-the-scrutinee per-clause candidates           (Analyze.ClausePatterns)
  #   * `:mutare_hosted` — selector-host candidates for a DSL fragment (Ecto-style)   (Analyze, via Mutator host/2)
  @delivery [:mutare, :mutare_case, :mutare_hosted]

  # Pre-pass / resolution bookkeeping stamps (owning module in parentheses):
  #   * `:mutare_tag`              — replace-by-tag discovery marker                 (Tag)
  #   * `:mutare_nid`              — stable per-node identity for overlap pruning    (Resolve, read by Overlap)
  #   * `:mutare_alias`            — module a remote call's aliased path resolves to (Aliases)
  #   * `:mutare_import`           — `{module, :bare | :qualify}` for a bare call    (Imports)
  #   * `:mutare_import_witness`   — dead-code import-witness payload                (Imports, spliced by ImportWitness)
  #   * `:mutare_kernel_displaced` — a Kernel fn displaced by `import …, except:`    (Imports)
  #   * `:mutare_macro`            — known-macro per-argument routing                (Resolve, from Macros)
  #   * `:mutare_macro_piped`      — piped-value routing for a known-macro RHS       (Resolve, from Macros)
  #   * `:mutare_use_directives`   — import/alias/require a `use` injects            (Uses)
  #   * `:mutare_use_behaviours`   — `@behaviour`s a `use` injects (on the `use`)    (Uses)
  #   * `:mutare_behaviours`       — a `defmodule`'s behaviour MapSet               (Behaviours)
  @bookkeeping [
    :mutare_tag,
    :mutare_nid,
    :mutare_alias,
    :mutare_import,
    :mutare_import_witness,
    :mutare_kernel_displaced,
    :mutare_macro,
    :mutare_macro_piped,
    :mutare_use_directives,
    :mutare_use_behaviours,
    :mutare_behaviours
  ]

  @all @delivery ++ @bookkeeping

  @doc "The candidate-delivery meta keys — `Mutare.Transform` strips these during emit."
  @spec delivery() :: [atom()]
  def delivery, do: @delivery

  @doc "Every internal node-metadata key — `Mutare.Transform.Render` strips these before render."
  @spec all() :: [atom()]
  def all, do: @all
end
