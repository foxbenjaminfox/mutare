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
  #
  # Attribution is recorded at TWO granularities from the one `{module, name}` label. The module
  # half always maps to a test *file* (`@attr_table`) — the granularity file-level selection
  # (`:coverage`) needs. The name half is *also* kept (`@test_table`) whenever it is a **runnable
  # ExUnit test name** (`filterable_name?/1`: a `test `/`doctest `/`property ` prefix), so
  # per-test-case selection (`:tests`) can run `mix test <file> --only test:<name>`. A labeled hit
  # whose name is NOT a runnable test — `setup_all` (`:setup_all`), an `on_exit` closure
  # (`-test …`) — is recorded to `@wholefile_table` instead: it covers the id but pins to no single
  # test, so `:tests` must run its whole file (never narrowing away the covering context).

  @agg_table :mutare_cov_agg
  @attr_table :mutare_cov_attr
  @unlabeled_table :mutare_cov_unlabeled
  # Per-test-case attribution: `{{mod, name, id}}` for hits whose label is a runnable ExUnit test
  # name — the finer key `:tests` narrows with. `@wholefile_table` holds ids with a labeled but
  # NON-narrowable attribution (`setup_all`/`on_exit`), which `:tests` must not narrow.
  @test_table :mutare_cov_test
  @wholefile_table :mutare_cov_wholefile
  @dump_file "mutare_cov.terms"
  @dump_path_env "MUTARE_COV_DUMP"
  @root_env "MUTARE_COV_ROOT"
  @seen_key :mutare_cov_seen
  @label_key :mutare_cov_label

  # The contract constants, exposed so `Mutare.Coverage.Recorder` sources them from here — the
  # single source of truth shared by the table-creation bootstrap and the dump reader. (These
  # accessors are harmless in the written sandbox helper, where only `hit/1` and `dump/1` are
  # ever called.)
  def agg_table, do: @agg_table
  def attr_table, do: @attr_table
  def unlabeled_table, do: @unlabeled_table
  def test_table, do: @test_table
  def wholefile_table, do: @wholefile_table
  def dump_file, do: @dump_file
  def dump_path_env, do: @dump_path_env
  def root_env, do: @root_env

  # Namespace before the seen-cache as well as ETS: local id 1 in two files is
  # two independent hits, even when both execute in the same test process.
  def hit(namespace, ids), do: hit(Enum.map(ids, &{namespace, &1}))

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

  # A concrete (runnable-test) label dedups per `{mod, name}`, so one id recorded under test A does
  # not suppress the same id under sibling test B in the same module — both names must reach
  # `@test_table` for `:tests` to narrow to either. A non-narrowable labeled hit (`setup_all`/
  # `on_exit`) dedups per module (`{:labeled, mod}`) — its name is not a key `:tests` uses.
  defp attribution_key({mod, name}) when is_atom(mod) do
    if filterable_name?(name), do: {:test, mod, name}, else: {:labeled, mod}
  end

  defp attribution_key(_label), do: :unlabeled

  defp record(ids, label) do
    Enum.each(ids, fn id ->
      :ets.insert(@agg_table, {id})

      case label do
        {mod, name} when is_atom(mod) ->
          # Module → file, always: the granularity `:coverage` (and the `:tests` fallback) needs.
          :ets.insert(@attr_table, {{mod, id}})

          if filterable_name?(name) do
            # A runnable ExUnit test name — the finer key `:tests` narrows with
            # (`mix test <file> --only test:<name>`).
            :ets.insert(@test_table, {{mod, name, id}})
          else
            # Labeled, but NOT a single runnable test: `setup_all` (`:setup_all`) or an `on_exit`
            # closure (`-test …`). It covers the id through a module-scoped context, so `:tests`
            # must run the whole file — narrowing to named tests would drop the covering context
            # and manufacture a false survivor.
            :ets.insert(@wholefile_table, {id})
          end

        # No recoverable test label — the line ran in a bare spawn, a `setup`-registered
        # `on_exit` closure, or a `setup_all` whose work ran off-stack in a `Task` (an ordinary
        # `setup_all`, and an `on_exit` registered in a test body, are recovered by tier 3,
        # `stacktrace_label/1`, and take the attribution branch above). Record it so the caller
        # runs the whole suite for this id rather than trusting partial per-file attribution (a
        # test that also touches the line directly would otherwise mask this run and manufacture a
        # false survivor).
        _ ->
          :ets.insert(@unlabeled_table, {id})
      end
    end)

    true
  end

  # Is `name` a **runnable** ExUnit test name — one `mix test --only test:<name>` can select? The
  # three ExUnit generators name their bodies `:"test …"`, `:"doctest …"`, `:"property …"` (the
  # embedded space cannot occur in an ordinary identifier, so it never collides with a target's own
  # function). This is the exact rule `test_label/2`/`closure_test_label/1` key on — so a
  # `setup_all` (`:setup_all`, no space) and an `on_exit` closure (`-test …`, leading `-`) both
  # fail it and stay whole-file. Anything unexpected also fails → whole-file, the conservative side.
  defp filterable_name?(name) when is_atom(name) do
    case Atom.to_string(name) do
      "test " <> _ -> true
      "doctest " <> _ -> true
      "property " <> _ -> true
      _ -> false
    end
  end

  defp filterable_name?(_), do: false

  def dump(_suite_result) do
    # Every umbrella app's `after_suite` calls this; the ETS tables are shared and accumulate-only,
    # so each write is the full union and the last app to finish wins. The path is absolute (set by
    # the probe) so a per-app cwd doesn't scatter N partial dumps. An error must overwrite any
    # earlier dump too: leaving that file in place would let the reader trust stale coverage.
    dump_path = System.get_env(@dump_path_env) || @dump_file
    File.write!(dump_path, :erlang.term_to_binary(dump_payload()))
  end

  defp dump_payload do
    # Serialise plain data (lists, not `MapSet`s) so the reader makes no assumption about a
    # struct's wire representation. A missing table means capture failed, whereas existing
    # empty tables mean no emitted mutant ran. Read all five successfully before producing a
    # coverage map; otherwise write an explicit error without crashing the after-suite hook.
    with {:ok, aggregate} <- table_entries(@agg_table),
         {:ok, unlabeled} <- table_entries(@unlabeled_table),
         {:ok, wholefile} <- table_entries(@wholefile_table),
         {:ok, attributed} <- table_entries(@attr_table),
         {:ok, tests} <- table_entries(@test_table) do
      aggregate = for {id} <- aggregate, do: id
      unlabeled = for {id} <- unlabeled, do: id
      wholefile = for {id} <- wholefile, do: id

      by_file =
        Enum.reduce(attributed, %{}, fn {{mod, id}}, acc ->
          case source_file(mod) do
            nil -> acc
            file -> Map.update(acc, file, [id], &[id | &1])
          end
        end)

      # Per-test-case attribution, keyed by mutant id → the runnable test names that covered it.
      # Names are strings (the `mix test --only test:<name>` value); `:tests` unions them with the
      # covering files from `by_file`. An id in a shared lib carries every covering test name.
      by_test =
        Enum.reduce(tests, %{}, fn {{_mod, name, id}}, acc ->
          Map.update(acc, id, [to_string(name)], &[to_string(name) | &1])
        end)

      %{
        aggregate: aggregate,
        by_file: by_file,
        unlabeled: unlabeled,
        by_test: by_test,
        wholefile: wholefile
      }
    end
  end

  defp table_entries(table) do
    {:ok, :ets.tab2list(table)}
  rescue
    ArgumentError -> {:error, {:missing_coverage_table, table}}
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
  # An `on_exit` callback registered in a test body is recovered too (`on_exit_frame/1`): its
  # closure frame names the owning test module, and ExUnit's per-test runner-loop frame scopes the
  # match. A bare spawn / a `setup`-registered `on_exit` closure matches nothing (no label, no live
  # caller chain, no recognisable frame) → `nil`, and the caller routes that id to the unlabeled
  # bucket (whole suite). Only the module is needed for file-granular selection; the name half is
  # incidental.
  #
  # Cost discipline — this runs on EVERY hit, inside the target's hottest loops, so each tier pays
  # only what its freshness contract needs:
  #
  #   * The process's **own** label is re-read every hit, but straight from the process dictionary
  #     (`Process.get/1`, ~free) — `Process.set_label/1` stores the label under `:"$process_label"`
  #     on every Elixir/OTP combination we support, so no `Process.info(self(), :dictionary)`
  #     full-copy is needed. A reusable process that relabels itself between tests/requests is
  #     always seen (stale attribution is worse than the read cost).
  #   * The **recovery** tiers (own-stack ExUnit frames; the `$callers`/`$ancestors` walk) do
  #     stacktrace builds and cross-process `Process.info` reads — a signal round-trip per pid.
  #     Paying that per hit livelocked real probes: a LiveView suite's render/diff loops run in
  #     unlabeled channel processes, and per-hit ancestor walks turned a ~2-minute suite into an
  #     unbounded crawl (the probe looked hung). So the recovery *result* is memoized in the
  #     process dictionary and revalidated per hit with cheap local reads only; it is recomputed
  #     when the `$callers` chain changes (a reused worker serving a new caller) or when the
  #     witness pid that produced the label dies — a long-lived Task outliving its spawning test
  #     must degrade to unlabeled (whole suite) so selection stays conservative.
  defp label do
    case Process.get(:"$process_label") do
      {mod, _name} = label when is_atom(mod) -> label
      _ -> recovery_label()
    end
  end

  # The memoized recovery: `{callers, witness, label}` under `@label_key`, where `witness` is the
  # pid whose label/stack produced `label` (`self()` for an own-stack recovery). Valid while the
  # `$callers` chain is unchanged and the witness is alive; `{callers, nil, nil}` memoizes "no
  # attribution" (the unlabeled bucket) under the same `$callers` guard — a later hit with a new
  # caller re-resolves, and the per-hit own-label read above already catches a self relabel.
  defp recovery_label do
    callers = Process.get(:"$callers")

    case Process.get(@label_key) do
      {^callers, nil, nil} -> nil
      {^callers, witness, label} when is_pid(witness) -> validate(witness, label, callers)
      _ -> recover(callers)
    end
  end

  defp validate(witness, label, callers) do
    if Process.alive?(witness), do: label, else: recover(callers)
  end

  defp recover(callers) do
    {witness, label} =
      case stacktrace_label(self()) do
        {mod, _name} = label when is_atom(mod) -> {self(), label}
        _ -> recovered_label()
      end

    Process.put(@label_key, {callers, witness, label})
    label
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
    # `{module, name}` to, returning it with the pid that witnessed it (for the memo's liveness
    # check). The test pid sits at the tail of the chain even for nested tasks, so a labeled (or
    # stack-recoverable) owner is found if one exists. Local pids only: `Process.info/2` (and the
    # memo's `Process.alive?/1`) raise on a remote pid, and a cross-node caller can't map to a
    # local test file anyway.
    callers = Process.get(:"$callers", []) ++ Process.get(:"$ancestors", [])

    Enum.find_value(callers, {nil, nil}, fn
      pid when is_pid(pid) and node(pid) == node() ->
        case label_of(pid) do
          {mod, _name} = label when is_atom(mod) -> {pid, label}
          _ -> nil
        end

      _ ->
        nil
    end)
  end

  # The `$process_label` of `pid` (an ancestor's — `label/0` reads our own straight from the
  # process dictionary), OTP-tolerant and the single home for the version check. On OTP 27+
  # `:proc_lib.get_label/1` reads it directly (cross-process too); on OTP 26 and earlier the label
  # lives in the process dictionary, which `Process.info(pid, :dictionary)` exposes
  # (`Process.get/1` would only read our own). `apply/3`, not a direct call, so a static reference
  # to the OTP 27-only function doesn't warn "undefined" on OTP 26 and earlier. Best-effort — a
  # dead pid yields `nil`, never a crash.
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
  # uses when no `$process_label` is set (every line on **Elixir 1.18**; a `setup_all` and an
  # `on_exit` callback on every version, which run unlabeled). From Elixir 1.19 the runner labels
  # every test process — `test`, `doctest`, and `property` alike — so `proc_label/1` (tier 1)
  # resolves them and, of the frame shapes below, only the `setup_all` and `on_exit` ones still run.
  #
  # A test **body** is recognised two ways, the second a naming-agnostic backstop for the first:
  #
  #   * by its function name (`test_label/2`) — ExUnit names test bodies `:"test …"`, `:"doctest …"`,
  #     `:"property …"`; the embedded space can't occur in an ordinary identifier;
  #   * else by position (`dispatched_test_frame/1`) — the frame directly above ExUnit's per-test
  #     dispatcher `ExUnit.Runner.exec_test/2` *is* the test body, whatever generator named it, so a
  #     test kind the name list doesn't know still attributes to the right module.
  #
  # An `on_exit` callback registered in a test body is recognised by `on_exit_frame/1` (its own
  # comment has the soundness argument): the closure frame names the module, and ExUnit's per-test
  # runner-loop frame scopes the match to real `on_exit` runs.
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
      {:current_stacktrace, stack} ->
        named_frame(stack) || dispatched_test_frame(stack) || on_exit_frame(stack)

      _ ->
        nil
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

  # An `on_exit` callback, attributed to the test that registered it. ExUnit runs each test's
  # `on_exit` callbacks in a dedicated per-test runner process whose stack bottoms out in
  # `ExUnit.OnExitHandler.on_exit_runner_loop/0`, and a callback registered *in a test body* is a
  # closure whose frame is named `:"-test …/N-fun-M-"` — the embedded space, exactly as in
  # `test_label/2`, cannot occur for a target's own function (a target function literally named
  # `test` yields `-test/1-fun-0-`, no space). Requiring BOTH signals scopes the recovery to real
  # `on_exit` callbacks, which is what keeps it sound: an `on_exit` failure fails the *owning*
  # test, so that test's own file kills the mutant. A detached `spawn` from a test body carries
  # the same closure frame but no runner-loop frame — its effects may be observable only by
  # another file's tests, so it must stay in the unlabeled bucket (whole suite). A callback
  # registered from a `setup`/`setup_all` block (closure named `-__ex_unit_setup…`, possibly
  # defined in an `ExUnit.CaseTemplate` whose source is not a runnable test file) is deliberately
  # not recognised either — unlabeled, conservative. If ExUnit ever renames the runner loop, the
  # match just stops firing and `on_exit` ids fall back to the unlabeled bucket — degraded, never
  # wrong. Both ExUnit references are bare atom matches (no call, no module load), keeping this
  # dependency-free.
  defp on_exit_frame(stack) do
    on_exit_runner? =
      Enum.any?(stack, fn
        {ExUnit.OnExitHandler, :on_exit_runner_loop, _arity, _} -> true
        _ -> false
      end)

    if on_exit_runner? do
      Enum.find_value(stack, fn
        {mod, fun, _arity, _} when is_atom(mod) and is_atom(fun) -> closure_test_label(mod, fun)
        _ -> nil
      end)
    end
  end

  # `{mod, fun}` when `fun` is a closure defined inside an ExUnit-generated test body —
  # `test_label/2`'s naming rule applied to anonymous-fun frames (`-<enclosing name>/<arity>-fun-N-`,
  # nesting only appends further `-fun-M-` suffixes, so the prefix survives).
  defp closure_test_label(mod, fun) do
    case Atom.to_string(fun) do
      "-test " <> _ -> {mod, fun}
      "-doctest " <> _ -> {mod, fun}
      "-property " <> _ -> {mod, fun}
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
