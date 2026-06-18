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
    test "decodes the aggregate and per-file id lists into MapSets", %{tmp_dir: dir} do
      path = Path.join(dir, "dump.terms")

      payload = %{
        aggregate: [1, 2, 3],
        by_file: %{"test/a_test.exs" => [1, 2], "test/b_test.exs" => [3]}
      }

      File.write!(path, :erlang.term_to_binary(payload))

      assert {:ok, %{aggregate: aggregate, by_file: by_file}} = Coverage.read_dump(path)
      assert aggregate == MapSet.new([1, 2, 3])
      assert by_file["test/a_test.exs"] == MapSet.new([1, 2])
      assert by_file["test/b_test.exs"] == MapSet.new([3])
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

      System.put_env(Recorder.env_var(), "1")

      on_exit(fn ->
        restore_env(Recorder.env_var(), saved_env)
        restore_track(saved_track)
        drop_table_unless(:mutare_cov_agg, agg_existed?)
        drop_table_unless(:mutare_cov_attr, attr_existed?)
      end)

      ast = Recorder.setup_ast()

      # Two apps' test helpers evaluate this in the same VM; without the
      # create-once guard the second :ets.new would raise :badarg.
      assert {_, _} = Code.eval_quoted(ast)
      assert {_, _} = Code.eval_quoted(ast)
      assert :ets.whereis(:mutare_cov_agg) != :undefined
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

      by_op = Map.new(run.results, &{&1.site.original_op, &1})

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

      by_op = Map.new(run.results, &{&1.site.original_op, &1})

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
