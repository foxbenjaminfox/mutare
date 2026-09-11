defmodule Mutare.Runner.Compile do
  @moduledoc false
  # The one metamutant compile plus its poison-recovery loop, extracted from `Mutare.Runner`.
  # `run/3` materialises and claims the sandbox, compiles it once, and — on a poisoned compile —
  # drops the implicated mutants, rebuilds into the *same* sandbox, and recompiles (bounded),
  # distinguishing dependency/timeout failures (never recovered) from compile-poisoning. It hands
  # `Mutare.Runner` back `{:ok, schema, sandbox, recovery}` (the possibly-rebuilt schema and the
  # bookkeeping struct) or `{:error, reason, detail, sandbox}` — the sandbox always returned so the
  # caller owns cleanup uniformly. `summary/2` folds that struct into the public
  # `t:Mutare.Run.recovery/0` a completed compile carries. See `Mutare.Poison` for the attribution.

  alias Mutare.{Poison, Schema, Sandbox, Selector, Site}
  alias Mutare.Run.Context
  alias Mutare.Runner.Partitions
  alias Mutare.Sandbox.CompilerOptions
  alias Mutare.Sandbox.Command.{Exit, Invocation, Output}

  # The poison-recovery bookkeeping threaded through `compile_with_recovery/4`: how many
  # rebuild rounds have run, the accumulated dropped ids (`skip_ids`, forwarded to each
  # `Schema.rebuild`), the block-macro invocations struck once (the evidence
  # `escalate_block_poison/3` reads), the ones escalated wholesale, and the
  # `{module, fun}` macros the macro-expansion fallback skipped (an inline DSL macro the
  # compiler blamed by name — see `recover_compile_poison/5`). On success it is folded into
  # the public summary (`recovery_summary/2`) that rides on `Mutare.Run`'s `:recovery` — the
  # material the Mix task turns into a `:call_routes` suggestion.
  defmodule Recovery do
    @moduledoc false
    defstruct rounds: 0,
              skip_ids: MapSet.new(),
              struck: MapSet.new(),
              escalated: MapSet.new(),
              macro_skips: MapSet.new()
  end

  # Materialise the schema and compile it once, recovering from compile-poisoning.
  @poison_attempts 25

  # Materialise (and **claim**) the sandbox once, then hand off to the poison-recovery
  # loop. The sandbox path is fixed here for the whole run — a poison retry re-renders the
  # rebuilt schema into this *same* dir — so there are no orphaned dirs and ownership is
  # claimed exactly once. Returns `{:ok, schema, sandbox, recovery}` or `{:error, reason,
  # detail, sandbox}`; either way the sandbox is handed back so `with_compiled_sandbox/3`
  # owns cleanup uniformly (this function never cleans up itself).
  def run(schema, root, %Context{} = context) do
    on_phase = Context.hook(context, :on_phase)
    {sandbox, materialized} = Sandbox.prepare(root, schema, context)
    narrate_materialization(on_phase, materialized)

    deps = %{root: root, options: context.options, sandbox: sandbox, on_phase: on_phase}
    compile_with_recovery(deps, schema, %Recovery{}, @poison_attempts)
  end

  # Relay what materialising found out (`t:Mutare.Sandbox.materialized/0`) as `:on_phase` detail
  # events for `--verbose` (`Mutare.Report.Live`), during the `:compiling` phase where the facts
  # arise: each `mix.exs` whose inference override did not land (its project compiles with
  # inference on, which can stretch the one compile from seconds to hours — a long compile
  # should not go unexplained), then the app-build seed's outcome (the reused/recompiled
  # counts, or an otherwise-silent fall back to a cold compile). `Mutare.Sandbox` reports;
  # only the runner narrates.
  defp narrate_materialization(on_phase, %{declined: declined, seed: seed}) do
    for {file, reason} <- declined,
        do: on_phase.({:inference_override_declined, %{file: file, reason: reason}})

    on_phase.({:seed_app_build, seed})
    :ok
  end

  # Compile the materialised sandbox. A dependency-check failure stops immediately;
  # on a poisoned compile, drop the implicated mutants, rebuild + rematerialise into
  # the same sandbox, and retry — bounded by `attempts`. `deps`
  # (`root`/`options`/`sandbox`/`on_phase`) is fixed for the whole loop; the rest is per-round
  # state — the `schema` rebuilt each round, the accumulating `Recovery`, and the remaining
  # `attempts`.
  defp compile_with_recovery(%{sandbox: sandbox} = deps, schema, %Recovery{} = recovery, attempts) do
    # The compile evaluates the target's config under `MIX_ENV=test`, so a
    # partitioned config that reads the var without a default (e.g.
    # `System.fetch_env!("MIX_TEST_PARTITION")`) must see it *here* too — before
    # the baseline/probe that also set it — or the compile fails. Sequential like
    # those, so the fixed partition (`1`) suffices.
    case compile(
           sandbox,
           Partitions.entry(deps.options.partition_env, 1),
           deps.options.compile_timeout
         ) do
      :ok ->
        {:ok, schema, sandbox, recovery}

      {:error, :compile_timed_out, output} ->
        # The compile self-halted past its wall-clock cap. Infrastructure, like a
        # dependency failure: there is no compiler error to attribute to a mutant,
        # and a poison-recovery rebuild cannot make an oversized compile faster.
        {:error, :compile_timed_out, output, sandbox}

      {:error, :compile_failed, output} ->
        dependency_issue = Output.dependency_issue(output)

        if dependency_issue do
          # Dependency validation happens before the compiler can reach a
          # metamutant. It is infrastructure, never compile-poisoning: retrying
          # with dropped mutant ids cannot change the copied dependency state.
          {:error, :dependency_failed, output, sandbox}
        else
          recover_compile_poison(deps, schema, recovery, attempts, output)
        end
    end
  end

  defp recover_compile_poison(deps, schema, %Recovery{} = recovery, attempts, output) do
    sandbox = deps.sandbox

    # Both attributions of this round's failure from one `Poison` pass (one manifest per
    # implicated file): the line-attributed ids, and the macro-expansion fallback's matches.
    %{line: raw, macro: macro_matches} =
      Poison.attribution(output, schema.metamutants, Mutare.RuntimeId.file_index(schema.sites))

    # The line-implicated ids, then evidence-based escalation for an unknown module-level
    # block macro: a block is dropped *wholesale* only once a *second, distinct* poison
    # lands in it after a targeted single-id drop — the only signal that distinguishes a
    # DSL rejecting the injected selector wholesale (recurs under a single drop) from one
    # mutant's broken replacement (does not). See `escalate_block_poison/3`.
    {poison, struck, escalated} = escalate_block_poison(raw, schema.sites, recovery.struck)

    # Inline-macro attribution takes **priority** over line attribution. A macro that rejects the
    # selector spliced into its argument makes the compiler blame the macro *call* line; when that
    # call sits inside an *outer* selector — a return-value mutant wrapping a tail-position
    # `query(a > b)` — line attribution maps the line to that outer selector's whole-`case`
    # fallback and would wrongly drop those valid mutants as `:poisoned` (they'd never run) while
    # leaving the real argument poison in place. The macro-identity match names the true culprit
    # (the argument mutants inside the raising macro), so we drop those first. Block-macro mutants
    # are excluded here — they recover through `escalate_block_poison/3`'s second-strike path.
    inline = inline_macro_poison(macro_matches, schema.sites, recovery.skip_ids)

    cond do
      attempts <= 0 ->
        {:error, :compile_failed, output, sandbox}

      inline != [] ->
        do_macro_recovery(deps, schema, recovery, attempts, inline)

      not MapSet.subset?(poison, recovery.skip_ids) ->
        do_line_recovery(deps, schema, recovery, attempts, poison, struck, escalated)

      true ->
        {:error, :compile_failed, output, sandbox}
    end
  end

  # The classic line-attributed drop (built-in mutators, block escalation). Narrate the
  # round before paying for its rebuild + recompile — each round is a full recompile, and
  # without a line per round the whole recovery hides behind the "compiling metamutant
  # (once)…" spinner and reads as a hang.
  defp do_line_recovery(deps, schema, recovery, attempts, poison, struck, escalated) do
    deps.on_phase.({:poison_round, poison_round_info(recovery, poison, escalated, schema)})

    # Drop the poisoning mutants and rebuild. Ids are stable across rebuilds (the transform
    # advances its counter for skipped ids), so accumulated `skip_ids` keep referring to the
    # same mutations. Rebuild against the *same* files this schema covers (not a fresh
    # discovery), so a restricted schema (`from_files/4`, `:only_files`, `:exclude`) can't
    # silently expand. Forward the original options so `:mutators` survive.
    recovery = %{
      recovery
      | rounds: recovery.rounds + 1,
        skip_ids: MapSet.union(recovery.skip_ids, poison),
        struck: struck,
        escalated: MapSet.union(recovery.escalated, escalated)
    }

    schema = Schema.rebuild(schema, deps.root, deps.options, recovery.skip_ids)
    Sandbox.rematerialize(deps.sandbox, schema)
    compile_with_recovery(deps, schema, recovery, attempts - 1)
  end

  # The macro-expansion fallback's matches carrying *new* (not-yet-skipped) ids, with block-macro
  # mutants removed — those recover through `escalate_block_poison/3`, and letting the inline
  # fallback drop a block's body wholesale on the first strike would pre-empt its id-specific vs
  # wholesale distinction. `[]` when nothing inline maps (or all its ids are already skipped),
  # so line attribution / abort take over. `matches` is `Poison.attribution/3`'s `:macro` half.
  defp inline_macro_poison(matches, sites, skip_ids) do
    block_ids = block_macro_ids(sites)

    matches
    |> Enum.map(fn {macro, ids} -> {macro, MapSet.difference(ids, block_ids)} end)
    |> Enum.reject(fn {_macro, ids} -> Enum.empty?(ids) or MapSet.subset?(ids, skip_ids) end)
  end

  # The mutant ids that belong to an unknown module-level block macro (`site.block_macro` set).
  defp block_macro_ids(sites) do
    for %Site{block_macro: tag, id: id} <- sites, not is_nil(tag), into: MapSet.new(), do: id
  end

  # Drop the macros' argument mutants wholesale (`matched` is `inline_macro_poison/3`'s already-
  # filtered result), record the skip for the durable `{Module, :fun, :raw}` suggestion, fire a
  # loud `{:macro_poison, info}` warning naming the macro, and rebuild + recurse.
  defp do_macro_recovery(deps, schema, recovery, attempts, matched) do
    macro_ids =
      Enum.reduce(matched, MapSet.new(), fn {_m, ids}, acc -> MapSet.union(acc, ids) end)

    deps.on_phase.({:macro_poison, macro_poison_info(matched)})

    recovery = %{
      recovery
      | rounds: recovery.rounds + 1,
        skip_ids: MapSet.union(recovery.skip_ids, macro_ids),
        macro_skips:
          MapSet.union(recovery.macro_skips, MapSet.new(matched, fn {macro, _ids} -> macro end))
    }

    schema = Schema.rebuild(schema, deps.root, deps.options, recovery.skip_ids)
    Sandbox.rematerialize(deps.sandbox, schema)
    compile_with_recovery(deps, schema, recovery, attempts - 1)
  end

  # The `{:macro_poison, info}` narration payload: one `%{module, macro, count}` entry per
  # macro the fallback skipped this round, naming it for the loud warning line.
  defp macro_poison_info(matched) do
    entries =
      Enum.map(matched, fn {{module, fun}, ids} ->
        %{module: module, macro: fun, count: MapSet.size(ids)}
      end)

    %{macros: entries}
  end

  # The `{:poison_round, info}` narration payload for one recovery round, fired just
  # before the rebuild it announces: the mutants newly dropped *individually* this round
  # (as `%{id, file, line, mutator}` descriptors, in source order — excluding the ids a
  # block escalation swept up, which its `:escalated` entry already covers in aggregate)
  # and the block(s) escalated wholesale this round (`t:Mutare.Run.escalation/0`).
  defp poison_round_info(%Recovery{} = recovery, poison, escalated, schema) do
    new_ids = MapSet.difference(poison, recovery.skip_ids)

    dropped =
      for site <- schema.sites,
          MapSet.member?(new_ids, site.id),
          not MapSet.member?(escalated, block_macro_key(site)),
          do: %{id: site.id, file: site.file, line: site.line, mutator: site.mutator}

    %{dropped: dropped, escalated: escalations(escalated, schema.sites)}
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

  # The public recovery summary a completed compile carries (`Mutare.Run`'s `:recovery`,
  # and `check_with_schema/3`'s result): the rebuild-round count, every dropped mutant
  # id, and the block macros escalated wholesale — the material the Mix task turns into
  # a `:call_routes` suggestion (`Mutare.Poison.Hint.escalation_note/1`). `nil` for a
  # clean first compile, so a healthy run carries no vestigial zero-summary.
  def summary(%Recovery{rounds: 0}, _schema), do: nil

  def summary(%Recovery{} = recovery, schema) do
    %{
      rounds: recovery.rounds,
      dropped: recovery.skip_ids,
      escalated: escalations(recovery.escalated, schema.sites),
      macro_skipped: macro_skips(recovery.macro_skips)
    }
  end

  # The macro-expansion fallback's skips as public summary entries: one
  # `%{module, macro}` per `{module_string, fun}` the fallback dropped, in a stable order.
  # `module` is the frame's module string (`"Ecto.Query"`), rendered into the durable
  # `{Module, :fun, :raw}` suggestion by `Mutare.Poison.Hint.macro_skip_note/1`.
  defp macro_skips(macro_skips) do
    macro_skips
    |> Enum.map(fn {module, fun} -> %{module: module, macro: fun} end)
    |> Enum.sort_by(&{&1.module, to_string(&1.macro)})
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
  # The build can't tell them apart — whether an unknown DSL rejects a given selector is
  # information that only exists at compile time. But the two modes differ in **recurrence
  # under a single drop**: wholesale recurs (drop one selector, the next fails), id-specific
  # does not (drop the bad mutant, the rest compile). So we escalate a block only on its
  # **second** strike: the first poison in a block drops just the implicated id(s) and *marks
  # the block struck* (`struck`); a later poison in an already-struck block drops *every*
  # mutant in it — the runtime-stable equivalent of routing the macro `:raw` (the body
  # renders raw, its mutants recorded `:poisoned`), while ids stay stable across rebuilds
  # (unlike a true `:raw` route, which would stop analyzing the body and shift later ids).
  #
  # Cost of the precision: a genuinely-wholesale block pays **one extra rebuild** (drop one,
  # see it recur, escalate). Limit: two *independent* id-specific failures in one block also
  # escalate it on the second — indistinguishable from wholesale recurrence without trying
  # each id individually, which is exactly the budget blow-up escalation exists to prevent.
  #
  # Identity is **per-invocation** — `{file, {macro_name, nid}}`, tagged on each `Site` by the
  # transform — so a poison in one `custom_dsl do … end` only ever escalates that block, never
  # a sibling invocation of the same macro that expands differently. A poison touching no block
  # macro returns `{poison, struck, escalate}` with `poison`/`struck` unchanged and `escalate`
  # empty (the common path). `escalate` (the keys widened *this round*) drives the
  # `{:poison_round, …}` narration and the run's `:recovery` summary.
  defp escalate_block_poison(poison, sites, struck) do
    by_id = Map.new(sites, &{&1.id, &1})

    hit =
      poison
      |> Enum.map(&block_macro_key(by_id[&1]))
      |> Enum.reject(&is_nil/1)
      |> MapSet.new()

    # Escalate only blocks hit this round that were *already* struck on a prior round;
    # newly-hit blocks are merely recorded (struck for next time) and dropped per-id.
    escalate = MapSet.intersection(hit, struck)

    siblings =
      for site <- sites,
          key = block_macro_key(site),
          not is_nil(key),
          MapSet.member?(escalate, key),
          do: site.id

    {MapSet.union(poison, MapSet.new(siblings)), MapSet.union(struck, hit), escalate}
  end

  # The `{file, {macro_name, nid}}` invocation a site belongs to when it lives in an
  # unknown block macro, else `nil` (an untagged site, or a missing id). The `nid` in
  # the tag scopes it to the one invocation; pairing with `file` disambiguates the
  # per-file nid counter across files.
  defp block_macro_key(%Site{block_macro: tag, file: file}) when not is_nil(tag),
    do: {file, tag}

  defp block_macro_key(_), do: nil

  # The one compilation. `Exit` owns the exit-code readings; `CompilerOptions`
  # carries the diagnostics-only speed switches (the SSA alias pass off via the
  # `:compile` run option, the verify pass off via `compile_args/0` — free compile
  # wins, applied only here since per-mutant runs never recompile the lib).
  # `partition` is the fixed partition entry (or `[]`), so a config read at
  # compile time finds a valid partition — see `compile_with_recovery/5`.
  #
  # `:compile_timeout` arms the config-hosted wall-clock watcher
  # (`Invocation.compile_watcher_ast/0`) via the `:compile_cap` run option: the
  # compile halts *itself* with the timeout exit past the cap, which we read here as
  # `:compile_timed_out` — never fed to poison recovery (there is no error to
  # attribute, and a rebuild cannot make an oversized compile faster).
  defp compile(sandbox, partition, compile_timeout) do
    {output, status} =
      Invocation.mix(sandbox, ["compile" | CompilerOptions.compile_args()], Selector.baseline(),
        compile: true,
        compile_cap: compile_timeout,
        partition: partition
      )

    cond do
      Exit.success?(status) -> :ok
      Exit.timed_out?(status) -> {:error, :compile_timed_out, output}
      true -> {:error, :compile_failed, output}
    end
  end
end
