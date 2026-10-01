# Stand-ins for ExUnit case modules, for the labels these tests set by hand: the helper takes a
# `$process_label` as a test's only when its module exports `__ex_unit__/0`, as every
# `use ExUnit.Case` module does.
for name <-
      ~w(DocMod FakeAttrMod GainedCallerMod GroupMod GroupRelabelMod GroupWitnessMod PerTestMod PropMod RecoveredMod RecoveredThenDeadMod RelabelFirstMod RelabelSecondMod ReusedFirstMod ReusedSecondMod SharedMod AnchorMod ReanchorFirstMod ReanchorSecondMod)a do
  # Bound first: `defmodule <remote-call>` is rejected ("invalid module name").
  mod = Module.concat(Mutare.Coverage.HelperTemplateTest.Cases, name)

  defmodule mod do
    @moduledoc false
    def __ex_unit__, do: nil
  end
end

# A run-time stand-in for an ExUnit-*compiled* test module, for the `on_exit` recovery tests: a
# `:"test …"`-named function (the shape ExUnit's `test` macro generates) that *returns* the closure
# a test body would register with `on_exit`. The closure's frame is therefore named
# `:"-test registers on_exit/1-fun-0-"` — exactly what `on_exit_frame/1` recognises.
defmodule Mutare.Coverage.HelperTemplateTest.OnExitFixture do
  @moduledoc false

  # The trailing `:ok` keeps `hit/1` off tail position, so the closure frame survives on the
  # stack while the hit records — as in the metamutant, where the hit is never a tail call.
  def unquote(:"test registers on_exit")(ids) do
    fn ->
      Mutare.Coverage.HelperTemplate.hit(ids)
      :ok
    end
  end
end

# Stand-ins for ExUnit's generated setup dispatch (`__ex_unit__/2`) and a test body that reach
# their innermost call through more distinct frames than `current_stacktrace` reports, so the
# owning frame shows only in the process's `:backtrace` — a `setup_all` running a deep walker.
defmodule Mutare.Coverage.HelperTemplateTest.DeepFixture do
  @moduledoc false

  def __ex_unit__(frames, fun) do
    descend(frames, fun)
    :ok
  end

  def unquote(:"test it's a \\ ünïcode → name")(frames, fun) do
    descend(frames, fun)
    :ok
  end

  def plain(frames, fun) do
    descend(frames, fun)
    :ok
  end

  # Two call sites, alternated: the VM reports a run of frames with one return address once.
  def descend(0, fun), do: fun.()

  def descend(n, fun) when rem(n, 2) == 0 do
    descend(n - 1, fun)
    :ok
  end

  def descend(n, fun) do
    descend(n - 1, fun)
    :ok
  end
end

defmodule Mutare.Coverage.HelperTemplateTest do
  # The coverage helper is a real, compiled module (`Mutare.Coverage.HelperTemplate`) whose
  # *source* is copied verbatim into each sandbox as `:mutare_cov` — so in a normal run its
  # `hit/1`/`dump/1` logic only ever executes inside the sandbox subprocess, never in Mutare's
  # own VM. These tests exercise that logic directly against the shared ETS tables it owns, so
  # a regression in the recording/attribution tiers is caught in Mutare's own suite rather than
  # only when a sandbox runs. Named global ETS tables ⇒ `async: false`.
  #
  # Fixture tables/caches/dump variables are separate from the outer probe, so
  # these tests may run during self-hosting without destroying its capture.
  use ExUnit.Case, async: false

  alias Mutare.Coverage.HelperTemplate, as: H
  alias Mutare.Coverage.HelperTemplateTest.{DeepFixture, OnExitFixture}

  alias Mutare.Coverage.HelperTemplateTest.Cases.{
    AnchorMod,
    DocMod,
    FakeAttrMod,
    GainedCallerMod,
    GroupMod,
    GroupRelabelMod,
    GroupWitnessMod,
    PerTestMod,
    PropMod,
    ReanchorFirstMod,
    ReanchorSecondMod,
    RecoveredMod,
    RecoveredThenDeadMod,
    RelabelFirstMod,
    RelabelSecondMod,
    ReusedFirstMod,
    ReusedSecondMod,
    SharedMod
  }

  @anchor_key H.runtime(:fixture).anchor_key

  # Tables are created once and owned by the (module-lifetime) setup_all process, so they
  # survive across every test. `hit([777])` here runs *inside* `__ex_unit__/2`, exercising the
  # `setup_all` stacktrace-recovery tier (tier 3 of `label/0`).
  setup_all do
    for t <- [
          H.agg_table(),
          H.attr_table(),
          H.unlabeled_table(),
          H.test_table(),
          H.wholefile_table()
        ] do
      if :ets.whereis(t) != :undefined, do: :ets.delete(t)
      :ets.new(t, [:named_table, :public, :set])
    end

    # `:setup_all` is not a runnable test name, so a `setup_all`-covered id records to the
    # whole-file table, never the per-test table.
    H.hit([777])
    :ok
  end

  describe "contract-constant accessors" do
    test "fixture capture shares no keys or output destinations with the harness" do
      harness = H.runtime(:harness) |> Map.values() |> MapSet.new()
      fixture = H.runtime(:fixture) |> Map.values() |> MapSet.new()
      assert MapSet.disjoint?(harness, fixture)
    end

    test "expose the table names, dump file, and env-var keys" do
      assert H.agg_table() == :mutare_cov_agg__fixture
      assert H.attr_table() == :mutare_cov_attr__fixture
      assert H.unlabeled_table() == :mutare_cov_unlabeled__fixture
      assert H.dump_file() == "mutare_cov.fixture.terms"
      assert H.dump_path_env() == "MUTARE_COV_DUMP_FIXTURE"
      assert H.root_env() == "MUTARE_COV_ROOT_FIXTURE"
    end
  end

  describe "hit/1 — recording and label attribution" do
    test "returns true (so the spliced `and` chain stays boolean)" do
      assert run_in(fn -> H.hit([401]) end, label: nil) == true
    end

    test "a labeled process attributes its ids to that module (tier 1)" do
      run_in(fn -> H.hit([101, 102]) end, label: {FakeAttrMod, :a_test})

      assert :ets.lookup(H.agg_table(), 101) == [{101}]
      assert :ets.lookup(H.agg_table(), 102) == [{102}]
      assert :ets.lookup(H.attr_table(), {FakeAttrMod, 101}) == [{{FakeAttrMod, 101}}]
      assert :ets.lookup(H.attr_table(), {FakeAttrMod, 102}) == [{{FakeAttrMod, 102}}]
      # not unlabeled
      assert :ets.lookup(H.unlabeled_table(), 101) == []
    end

    test "a long-lived process re-reads changed process labels" do
      parent = self()

      worker =
        spawn(fn ->
          Process.set_label({RelabelFirstMod, :first})
          H.hit([901, 903])

          Process.set_label({RelabelSecondMod, :second})
          H.hit([902, 903])

          send(parent, :done)
        end)

      ref = Process.monitor(worker)
      assert_receive :done
      assert_receive {:DOWN, ^ref, :process, ^worker, _}

      assert :ets.lookup(H.attr_table(), {RelabelFirstMod, 901}) == [
               {{RelabelFirstMod, 901}}
             ]

      assert :ets.lookup(H.attr_table(), {RelabelSecondMod, 902}) == [
               {{RelabelSecondMod, 902}}
             ]

      assert :ets.lookup(H.attr_table(), {RelabelFirstMod, 903}) == [
               {{RelabelFirstMod, 903}}
             ]

      assert :ets.lookup(H.attr_table(), {RelabelSecondMod, 903}) == [
               {{RelabelSecondMod, 903}}
             ]

      assert :ets.lookup(H.attr_table(), {RelabelFirstMod, 902}) == []
      assert :ets.lookup(H.unlabeled_table(), 902) == []
    end

    test "a Task recovers its spawning test's label from the caller chain (tier 2)" do
      # The current process is labeled; a Task started from it carries it in `$callers`, so
      # the unlabeled Task process recovers the label rather than falling to the bucket.
      Process.set_label({RecoveredMod, :a_test})

      Task.async(fn -> H.hit([301]) end) |> Task.await()

      assert :ets.lookup(H.attr_table(), {RecoveredMod, 301}) == [{{RecoveredMod, 301}}]
      assert :ets.lookup(H.unlabeled_table(), 301) == []
    end

    test "a caller-attributed long-lived process becomes unlabeled after the caller exits" do
      parent = self()

      holder =
        spawn(fn ->
          Process.set_label({RecoveredThenDeadMod, :a_test})
          send(parent, :holder_ready)

          receive do
            :stop -> :ok
          end
        end)

      assert_receive :holder_ready
      holder_ref = Process.monitor(holder)

      worker =
        spawn(fn ->
          Process.put(:"$callers", [holder])
          send(parent, {:first, H.hit([801])})

          receive do
            :after_caller_exit -> :ok
          end

          send(parent, {:second, H.hit([801, 802])})
        end)

      worker_ref = Process.monitor(worker)

      assert_receive {:first, true}

      assert :ets.lookup(H.attr_table(), {RecoveredThenDeadMod, 801}) == [
               {{RecoveredThenDeadMod, 801}}
             ]

      assert :ets.lookup(H.unlabeled_table(), 801) == []

      send(holder, :stop)
      assert_receive {:DOWN, ^holder_ref, :process, ^holder, _}

      send(worker, :after_caller_exit)
      assert_receive {:second, true}
      assert_receive {:DOWN, ^worker_ref, :process, ^worker, _}

      assert :ets.lookup(H.unlabeled_table(), 801) == [{801}]
      assert :ets.lookup(H.unlabeled_table(), 802) == [{802}]
      assert :ets.lookup(H.attr_table(), {RecoveredThenDeadMod, 802}) == []
    end

    test "a reused worker re-resolves when its `$callers` chain changes" do
      # The recovery memo (`:mutare_cov_label`) must not pin the first caller's attribution on a
      # worker that serves a *new* caller: the memo is guarded by the `$callers` value, so a
      # changed chain re-resolves even while the old caller is still alive.
      parent = self()

      first = labeled_holder({ReusedFirstMod, :a_test})
      second = labeled_holder({ReusedSecondMod, :a_test})

      worker =
        spawn(fn ->
          Process.put(:"$callers", [first])
          H.hit([811])

          Process.put(:"$callers", [second])
          H.hit([812])

          send(parent, :done)
        end)

      ref = Process.monitor(worker)
      assert_receive :done
      assert_receive {:DOWN, ^ref, :process, ^worker, _}

      assert :ets.lookup(H.attr_table(), {ReusedFirstMod, 811}) == [{{ReusedFirstMod, 811}}]
      assert :ets.lookup(H.attr_table(), {ReusedSecondMod, 812}) == [{{ReusedSecondMod, 812}}]
      assert :ets.lookup(H.attr_table(), {ReusedFirstMod, 812}) == []
      assert :ets.lookup(H.unlabeled_table(), 811) == []
      assert :ets.lookup(H.unlabeled_table(), 812) == []
    end

    test "an unlabeled process re-resolves once it gains a caller chain" do
      # The memoized "no attribution" result is guarded by `$callers` too: a process that recorded
      # unlabeled and *then* gains a caller must attribute later ids, not stay pinned unlabeled.
      parent = self()
      holder = labeled_holder({GainedCallerMod, :a_test})

      worker =
        spawn(fn ->
          H.hit([821])

          Process.put(:"$callers", [holder])
          H.hit([822])

          send(parent, :done)
        end)

      ref = Process.monitor(worker)
      assert_receive :done
      assert_receive {:DOWN, ^ref, :process, ^worker, _}

      assert :ets.lookup(H.unlabeled_table(), 821) == [{821}]
      assert :ets.lookup(H.attr_table(), {GainedCallerMod, 822}) == [{{GainedCallerMod, 822}}]
      assert :ets.lookup(H.unlabeled_table(), 822) == []
    end

    test "a bare spawn (no label, no caller chain, no setup_all frame) falls to the unlabeled bucket" do
      run_in(fn -> H.hit([201]) end, label: nil)

      assert :ets.lookup(H.unlabeled_table(), 201) == [{201}]
      assert :ets.lookup(H.agg_table(), 201) == [{201}]
      # nothing attributed to a module
      refute Enum.any?(:ets.tab2list(H.attr_table()), fn {{_mod, id}} -> id == 201 end)
    end

    test "an unlabeled pid and a non-pid in the caller chain recover no label → unlabeled bucket" do
      # `recovered_label/1` walks `$callers ++ $ancestors`: a live but unlabeled pid yields no
      # `{module, name}` (the `_ -> nil` arm), and a non-pid entry (a registered name) is skipped
      # too — so the id falls to the unlabeled bucket.
      unlabeled = spawn(fn -> Process.sleep(:infinity) end)
      parent = self()

      worker =
        spawn(fn ->
          Process.put(:"$callers", [unlabeled, :a_registered_name])
          send(parent, {:done, H.hit([551])})
        end)

      ref = Process.monitor(worker)
      assert_receive {:done, true}

      receive do
        {:DOWN, ^ref, :process, ^worker, _} -> :ok
      end

      Process.exit(unlabeled, :kill)

      assert :ets.lookup(H.unlabeled_table(), 551) == [{551}]
      refute Enum.any?(:ets.tab2list(H.attr_table()), fn {{_mod, id}} -> id == 551 end)
    end

    test "an on_exit callback registered in a test body attributes to that test's module" do
      # The real mechanism, end to end: ExUnit runs a test's `on_exit` callbacks in a dedicated
      # runner process (`ExUnit.OnExitHandler.on_exit_runner_loop/0`); the callback is a closure
      # defined in the test body, so its `:"-test …/1-fun-N-"` frame names the owning module.
      # Drive the actual runner loop so a rename of either signal breaks this test, not a sandbox.
      callback = apply(OnExitFixture, :"test registers on_exit", [[861]])
      {runner, ref} = spawn_monitor(ExUnit.OnExitHandler, :on_exit_runner_loop, [])

      # The reply value is ExUnit-internal (nil on success in current versions) — only the
      # round-trip matters here; the attribution assertions below carry the test.
      send(runner, {:run, self(), callback})
      assert_receive {^runner, _reply}

      Process.exit(runner, :kill)
      assert_receive {:DOWN, ^ref, :process, ^runner, _}

      assert :ets.lookup(H.attr_table(), {OnExitFixture, 861}) == [{{OnExitFixture, 861}}]
      assert :ets.lookup(H.agg_table(), 861) == [{861}]
      assert :ets.lookup(H.unlabeled_table(), 861) == []
    end

    test "the same test-body closure in a detached spawn stays unlabeled (whole suite)" do
      # A bare `spawn` from a test body carries the identical `:"-test …"` closure frame — but no
      # on_exit runner-loop frame. It must NOT be attributed: a detached process can outlive its
      # test, and its effects may only be observable by another file's tests, so trusting the
      # spawning test's file could mask the real killer (a false survivor). Unlabeled → whole suite.
      callback = apply(OnExitFixture, :"test registers on_exit", [[862]])
      run_in(fn -> callback.() end, label: nil)

      assert :ets.lookup(H.unlabeled_table(), 862) == [{862}]
      assert :ets.lookup(H.agg_table(), 862) == [{862}]
      refute Enum.any?(:ets.tab2list(H.attr_table()), fn {{_mod, id}} -> id == 862 end)
    end

    test "a setup_all-recovered id is attributed to its own module's file (tier 3)" do
      # `hit([777])` ran in setup_all (above), whose process is unlabeled and caller-less but
      # executes within this module's generated `__ex_unit__/2` dispatch — so the owning module
      # is on the stack and recovered there.
      assert :ets.lookup(H.attr_table(), {__MODULE__, 777}) == [{{__MODULE__, 777}}]
      assert :ets.lookup(H.agg_table(), 777) == [{777}]
    end

    test "a setup_all dispatch below the reported stack is recovered from the backtrace" do
      run_deep(:__ex_unit__, [871])

      assert :ets.lookup(H.attr_table(), {DeepFixture, 871}) == [{{DeepFixture, 871}}]
      assert :ets.lookup(H.wholefile_table(), 871) == [{871}]
      assert :ets.lookup(H.unlabeled_table(), 871) == []
    end

    test "a test body below the reported stack keeps its exact name, however it is quoted" do
      name = :"test it's a \\ ünïcode → name"
      run_deep(name, [872])

      assert :ets.lookup(H.test_table(), {DeepFixture, name, 872}) == [{{DeepFixture, name, 872}}]
      assert :ets.lookup(H.unlabeled_table(), 872) == []
    end

    test "a deep stack with no ExUnit frame anywhere stays unlabeled" do
      run_deep(:plain, [873])

      assert :ets.lookup(H.unlabeled_table(), 873) == [{873}]
      refute Enum.any?(:ets.tab2list(H.attr_table()), fn {{_mod, id}} -> id == 873 end)
    end

    test "a runnable test name records the id to the per-test table (narrowable)" do
      run_in(fn -> H.hit([111, 112]) end, label: {PerTestMod, :"test does a thing"})

      # Module → file, as always (the `:coverage` superset).
      assert :ets.lookup(H.attr_table(), {PerTestMod, 111}) == [{{PerTestMod, 111}}]
      # …and the finer per-test key `:tests` narrows with.
      assert :ets.lookup(H.test_table(), {PerTestMod, :"test does a thing", 111}) ==
               [{{PerTestMod, :"test does a thing", 111}}]

      assert :ets.lookup(H.test_table(), {PerTestMod, :"test does a thing", 112}) ==
               [{{PerTestMod, :"test does a thing", 112}}]

      # A narrowable id, so NOT in the whole-file table.
      assert :ets.lookup(H.wholefile_table(), 111) == []
    end

    test "doctest and property names are runnable too" do
      run_in(fn -> H.hit([113]) end, label: {DocMod, :"doctest DocMod.foo/1 (2)"})
      run_in(fn -> H.hit([114]) end, label: {PropMod, :"property sorts anything"})

      assert :ets.lookup(H.test_table(), {DocMod, :"doctest DocMod.foo/1 (2)", 113}) ==
               [{{DocMod, :"doctest DocMod.foo/1 (2)", 113}}]

      assert :ets.lookup(H.test_table(), {PropMod, :"property sorts anything", 114}) ==
               [{{PropMod, :"property sorts anything", 114}}]

      assert :ets.lookup(H.wholefile_table(), 113) == []
    end

    test "sibling tests in one module each reach the per-test table (dedup is per name)" do
      # The seen-cache must not suppress the same id under a *second* test in the same module — both
      # covering names must be recorded so `:tests` can narrow to either.
      run_in(fn -> H.hit([115]) end, label: {SharedMod, :"test alpha"})
      run_in(fn -> H.hit([115]) end, label: {SharedMod, :"test beta"})

      assert :ets.lookup(H.test_table(), {SharedMod, :"test alpha", 115}) ==
               [{{SharedMod, :"test alpha", 115}}]

      assert :ets.lookup(H.test_table(), {SharedMod, :"test beta", 115}) ==
               [{{SharedMod, :"test beta", 115}}]
    end

    test "a setup_all label records to the whole-file table, never the per-test table" do
      # `:setup_all` is not a runnable test name: `hit([777])` from setup_all recorded 777 to the
      # module (file) and to the whole-file table, and nothing to the per-test table.
      assert :ets.lookup(H.wholefile_table(), 777) == [{777}]
      refute Enum.any?(:ets.tab2list(H.test_table()), fn {{_m, _n, id}} -> id == 777 end)
    end

    test "an on_exit closure label records to the whole-file table, never the per-test table" do
      # The on_exit closure frame (`:"-test …/1-fun-N-"`) is recovered for attribution but is not a
      # runnable test name — so 861 (recorded via the real runner loop above) is whole-file, not
      # per-test.
      callback = apply(OnExitFixture, :"test registers on_exit", [[871]])
      {runner, ref} = spawn_monitor(ExUnit.OnExitHandler, :on_exit_runner_loop, [])
      send(runner, {:run, self(), callback})
      assert_receive {^runner, _reply}
      Process.exit(runner, :kill)
      assert_receive {:DOWN, ^ref, :process, ^runner, _}

      assert :ets.lookup(H.attr_table(), {OnExitFixture, 871}) == [{{OnExitFixture, 871}}]
      assert :ets.lookup(H.wholefile_table(), 871) == [{871}]
      refute Enum.any?(:ets.tab2list(H.test_table()), fn {{_m, _n, id}} -> id == 871 end)
    end

    test "hit tracks ids seen by the current process, per namespace" do
      # Coverage is set-like. The helper records an id once per process and then returns early for
      # repeated hits, keeping the probe closer to target timing in hot loops. Each namespace (`nil`
      # for `hit/1`) has its own cache entry, so local id 701 in a file is a distinct hit.
      tid = :ets.whereis(H.agg_table())

      H.hit([701])
      H.hit([701, 702])
      H.hit("lib/seen.ex", [701])

      assert {^tid, seen} = Process.get({H.runtime(:fixture).seen_key, nil})
      assert {^tid, file_seen} = Process.get({H.runtime(:fixture).seen_key, "lib/seen.ex"})
      assert seen |> Map.keys() |> Enum.filter(&(&1 > 0)) |> Enum.sort() == [701, 702]
      assert file_seen |> Map.keys() |> Enum.filter(&(&1 > 0)) == [701]
      assert :ets.lookup(H.agg_table(), {"lib/seen.ex", 701}) == [{{"lib/seen.ex", 701}}]
      # This runs in the test process, which carries a runnable test name (a `$process_label` on
      # 1.19+, a `:"test …"` stack frame on 1.18) — so the per-process seen-key is the *per-test*
      # form `{:test, module, name}`, not the module-only `{:labeled, module}` a non-runnable
      # (`setup_all`/`on_exit`) label would use.
      assert Enum.any?(Map.keys(seen[701]), &match?({:test, __MODULE__, _}, &1))
      assert Enum.any?(Map.keys(seen[702]), &match?({:test, __MODULE__, _}, &1))
      assert :ets.lookup(H.agg_table(), 701) == [{701}]
      assert :ets.lookup(H.agg_table(), 702) == [{702}]
    end

    test "overlapping groups sharing their first id preserve every new id and namespace" do
      run_in(
        fn ->
          for ids <- [[1101, 1102, 1103], [1101, 1104, 1103], [1101, 1102, 1103, 1105]] do
            H.hit("lib/groups.ex", ids)
            H.hit("lib/groups.ex", ids)
          end

          H.hit("lib/other_groups.ex", [1101, 1102, 1103])
        end,
        label: {GroupMod, :"test overlapping groups"}
      )

      for id <- 1101..1105 do
        qualified = {"lib/groups.ex", id}
        assert :ets.lookup(H.agg_table(), qualified) == [{qualified}]

        assert :ets.lookup(H.test_table(), {GroupMod, :"test overlapping groups", qualified}) ==
                 [{{GroupMod, :"test overlapping groups", qualified}}]
      end

      for id <- 1101..1103 do
        qualified = {"lib/other_groups.ex", id}
        assert :ets.lookup(H.agg_table(), qualified) == [{qualified}]
      end

      assert :ets.lookup(H.agg_table(), {"lib/other_groups.ex", 1104}) == []
    end

    test "one cached group records sibling test labels and whole-file contexts independently" do
      run_in(
        fn ->
          for name <- [:"test first", :"test second", :setup_all] do
            Process.set_label({GroupRelabelMod, name})
            H.hit([1201, 1202, 1203])
            H.hit([1201, 1202, 1203])
          end
        end,
        label: nil
      )

      for id <- 1201..1203 do
        for name <- [:"test first", :"test second"] do
          assert :ets.lookup(H.test_table(), {GroupRelabelMod, name, id}) ==
                   [{{GroupRelabelMod, name, id}}]
        end

        assert :ets.lookup(H.wholefile_table(), id) == [{id}]
        assert :ets.lookup(H.unlabeled_table(), id) == []
      end
    end

    test "a cached group becomes unlabeled when the attribution witness dies" do
      holder = labeled_holder({GroupWitnessMod, :"test spawning task"})
      holder_ref = Process.monitor(holder)
      parent = self()

      {worker, worker_ref} =
        spawn_monitor(fn ->
          Process.put(:"$callers", [holder])
          H.hit([1301, 1302, 1303])
          H.hit([1301, 1302, 1303])
          send(parent, :group_recorded)

          receive do
            :witness_exited ->
              H.hit([1301, 1302, 1303])
          end
        end)

      assert_receive :group_recorded
      assert :ets.lookup(H.unlabeled_table(), 1301) == []
      Process.exit(holder, :kill)
      assert_receive {:DOWN, ^holder_ref, :process, ^holder, _}
      send(worker, :witness_exited)
      assert_receive {:DOWN, ^worker_ref, :process, ^worker, :normal}

      for id <- 1301..1303 do
        assert :ets.lookup(H.unlabeled_table(), id) == [{id}]
      end
    end
  end

  describe "hit — a label that names no ExUnit case" do
    test "a label naming a real ExUnit case is a test label", %{test: name} do
      # The other tests label processes with stand-in modules, so this is the one that fails if
      # ExUnit stops exporting what `exunit_label/1` checks for. The bare spawn has no test frame
      # and no lineage, so no lower tier could attribute the hit in its place.
      run_in(fn -> H.hit([1403]) end, label: {__MODULE__, name})

      assert :ets.lookup(H.test_table(), {__MODULE__, name, 1403}) ==
               [{{__MODULE__, name, 1403}}]

      assert :ets.lookup(H.unlabeled_table(), 1403) == []
    end

    test "an own two-tuple label of a non-test module is not a test label" do
      # ecto_sql's `start_owner!/2` labels its owner this way. Taken as a label, the id would be
      # attributed to a module with no test file and dropped at dump time instead of going to the
      # unlabeled bucket.
      run_in(fn -> H.hit([1401]) end, label: {:sql_sandbox_owner, %{started_by: self()}})

      assert :ets.lookup(H.unlabeled_table(), 1401) == [{1401}]
      refute Enum.any?(:ets.tab2list(H.attr_table()), fn {{_mod, id}} -> id == 1401 end)
      assert :ets.lookup(H.wholefile_table(), 1401) == []
    end

    test "a caller labeled by a non-test module is passed over for the next one" do
      bystander = labeled_holder({:worker_pool, :worker})
      holder = labeled_holder({RecoveredMod, :"test beyond the bystander"})

      in_worker(fn ->
        Process.put(:"$callers", [bystander, holder])
        H.hit([1402])
      end)

      assert :ets.lookup(H.test_table(), {RecoveredMod, :"test beyond the bystander", 1402}) ==
               [{{RecoveredMod, :"test beyond the bystander", 1402}}]

      refute Enum.any?(:ets.tab2list(H.attr_table()), fn {{mod, id}} ->
               id == 1402 and mod == :worker_pool
             end)
    end
  end

  describe "hit — a declared owner (the anchor)" do
    test "an anchored process is attributed to the owner's test" do
      owner = labeled_holder({AnchorMod, :"test drives a browser"})

      in_worker(fn ->
        Process.put(@anchor_key, owner)
        H.hit([1501])
      end)

      assert :ets.lookup(H.test_table(), {AnchorMod, :"test drives a browser", 1501}) ==
               [{{AnchorMod, :"test drives a browser", 1501}}]

      assert :ets.lookup(H.unlabeled_table(), 1501) == []
    end

    test "an owner is resolved through its own ancestry, as a sandbox owner is" do
      # The shape of ecto_sql's `start_owner!/2`: an unlinked `Agent` started by the test, with a
      # label naming no test. Its `$ancestors` begins with the test process.
      test_pid = self()

      {:ok, owner} =
        Agent.start(fn -> Process.set_label({:sql_sandbox_owner, %{started_by: test_pid}}) end)

      on_exit(fn -> Process.exit(owner, :kill) end)

      in_worker(fn ->
        Process.put(@anchor_key, owner)
        H.hit([1502])
      end)

      assert Enum.any?(:ets.tab2list(H.test_table()), &match?({{__MODULE__, _name, 1502}}, &1))
      assert :ets.lookup(H.unlabeled_table(), 1502) == []
    end

    test "a process spawned by an anchored one resolves through the anchor" do
      owner = labeled_holder({AnchorMod, :"test spawns from a request"})

      in_worker(fn ->
        Process.put(@anchor_key, owner)
        Task.async(fn -> H.hit([1503]) end) |> Task.await()
      end)

      assert :ets.lookup(H.test_table(), {AnchorMod, :"test spawns from a request", 1503}) ==
               [{{AnchorMod, :"test spawns from a request", 1503}}]

      assert :ets.lookup(H.unlabeled_table(), 1503) == []
    end

    test "re-anchoring a process switches its attribution while both owners live" do
      # A keep-alive connection serving a second test's request: the memo is guarded by the
      # anchor, so the first owner's attribution is not kept.
      first = labeled_holder({ReanchorFirstMod, :"test first request"})
      second = labeled_holder({ReanchorSecondMod, :"test second request"})

      in_worker(fn ->
        Process.put(@anchor_key, first)
        H.hit([1504, 1506])
        Process.put(@anchor_key, second)
        H.hit([1505, 1506])
      end)

      assert :ets.lookup(H.attr_table(), {ReanchorFirstMod, 1504}) == [{{ReanchorFirstMod, 1504}}]

      assert :ets.lookup(H.attr_table(), {ReanchorSecondMod, 1505}) == [
               {{ReanchorSecondMod, 1505}}
             ]

      assert :ets.lookup(H.attr_table(), {ReanchorSecondMod, 1506}) == [
               {{ReanchorSecondMod, 1506}}
             ]

      assert :ets.lookup(H.attr_table(), {ReanchorFirstMod, 1505}) == []
    end

    test "withdrawing the anchor makes the process unlabeled while the owner lives" do
      # A keep-alive connection's request that carries no owner: the anchor is withdrawn
      # (`attribute_to(nil)` deletes the key), and the memo guarded by it is not kept.
      owner = labeled_holder({AnchorMod, :"test before the withdrawal"})

      in_worker(fn ->
        Process.put(@anchor_key, owner)
        H.hit([1512])
        Process.delete(@anchor_key)
        H.hit([1512, 1513])
      end)

      assert :ets.lookup(H.test_table(), {AnchorMod, :"test before the withdrawal", 1512}) ==
               [{{AnchorMod, :"test before the withdrawal", 1512}}]

      assert :ets.lookup(H.unlabeled_table(), 1512) == [{1512}]
      assert :ets.lookup(H.unlabeled_table(), 1513) == [{1513}]
      assert Process.alive?(owner)
    end

    test "an anchored process becomes unlabeled once the owner's test exits" do
      parent = self()
      owner = labeled_holder({AnchorMod, :"test exits first"})
      owner_ref = Process.monitor(owner)

      {worker, worker_ref} =
        spawn_monitor(fn ->
          Process.put(@anchor_key, owner)
          H.hit([1507])
          send(parent, :first_recorded)

          receive do
            :owner_exited -> H.hit([1507, 1508])
          end
        end)

      assert_receive :first_recorded
      assert :ets.lookup(H.unlabeled_table(), 1507) == []
      Process.exit(owner, :kill)
      assert_receive {:DOWN, ^owner_ref, :process, ^owner, _}
      send(worker, :owner_exited)
      assert_receive {:DOWN, ^worker_ref, :process, ^worker, :normal}

      assert :ets.lookup(H.unlabeled_table(), 1507) == [{1507}]
      assert :ets.lookup(H.unlabeled_table(), 1508) == [{1508}]
    end

    test "an anchor to a dead or remote pid, or a cycle of anchors, attributes nothing" do
      dead = spawn(fn -> :ok end)
      dead_ref = Process.monitor(dead)
      assert_receive {:DOWN, ^dead_ref, :process, ^dead, _}

      in_worker(fn ->
        Process.put(@anchor_key, dead)
        H.hit([1509])
      end)

      in_worker(fn ->
        Process.put(@anchor_key, remote_pid(self()))
        H.hit([1510])
      end)

      parent = self()

      a =
        spawn(fn ->
          receive do
            {:anchor, pid} -> Process.put(@anchor_key, pid)
          end

          send(parent, :anchored)
          Process.sleep(:infinity)
        end)

      b =
        spawn(fn ->
          Process.put(@anchor_key, a)
          send(parent, :anchored)
          Process.sleep(:infinity)
        end)

      send(a, {:anchor, b})
      assert_receive :anchored
      assert_receive :anchored
      on_exit(fn -> Enum.each([a, b], &Process.exit(&1, :kill)) end)

      in_worker(fn ->
        Process.put(@anchor_key, a)
        H.hit([1511])
      end)

      for id <- 1509..1511 do
        assert :ets.lookup(H.unlabeled_table(), id) == [{id}]
      end
    end
  end

  describe "dump/1 — serialising the tables to the dump file" do
    setup do
      dump =
        Mutare.Test.Project.tmp_dir(:cov_test) <> ".terms"

      System.put_env(H.dump_path_env(), dump)
      System.put_env(H.root_env(), File.cwd!())

      on_exit(fn ->
        System.delete_env(H.dump_path_env())
        System.delete_env(H.root_env())
        File.rm(dump)
      end)

      %{dump: dump}
    end

    test "maps an attributed id to its module's source file, relative to the root", %{dump: dump} do
      # A real, loadable module so `source_file/1` resolves a source, and a *lib* one no sibling
      # test attributes to, so this `by_file` key stays exclusively ours (the tables accumulate
      # across the file). Its beam records the absolute path it was compiled from, which a
      # narrowed self-hosted run seeds from the *original* checkout — so derive the root from
      # that source rather than assuming the cwd. What's under test is the relativising, not
      # which tree compiled the beam (NOTES "Self-hosting: a seeded beam records the original
      # checkout's path").
      mod = Mutare.Mutators.Arithmetic
      rel = "lib/mutare/mutators/arithmetic.ex"
      source = mod.module_info(:compile) |> Keyword.fetch!(:source) |> to_string()

      assert String.ends_with?(source, "/" <> rel)
      System.put_env(H.root_env(), String.replace_suffix(source, "/" <> rel, ""))

      :ets.insert(H.agg_table(), {501})
      :ets.insert(H.attr_table(), {{mod, 501}})

      H.dump(:ignored_suite_result)

      payload = dump |> File.read!() |> :erlang.binary_to_term()

      assert 501 in payload.aggregate[nil]
      assert payload.by_file[rel] == %{nil => [501]}
      assert is_map(payload.unlabeled)
    end

    test "serialises per-test names (by id) and the whole-file id set", %{dump: dump} do
      # `by_test` is built purely from the per-test table (keyed by id, module ignored) and
      # `wholefile` purely from the whole-file table — independent of `by_file`, so no attr/agg
      # inserts (they would pollute the shared, accumulate-only `by_file` a sibling test asserts on).
      :ets.insert(H.test_table(), {{FakeDumpMod, :"test halves", 511}})
      :ets.insert(H.test_table(), {{FakeDumpMod, :"test doubles", 511}})
      :ets.insert(H.wholefile_table(), {512})

      H.dump(:ignored_suite_result)

      payload = dump |> File.read!() |> :erlang.binary_to_term()

      # Names are strings (the `--only test:<name>` value), keyed by namespace, then mutant id.
      assert Enum.sort(payload.by_test[nil][511]) == ["test doubles", "test halves"]
      assert 512 in payload.wholefile[nil]
    end

    test "drops an id whose module cannot be loaded (source_file → nil)", %{dump: dump} do
      :ets.insert(H.agg_table(), {601})
      :ets.insert(H.attr_table(), {{:totally_unloadable_module_xyz, 601}})

      H.dump(:ignored_suite_result)

      payload = dump |> File.read!() |> :erlang.binary_to_term()

      # The unloadable module contributes no by_file entry, but its id is still in the aggregate.
      assert 601 in payload.aggregate[nil]
      refute Enum.any?(Map.values(payload.by_file), &(601 in Map.get(&1, nil, [])))
    end
  end

  # Run `DeepFixture.<entry>` in a bare spawn, hitting `ids` below more frames than the reported
  # stack holds — after checking that the reported stack really has lost the entry frame, so a
  # raised `backtrace_depth` cannot make these tests pass without the backtrace read.
  defp run_deep(entry, ids) do
    parent = self()
    frames = 100

    run_in(
      fn ->
        apply(DeepFixture, entry, [
          frames,
          fn ->
            {:current_stacktrace, stack} = Process.info(self(), :current_stacktrace)
            send(parent, {:reported, Enum.any?(stack, &match?({DeepFixture, ^entry, 2, _}, &1))})
            H.hit(ids)
          end
        ])
      end,
      label: nil
    )

    assert_received {:reported, false}
  end

  # Run `fun` in a fresh, unlabeled process and wait for it to finish.
  defp in_worker(fun) do
    {pid, ref} = spawn_monitor(fun)
    assert_receive {:DOWN, ^ref, :process, ^pid, :normal}
  end

  # A pid of another node, built by rewriting a local pid's external term format: the helper never
  # sends to it or reads it, so no such node need exist. The node atom is encoded as
  # SMALL_ATOM_UTF8_EXT (119) by default from OTP 26, as ATOM_EXT (100, two-byte length) before.
  defp remote_pid(pid) do
    rest =
      case :erlang.term_to_binary(pid) do
        <<131, 88, 119, len, _node::binary-size(len), rest::binary>> -> rest
        <<131, 88, 100, len::16, _node::binary-size(len), rest::binary>> -> rest
      end

    node = "nowhere@nohost"
    :erlang.binary_to_term(<<131, 88, 119, byte_size(node), node::binary, rest::binary>>)
  end

  # A live, labeled process to stand in a worker's `$callers` chain; killed on test exit.
  defp labeled_holder(label) do
    parent = self()

    holder =
      spawn(fn ->
        Process.set_label(label)
        send(parent, :holder_ready)
        Process.sleep(:infinity)
      end)

    assert_receive :holder_ready
    on_exit(fn -> Process.exit(holder, :kill) end)
    holder
  end

  # Run `fun` in a fresh process, optionally labeled, and block until it finishes. Returns the
  # value `fun` produced. A bare spawn (label: nil) has no `$process_label`, no `$callers`/
  # `$ancestors`, and no `__ex_unit__/2` frame — the unlabeled shape.
  defp run_in(fun, opts) do
    parent = self()
    label = Keyword.get(opts, :label)

    pid =
      spawn(fn ->
        if label, do: Process.set_label(label)
        send(parent, {:result, fun.()})
      end)

    ref = Process.monitor(pid)

    receive do
      {:result, value} ->
        receive do
          {:DOWN, ^ref, :process, ^pid, _} -> :ok
        end

        value
    end
  end
end
