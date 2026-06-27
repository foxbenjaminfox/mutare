defmodule Mutare.Coverage.HelperTemplate do
  @moduledoc false
  # The **source template** for the dependency-free coverage helper `Mutare.Sandbox` writes into
  # each sandbox as `:mutare_cov` (compiled once, with the app). It lives as a real, compiled
  # module — rather than a `quote |> Macro.to_string` string inside `Mutare.Coverage.Recorder` —
  # so a typo or broken reference in `hit/1`/`dump/1` is caught at *Mutare's* compile time instead
  # of only when a sandbox compiles. `Recorder.helper_source/0` reads this file's source (via
  # `@external_resource`) and rewrites the `defmodule` *line* to `:mutare_cov` at write time
  # (anchored on that line, so the name is free to appear in comments/docs/strings here);
  # `Recorder` also sources the contract constants below from here, so they have a single home.
  #
  # **This module must stay DEPENDENCY-FREE** — its source is copied verbatim into the *target*
  # project's `lib/`, which has no Mutare modules on its path. Reference only stdlib/OTP
  # (`:ets`, `:proc_lib`, `Process`, `File`, `Code`, `System`, `Enum`, `Map`, `Keyword`, `Path`),
  # never a `Mutare.*` module.
  #
  # `hit/1` records into the shared ETS tables; `dump/1` (run by `after_suite`) serialises them to
  # the dump file, mapping each test module to its source file. The label read is OTP-version
  # tolerant: `:proc_lib.get_label/1` on OTP 27+, the `:"$process_label"` process-dictionary key
  # on OTP 26 and earlier. `hit/1` returns `true` so the spliced `and` chain stays boolean.

  @agg_table :mutare_cov_agg
  @attr_table :mutare_cov_attr
  @unlabeled_table :mutare_cov_unlabeled
  @dump_file "mutare_cov.terms"
  @dump_path_env "MUTARE_COV_DUMP"
  @root_env "MUTARE_COV_ROOT"

  # The contract constants, exposed so `Mutare.Coverage.Recorder` sources them from here — the
  # single source of truth shared by the table-creation bootstrap and the dump reader. (These
  # accessors are harmless in the written sandbox helper, where only `hit/1` and `dump/1` are
  # ever called.)
  def agg_table, do: @agg_table
  def attr_table, do: @attr_table
  def unlabeled_table, do: @unlabeled_table
  def dump_file, do: @dump_file
  def dump_path_env, do: @dump_path_env
  def root_env, do: @root_env

  def hit(ids) do
    label = label()

    Enum.each(ids, fn id ->
      :ets.insert(@agg_table, {id})

      case label do
        {mod, _name} when is_atom(mod) ->
          :ets.insert(@attr_table, {{mod, id}})

        # No recoverable test label — the line ran in `on_exit`/a bare spawn/a `setup_all` whose
        # work ran off-stack in a `Task` (an ordinary `setup_all` is recovered by tier 3,
        # `stacktrace_label/0`, and takes the attribution branch above). Record it so the caller
        # runs the whole suite for this id rather than trusting partial per-file attribution (a
        # test that also touches the line directly would otherwise mask this run and manufacture a
        # false survivor).
        _ ->
          :ets.insert(@unlabeled_table, {id})
      end
    end)

    true
  end

  def dump(_suite_result) do
    # Serialise plain data (lists, not `MapSet`s) so the reader makes no assumption about a
    # struct's wire representation.
    aggregate = for {id} <- :ets.tab2list(@agg_table), do: id
    unlabeled = for {id} <- :ets.tab2list(@unlabeled_table), do: id

    by_file =
      Enum.reduce(:ets.tab2list(@attr_table), %{}, fn {{mod, id}}, acc ->
        case source_file(mod) do
          nil -> acc
          file -> Map.update(acc, file, [id], &[id | &1])
        end
      end)

    payload = %{aggregate: aggregate, by_file: by_file, unlabeled: unlabeled}

    # Every umbrella app's `after_suite` calls this; the ETS tables are shared and accumulate-only,
    # so each write is the full union and the last app to finish wins. The path is absolute (set by
    # the probe) so a per-app cwd doesn't scatter N partial dumps. Do NOT split this into per-app
    # files — the single union is the point.
    dump_path = System.get_env(@dump_path_env) || @dump_file
    File.write!(dump_path, :erlang.term_to_binary(payload))
  end

  # The owning test's `{module, name}` label, used to attribute coverage to a test *file*.
  # Resolution has three tiers, tried in order:
  #
  #   1. our own `$process_label` — the test process is labeled directly;
  #   2. a labeled ancestor via the `$callers`/`$ancestors` chain — a `Task` records its caller
  #      chain, so a task started from a test belongs to that test;
  #   3. the `setup_all` recovery (`stacktrace_label/0`) — a `setup_all` block runs in an
  #      unlabeled, caller-less process, but *within* the test module's generated `__ex_unit__/2`
  #      dispatch, so the owning module is on our own stack.
  #
  # `on_exit`/a bare spawn matches none (no label, no caller chain, no `__ex_unit__/2` frame) →
  # `nil`, and the caller routes that id to the unlabeled bucket (whole suite). Only the module is
  # recovered in tier 3, which is all file-granular selection needs.
  defp label do
    case proc_label(self()) do
      {mod, _name} = labeled when is_atom(mod) -> labeled
      _ -> recovered_label() || stacktrace_label()
    end
  end

  defp recovered_label do
    # `$callers` (set by `Task`) then `$ancestors`: walk to the first ancestor carrying a
    # `{module, name}` test label. The test pid sits at the tail of the chain even for nested
    # tasks, so a labeled owner is found if one exists.
    callers = Process.get(:"$callers", []) ++ Process.get(:"$ancestors", [])

    Enum.find_value(callers, fn
      pid when is_pid(pid) ->
        case proc_label(pid) do
          {mod, _name} = labeled when is_atom(mod) -> labeled
          _ -> nil
        end

      _ ->
        nil
    end)
  end

  # The `$process_label` of `pid` (our own — `self()` — or an ancestor's), OTP-tolerant and the
  # single home for the version check. On OTP 27+ `:proc_lib.get_label/1` reads it directly
  # (cross-process too); on OTP 26 and earlier the label lives in the process dictionary, which
  # `Process.info(pid, :dictionary)` exposes (`Process.get/1` would only read our own). `apply/3`,
  # not a direct call, so a static reference to the OTP 27-only function doesn't warn "undefined"
  # on OTP 26 and earlier. Best-effort — a dead pid yields `nil`, never a crash (harmless for `self()`).
  defp proc_label(pid) do
    if function_exported?(:proc_lib, :get_label, 1) do
      try do
        apply(:proc_lib, :get_label, [pid])
      catch
        _, _ -> nil
      end
    else
      case Process.info(pid, :dictionary) do
        {:dictionary, dict} -> Keyword.get(dict, :"$process_label")
        _ -> nil
      end
    end
  end

  # Tier 3 of `label/0`: a `setup_all` runs in an unlabeled, caller-less process, but it executes
  # synchronously inside the test module's generated `__ex_unit__(:setup_all, _)` dispatch — so
  # that frame is on *our own* current stack and names the owning module. Module granularity is
  # exactly what file-granular selection wants; the `:setup_all` name half is ignored by the
  # attribution (only the module maps to a file). Absent — e.g. a line reached through a `Task`
  # spawned inside `setup_all`, whose fresh stack has no such frame — we return `nil` and the id
  # falls to the unlabeled bucket (whole suite). `:setup` needs nothing here: it runs in the
  # labeled test process, so tier 1 already catches it.
  #
  # Soundness note: this attributes a `setup_all`-covered id to its *own* module's file. That
  # captures every test that can observe the mutation through the `setup_all` *context*
  # (module-scoped — the common case). It does NOT capture a test in *another* module that fails
  # only because the `setup_all` had a cross-module global side effect (a seeded DB, a
  # `:persistent_term`); such an id, run only against its own file, could survive. This is the same
  # cross-file-dependency limitation `:coverage` mode already has for ordinary per-file attribution
  # (`:full` is the escape hatch) — the only change is that `setup_all` no longer gets the extra
  # whole-suite conservatism the unlabeled bucket used to give it.
  defp stacktrace_label do
    case Process.info(self(), :current_stacktrace) do
      {:current_stacktrace, stack} ->
        Enum.find_value(stack, fn
          {mod, :__ex_unit__, 2, _} -> {mod, :setup_all}
          _ -> nil
        end)

      _ ->
        nil
    end
  end

  defp source_file(mod) do
    with {:module, _} <- Code.ensure_loaded(mod),
         info when is_list(info) <- mod.module_info(:compile),
         source when not is_nil(source) <- Keyword.get(info, :source) do
      # Normalise against the absolute root (the umbrella/sandbox root the probe set), so an
      # umbrella app's cwd doesn't strip the `apps/<app>/` prefix. Unset (single app) ⇒ cwd, i.e.
      # the old `relative_to_cwd`.
      root = System.get_env(@root_env) || File.cwd!()
      source |> to_string() |> Path.relative_to(root)
    else
      _ -> nil
    end
  end
end
