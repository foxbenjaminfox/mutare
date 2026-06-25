defmodule Mutare.PartitionIntegrationTest do
  @moduledoc """
  End-to-end check that `:partition_env` delivers a per-worker partition id to the
  real `mix test` subprocesses — baseline, coverage probe, and per-mutant runs.

  The fixture suite *requires* the named partition var to be set (and within
  `1..workers`), so it is the env-delivery oracle:

    * a successful, fully-classified run proves the var reached the baseline and
      the probe (both green-check the whole suite);
    * the relational `>= -> >` mutant *surviving* (rather than being a false kill)
      proves it reached the per-mutant run too — that run executes the whole
      `calc_test.exs` file (the mutant's line is covered there), so a missing var
      would fail the partition test and wrongly mark the mutant killed.

  A custom var name (`MUTARE_TEST_DB_SLOT`, not `MIX_TEST_PARTITION`) is used so
  the negative case can't be fooled by an ambient `MIX_TEST_PARTITION` in the
  harness's own environment.
  """
  use ExUnit.Case, async: false

  alias Mutare.Result
  alias Mutare.Test.Project

  @probe [Mutare.Mutators.Arithmetic, Mutare.Mutators.Relational]
  @slot_var "MUTARE_TEST_DB_SLOT"

  @moduletag :runner
  # compile + baseline + probe + one subprocess per mutant
  @moduletag timeout: 180_000

  setup do
    Project.build(:partitioned, %{
      "lib/calc.ex" => """
      defmodule Calc do
        def add(a, b), do: a + b
        def gte?(a, b), do: a >= b
      end
      """,
      "test/calc_test.exs" => """
      defmodule CalcTest do
        use ExUnit.Case

        test "the partition var is delivered to this run, within 1..workers" do
          slot = System.get_env("#{@slot_var}")
          assert slot != nil, "#{@slot_var} was not set for this run"
          assert String.to_integer(slot) in 1..2
        end

        test "add sums its arguments" do
          assert Calc.add(2, 3) == 5
        end

        # No boundary test, so the relational `>= -> >` mutant survives.
        test "gte? is true well above the threshold" do
          assert Calc.gte?(10, 5) == true
        end
      end
      """
    })
  end

  test "delivers a per-worker partition var to baseline, probe, and mutant runs", %{
    project: project,
    sandbox: sandbox
  } do
    assert {:ok, run} =
             Mutare.run(project,
               sandbox: sandbox,
               mutators: @probe,
               partition_env: @slot_var,
               workers: 2
             )

    # A clean run (green baseline + probe) means the var reached both; the
    # surviving relational mutant means it reached the per-mutant run too (else
    # the partition test would fail there and false-kill it).
    assert length(run.results) == 3
    assert Enum.count(run.results, &(&1.status == :killed)) == 2

    assert [%Result{site: %{mutator: :relational, original_op: :>=, mutated_op: :>}}] =
             Enum.filter(run.results, &(&1.status == :survived))
  end

  test "without :partition_env the suite (which requires the var) fails the baseline", %{
    project: project,
    sandbox: sandbox
  } do
    # The fixture suite asserts the var is set; with partitioning off it isn't, so
    # the baseline is red — proving the positive test above isn't passing for some
    # unrelated reason (the oracle genuinely depends on delivery).
    assert {:error, :baseline_failed, _detail} =
             Mutare.run(project, sandbox: sandbox, mutators: @probe)
  end

  test "delivers the fixed partition var to the compile phase (config read at compile time)" do
    # A partitioned config reads the var at config-eval time, which happens during
    # `mix compile` (under MIX_ENV=test) — *before* the baseline/probe run. With no
    # default and no var, `mix compile` fails, so the fixed partition must reach the
    # compile too, not just the baseline/probe. (Its own setup: this fixture needs a
    # config file the shared `setup` doesn't provide.)
    %{project: project, sandbox: sandbox} =
      Project.build(:partition_compile, %{
        "config/config.exs" => """
        import Config
        # A partitioned Repo reads this at config-eval (compile) time; with no
        # default it raises, failing `mix compile` before the baseline ever runs.
        _slot = System.fetch_env!("#{@slot_var}")
        """,
        "lib/calc.ex" => """
        defmodule Calc do
          def add(a, b), do: a + b
        end
        """,
        "test/calc_test.exs" => """
        defmodule CalcTest do
          use ExUnit.Case

          test "add sums its arguments" do
            assert Calc.add(2, 3) == 5
          end
        end
        """
      })

    # With the fix the compile sees the fixed partition (1), config evaluates, and
    # the run proceeds; without it the compile would fail with :compile_failed.
    assert {:ok, _run} =
             Mutare.run(project,
               sandbox: sandbox,
               mutators: [Mutare.Mutators.Arithmetic],
               partition_env: @slot_var,
               workers: 2
             )
  end
end
