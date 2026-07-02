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
  @seen_key :mutare_cov_seen

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
    # Best-effort, never crash: a missing aggregate table means there is nowhere to
    # record, so skip (mirrors the dead-pid label guards below). A real probe run
    # never hits this — the bootstrap creates the tables in the test-helper process,
    # which outlives the whole suite. It only arises when Mutare is mutation-tested
    # *with Mutare*: its own coverage tests create these process-global, named tables
    # and tear them down, while the metamutant of Mutare's lib records into the *same*
    # names. A coverage test that sets the tracking flag and then exits (its
    # process-owned table dying with it) would otherwise leave the gate open over a
    # vanished table, and the next instrumented line — in that test's own `on_exit`,
    # or any later test — would crash on the `:ets.insert`. See NOTES "Self-hosting".
    case :ets.whereis(@agg_table) do
      :undefined ->
        true

      tid ->
        label = label()

        case unrecorded_ids(tid, ids, label) do
          [] -> true
          unrecorded -> record(unrecorded, label)
        end
    end
  end

  # Coverage is set-like per attribution state, not just per id. A long-lived Task keeps its
  # `$callers` chain after the spawning test exits: while the caller is alive the hit is attributed
  # to that test file, but after the caller dies the same process must record the id as unlabeled so
  # selection runs the whole suite. The process-local cache therefore suppresses only repeats under
  # the same attribution key (or anything after an unlabeled hit, which already dominates).
  #
  # The ETS table id is part of the cache so tests (and self-hosting edge cases) that delete/recreate
  # the named tables get a fresh seen set instead of silently suppressing new-table writes.
  defp unrecorded_ids(tid, ids, label) do
    seen =
      case Process.get(@seen_key) do
        {^tid, seen} when is_map(seen) -> seen
        _ -> %{}
      end

    key = attribution_key(label)

    {seen, unrecorded} =
      Enum.reduce(ids, {seen, []}, fn id, {seen, unrecorded} ->
        keys = Map.get(seen, id, %{})

        cond do
          Map.has_key?(keys, :unlabeled) ->
            {seen, unrecorded}

          Map.has_key?(keys, key) ->
            {seen, unrecorded}

          true ->
            {Map.put(seen, id, Map.put(keys, key, true)), [id | unrecorded]}
        end
      end)

    Process.put(@seen_key, {tid, seen})
    Enum.reverse(unrecorded)
  end

  defp attribution_key({mod, _name}) when is_atom(mod), do: {:labeled, mod}
  defp attribution_key(_label), do: :unlabeled

  defp record(ids, label) do
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
    # struct's wire representation. `tab_list/1` tolerates a vanished table (→ `[]`) for the
    # same self-hosting reason `hit/1` does: dogfooding Mutare runs its own coverage tests,
    # which create and tear down these named tables, so an `after_suite` dump can find one
    # already gone. An empty/partial dump just degrades the caller to run-all selection (the
    # `Mutare.Runner.CoverageProbe` empty-aggregate path) — far better than crashing the probe.
    aggregate = for {id} <- tab_list(@agg_table), do: id
    unlabeled = for {id} <- tab_list(@unlabeled_table), do: id

    by_file =
      Enum.reduce(tab_list(@attr_table), %{}, fn {{mod, id}}, acc ->
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

  # `:ets.tab2list/1`, but `[]` for a table that doesn't exist (see `dump/1`).
  defp tab_list(table) do
    if :ets.whereis(table) == :undefined, do: [], else: :ets.tab2list(table)
  end

  # The owning test's `{module, name}` label, used to attribute coverage to a test *file*. Resolved
  # for the process that ran the line (`self()`), and — failing that — for each process in its
  # caller chain, by `label_of/1`. Two signals back it:
  #
  #   1. a `$process_label` (`proc_label/1`) — ExUnit's runner labels the test process directly on
  #      **Elixir 1.19+**, and a `Task` records its `$callers` chain, so a task started from a test
  #      belongs to that test;
  #   2. an ExUnit test / `setup_all` frame on the process's current stack (`stacktrace_label/1`) —
  #      the only signal on **Elixir 1.18**, whose runner does *not* label the test process
  #      (`Process.set_label` was added to it in 1.19): a direct test then has no label and no
  #      caller chain, but its own `:"test …"` function is on the stack; a `setup_all` carries the
  #      `{module, __ex_unit__, 2}` frame on every version; and a `Task`'s awaiting caller still has
  #      its test frame (read cross-process).
  #
  # `on_exit`/a bare spawn matches neither (no label, no caller chain, no ExUnit frame) → `nil`, and
  # the caller routes that id to the unlabeled bucket (whole suite). Only the module is needed for
  # file-granular selection; the name half is incidental.
  #
  # The current process label is intentionally re-read for every hit. A reusable process can update
  # its own `Process.set_label/1` between tests/requests, and stale attribution is worse than the
  # small read cost. The separate seen cache is keyed by attribution, so repeated hits under the
  # same label are still suppressed, while a changed label records a new attribution. Labels
  # recovered through `$callers` are liveness-sensitive too: once the spawning test exits, the same
  # long-lived Task/process must become unlabeled so coverage selection stays conservative.
  defp label do
    case label_of(self()) do
      {mod, _name} = label when is_atom(mod) ->
        label

      _ ->
        recovered_label()
    end
  end

  # `pid`'s owning `{module, name}`: its `$process_label`, else an ExUnit frame on its current stack
  # (so attribution works on Elixir 1.18, which leaves test processes unlabeled — see `label/0`).
  defp label_of(pid) do
    case proc_label(pid) do
      {mod, _name} = labeled when is_atom(mod) -> labeled
      _ -> stacktrace_label(pid)
    end
  end

  defp recovered_label do
    # `$callers` (set by `Task`) then `$ancestors`: walk to the first ancestor we can attribute a
    # `{module, name}` to. The test pid sits at the tail of the chain even for nested tasks, so a
    # labeled (or stack-recoverable) owner is found if one exists.
    callers = Process.get(:"$callers", []) ++ Process.get(:"$ancestors", [])

    Enum.find_value(callers, fn
      pid when is_pid(pid) -> label_of(pid)
      _ -> nil
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

  # An ExUnit frame on `pid`'s current stack, naming the owning module — the recovery `label_of/1`
  # uses when no `$process_label` is set (every line on **Elixir 1.18**; a `setup_all` on every
  # version, which runs unlabeled). This is *only* ever reached on 1.18 and for `setup_all`: from
  # Elixir 1.19 the runner labels every test process — `test`, `doctest`, and `property` alike — so
  # `proc_label/1` (tier 1) resolves them and none of the frame-shape guesswork below runs.
  #
  # A test **body** is recognised two ways, the second a naming-agnostic backstop for the first:
  #
  #   * by its function name (`test_label/2`) — ExUnit names test bodies `:"test …"`, `:"doctest …"`,
  #     `:"property …"`; the embedded space can't occur in an ordinary identifier;
  #   * else by position (`dispatched_test_frame/1`) — the frame directly above ExUnit's per-test
  #     dispatcher `ExUnit.Runner.exec_test/2` *is* the test body, whatever generator named it, so a
  #     test kind the name list doesn't know still attributes to the right module.
  #
  # A `setup_all` (or `setup`) is recognised by its `{module, :__ex_unit__, 2, _}` dispatch frame:
  # it runs synchronously inside the test module's generated `__ex_unit__/2`, so that frame is on
  # the stack and names the module (the `:setup_all` name half is ignored — only the module maps to
  # a file). `:setup` needs no special case: on 1.19+ it runs in the labeled test process (tier 1);
  # on 1.18 its `__ex_unit__/2` frame is recovered here, same as `setup_all`.
  #
  # `Process.info/2` reads the stack cross-process too, so an awaiting `Task` caller is recovered
  # the same way. Absent — a bare spawn, or a `Task` whose caller has already exited (a dead pid
  # yields `nil`) — the id falls to the unlabeled bucket (whole suite).
  #
  # Soundness note: this attributes a `setup_all`-covered id to its *own* module's file. That
  # captures every test that can observe the mutation through the `setup_all` *context*
  # (module-scoped — the common case). It does NOT capture a test in *another* module that fails
  # only because the `setup_all` had a cross-module global side effect (a seeded DB, a
  # `:persistent_term`); such an id, run only against its own file, could survive. This is the same
  # cross-file-dependency limitation `:coverage` mode already has for ordinary per-file attribution
  # (`:full` is the escape hatch) — the only change is that `setup_all` no longer gets the extra
  # whole-suite conservatism the unlabeled bucket used to give it.
  defp stacktrace_label(pid) do
    case Process.info(pid, :current_stacktrace) do
      {:current_stacktrace, stack} -> named_frame(stack) || dispatched_test_frame(stack)
      _ -> nil
    end
  end

  # A `setup_all`/`setup` dispatch, or a named ExUnit test body, taken from the first matching frame.
  defp named_frame(stack) do
    Enum.find_value(stack, fn
      {mod, :__ex_unit__, 2, _} -> {mod, :setup_all}
      {mod, fun, _arity, _} when is_atom(mod) and is_atom(fun) -> test_label(mod, fun)
      _ -> nil
    end)
  end

  # `{mod, fun}` when `fun` is an ExUnit-generated test name, else `nil`. ExUnit's three test
  # generators name their bodies `:"test <name>"`, `:"doctest <module> (<n>)"`, and
  # `:"property <name>"` — the embedded space can't appear in an ordinary identifier, so the prefix
  # never collides with a target's own function on the stack. Need only track 1.18's generators
  # (1.19+ labels the process); `dispatched_test_frame/1` is the backstop for any this list misses.
  defp test_label(mod, fun) do
    case Atom.to_string(fun) do
      "test " <> _ -> {mod, fun}
      "doctest " <> _ -> {mod, fun}
      "property " <> _ -> {mod, fun}
      _ -> nil
    end
  end

  # The frame directly above ExUnit's per-test dispatcher (`ExUnit.Runner.exec_test/2`) — the test
  # body, whatever named it — recovering its module name-agnostically. The dispatcher reference is
  # a bare atom match (no call, no module load), so this stays dependency-free; absent it (a stack
  # without that frame), `nil` falls through to the unlabeled bucket.
  defp dispatched_test_frame(stack) do
    stack
    |> Enum.chunk_every(2, 1, :discard)
    |> Enum.find_value(fn
      [{mod, fun, _arity, _}, {ExUnit.Runner, :exec_test, 2, _}]
      when is_atom(mod) and is_atom(fun) ->
        {mod, fun}

      _ ->
        nil
    end)
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
