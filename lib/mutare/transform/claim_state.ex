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
  #
  # The `sink` selects what each claim *retains* — the one knob that splits a render from the
  # schema's render-free count pass:
  #
  #   * `:render` — build a `Mutare.Site` per claim and accumulate it in `sites`; a poison-skipped
  #     id records a poisoned site but emits no artifact. This is the full transform. The
  #     `{render_code?, summary?}` flags threaded to `site_fn` decide which diff text the site
  #     carries — the `Sourceror` `*_code` (deferred for a `mix mutare` scan) and/or the cheap
  #     `Macro` live `summary` (off under `--quiet`); see `Mutare.Transform.Config`. Either way a
  #     `Site` is built and retained.
  #   * `:count` — advance the id and bump `count` only. No `Site` is built (so the per-mutant
  #     `Sourceror` render in `Mutare.Site` is skipped) and none is retained, but the live
  #     artifact is still emitted, so the metamutant tree stays well-formed and the *set* of
  #     downstream claims is identical to a render. The count is therefore drift-proof by
  #     construction — it comes from the same claim path, just without the site cost (see
  #     `Mutare.Schema`'s two-phase build and NOTES "Scan is transform-bound").
  #
  # `claim/7` is the one place the two sinks diverge; everything upstream is sink-agnostic.

  alias Mutare.Site

  @type sink :: :render | :count

  @type t :: %__MODULE__{
          sink: sink(),
          next_id: pos_integer(),
          group: non_neg_integer(),
          sites: [Site.t()],
          count: non_neg_integer()
        }

  defstruct sink: :render, next_id: 1, group: 0, sites: [], count: 0

  @doc """
  Claim the next id for `item`, returning `{artifacts, claim}`.

  Both sinks advance `next_id` and emit the live artifact (so the emitted tree, and hence the
  set of downstream claims, is identical); they differ only in what they retain:

    * `:count` — bump the tally; build no `Site`, retain none, ignore `skip_ids` (a skipped id
      still advances the counter, so the count is independent of poison recovery).
    * `:render` — build a `Site` via `site_fn` and accumulate it; a `skip_ids` id records a
      poisoned site but emits no artifact.
  """
  @spec claim(
          t(),
          String.t(),
          MapSet.t(),
          item,
          (pos_integer(), item, String.t(), {boolean(), boolean()} -> Site.t()),
          (pos_integer(), item -> artifact),
          {boolean(), boolean()}
        ) :: {[artifact], t()}
        when item: term(), artifact: term()
  def claim(
        %__MODULE__{sink: :count} = claim,
        _file,
        _skip_ids,
        item,
        _site_fn,
        artifact_fn,
        _render_flags
      ) do
    id = claim.next_id
    {[artifact_fn.(id, item)], %{claim | next_id: id + 1, count: claim.count + 1}}
  end

  def claim(
        %__MODULE__{sink: :render} = claim,
        file,
        skip_ids,
        item,
        site_fn,
        artifact_fn,
        render_flags
      ) do
    id = claim.next_id
    site = site_fn.(id, item, file, render_flags)
    claim = %{claim | next_id: id + 1}

    if id in skip_ids do
      {[], %{claim | sites: [poison(site) | claim.sites]}}
    else
      {[artifact_fn.(id, item)], %{claim | sites: [site | claim.sites]}}
    end
  end

  @doc """
  How many mutants have been claimed — `length(sites)` for the `:render` sink, the running
  `count` tally for the `:count` sink. Either equals `next_id - start_id`.
  """
  @spec total(t()) :: non_neg_integer()
  def total(%__MODULE__{sink: :count, count: count}), do: count
  def total(%__MODULE__{sites: sites}), do: length(sites)

  defp poison(%Site{} = site), do: %{site | poisoned: true}
end
