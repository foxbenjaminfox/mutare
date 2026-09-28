# Mimics an ExUnit-*compiled* test module for the label-recovery regression tests below: a
# function named like an ExUnit test (`:"test …"`, the runtime-compiled shape the helper's
# stacktrace recovery keys on) and a plainly-named one that must NOT be mistaken for a test. The
# functions call the real coverage helper (`Mutare.Coverage.HelperTemplate`, the very source copied
# into every sandbox as `:mutare_cov`), so the test pins the code that actually runs there.
defmodule Mutare.CoverageTest.ExUnitFrameFixture do
  @moduledoc false

  # An ExUnit-named test body: a hit made from inside it carries a `{__MODULE__, :"test …", …}`
  # frame, so the helper attributes it even when the process has no `$process_label` (Elixir 1.18).
  # The `:ok` after the call keeps `hit/1` out of tail position so this frame survives on the stack
  # — exactly as the metamutant records (`hit(ids); <original expression>`, never a tail call).
  def unquote(:"test runs a body")(ids) do
    Mutare.Coverage.HelperTemplate.hit(ids)
    :ok
  end

  # A doctest body: ExUnit generates these as `:"doctest <module> (<n>)"` (a distinct prefix from
  # `test`), so doctest-heavy projects need their own recovery on Elixir 1.18.
  def unquote(:"doctest Mutare (1)")(ids) do
    Mutare.Coverage.HelperTemplate.hit(ids)
    :ok
  end

  # A test process blocked in `Task.await`: keeps its `:"test …"` frame on the stack until released,
  # so a *cross-process* stack read recovers it for an awaited `Task`'s otherwise-unlabeled hit.
  def unquote(:"test awaits a task")(parent, ref) do
    send(parent, {ref, :ready})

    receive do
      {^ref, :release} -> :ok
    end
  end

  # Not an ExUnit-named function (no `"test "`/`"property "` prefix), so a hit from here identifies
  # no owning test and must fall to the unlabeled bucket.
  def plain(ids), do: Mutare.Coverage.HelperTemplate.hit(ids)
end

defmodule Mutare.CoverageTest do
  use ExUnit.Case, async: false

  import ExUnit.CaptureLog, only: [capture_log: 1]

  alias Mutare.Coverage
  alias Mutare.Coverage.Recorder
  alias Mutare.Coverage.HelperTemplate, as: H

  # A well-formed dump with nothing recorded — every key the helper writes, each empty.
  defp empty_dump,
    do: %{aggregate: %{}, by_file: %{}, unlabeled: %{}, by_test: %{}, wholefile: %{}}

  describe "read_dump/1" do
    @tag :tmp_dir
    test "decodes the aggregate, per-file, unlabeled, per-test, and whole-file data into MapSets",
         %{tmp_dir: dir} do
      path = Path.join(dir, "dump.terms")

      # A standalone transform's integer ids, grouped under the `nil` namespace.
      payload = %{
        aggregate: %{nil => [1, 2, 3]},
        by_file: %{"test/a_test.exs" => %{nil => [1, 2]}, "test/b_test.exs" => %{nil => [3]}},
        unlabeled: %{nil => [2]},
        by_test: %{nil => %{1 => ["test alpha", "test beta"], 3 => ["test gamma"]}},
        wholefile: %{nil => [3]}
      }

      File.write!(path, :erlang.term_to_binary(payload))

      assert {:ok,
              %{
                aggregate: aggregate,
                by_file: by_file,
                unlabeled: unlabeled,
                by_test: by_test,
                wholefile: wholefile
              }} = Coverage.read_dump(path)

      assert aggregate == MapSet.new([1, 2, 3])
      assert by_file["test/a_test.exs"] == MapSet.new([1, 2])
      assert by_file["test/b_test.exs"] == MapSet.new([3])
      assert unlabeled == MapSet.new([2])
      assert by_test[1] == MapSet.new(["test alpha", "test beta"])
      assert by_test[3] == MapSet.new(["test gamma"])
      assert wholefile == MapSet.new([3])
    end

    @tag :tmp_dir
    test "errors (for run-all fallback) on a dump missing any of the five keys", %{tmp_dir: dir} do
      # The helper always writes all five (`Mutare.Coverage.Recorder`), so a missing key is a
      # malformed dump — not a partial capture to read as empty, which could mask lost
      # attribution behind a false survivor.
      for key <- Map.keys(empty_dump()) do
        path = Path.join(dir, "missing_#{key}.terms")
        File.write!(path, :erlang.term_to_binary(Map.delete(empty_dump(), key)))

        assert capture_log(fn ->
                 assert {:error, :bad_shape} = Coverage.read_dump(path),
                        "expected a dump without #{key} to degrade to :bad_shape"
               end) =~ "unexpected shape"
      end
    end

    @tag :tmp_dir
    test "errors (for run-all fallback) when :by_test/:wholefile are the wrong type",
         %{tmp_dir: dir} do
      for {label, extra} <- [
            {"by_test-not-a-map", %{by_test: [1, 2]}},
            {"wholefile-ungrouped", %{wholefile: [1]}}
          ] do
        path = Path.join(dir, "bad_new_key_#{label}.terms")
        payload = Map.merge(%{empty_dump() | aggregate: %{nil => [1]}}, extra)
        File.write!(path, :erlang.term_to_binary(payload))

        assert capture_log(fn ->
                 assert {:error, :bad_shape} = Coverage.read_dump(path)
               end) =~ "unexpected shape"
      end
    end

    @tag :tmp_dir
    test "errors (for run-all fallback) on a nested value of the wrong type", %{tmp_dir: dir} do
      # The outer map is well-formed, so only a check that descends *into* the collections
      # catches these. Un-checked, a non-enumerable value would raise `Protocol.UndefinedError`
      # out of `read_dump/1`, and a non-string would reach `mix test` argv — either way an
      # exception instead of the documented run-all fallback.
      ok = %{nil => [1]}

      for {label, fields} <- [
            {"aggregate-ungrouped", %{aggregate: [1]}},
            {"namespace-empty", %{aggregate: %{"" => [1]}}},
            {"namespace-not-a-string", %{aggregate: %{lib: [1]}}},
            {"group-not-a-list", %{aggregate: %{nil => :not_a_list}}},
            {"by_file-value-ungrouped", %{aggregate: ok, by_file: %{"test/a_test.exs" => [1]}}},
            {"by_test-value-not-a-map", %{aggregate: ok, by_test: %{nil => [1]}}},
            {"by_test-names-not-a-list", %{aggregate: ok, by_test: %{nil => %{1 => :nope}}}},
            {"by_file-key-not-a-string", %{aggregate: ok, by_file: %{:atom_key => ok}}},
            {"by_test-name-not-a-string",
             %{aggregate: ok, by_test: %{nil => %{1 => [:atom_name]}}}},
            {"by_test-key-not-an-id", %{aggregate: ok, by_test: %{nil => %{"1" => ["t"]}}}},
            {"aggregate-element-not-an-id", %{aggregate: %{nil => [:a, {:b}]}}},
            {"id-not-positive", %{aggregate: %{nil => [0]}}},
            {"unlabeled-element-not-an-id", %{aggregate: ok, unlabeled: %{nil => ["x"]}}},
            {"wholefile-element-not-an-id", %{aggregate: ok, wholefile: %{nil => [nil]}}},
            {"by_file-nested-id-not-an-id",
             %{aggregate: ok, by_file: %{"test/a_test.exs" => %{nil => [1, :two]}}}},
            {"by_file-is-a-struct", %{aggregate: ok, by_file: MapSet.new([1])}}
          ] do
        path = Path.join(dir, "nested_#{label}.terms")
        File.write!(path, :erlang.term_to_binary(Map.merge(empty_dump(), fields)))

        assert capture_log(fn ->
                 assert {:error, :bad_shape} = Coverage.read_dump(path),
                        "expected #{label} to degrade to :bad_shape"
               end) =~ "unexpected shape"
      end
    end

    @tag :tmp_dir
    test "errors (for run-all fallback) on a missing dump", %{tmp_dir: dir} do
      assert capture_log(fn ->
               assert {:error, _} = Coverage.read_dump(Path.join(dir, "absent.terms"))
             end) =~ "falling back to run-all"
    end

    @tag :tmp_dir
    test "errors (for run-all fallback) on a garbled dump", %{tmp_dir: dir} do
      path = Path.join(dir, "garbage.terms")
      File.write!(path, "this is not an erlang term")

      assert capture_log(fn -> assert {:error, _} = Coverage.read_dump(path) end) =~
               "falling back to run-all"
    end

    @tag :tmp_dir
    test "errors (for run-all fallback) on a valid term of the wrong shape", %{tmp_dir: dir} do
      # A payload that deserializes cleanly but isn't the expected map must degrade, not crash
      # the `with` (a non-map term, or a map missing `:aggregate`/`:by_file`, used to fall
      # through every `else` clause and raise `CaseClauseError`).
      for {label, term} <- [
            {"atom", :nonsense},
            {"list", [1, 2, 3]},
            {"map-missing-keys", %{aggregate: %{nil => [1]}, by_file: %{}}}
          ] do
        path = Path.join(dir, "wrong_shape_#{label}.terms")
        File.write!(path, :erlang.term_to_binary(term))

        assert capture_log(fn ->
                 assert {:error, :bad_shape} = Coverage.read_dump(path)
               end) =~ "unexpected shape"
      end
    end
  end

  describe "fixture_module/0 (self-hosting: the stand-in cedes :mutare_cov)" do
    # The env var is process-global and this very suite runs under dogfooding (where
    # `Mutare.Sandbox.Command` sets the override), so save/restore it rather than
    # blindly clearing — same discipline as `selector_test`'s key override.
    setup do
      saved = System.get_env(Recorder.fixture_override_env())

      on_exit(fn ->
        case saved do
          nil -> System.delete_env(Recorder.fixture_override_env())
          value -> System.put_env(Recorder.fixture_override_env(), value)
        end
      end)
    end

    test "is helper_module/0 unless MUTARE_COV_FIXTURE_MODULE overrides it" do
      # The twin of the selection-key split: the real helper the sandbox writes keeps
      # `:mutare_cov`; only Mutare's own `test/support/mutare_cov.ex` stand-in reads
      # this override, so under dogfooding it cedes `:mutare_cov` to the real helper
      # (whose `dump/1` the probe's `after_suite` needs). See NOTES "Self-hosting:
      # the coverage helper module clashes with its test stand-in".
      System.delete_env(Recorder.fixture_override_env())
      assert Recorder.fixture_module() == Recorder.helper_module()
      assert Recorder.track_key() == Recorder.runtime(:harness).track_key

      System.put_env(Recorder.fixture_override_env(), Recorder.suite_fixture_module())
      assert Recorder.fixture_module() == String.to_atom(Recorder.suite_fixture_module())
      assert Recorder.track_key() == Recorder.runtime(:fixture).track_key
      assert Recorder.record?(Recorder.record_ast([1]))

      System.put_env(Recorder.fixture_override_env(), "Elixir.CoverageFixture.Helper")
      rendered = Recorder.record_ast([1], :mutare_active_1) |> Sourceror.to_string()
      assert Recorder.record?(Sourceror.parse_string!(rendered))

      # Blank is treated as unset (the same empty-string rule the selector key uses).
      System.put_env(Recorder.fixture_override_env(), "")
      assert Recorder.fixture_module() == Recorder.helper_module()
    end
  end

  describe "tables_ast/1 (umbrella shares one BEAM)" do
    test "creating the coverage tables twice is a no-op, not a :badarg" do
      # Fixture state stays separate from the outer dogfood probe. Preserve prior
      # fixture state too, since this test deliberately initializes it twice.
      saved_env = System.get_env(Recorder.runtime(:fixture).env_var)
      saved_track = :persistent_term.get(Recorder.runtime(:fixture).track_key, :unset)
      saved_mode = :persistent_term.get(Recorder.runtime(:fixture).mode_key, :unset)
      agg_existed? = :ets.whereis(H.agg_table()) != :undefined
      attr_existed? = :ets.whereis(H.attr_table()) != :undefined
      unlabeled_existed? = :ets.whereis(H.unlabeled_table()) != :undefined

      System.put_env(Recorder.runtime(:fixture).env_var, "1")

      on_exit(fn ->
        restore_env(Recorder.runtime(:fixture).env_var, saved_env)
        restore_track(saved_track)
        key = Recorder.runtime(:fixture).mode_key

        if saved_mode == :unset,
          do: :persistent_term.erase(key),
          else: :persistent_term.put(key, saved_mode)

        drop_table_unless(H.agg_table(), agg_existed?)
        drop_table_unless(H.attr_table(), attr_existed?)
        drop_table_unless(H.unlabeled_table(), unlabeled_existed?)
      end)

      :persistent_term.erase(Recorder.runtime(:fixture).mode_key)
      Code.eval_quoted(Recorder.mode_ast(:fixture))
      System.delete_env(Recorder.runtime(:fixture).env_var)
      Code.eval_quoted(Recorder.mode_ast(:fixture))
      ast = Recorder.tables_ast(:fixture)

      # Two apps' test helpers evaluate this in the same VM; without the
      # create-once guard the second :ets.new would raise :badarg.
      assert {_, _} = Code.eval_quoted(ast)
      assert {_, _} = Code.eval_quoted(ast)
      assert :ets.whereis(H.agg_table()) != :undefined
      assert :ets.whereis(H.unlabeled_table()) != :undefined
    end

    test "a record is a no-op (not a crash) when the aggregate table is absent" do
      assert :ets.whereis(H.agg_table()) == :undefined
      assert Mutare.Coverage.HelperTemplate.hit([123_456]) == true
    end
  end

  # The owning test *file* is recovered from the process label ExUnit sets — but its runner only
  # started doing that in Elixir 1.19. On **Elixir 1.18** the test process is unlabeled, so the
  # helper falls back to an ExUnit frame on the stack (a `:"test …"` body, a `setup_all`'s
  # `__ex_unit__/2`, or an awaiting `Task` caller's frame). Without that fallback, every direct
  # test's coverage lands in the unlabeled bucket → every mutant runs the whole suite (no per-file
  # selection at all). These exercise the recovery *directly*, so the regression is caught on any
  # host Elixir — the end-to-end selection tests only surface it when the *sandbox* runs 1.18 (CI's
  # 1.18 lane). `hit/1` records into the shared, process-global ETS tables, so — like the table
  # test above — we restore the prior state exactly and use ids no real mutant can own.
  describe "label recovery without a `$process_label` (Elixir 1.18)" do
    @attr_id 999_999_001
    @unlabeled_id 999_999_002
    @fixture Mutare.CoverageTest.ExUnitFrameFixture

    setup do
      pre =
        Map.new(
          [
            H.agg_table(),
            H.attr_table(),
            H.unlabeled_table(),
            H.test_table(),
            H.wholefile_table()
          ],
          &{&1, table?(&1)}
        )

      Enum.each(Map.keys(pre), &ensure_table/1)

      on_exit(fn ->
        # Drop our probe ids first (they may live in a table the bootstrap owns under dogfooding),
        # then drop only the tables this test created. A concrete-named fixture records @attr_id to
        # the per-test table (module ignored in the match), so clear it by id.
        delete_key(H.agg_table(), @attr_id)
        delete_key(H.agg_table(), @unlabeled_id)
        delete_key(H.unlabeled_table(), @unlabeled_id)
        delete_key(H.attr_table(), {@fixture, @attr_id})
        match_delete(H.test_table(), {{:_, :_, @attr_id}})
        match_delete(H.wholefile_table(), {@attr_id})
        Enum.each(pre, fn {table, existed?} -> drop_table_unless(table, existed?) end)
      end)

      :ok
    end

    test "an unlabeled process attributes its hit to the ExUnit test frame on its stack" do
      in_unlabeled_process(fn -> apply(@fixture, :"test runs a body", [[@attr_id]]) end)

      assert :ets.member(H.attr_table(), {@fixture, @attr_id})
      refute :ets.member(H.unlabeled_table(), @attr_id)
    end

    test "an unlabeled process attributes a doctest body's hit to its module" do
      in_unlabeled_process(fn -> apply(@fixture, :"doctest Mutare (1)", [[@attr_id]]) end)

      assert :ets.member(H.attr_table(), {@fixture, @attr_id})
      refute :ets.member(H.unlabeled_table(), @attr_id)
    end

    test "an unlabeled Task attributes its hit to its awaiting test caller's frame" do
      ref = make_ref()
      parent = self()
      holder = spawn(fn -> apply(@fixture, :"test awaits a task", [parent, ref]) end)
      assert_receive {^ref, :ready}

      # The Task: unlabeled, with `$callers` pointing at the awaiting test (as `Task` sets it).
      in_unlabeled_process(fn ->
        Process.put(:"$callers", [holder])
        Mutare.Coverage.HelperTemplate.hit([@attr_id])
      end)

      send(holder, {ref, :release})
      assert :ets.member(H.attr_table(), {@fixture, @attr_id})
      refute :ets.member(H.unlabeled_table(), @attr_id)
    end

    test "an unlabeled process with no ExUnit frame and no callers stays unlabeled" do
      in_unlabeled_process(fn -> apply(@fixture, :plain, [[@unlabeled_id]]) end)

      assert :ets.member(H.unlabeled_table(), @unlabeled_id)
      refute :ets.member(H.attr_table(), {@fixture, @unlabeled_id})
    end
  end

  defp table?(name), do: :ets.whereis(name) != :undefined

  defp ensure_table(name) do
    unless table?(name), do: :ets.new(name, [:named_table, :public, :set])
    :ok
  end

  defp delete_key(table, key) do
    with_table(table, &:ets.delete(&1, key))
  end

  defp match_delete(table, pattern) do
    with_table(table, &:ets.match_delete(&1, pattern))
  end

  defp with_table(table, fun) do
    case :ets.whereis(table) do
      :undefined ->
        :ok

      tid ->
        try do
          fun.(tid)
          :ok
        rescue
          error in ArgumentError ->
            if :ets.info(tid) == :undefined do
              :ok
            else
              reraise error, __STACKTRACE__
            end
        end
    end
  end

  # Run `fun` in a fresh process and wait for it to finish. A raw `spawn` inherits no
  # `$process_label`, `$callers`, or `$ancestors` — exactly an Elixir 1.18 test process — so each
  # test controls precisely which recovery signal (if any) is present.
  defp in_unlabeled_process(fun) do
    parent = self()
    ref = make_ref()

    spawn(fn ->
      fun.()
      send(parent, {ref, :done})
    end)

    receive do
      {^ref, :done} -> :ok
    after
      2_000 -> flunk("unlabeled worker did not finish")
    end
  end

  defp restore_env(var, nil), do: System.delete_env(var)
  defp restore_env(var, value), do: System.put_env(var, value)

  defp restore_track(:unset), do: :persistent_term.erase(Recorder.runtime(:fixture).track_key)
  defp restore_track(value), do: :persistent_term.put(Recorder.runtime(:fixture).track_key, value)

  # Drop a coverage table only if this test created it; leave a pre-existing one
  # (under the probe, the bootstrap owns it and later tests still record into it).
  defp drop_table_unless(_table, true = _pre_existed), do: :ok

  defp drop_table_unless(table, false) do
    with_table(table, &:ets.delete/1)
  end

  describe "record_ast/1 (ids render as a list, never a charlist)" do
    # A bare list of small integers renders as a charlist (`[91, 92]` → `~c"[\\"`),
    # and such a charlist can splice an unbalanced quote/backslash into the
    # metamutant and break its re-parse (the real plug failure). The ids must
    # always render as a list literal.
    test "dangerous ids ([, \\, \") stay a list literal and re-parse cleanly" do
      for ids <- [[91, 92], [34, 92], [9, 10], [1, 2, 3], [123, 456]] do
        rendered = Sourceror.to_string(Recorder.record_ast(ids))

        # `inspect/1` itself charlists a small-int list — force a list rendering.
        as_list = inspect(ids, charlists: :as_lists)

        refute rendered =~ "~c", "ids #{as_list} rendered as a charlist: #{rendered}"
        assert rendered =~ "hit(#{as_list})"
        assert {:ok, _} = Sourceror.parse_string(rendered)
      end
    end
  end
end
