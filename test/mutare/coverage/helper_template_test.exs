defmodule Mutare.Coverage.HelperTemplateTest do
  # The coverage helper is a real, compiled module (`Mutare.Coverage.HelperTemplate`) whose
  # *source* is copied verbatim into each sandbox as `:mutare_cov` — so in a normal run its
  # `hit/1`/`dump/1` logic only ever executes inside the sandbox subprocess, never in Mutare's
  # own VM. These tests exercise that logic directly against the shared ETS tables it owns, so
  # a regression in the recording/attribution tiers is caught in Mutare's own suite rather than
  # only when a sandbox runs. Named global ETS tables ⇒ `async: false`.
  #
  # `:coverage_tables` excludes the whole module under self-hosting: its `setup_all`
  # `:ets.delete`s and recreates the `:mutare_cov_*` tables (and writes small, real-id-range
  # markers) — under a dogfood run those are the *same* tables the coverage probe records into,
  # so running it would wipe the probe's data and silently force run-all selection. See
  # `test/test_helper.exs` and NOTES "Self-hosting".
  use ExUnit.Case, async: false
  @moduletag :coverage_tables

  alias Mutare.Coverage.HelperTemplate, as: H

  # Tables are created once and owned by the (module-lifetime) setup_all process, so they
  # survive across every test. `hit([777])` here runs *inside* `__ex_unit__/2`, exercising the
  # `setup_all` stacktrace-recovery tier (tier 3 of `label/0`).
  setup_all do
    for t <- [H.agg_table(), H.attr_table(), H.unlabeled_table()] do
      if :ets.whereis(t) != :undefined, do: :ets.delete(t)
      :ets.new(t, [:named_table, :public, :set])
    end

    H.hit([777])
    :ok
  end

  describe "contract-constant accessors" do
    test "expose the table names, dump file, and env-var keys" do
      assert H.agg_table() == :mutare_cov_agg
      assert H.attr_table() == :mutare_cov_attr
      assert H.unlabeled_table() == :mutare_cov_unlabeled
      assert H.dump_file() == "mutare_cov.terms"
      assert H.dump_path_env() == "MUTARE_COV_DUMP"
      assert H.root_env() == "MUTARE_COV_ROOT"
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

    test "a setup_all-recovered id is attributed to its own module's file (tier 3)" do
      # `hit([777])` ran in setup_all (above), whose process is unlabeled and caller-less but
      # executes within this module's generated `__ex_unit__/2` dispatch — so the owning module
      # is on the stack and recovered there.
      assert :ets.lookup(H.attr_table(), {__MODULE__, 777}) == [{{__MODULE__, 777}}]
      assert :ets.lookup(H.agg_table(), 777) == [{777}]
    end

    test "hit/1 tracks ids seen by the current process" do
      # Coverage is set-like. The helper records an id once per process and then returns early for
      # repeated hits, keeping the probe closer to target timing in hot loops.
      tid = :ets.whereis(H.agg_table())

      H.hit([701])
      H.hit([701, 702])

      assert {^tid, seen} = Process.get(:mutare_cov_seen)
      assert Map.has_key?(seen, 701)
      assert Map.has_key?(seen, 702)
      assert Map.has_key?(seen[701], {:labeled, __MODULE__})
      assert Map.has_key?(seen[702], {:labeled, __MODULE__})
      assert :ets.lookup(H.agg_table(), 701) == [{701}]
      assert :ets.lookup(H.agg_table(), 702) == [{702}]
    end
  end

  describe "dump/1 — serialising the tables to the dump file" do
    setup do
      dump =
        Path.join(
          System.tmp_dir!(),
          "mutare_cov_test_#{System.unique_integer([:positive])}.terms"
        )

      System.put_env("MUTARE_COV_DUMP", dump)
      System.put_env("MUTARE_COV_ROOT", File.cwd!())

      on_exit(fn ->
        System.delete_env("MUTARE_COV_DUMP")
        System.delete_env("MUTARE_COV_ROOT")
        File.rm(dump)
      end)

      %{dump: dump}
    end

    test "maps an attributed id to its module's source file, relative to the root", %{dump: dump} do
      # A real, loadable module so `source_file/1` resolves a source.
      mod = Mutare.Mutators.Arithmetic
      :ets.insert(H.agg_table(), {501})
      :ets.insert(H.attr_table(), {{mod, 501}})

      H.dump(:ignored_suite_result)

      payload = dump |> File.read!() |> :erlang.binary_to_term()

      assert 501 in payload.aggregate
      assert payload.by_file["lib/mutare/mutators/arithmetic.ex"] == [501]
      assert is_list(payload.unlabeled)
    end

    test "drops an id whose module cannot be loaded (source_file → nil)", %{dump: dump} do
      :ets.insert(H.agg_table(), {601})
      :ets.insert(H.attr_table(), {{:totally_unloadable_module_xyz, 601}})

      H.dump(:ignored_suite_result)

      payload = dump |> File.read!() |> :erlang.binary_to_term()

      # The unloadable module contributes no by_file entry, but its id is still in the aggregate.
      assert 601 in payload.aggregate
      refute payload.by_file |> Map.values() |> List.flatten() |> Enum.member?(601)
    end
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
