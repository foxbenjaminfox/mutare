defmodule Mutare.Runner.Compile do
  @moduledoc false
  # The one metamutant compile plus its poison-recovery loop, extracted from `Mutare.Runner`.
  # `run/2` materialises and claims the sandbox, compiles it once, and — on a poisoned compile —
  # drops the implicated mutants, rebuilds into the *same* sandbox, and recompiles (bounded),
  # distinguishing dependency/timeout failures (never recovered) from compile-poisoning. It hands
  # `Mutare.Runner` back `{:ok, schema, sandbox, recovery}` (the possibly-rebuilt schema and the
  # bookkeeping struct) or `{:error, reason, detail, sandbox}` — the sandbox always returned so the
  # caller owns cleanup uniformly. `Recovery` decides each recovery round (and folds the struct
  # into the public `t:Mutare.Run.recovery/0`); this module carries the rounds out. See
  # `Mutare.Poison` for the attribution.
  #
  # The loop threads two fixed values — the `Mutare.Run.Context` (the project root, the options,
  # the `on_phase` hook all read from it) and the `sandbox` — plus the per-round `schema` and
  # `Recovery`.

  alias Mutare.{Poison, Schema, Sandbox, Selector}
  alias Mutare.Run.Context
  alias Mutare.Runner.Compile.Recovery
  alias Mutare.Runner.Partitions
  alias Mutare.Sandbox.CompilerOptions
  alias Mutare.Sandbox.Command.{Exit, Invocation, Output}

  # Materialise (and **claim**) the sandbox once, then hand off to the poison-recovery
  # loop. The sandbox path is fixed here for the whole run — a poison retry re-renders the
  # rebuilt schema into this *same* dir — so there are no orphaned dirs and ownership is
  # claimed exactly once. The project root is the context's `copy_root` (the caller resolved the
  # project). Returns `{:ok, schema, sandbox, recovery}` or `{:error, reason, detail, sandbox}`;
  # either way the sandbox is handed back so `with_compiled_sandbox/3` owns cleanup uniformly
  # (this function never cleans up itself).
  @spec run(Schema.t(), Context.t()) ::
          {:ok, Schema.t(), Path.t(), Recovery.t()} | {:error, atom(), String.t(), Path.t()}
  def run(schema, %Context{} = context) do
    {sandbox, materialized} = Sandbox.prepare(root(context), schema, context)
    narrate_materialization(Context.hook(context, :on_phase), materialized)
    compile_with_recovery(context, sandbox, schema, %Recovery{})
  end

  defp root(%Context{project: project}), do: project.copy_root

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
  # the same sandbox, and retry — bounded by `Recovery.max_rounds/0` rounds. `context` and `sandbox`
  # are fixed for the whole loop; the rest is per-round state — the `schema` rebuilt each round
  # and the accumulating `Recovery`.
  defp compile_with_recovery(%Context{} = context, sandbox, schema, %Recovery{} = recovery) do
    options = context.options

    # The compile evaluates the target's config under `MIX_ENV=test`, so a
    # partitioned config that reads the var without a default (e.g.
    # `System.fetch_env!("MIX_TEST_PARTITION")`) must see it *here* too — before
    # the baseline/probe that also set it — or the compile fails. Sequential like
    # those, so the fixed partition (`1`) suffices.
    case compile(
           sandbox,
           root(context),
           Partitions.entry(options.partition_env, 1),
           options.compile_timeout
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
          recover(context, sandbox, schema, recovery, output)
        end
    end
  end

  # One failed compile's recovery: `Recovery.next_round/3` decides, and this carries the
  # decision out — announce the round before paying for it, rebuild without everything
  # dropped so far, rematerialise into the same sandbox, and compile again.
  defp recover(context, sandbox, schema, recovery, output) do
    case Recovery.next_round(Poison.attribution(output, schema), schema.sites, recovery) do
      {:abort, _why} ->
        {:error, :compile_failed, output, sandbox}

      {:retry, %Recovery.Plan{recovery: recovery} = plan} ->
        on_phase = Context.hook(context, :on_phase)
        Enum.each(Recovery.announcements(plan, schema.sites), on_phase)

        # Rebuild from the schema's source snapshot, so edits to the checkout cannot change
        # the mutations the accumulated ids name.
        rebuilt = Schema.rebuild(schema, recovery.skip_ids, recovery.skip_regions)
        Sandbox.rematerialize(sandbox, rebuilt)
        compile_with_recovery(context, sandbox, rebuilt, recovery)
    end
  end

  # The one compilation. `Exit` owns the exit-code readings; `CompilerOptions`
  # carries the diagnostics-only speed switches (the SSA alias pass off via the
  # `:compile` run option, the verify pass off via `compile_args/0` — free compile
  # wins, applied only here since per-mutant runs never recompile the lib).
  # `partition` is the fixed partition entry (or `[]`), so a config read at
  # compile time finds a valid partition — see `compile_with_recovery/4`; `project_root`
  # reaches that config for the same reason (`Invocation.project_root_env/0`).
  #
  # `:compile_timeout` arms the config-hosted wall-clock watcher
  # (`Invocation.compile_watcher_ast/0`) via the `:compile_cap` run option: the
  # compile halts *itself* with the timeout exit past the cap, which we read here as
  # `:compile_timed_out` — never fed to poison recovery (there is no error to
  # attribute, and a rebuild cannot make an oversized compile faster).
  defp compile(sandbox, project_root, partition, compile_timeout) do
    {output, status} =
      Invocation.mix(sandbox, ["compile" | CompilerOptions.compile_args()], Selector.baseline(),
        compile: true,
        compile_cap: compile_timeout,
        project_root: project_root,
        partition: partition
      )

    cond do
      Exit.success?(status) -> :ok
      Exit.timed_out?(status) -> {:error, :compile_timed_out, output}
      true -> {:error, :compile_failed, output}
    end
  end
end
