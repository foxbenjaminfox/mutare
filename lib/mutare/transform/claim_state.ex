defmodule Mutare.Transform.ClaimState do
  @moduledoc false

  # The **id/site accumulation** half of a transform pass's threading context — the part that
  # grows as ids are claimed:
  #
  #   * `next_id` — the running mutant id, advanced on **every** claim (even a poison-skipped
  #     one), so ids stay stable across the rebuilds poison recovery relies on.
  #   * `group` — numbers lifted clause groups, for collision-free private function names.
  #   * `sites` — the recorded `Mutare.Site`s (reversed; the caller flips them once), the input
  #     to the report and the lazily-built manifest. Retained only by the `:render` sink.
  #   * `count` — a running mutant tally, the `:count` sink's cheap stand-in for `length(sites)`.
  #   * `skip_matches` — the normalized `:skip_lifting` entries any statement sequence in this
  #     pass matched (`Mutare.Transform.ModulePlan` reports them; `Mutare.Transform` unions them
  #     in). Read by `count_report/2` so `Mutare.Schema` can surface configured entries that
  #     matched nothing anywhere — the ineffective-entry diagnostic. Sink-independent.
  #   * `route_matches` / `mark_matches` — the same diagnostic for configuration: the route keys
  #     (`Mutare.CallRouting.Spec.key/0`) and mark-declaration keys (`{module_key, fun, arity}`) the
  #     resolved calls in this pass hit (`Mutare.Transform.ConfigMatches`), so `Mutare.Schema` can
  #     surface `call_routes:` / `argument_marks:` entries that matched no call anywhere.
  #
  # The `sink` selects what each claim *retains* — the one knob that splits a render from the
  # schema's render-free count pass:
  #
  #   * `:render` — build a `Mutare.Site` per claim and accumulate it in `sites`; a poison-skipped
  #     id records a poisoned site but emits no artifact. This is the full transform. The
  #     `{render_code?, summary?}` flags threaded to `site_fn` decide which diff text the site
  #     carries — the `Sourceror` `*_code` (deferred for a `mix mutare` scan) and/or the cheap
  #     `Macro` live `summary` (off under `--quiet`); see `Mutare.Transform.Config`. Either way a
  #     `Site` is built and retained. Statically unselected ids also emit no artifact;
  #     their diagnostic sites stay unpoisoned and carry no rendered diff text.
  #     The `{site_fn, line_fn}` pair a caller passes covers both needs: `site_fn` builds the
  #     recorded `Site`, `line_fn` answers *where* it would be recorded without building one.
  #   * `:count` — advance the id and bump `count` only. No `Site` is built (so the per-mutant
  #     `Sourceror` render in `Mutare.Site` is skipped) and none is retained, but the live
  #     artifact is still emitted, so the metamutant tree stays well-formed and the *set* of
  #     downstream claims is identical to a render. The count is therefore drift-proof by
  #     construction — it comes from the same claim path, just without the site cost (see
  #     `Mutare.Schema`'s two-phase build and NOTES "Scan is transform-bound"). With a line
  #     filter, `line_fn` alone decides which local ids match, so this sink still builds no
  #     `Site` — and never invokes a producing mutator's `variant/2` for a position it is only
  #     locating.
  #
  # `claim/8` is the one place the two sinks diverge; everything upstream is sink-agnostic.

  alias Mutare.Site

  @type sink :: :render | :count

  @type t :: %__MODULE__{
          sink: sink(),
          next_id: pos_integer(),
          group: non_neg_integer(),
          sites: [Site.t()],
          count: non_neg_integer(),
          emitted: non_neg_integer(),
          selection_lines: MapSet.t(pos_integer()) | nil,
          selected_ids: [pos_integer()],
          skip_matches: MapSet.t(Mutare.Lifting.skip_entry()),
          route_matches: MapSet.t(tuple()),
          mark_matches: MapSet.t(tuple())
        }

  defstruct sink: :render,
            next_id: 1,
            group: 0,
            sites: [],
            count: 0,
            # Artifacts actually delivered into the tree. Zero means the emitted program is the
            # parsed original — nothing to render, and `Mutare.Transform` hands back the source
            # bytes instead. Distinct from `count`, which tallies every *reserved* id.
            emitted: 0,
            selection_lines: nil,
            selected_ids: [],
            skip_matches: MapSet.new(),
            route_matches: MapSet.new(),
            mark_matches: MapSet.new()

  @doc """
  Claim the next id for `item`, returning `{artifacts, claim}`.

  Both sinks advance `next_id` and emit the live artifact (so the emitted tree, and hence the
  set of downstream claims, is identical); they differ only in what they retain:

    * `:count` — bump the tally; build no `Site`, retain none, ignore `skip_ids` (a skipped id
      still advances the counter, so the count is independent of poison recovery).
    * `:render` — build a `Site` via `site_fn` and accumulate it; a `skip_ids` id records a
      poisoned site but emits no artifact. An id outside `emit_ids` also emits no
      artifact, but its site remains unpoisoned for directive diagnostics.
  """
  @spec claim(
          t(),
          String.t(),
          MapSet.t(),
          item,
          {(pos_integer(), item, String.t(), {boolean(), boolean()} -> Site.t()),
           (item -> pos_integer() | nil)},
          (pos_integer(), item -> artifact),
          {boolean(), boolean()},
          MapSet.t(pos_integer()) | nil
        ) :: {[artifact], t()}
        when item: term(), artifact: term()
  def claim(
        %__MODULE__{sink: :count} = claim,
        _file,
        _skip_ids,
        item,
        {_site_fn, line_fn},
        artifact_fn,
        _render_flags,
        _emit_ids
      ) do
    id = claim.next_id
    claim = collect_selected_id(claim, id, item, line_fn)

    {[artifact_fn.(id, item)],
     %{claim | next_id: id + 1, count: claim.count + 1, emitted: claim.emitted + 1}}
  end

  def claim(
        %__MODULE__{sink: :render} = claim,
        file,
        skip_ids,
        item,
        {site_fn, _line_fn},
        artifact_fn,
        render_flags,
        emit_ids
      ) do
    id = claim.next_id
    selected? = is_nil(emit_ids) or MapSet.member?(emit_ids, id)
    site = site_fn.(id, item, file, if(selected?, do: render_flags, else: {false, false}))
    claim = %{claim | next_id: id + 1}

    cond do
      id in skip_ids ->
        {[], %{claim | sites: [poison(site) | claim.sites]}}

      selected? ->
        {[artifact_fn.(id, item)],
         %{claim | sites: [site | claim.sites], emitted: claim.emitted + 1}}

      true ->
        {[], %{claim | sites: [site | claim.sites]}}
    end
  end

  @doc """
  How many mutants have been claimed — `length(sites)` for the `:render` sink, the running
  `count` tally for the `:count` sink. Either equals `next_id - start_id`.
  """
  @spec total(t()) :: non_neg_integer()
  def total(%__MODULE__{sink: :count, count: count}), do: count
  def total(%__MODULE__{sites: sites}), do: length(sites)

  # Line selection reads the location the render pass will record — including a custom
  # mutator's attribution override — through `line_fn` (`Mutare.Transform.Candidate.Delivery`'s
  # `line/1`), never by building a `Site`: the count sink builds none by design, and a `Site`
  # would run the producing mutator's `variant/2` callback for a mere line test. Only local ids
  # are retained. An unrestricted count keeps the tally-only path and reads no location at all.
  defp collect_selected_id(%{selection_lines: nil} = claim, _id, _item, _line_fn), do: claim

  defp collect_selected_id(claim, id, item, line_fn) do
    if MapSet.member?(claim.selection_lines, line_fn.(item)),
      do: %{claim | selected_ids: [id | claim.selected_ids]},
      else: claim
  end

  defp poison(%Site{} = site), do: %{site | poisoned: true}
end
