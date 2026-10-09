defmodule Mutare.Transform.MetaKeys do
  @moduledoc false
  # Single source of truth for the internal `:mutare_*` keys the transform stamps onto a
  # node's `meta` keyword list. These are bookkeeping the families and emit read; none may
  # reach the rendered metamutant source. Consumers derive their strip lists from here,
  # so none can silently drift from a stamp site (the bug this module exists to prevent —
  # before it, `Mutare.Transform.Render`'s list and the emit-time strip's list were maintained
  # by hand and `:mutare_hosted` had already gone missing from the former):
  #
  #   * `Mutare.Transform.Render` strips **all** of them (`all/0`) just before rendering —
  #     the belt-and-suspenders final scrub.
  #   * `Mutare.Transform.Meta.Lifecycle.consume_delivery/1` strips the **candidate-delivery** subset
  #     (`delivery/0`) during emit, once a node's candidates are consumed and before the bare
  #     node is rebuilt.
  #   * `Meta.Lifecycle` derives call/module invalidation and analysis release sets from
  #     the lifetime on every entry. A missing or unknown lifetime fails compilation.
  #
  # Only node-`meta` keys belong here. The other `:mutare_*` atoms are **not** metadata and
  # stay owned by their modules: runtime-contract identifiers (`:mutare_active`/`:mutare_track`
  # persistent_term keys in `Mutare.Selector`; the `:mutare_cov*` ETS tables in
  # `Mutare.Coverage.Recorder`), generated variable-name bases (`:mutare_piped`/`:mutare_cond`/
  # `:mutare_super`/`:mutare_capture_arg` in `Mutare.Transform.Names`/`Ctx`), and the
  # `:mutare_unmatched` placeholder var.

  # Candidate-delivery keys, with an explicit delivery lifetime. Each holds a list of
  # `Mutare.Transform.Candidate` structs that an emit path consumes, then strips from the node
  # before building it. No module names these atoms directly any more: `Mutare.Transform.Meta`
  # maps each *logical kind* to its key through the generated `<kind>_key/0` accessor (below), so
  # the candidate API (`candidates/2`, `put_candidates/3`, …) speaks in kinds and the raw atoms
  # stay here. Owning analyze path in parentheses:
  #   * `in_place` → `:mutare`        — in-place / lifted candidates, the node-wrapping selector  (Analyze)
  #   * `case`     → `:mutare_case`   — `case` tuple-the-scrutinee per-clause candidates          (Analyze.ClausePatterns)
  #   * `hosted`   → `:mutare_hosted` — selector-host candidates for a DSL fragment (Ecto-style)  (Analyze, via Mutator host/2)
  # Lifetimes declare invalidation and release policy. All are scrubbed at render.
  # `:analysis` is also invalidated with a call, but is released throughout the tree before
  # rendering; `:module_resolution` belongs to a call's receiver, not the call's own meta.
  @delivery_keys [
    {:in_place_key, :mutare, :delivery},
    {:case_key, :mutare_case, :delivery},
    {:hosted_key, :mutare_hosted, :delivery}
  ]

  # Pre-pass / resolution bookkeeping stamps, as `{accessor_name, meta_key, lifetime}` entries. This list is
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
  #   * `:mutare_route`            — a routed call's per-argument positions, or `:skip` (Resolve.RouteStamp, from the route registry)
  #   * `:mutare_displaced_route`  — on a configured `:skip`: the positions of the declaration it displaced or shadowed, or `:unknown` (Resolve.RouteStamp, read by Resolve.effective_routing/2)
  #   * `:mutare_route_call`       — resolved `{module_key, name, arity}` routed-call identity (Resolve.RouteStamp, read through Meta.routed_call/1)
  #   * `:mutare_resolution`       — the environment a call was resolved in: rerouting a rebuilt call (Resolve.reroute/2); at a routed call, a host's Elixir islands (Resolve.context/2); removed before retention/render
  #   * `:mutare_use_directives`   — import/alias/require a `use` injects            (Uses)
  #   * `:mutare_use_behaviours`   — `@behaviour`s a `use` injects (on the `use`)    (Uses)
  #   * `:mutare_use_degraded`     — `{module, reason}` a `use` failed to expand     (Uses, read by `--check`)
  #   * `:mutare_behaviours`       — a `defmodule`'s behaviour MapSet               (Behaviours)
  #   * `:mutare_impl_module`      — the impl module a `Kernel.defimpl` opens (`P.T`, or the unresolved sentinel); absent on a displaced `defimpl` (Resolve, read by Transform)
  #   * `:mutare_marks`            — mutator-requested position marks (label set)   (Resolve.ArgumentMarks, read by Attach.offer)
  #   * `:mutare_mark_call`        — `{module_key, fun, arity}` of a call some mark declaration matched (Resolve, read by ConfigMatches)
  #   * `:mutare_unit_tail`        — a unit-returning function's leaf return tail    (UnitReturns, read by Attach.offer + Analyze.Returns)
  #   * `:mutare_bindings`         — `{bound on entry, referenced after}` of a binding node (Bindings, read by SelectorDelivery + Eligibility.gate)
  #   * `:mutare_selector`         — marks a selector `case` the emit built           (Render.selector_case, read back by Render)
  #   * `:mutare_operand_of`       — the operator position a node was written in      (Resolve.OperandPositions, read by Site.Parenthesize)
  #   * `:mutare_written_pipe`     — the meta of the `|>` a call was written as, before Resolve made it the direct call (WrittenPipe.direct/2; WrittenPipe.written/1 rebuilds the pipe from it)
  #   * `:mutare_pipe_group`       — operator metadata needed to undo a right-nested pipe rotation (WrittenPipe)
  #   * `:mutare_pipe_continuation` — remaining stages around a synthetic prefix, for complete source patches (WrittenPipe)
  @bookkeeping_keys [
    {:tag_key, :mutare_tag, :render},
    {:selector_key, :mutare_selector, :render},
    {:written_pipe_key, :mutare_written_pipe, :render},
    {:pipe_group_key, :mutare_pipe_group, :render},
    {:pipe_continuation_key, :mutare_pipe_continuation, :render},
    {:operand_of_key, :mutare_operand_of, :render},
    {:nid_key, :mutare_nid, :render},
    {:marks_key, :mutare_marks, :render},
    {:mark_call_key, :mutare_mark_call, :call_resolution},
    {:unit_tail_key, :mutare_unit_tail, :render},
    {:bindings_key, :mutare_bindings, :render},
    {:alias_key, :mutare_alias, :module_resolution},
    {:import_key, :mutare_import, :call_resolution},
    {:import_witness_key, :mutare_import_witness, :call_resolution},
    {:kernel_displaced_key, :mutare_kernel_displaced, :call_resolution},
    {:route_key, :mutare_route, :call_resolution},
    {:displaced_route_key, :mutare_displaced_route, :call_resolution},
    {:route_call_key, :mutare_route_call, :call_resolution},
    {:resolution_key, :mutare_resolution, :analysis},
    {:use_directives_key, :mutare_use_directives, :render},
    {:use_behaviours_key, :mutare_use_behaviours, :render},
    {:use_degraded_key, :mutare_use_degraded, :render},
    {:behaviours_key, :mutare_behaviours, :render},
    {:impl_module_key, :mutare_impl_module, :render}
  ]

  @entries @delivery_keys ++ @bookkeeping_keys

  # Do not filter malformed declarations in a comprehension: every entry must choose a
  # lifetime, and a typo must fail at compile time rather than silently omit its key.
  Enum.each(@entries, fn {name, key, lifetime}
                         when is_atom(name) and is_atom(key) and
                                lifetime in [
                                  :delivery,
                                  :call_resolution,
                                  :module_resolution,
                                  :analysis,
                                  :render
                                ] ->
    :ok
  end)

  @all Enum.map(@entries, fn {_name, key, _lifetime} -> key end)
  @delivery for {_name, key, :delivery} <- @entries, do: key
  @call_resolution for {_name, key, lifetime} <- @entries,
                       lifetime in [:call_resolution, :analysis],
                       do: key
  @module_resolution for {_name, key, :module_resolution} <- @entries, do: key
  @analysis for {_name, key, :analysis} <- @entries, do: key

  # A stamp site binds its accessor at compile time, so a removed key fails there too.
  for {name, key, _lifetime} <- @entries do
    @doc false
    @spec unquote(name)() :: atom()
    def unquote(name)(), do: unquote(key)
  end

  @doc "The candidate-delivery keys consumed during emission."
  @spec delivery() :: [atom()]
  def delivery, do: @delivery

  @doc "The keys invalidated on a call when it must be resolved again."
  @spec call_resolution() :: [atom()]
  def call_resolution, do: @call_resolution

  @doc "The keys invalidated on a module reference, including a remote call's receiver."
  @spec module_resolution() :: [atom()]
  def module_resolution, do: @module_resolution

  @doc "The retained analysis capabilities released throughout the tree before rendering."
  @spec analysis() :: [atom()]
  def analysis, do: @analysis

  @doc "Every internal node-metadata key, scrubbed before rendering."
  @spec all() :: [atom()]
  def all, do: @all
end
