defmodule Mutare.Runner.Compile.Recovery do
  @moduledoc false
  # Poison recovery's decisions, kept pure. `next_round/3` takes one failed compile's
  # attribution (`Mutare.Poison.attribution/2`), the sites of the schema that failed, and the
  # state earlier rounds left, and either aborts or returns the next round's `Plan`: what it
  # newly drops, why, and the state its rebuild runs under. `Mutare.Runner.Compile` announces
  # the plan (`announcements/2`), rebuilds and recompiles; nothing here touches a sandbox.
  #
  # The rules, in the order `next_round/3` applies them:
  #
  #   1. **Budget.** After `max_rounds/0` rebuilds, abort whatever the attribution says.
  #   2. **Inline-macro attribution takes precedence.** A macro that rejects the selector
  #      spliced into its argument makes the compiler blame the macro *call* line; when that
  #      call sits inside an outer selector (a return-value mutant wrapping a tail-position
  #      `query(a > b)`), line attribution maps the line to the outer selector's fallback and
  #      would drop those valid mutants while leaving the real poison in place. So when the
  #      fallback names any not-yet-dropped id, the round drops those ids (wholesale per
  #      macro) and ignores line attribution entirely — no strike is recorded either.
  #      Block-macro mutants are excluded from it: they recover by rule 3.
  #   3. **Line attribution, with second-strike escalation** (`escalate_block_poison/3`).
  #   4. **No progress, no round.** A round must drop a new id or a newly blamed clean region;
  #      otherwise rebuilding would compile the same program again, so abort.
  #
  # A clean region blamed this round is dropped by whichever of rules 2 and 3 applies: it
  # costs no mutant, and folding it in saves the round it would otherwise take alone.

  alias Mutare.{Poison, Site}

  @typedoc "An unknown block-macro invocation: `{file, site.block_macro}`."
  @type block_key :: {String.t(), {atom(), non_neg_integer()}}

  @typedoc "A macro named by the expansion fallback: `{module_string, fun}`."
  @type macro :: {String.t(), atom()}

  # How many rebuilds have run; the accumulated dropped ids and clean regions (forwarded to
  # each `Schema.rebuild/3` — ids are stable across rebuilds, so these keep naming the same
  # mutations; NOTES "Clean regions are attributable"); the block-macro invocations struck
  # once (the evidence `escalate_block_poison/3` reads); the invocations escalated wholesale;
  # and the macros the expansion fallback dropped. `summary/2` folds it into the public
  # `t:Mutare.Run.recovery/0`.
  @type t :: %__MODULE__{
          rounds: non_neg_integer(),
          skip_ids: MapSet.t(pos_integer()),
          skip_regions: MapSet.t(Poison.clean_region()),
          struck: MapSet.t(block_key()),
          escalated: MapSet.t(block_key()),
          macro_skips: MapSet.t(macro())
        }
  defstruct rounds: 0,
            skip_ids: MapSet.new(),
            skip_regions: MapSet.new(),
            struck: MapSet.new(),
            escalated: MapSet.new(),
            macro_skips: MapSet.new()

  defmodule Plan do
    @moduledoc false
    # One recovery round. `ids` and `regions` are exactly what this round newly drops —
    # disjoint from what earlier rounds dropped, and not both empty — and `recovery` is the
    # state after the round, its `skip_ids`/`skip_regions` the old ones plus these. `cause`
    # says which rule fired: the inline-macro fallback (with each macro's newly dropped ids)
    # or line attribution (with the block invocations it escalated wholesale this round).
    alias Mutare.Runner.Compile.Recovery

    @type cause ::
            {:inline_macro, [{Recovery.macro(), MapSet.t(pos_integer())}, ...]}
            | {:line, escalated :: MapSet.t(Recovery.block_key())}

    @type t :: %__MODULE__{
            cause: cause(),
            ids: MapSet.t(pos_integer()),
            regions: MapSet.t(Mutare.Poison.clean_region()),
            recovery: Recovery.t()
          }
    @enforce_keys [:cause, :ids, :regions, :recovery]
    defstruct @enforce_keys
  end

  @max_rounds 25

  @doc false
  @spec max_rounds() :: pos_integer()
  def max_rounds, do: @max_rounds

  @doc false
  @spec next_round(Poison.attribution(), [Site.t()], t()) ::
          {:retry, Plan.t()} | {:abort, :exhausted | :no_progress}
  def next_round(_attribution, _sites, %__MODULE__{rounds: rounds}) when rounds >= @max_rounds,
    do: {:abort, :exhausted}

  def next_round(%{line: line, macro: macro, clean: clean}, sites, %__MODULE__{} = recovery) do
    regions = MapSet.difference(clean, recovery.skip_regions)

    case inline_macro_poison(macro, sites, recovery.skip_ids) do
      [_ | _] = matched -> {:retry, inline_round(matched, regions, recovery)}
      [] -> line_round(line, regions, sites, recovery)
    end
  end

  defp inline_round(matched, regions, recovery) do
    ids = Enum.reduce(matched, MapSet.new(), fn {_macro, ids}, acc -> MapSet.union(acc, ids) end)
    macros = MapSet.new(matched, fn {macro, _ids} -> macro end)
    recovery = %{recovery | macro_skips: MapSet.union(recovery.macro_skips, macros)}
    plan({:inline_macro, matched}, ids, regions, recovery)
  end

  defp line_round(line, regions, sites, recovery) do
    {poison, struck, escalated} = escalate_block_poison(line, sites, recovery.struck)
    ids = MapSet.difference(poison, recovery.skip_ids)

    if Enum.empty?(ids) and Enum.empty?(regions) do
      {:abort, :no_progress}
    else
      recovery = %{
        recovery
        | struck: struck,
          escalated: MapSet.union(recovery.escalated, escalated)
      }

      {:retry, plan({:line, escalated}, ids, regions, recovery)}
    end
  end

  # The one place a round's drops enter the state, so a plan's `ids`/`regions` and its
  # `recovery` cannot disagree.
  defp plan(cause, ids, regions, recovery) do
    %Plan{
      cause: cause,
      ids: ids,
      regions: regions,
      recovery: %{
        recovery
        | rounds: recovery.rounds + 1,
          skip_ids: MapSet.union(recovery.skip_ids, ids),
          skip_regions: MapSet.union(recovery.skip_regions, regions)
      }
    }
  end

  # The fallback's matches, each narrowed to its not-yet-dropped ids outside any unknown block
  # macro, those left with none removed. Block-macro mutants recover through
  # `escalate_block_poison/3`; letting this fallback drop a block's body wholesale on the
  # first strike would pre-empt its id-specific vs wholesale distinction.
  defp inline_macro_poison(matches, sites, skip_ids) do
    excluded = MapSet.union(block_macro_ids(sites), skip_ids)

    matches
    |> Enum.map(fn {macro, ids} -> {macro, MapSet.difference(ids, excluded)} end)
    |> Enum.reject(fn {_macro, ids} -> Enum.empty?(ids) end)
  end

  defp block_macro_ids(sites) do
    for %Site{block_macro: tag, id: id} <- sites, not is_nil(tag), into: MapSet.new(), do: id
  end

  # Evidence-based escalation for a poison inside an *unknown* module-level block macro
  # (a DSL whose `do` body the transform mutates on the guess it is unquoted into a
  # function). Two distinct failure modes both surface here, and they need opposite
  # responses:
  #
  #   * **Wholesale** — the DSL rejects the injected selector `case` itself (it splices the
  #     body into a guard/pattern/compile-time position). *Every* selector in the block will
  #     fail, so the whole block must be dropped at once — otherwise we'd hit the next
  #     selector round after round and could exhaust the attempt budget.
  #   * **Id-specific** — one mutant's *replacement* is illegal (classically a custom mutator
  #     emitting uncompilable code). Only that mutant must be dropped; its innocent
  #     (compile-safe-by-construction) siblings in the same block should still run.
  #
  # The build can't tell them apart, but they differ in **recurrence under a single drop**:
  # wholesale recurs, id-specific does not. So a block escalates only on its **second**
  # strike: the first poison in a block drops just the implicated id(s) and marks the block
  # struck; a later poison in an already-struck block drops *every* mutant in it, while ids
  # stay stable across rebuilds. NOTES has the costs and the accepted imprecision.
  #
  # Identity is **per-invocation** — `{file, {macro_name, nid}}` — so a poison in one
  # `custom_dsl do … end` only ever escalates that block. Returns the poison widened by the
  # escalated blocks' ids, the updated struck set, and the keys escalated this round.
  defp escalate_block_poison(poison, sites, struck) do
    by_id = Map.new(sites, &{&1.id, &1})

    hit =
      poison
      |> Enum.map(&block_macro_key(by_id[&1]))
      |> Enum.reject(&is_nil/1)
      |> MapSet.new()

    escalate = MapSet.intersection(hit, struck)

    siblings =
      for site <- sites,
          key = block_macro_key(site),
          not is_nil(key),
          MapSet.member?(escalate, key),
          do: site.id

    {MapSet.union(poison, MapSet.new(siblings)), MapSet.union(struck, hit), escalate}
  end

  # The invocation a site belongs to when it lives in an unknown block macro, else `nil` (an
  # untagged site, or an id no site carries). Pairing the tag with `file` disambiguates the
  # per-file nid counter across files.
  defp block_macro_key(%Site{block_macro: tag, file: file}) when not is_nil(tag), do: {file, tag}
  defp block_macro_key(_), do: nil

  # ── Announcements ─────────────────────────────────────────────────────────────────────

  @doc false
  # The `:on_phase` events announcing a round, fired before the rebuild they announce — each
  # round is a full recompile, and without a line per round the recovery hides behind the
  # compile spinner and reads as a hang. An inline-macro round names its macros in a loud
  # `{:macro_poison, …}` (plus a `{:poison_round, …}` for any clean region it drops); a line
  # round is one `{:poison_round, …}` listing the mutants dropped individually (an escalated
  # block's ids are covered by its `:escalated` entry instead), the escalated blocks, and
  # the clean regions.
  @spec announcements(Plan.t(), [Site.t()]) :: [{:macro_poison | :poison_round, map()}]
  def announcements(%Plan{cause: {:inline_macro, matched}, regions: regions}, _sites) do
    macros =
      Enum.map(matched, fn {{module, fun}, ids} ->
        %{module: module, macro: fun, count: MapSet.size(ids)}
      end)

    regions_round =
      if Enum.empty?(regions),
        do: [],
        else: [{:poison_round, %{dropped: [], escalated: [], clean: clean_regions(regions)}}]

    [{:macro_poison, %{macros: macros}} | regions_round]
  end

  def announcements(%Plan{cause: {:line, escalated}, ids: ids, regions: regions}, sites) do
    dropped =
      for site <- sites,
          MapSet.member?(ids, site.id),
          not MapSet.member?(escalated, block_macro_key(site)),
          do: %{id: site.id, file: site.file, line: site.line, mutator: site.mutator}

    [
      {:poison_round,
       %{
         dropped: dropped,
         escalated: escalations(escalated, sites),
         clean: clean_regions(regions)
       }}
    ]
  end

  # ── Summary ───────────────────────────────────────────────────────────────────────────

  @doc false
  # The public recovery summary a completed compile carries (`Mutare.Run`'s `:recovery`): the
  # rebuild-round count, every dropped mutant id, the clean regions, the block macros escalated
  # wholesale and the macros the fallback dropped — the material the Mix task turns into a
  # `:call_routes` suggestion (`Mutare.Poison.Hint`). `nil` for a clean first compile, so a
  # healthy run carries no vestigial zero-summary.
  @spec summary(t(), [Site.t()]) :: Mutare.Run.recovery() | nil
  def summary(%__MODULE__{rounds: 0}, _sites), do: nil

  def summary(%__MODULE__{} = recovery, sites) do
    %{
      rounds: recovery.rounds,
      dropped: recovery.skip_ids,
      clean_regions: clean_regions(recovery.skip_regions),
      escalated: escalations(recovery.escalated, sites),
      macro_skipped: macro_skips(recovery.macro_skips)
    }
  end

  # Clean regions as display entries (`t:Mutare.Run.clean_region/0`), in a stable order.
  defp clean_regions(regions) do
    regions
    |> Enum.sort()
    |> Enum.map(fn {file, {first, last}} -> %{file: file, first: first, last: last} end)
  end

  # Escalated block keys → display entries: one `%{macro, file, line, count}` per
  # escalated invocation, in source order. The tag records no source line of its own, so
  # `line` is the block's first mutant's line (`nil` when none carries one).
  defp escalations(keys, sites) do
    sites
    |> Enum.filter(&MapSet.member?(keys, block_macro_key(&1)))
    |> Enum.group_by(&block_macro_key/1)
    |> Enum.map(fn {{file, {name, _nid}}, block_sites} ->
      lines = block_sites |> Enum.map(& &1.line) |> Enum.reject(&is_nil/1)
      %{macro: name, file: file, line: Enum.min(lines, fn -> nil end), count: length(block_sites)}
    end)
    |> Enum.sort_by(&{&1.file, &1.line})
  end

  # One `%{module, macro}` per macro the fallback dropped, in a stable order; `module` is the
  # frame's module string, rendered into the `{Module, :fun, :raw}` suggestion by
  # `Mutare.Poison.Hint.macro_skip_note/1`.
  defp macro_skips(macro_skips) do
    macro_skips
    |> Enum.map(fn {module, fun} -> %{module: module, macro: fun} end)
    |> Enum.sort_by(&{&1.module, to_string(&1.macro)})
  end
end
