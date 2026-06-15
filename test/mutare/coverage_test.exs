defmodule Mutare.CoverageTest do
  use ExUnit.Case, async: false

  alias Mutare.{Coverage, Manifest, Result}
  alias Mutare.Test.Project

  @moduletag timeout: 180_000

  # Pin the end-to-end runs to the operator-swap families: these tests assert
  # coverage classification and test-file selection, not mutant volume, so the
  # higher-volume default mutators (literals) are excluded for determinism/speed.
  @probe [Mutare.Mutators.Arithmetic, Mutare.Mutators.Relational]

  describe "index/1" do
    test "merges manifests to map every mutant id to its selector's {module, line}" do
      source = """
      defmodule Demo.Thing do
        def gte?(a, b), do: a >= b
        def step(n) when n > 0, do: n + 1
        def step(_), do: 0
      end
      """

      {meta, sites, _next_id} = Mutare.transform_string(source, file: "lib/demo/thing.ex")
      index = Coverage.index([Manifest.from_source(meta)])

      # every site is reachable through some selector/dispatcher
      assert Enum.all?(sites, &Map.has_key?(index, &1.id))
      # ids are attributed to the right module
      assert Enum.all?(index, fn {_id, {mod, line}} -> mod == Demo.Thing and is_integer(line) end)

      # the lifted ids for step/1 all share the dispatcher's line
      lifted_ids = for s <- sites, s.kind == :lifted, do: s.id
      lifted_lines = lifted_ids |> Enum.map(&elem(index[&1], 1)) |> Enum.uniq()
      assert length(lifted_lines) == 1
    end

    test "merges across files, ids globally unique so maps never collide" do
      a = "defmodule A do\n  def f(a, b), do: a + b\nend\n"
      b = "defmodule B do\n  def g(a, b), do: a - b\nend\n"

      {meta_a, sites_a, next} = Mutare.transform_string(a, file: "lib/a.ex")
      {meta_b, sites_b, _} = Mutare.transform_string(b, file: "lib/b.ex", start_id: next)

      index = Coverage.index([Manifest.from_source(meta_a), Manifest.from_source(meta_b)])

      ids = Enum.map(sites_a ++ sites_b, & &1.id)
      assert map_size(index) == length(ids)
      assert Enum.all?(ids, &Map.has_key?(index, &1))
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
  end
end
