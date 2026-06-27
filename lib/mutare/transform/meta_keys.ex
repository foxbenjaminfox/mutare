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
  # emit path consumes, then strips from the node before building it. These are read by literal
  # atom at their (few, central) emit sites, so they stay a plain list:
  #   * `:mutare`        — in-place / lifted candidates, the node-wrapping selector  (Analyze)
  #   * `:mutare_case`   — `case` tuple-the-scrutinee per-clause candidates           (Analyze.ClausePatterns)
  #   * `:mutare_hosted` — selector-host candidates for a DSL fragment (Ecto-style)   (Analyze, via Mutator host/2)
  @delivery [:mutare, :mutare_case, :mutare_hosted]

  # Pre-pass / resolution bookkeeping stamps, as `accessor_name: :meta_key` pairs. This list is
  # the single source of truth: `all/0`'s strip set is derived from it, and the per-key accessor
  # functions below are generated from it. Each stamping module references its key through the
  # accessor (`@meta_key MetaKeys.alias_key()`), *not* a hand-written `:mutare_*` literal — so a
  # renamed/removed/typo'd key is a **compile error at the stamp site** rather than a silent leak
  # into the rendered metamutant (the drift this module exists to prevent). Owning module in
  # parentheses:
  #   * `:mutare_tag`              — replace-by-tag discovery marker                 (Tag, literal)
  #   * `:mutare_nid`              — stable per-node identity for overlap pruning    (Resolve.NodeIds, read by Overlap)
  #   * `:mutare_alias`            — module a remote call's aliased path resolves to (Aliases)
  #   * `:mutare_import`           — `{module, :bare | :qualify}` for a bare call    (Imports)
  #   * `:mutare_import_witness`   — dead-code import-witness payload                (Imports, spliced by ImportWitness)
  #   * `:mutare_kernel_displaced` — a Kernel fn displaced by `import …, except:`    (Imports)
  #   * `:mutare_macro`            — known-macro per-argument routing                (Resolve.MacroStamp, from Macros)
  #   * `:mutare_macro_piped`      — piped-value routing for a known-macro RHS       (Resolve.MacroStamp, from Macros)
  #   * `:mutare_macro_call`       — resolved `{module_key, name}` macro identity    (Resolve.MacroStamp, read by Calls.resolved_macro_call/1)
  #   * `:mutare_use_directives`   — import/alias/require a `use` injects            (Uses)
  #   * `:mutare_use_behaviours`   — `@behaviour`s a `use` injects (on the `use`)    (Uses)
  #   * `:mutare_behaviours`       — a `defmodule`'s behaviour MapSet               (Behaviours)
  @bookkeeping_keys [
    tag_key: :mutare_tag,
    nid_key: :mutare_nid,
    alias_key: :mutare_alias,
    import_key: :mutare_import,
    import_witness_key: :mutare_import_witness,
    kernel_displaced_key: :mutare_kernel_displaced,
    macro_key: :mutare_macro,
    piped_macro_key: :mutare_macro_piped,
    macro_call_key: :mutare_macro_call,
    use_directives_key: :mutare_use_directives,
    use_behaviours_key: :mutare_use_behaviours,
    behaviours_key: :mutare_behaviours
  ]

  @all @delivery ++ Keyword.values(@bookkeeping_keys)

  # One zero-arity accessor per bookkeeping key, generated from the registry above. A stamp site
  # binds its private constant to one of these at compile time, so the link can't drift.
  for {name, key} <- @bookkeeping_keys do
    @doc false
    @spec unquote(name)() :: atom()
    def unquote(name)(), do: unquote(key)
  end

  @doc "The candidate-delivery meta keys — `Mutare.Transform` strips these during emit."
  @spec delivery() :: [atom()]
  def delivery, do: @delivery

  @doc "Every internal node-metadata key — `Mutare.Transform.Render` strips these before render."
  @spec all() :: [atom()]
  def all, do: @all
end
