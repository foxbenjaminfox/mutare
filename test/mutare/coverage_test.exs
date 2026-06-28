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

  alias Mutare.{Coverage, Result}
  alias Mutare.Coverage.Recorder
  alias Mutare.Test.Project

  @moduletag timeout: 180_000

  # Pin the end-to-end runs to the operator-swap families: these tests assert
  # coverage classification and test-file selection, not mutant volume, so the
  # higher-volume default mutators (literals) are excluded for determinism/speed.
  @probe [Mutare.Mutators.Arithmetic, Mutare.Mutators.Relational]

  describe "read_dump/1" do
    @tag :tmp_dir
    test "decodes the aggregate, per-file, and unlabeled id lists into MapSets", %{tmp_dir: dir} do
      path = Path.join(dir, "dump.terms")

      payload = %{
        aggregate: [1, 2, 3],
        by_file: %{"test/a_test.exs" => [1, 2], "test/b_test.exs" => [3]},
        unlabeled: [2]
      }

      File.write!(path, :erlang.term_to_binary(payload))

      assert {:ok, %{aggregate: aggregate, by_file: by_file, unlabeled: unlabeled}} =
               Coverage.read_dump(path)

      assert aggregate == MapSet.new([1, 2, 3])
      assert by_file["test/a_test.exs"] == MapSet.new([1, 2])
      assert by_file["test/b_test.exs"] == MapSet.new([3])
      assert unlabeled == MapSet.new([2])
    end

    @tag :tmp_dir
    test "tolerates a dump without an :unlabeled key (defaults to empty)", %{tmp_dir: dir} do
      path = Path.join(dir, "legacy.terms")
      File.write!(path, :erlang.term_to_binary(%{aggregate: [1], by_file: %{}}))

      assert {:ok, %{unlabeled: unlabeled}} = Coverage.read_dump(path)
      assert unlabeled == MapSet.new([])
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
            {"map-missing-keys", %{aggregate: [1]}}
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

      System.put_env(Recorder.fixture_override_env(), Recorder.suite_fixture_module())
      assert Recorder.fixture_module() == String.to_atom(Recorder.suite_fixture_module())

      # Blank is treated as unset (the same empty-string rule the selector key uses).
      System.put_env(Recorder.fixture_override_env(), "")
      assert Recorder.fixture_module() == Recorder.helper_module()
    end
  end

  describe "setup_ast/0 (umbrella shares one BEAM)" do
    test "creating the coverage tables twice is a no-op, not a :badarg" do
      # These coverage tables, the tracking flag, and the env var are all
      # process-global, and this very suite runs *under the probe* when dogfooding —
      # where the bootstrap has already created the tables and set the flag/env, and
      # the metamutant records into them across the whole suite. Tearing down what we
      # didn't create would suppress coverage for every later test (a spurious
      # run-all). So restore exactly the prior state — only undo what this test
      # introduced — the same discipline as `selector_test`'s key override.
      saved_env = System.get_env(Recorder.env_var())
      saved_track = :persistent_term.get(Recorder.track_key(), :unset)
      agg_existed? = :ets.whereis(:mutare_cov_agg) != :undefined
      attr_existed? = :ets.whereis(:mutare_cov_attr) != :undefined
      unlabeled_existed? = :ets.whereis(:mutare_cov_unlabeled) != :undefined

      System.put_env(Recorder.env_var(), "1")

      on_exit(fn ->
        restore_env(Recorder.env_var(), saved_env)
        restore_track(saved_track)
        drop_table_unless(:mutare_cov_agg, agg_existed?)
        drop_table_unless(:mutare_cov_attr, attr_existed?)
        drop_table_unless(:mutare_cov_unlabeled, unlabeled_existed?)
      end)

      ast = Recorder.setup_ast()

      # Two apps' test helpers evaluate this in the same VM; without the
      # create-once guard the second :ets.new would raise :badarg.
      assert {_, _} = Code.eval_quoted(ast)
      assert {_, _} = Code.eval_quoted(ast)
      assert :ets.whereis(:mutare_cov_agg) != :undefined
      assert :ets.whereis(:mutare_cov_unlabeled) != :undefined
    end

    test "a record is a no-op (not a crash) when the aggregate table is absent" do
      # The self-hosting trap: mutation-testing Mutare *with Mutare* runs its own coverage
      # tests (which create and tear down these process-global tables) against a metamutant
      # of Mutare's lib that records into the *same* names. A test that opens the gate and
      # then exits — its process-owned table dying with it — would otherwise leave a later
      # instrumented line (even its own `on_exit`) to `:ets.insert` into a vanished table and
      # crash, cascading across the suite. `hit/1` must skip when the table is gone. Leaving
      # the tables dropped is safe: every other coverage test recreates what it needs.
      for t <- [:mutare_cov_agg, :mutare_cov_attr, :mutare_cov_unlabeled],
          table?(t),
          do: :ets.delete(t)

      refute table?(:mutare_cov_agg)
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
      pre = Map.new([:mutare_cov_agg, :mutare_cov_attr, :mutare_cov_unlabeled], &{&1, table?(&1)})
      Enum.each(Map.keys(pre), &ensure_table/1)

      on_exit(fn ->
        # Drop our probe ids first (they may live in a table the bootstrap owns under dogfooding),
        # then drop only the tables this test created.
        delete_key(:mutare_cov_agg, @attr_id)
        delete_key(:mutare_cov_agg, @unlabeled_id)
        delete_key(:mutare_cov_unlabeled, @unlabeled_id)
        delete_key(:mutare_cov_attr, {@fixture, @attr_id})
        Enum.each(pre, fn {table, existed?} -> drop_table_unless(table, existed?) end)
      end)

      :ok
    end

    test "an unlabeled process attributes its hit to the ExUnit test frame on its stack" do
      in_unlabeled_process(fn -> apply(@fixture, :"test runs a body", [[@attr_id]]) end)

      assert :ets.member(:mutare_cov_attr, {@fixture, @attr_id})
      refute :ets.member(:mutare_cov_unlabeled, @attr_id)
    end

    test "an unlabeled process attributes a doctest body's hit to its module" do
      in_unlabeled_process(fn -> apply(@fixture, :"doctest Mutare (1)", [[@attr_id]]) end)

      assert :ets.member(:mutare_cov_attr, {@fixture, @attr_id})
      refute :ets.member(:mutare_cov_unlabeled, @attr_id)
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
      assert :ets.member(:mutare_cov_attr, {@fixture, @attr_id})
      refute :ets.member(:mutare_cov_unlabeled, @attr_id)
    end

    test "an unlabeled process with no ExUnit frame and no callers stays unlabeled" do
      in_unlabeled_process(fn -> apply(@fixture, :plain, [[@unlabeled_id]]) end)

      assert :ets.member(:mutare_cov_unlabeled, @unlabeled_id)
      refute :ets.member(:mutare_cov_attr, {@fixture, @unlabeled_id})
    end
  end

  defp table?(name), do: :ets.whereis(name) != :undefined

  defp ensure_table(name) do
    unless table?(name), do: :ets.new(name, [:named_table, :public, :set])
    :ok
  end

  defp delete_key(table, key) do
    if table?(table), do: :ets.delete(table, key)
    :ok
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

  defp restore_track(:unset), do: :persistent_term.erase(Recorder.track_key())
  defp restore_track(value), do: :persistent_term.put(Recorder.track_key(), value)

  # Drop a coverage table only if this test created it; leave a pre-existing one
  # (under the probe, the bootstrap owns it and later tests still record into it).
  defp drop_table_unless(_table, true = _pre_existed), do: :ok

  defp drop_table_unless(table, false) do
    if :ets.whereis(table) != :undefined, do: :ets.delete(table)
    :ok
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

  describe "no-coverage skipping (end to end)" do
    @tag :runner
    test "a mutant on an unexecuted line is :no_coverage and is not run" do
      %{project: project, sandbox: sandbox} =
        Project.build(:cov, %{
          "lib/cov.ex" => """
          defmodule Cov do
            def classify(x) do
              if x > 0 do
                x + 1
              else
                x - 1
              end
            end
          end
          """,
          "test/cov_test.exs" => """
          defmodule CovTest do
            use ExUnit.Case

            # Only the positive branch is ever exercised.
            test "classify positive" do
              assert Cov.classify(5) == 6
            end
          end
          """
        })

      assert {:ok, run} = Mutare.run(project, sandbox: sandbox, mutators: @probe)

      by_op = Map.new(run.results, &{&1.site.original_form, &1})

      # `x - 1` lives in the else branch, which no test executes → skipped.
      assert %Result{status: :no_coverage, duration_ms: 0, output: nil} = by_op[:-]

      # `x + 1` is in the executed then-branch → actually run (and killed here).
      assert by_op[:+].status == :killed

      # no-coverage mutants are excluded from the denominator
      assert Enum.count(run.results, &(&1.status == :no_coverage)) == 1
    end

    @tag :runner
    test "a covered mutant in a relative nested module is run" do
      %{project: project, sandbox: sandbox} =
        Project.build(:nested, %{
          "lib/outer.ex" => """
          defmodule Outer do
            defmodule Inner do
              def add(a, b), do: a + b
            end
          end
          """,
          "test/outer_test.exs" => """
          defmodule OuterTest do
            use ExUnit.Case
            test "nested add", do: assert(Outer.Inner.add(2, 3) == 5)
          end
          """
        })

      assert {:ok, run} = Mutare.run(project, sandbox: sandbox, mutators: @probe)
      assert [%Result{status: :killed}] = run.results
    end

    @tag :runner
    test "coverage tracking includes code reached from test_helper setup" do
      %{project: project, sandbox: sandbox} =
        Project.build(:helper_cov, %{
          "lib/startup.ex" => """
          defmodule Startup do
            def touch, do: 1 + 1
          end
          """,
          "test/test_helper.exs" => """
          Startup.touch()
          ExUnit.start()
          """,
          "test/startup_test.exs" => """
          defmodule StartupTest do
            use ExUnit.Case
            test "unrelated green test", do: assert(true)
          end
          """
        })

      assert {:ok, run} =
               Mutare.run(project, sandbox: sandbox, mutators: [Mutare.Mutators.Arithmetic])

      # The only execution of Startup.touch/0 happens in test_helper.exs before
      # any test process is labeled. That is covered-but-unattributed, so it must
      # run the whole suite rather than being skipped as :no_coverage.
      assert [%Result{status: :survived, duration_ms: ms, output: output}] = run.results
      assert ms > 0
      assert output =~ "1 test"
    end

    @tag :runner
    test "a target lib/mutare_cov.ex is preserved and can still host mutants" do
      %{project: project, sandbox: sandbox} =
        Project.build(:cov_name_collision, %{
          "lib/mutare_cov.ex" => """
          defmodule MutareCov do
            def value, do: 40 + 2
          end
          """,
          "test/mutare_cov_test.exs" => """
          defmodule MutareCovTest do
            use ExUnit.Case
            test "value", do: assert(MutareCov.value() == 42)
          end
          """
        })

      assert {:ok, run} =
               Mutare.run(project, sandbox: sandbox, mutators: [Mutare.Mutators.Arithmetic])

      assert [%Result{status: :killed}] = run.results
      assert File.read!(Path.join(sandbox, "lib/mutare_cov.ex")) =~ "def value"
      assert File.regular?(Path.join(sandbox, "lib/__mutare__/coverage_helper.ex"))
    end
  end

  describe "test-file selection (end to end)" do
    @tag :runner
    test "a mutant runs only the test files that cover it" do
      %{project: project, sandbox: sandbox} =
        Project.build(:sel, %{
          "lib/calc.ex" => "defmodule Calc do\n  def add(a, b), do: a + b\nend\n",
          "lib/greeter.ex" => "defmodule Greeter do\n  def shout(n), do: n * 2\nend\n",
          "test/calc_test.exs" => """
          defmodule CalcTest do
            use ExUnit.Case
            test "add", do: assert(Calc.add(2, 3) == 5)
          end
          """,
          "test/greeter_test.exs" => """
          defmodule GreeterTest do
            use ExUnit.Case
            test "shout", do: assert(Greeter.shout(3) == 6)
          end
          """
        })

      assert {:ok, run} = Mutare.run(project, sandbox: sandbox, mutators: @probe)

      by_op = Map.new(run.results, &{&1.site.original_form, &1})

      # Calc.add's `+` mutant is covered only by calc_test.exs → that file alone
      # runs (1 test), not the whole 2-test suite — and it's killed.
      calc = by_op[:+]
      assert calc.status == :killed
      assert calc.output =~ "1 test"
      refute calc.output =~ "2 tests"

      # Greeter.shout's `*` mutant likewise runs only greeter_test.exs, killed.
      greeter = by_op[:*]
      assert greeter.status == :killed
      assert greeter.output =~ "1 test"
    end

    @tag :runner
    test "a mutant covered via another file's setup_all is attributed to both files (no false survivor)" do
      %{project: project, sandbox: sandbox} =
        Project.build(:setup_all_cov, %{
          "lib/shared.ex" => "defmodule Shared do\n  def calc(x), do: x + 1\nend\n",
          # This file *touches the line* in its test body, so the id is attributed
          # here — but the test asserts nothing about the value, so it can never kill
          # the mutant. Under the old "attributed file wins" rule this masked the
          # killing file below and produced a false survivor.
          "test/touch_test.exs" => """
          defmodule TouchTest do
            use ExUnit.Case
            test "touches Shared.calc without asserting its value" do
              _ = Shared.calc(5)
              assert true
            end
          end
          """,
          # The killing test reaches Shared.calc only through `setup_all`. That runs
          # in an unlabeled process, but inside this module's `__ex_unit__/2`
          # dispatch, so the id is attributed to setup_all_test.exs via the
          # stacktrace recovery — the only test that distinguishes the mutation.
          "test/setup_all_test.exs" => """
          defmodule SetupAllTest do
            use ExUnit.Case
            setup_all do
              %{value: Shared.calc(5)}
            end
            test "asserts the exact value", %{value: value} do
              assert value == 6
            end
          end
          """
        })

      assert {:ok, run} = Mutare.run(project, sandbox: sandbox, mutators: @probe)

      # Every `+` mutant is killed (not a false survivor). Both files attribute the
      # id — touch_test.exs via its body, setup_all_test.exs via the `__ex_unit__/2`
      # stacktrace recovery — so the run includes the killing file. Here the two
      # covering files happen to be the whole 2-file suite.
      assert run.results != []
      assert Enum.all?(run.results, &(&1.status == :killed))

      # The kill is driven by setup_all_test's `assert value == 6` (touch_test asserts
      # nothing it could fail on), so a killed mutant proves the recovery-attributed
      # killing file was selected and run — touch_test's body attribution did not mask
      # it. We do *not* assert the subprocess test *count* ("2 tests"): the runner forces
      # `--max-failures 1` (`Mutare.Sandbox.Command`), so when ExUnit happens to run the
      # failing setup_all_test before touch_test the suite aborts after one test, making
      # the count order-dependent. The kill (and its source below) is not.
      assert Enum.all?(run.results, &(&1.output =~ "value == 6"))
    end

    @tag :runner
    test "a mutant covered only via setup_all is attributed to its own file (not the whole suite)" do
      %{project: project, sandbox: sandbox} =
        Project.build(:setup_all_only_cov, %{
          "lib/shared.ex" => "defmodule Shared do\n  def calc(x), do: x + 1\nend\n",
          # The mutated line runs only through this module's `setup_all`. The
          # `__ex_unit__/2` stacktrace recovery attributes it to setup_all_test.exs,
          # so selection runs *only* this file — not the whole suite — and its own
          # test (which asserts the setup_all value) still kills the mutant.
          "test/setup_all_test.exs" => """
          defmodule SetupAllOnlyTest do
            use ExUnit.Case
            setup_all do
              %{value: Shared.calc(5)}
            end
            test "asserts the exact value", %{value: value} do
              assert value == 6
            end
          end
          """,
          # An unrelated file that never touches the line. Before the recovery the id
          # was unlabeled → whole suite, so this file would have run too (2 tests).
          "test/idle_test.exs" => """
          defmodule IdleTest do
            use ExUnit.Case
            test "unrelated", do: assert(true)
          end
          """
        })

      assert {:ok, run} = Mutare.run(project, sandbox: sandbox, mutators: @probe)

      assert run.results != []
      assert Enum.all?(run.results, &(&1.status == :killed))
      # Tight selection: only setup_all_test.exs runs (1 test), not the idle file.
      assert Enum.all?(run.results, &(&1.output =~ "1 test"))
      refute Enum.any?(run.results, &(&1.output =~ "2 tests"))
    end

    @tag :runner
    test "a mutant covered only via a spawned Task is attributed to the spawning test's file" do
      %{project: project, sandbox: sandbox} =
        Project.build(:task_cov, %{
          "lib/worker.ex" => "defmodule Worker do\n  def work(x), do: x + 1\nend\n",
          # The line runs only inside a Task spawned by this test. Option 2 recovers
          # the test label via the Task's `$callers` chain, so the id is attributed
          # to worker_test.exs and selection stays tight (1 test, not whole suite).
          "test/worker_test.exs" => """
          defmodule WorkerTest do
            use ExUnit.Case
            test "work via a spawned task" do
              task = Task.async(fn -> Worker.work(5) end)
              assert Task.await(task) == 6
            end
          end
          """,
          "test/idle_test.exs" => """
          defmodule IdleTest do
            use ExUnit.Case
            test "unrelated", do: assert(true)
          end
          """
        })

      assert {:ok, run} = Mutare.run(project, sandbox: sandbox, mutators: @probe)

      assert run.results != []
      assert Enum.all?(run.results, &(&1.status == :killed))
      # Attributed to worker_test.exs (via the Task caller chain), so only that file
      # runs — not the whole suite.
      assert Enum.all?(run.results, &(&1.output =~ "1 test"))
      refute Enum.any?(run.results, &(&1.output =~ "2 tests"))
    end

    @tag :runner
    test "a non-zero coverage probe falls back to running every mutant" do
      %{project: project, sandbox: sandbox} =
        Project.build(:probe_failure, %{
          "lib/probe_failure.ex" => """
          defmodule ProbeFailure do
            def first, do: 1 + 1
            def second, do: 3 + 4
          end
          """,
          "test/test_helper.exs" => "ExUnit.start(seed: 0, max_failures: 1)\n",
          "test/probe_failure_test.exs" => """
          defmodule ProbeFailureTest do
            use ExUnit.Case

            test "first then probe-only failure" do
              assert ProbeFailure.first() == 2

              if System.get_env("MUTARE_COVERAGE") do
                flunk("probe-only failure")
              end
            end

            test "second" do
              assert ProbeFailure.second() == 7
            end
          end
          """
        })

      assert {:ok, run} =
               Mutare.run(project, sandbox: sandbox, mutators: [Mutare.Mutators.Arithmetic])

      assert length(run.results) == 2
      assert Enum.all?(run.results, &(&1.status == :killed))
      refute Enum.any?(run.results, &(&1.status == :no_coverage))
    end
  end
end
