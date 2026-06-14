defmodule Mutare.CoverageTest do
  use ExUnit.Case, async: false

  alias Mutare.{Coverage, Result}

  @moduletag timeout: 180_000

  describe "selector_index/1" do
    test "maps every mutant id to its selector's {module, metamutant line}" do
      source = """
      defmodule Demo.Thing do
        def gte?(a, b), do: a >= b
        def step(n) when n > 0, do: n + 1
        def step(_), do: 0
      end
      """

      {meta, sites, _next_id} = Mutare.transform_string(source, file: "lib/demo/thing.ex")
      index = Coverage.selector_index(meta)

      # every site is reachable through some selector/dispatcher
      assert Enum.all?(sites, &Map.has_key?(index, &1.id))
      # ids are attributed to the right module
      assert Enum.all?(index, fn {_id, {mod, line}} -> mod == Demo.Thing and is_integer(line) end)

      # the lifted ids for step/1 all share the dispatcher's line
      lifted_ids = for s <- sites, s.kind == :lifted, do: s.id
      lifted_lines = lifted_ids |> Enum.map(&elem(index[&1], 1)) |> Enum.uniq()
      assert length(lifted_lines) == 1
    end
  end

  describe "no-coverage skipping (end to end)" do
    @tag :runner
    test "a mutant on an unexecuted line is :no_coverage and is not run" do
      base = Path.join(System.tmp_dir!(), "mutare_cov_#{System.unique_integer([:positive])}")
      project = Path.join(base, "cov")
      sandbox = Path.join(base, "sandbox")
      write_project(project)
      on_exit(fn -> File.rm_rf!(base) end)

      assert {:ok, run} = Mutare.run(project, sandbox: sandbox)

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
      base = Path.join(System.tmp_dir!(), "mutare_nested_#{System.unique_integer([:positive])}")
      project = Path.join(base, "nested")
      sandbox = Path.join(base, "sandbox")
      write_nested_module_project(project)
      on_exit(fn -> File.rm_rf!(base) end)

      assert {:ok, run} = Mutare.run(project, sandbox: sandbox)
      assert [%Result{status: :killed}] = run.results
    end
  end

  describe "test-file selection (end to end)" do
    @tag :runner
    test "a mutant runs only the test files that cover it" do
      base = Path.join(System.tmp_dir!(), "mutare_sel_#{System.unique_integer([:positive])}")
      project = Path.join(base, "sel")
      sandbox = Path.join(base, "sandbox")
      write_two_module_project(project)
      on_exit(fn -> File.rm_rf!(base) end)

      assert {:ok, run} = Mutare.run(project, sandbox: sandbox)

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

  defp write_two_module_project(project) do
    write(project, "mix.exs", """
    defmodule Sel.MixProject do
      use Mix.Project
      def project, do: [app: :sel, version: "0.1.0", elixir: "~> 1.15"]
      def application, do: []
    end
    """)

    write(project, "lib/calc.ex", "defmodule Calc do\n  def add(a, b), do: a + b\nend\n")
    write(project, "lib/greeter.ex", "defmodule Greeter do\n  def shout(n), do: n * 2\nend\n")
    write(project, "test/test_helper.exs", "ExUnit.start()\n")

    write(project, "test/calc_test.exs", """
    defmodule CalcTest do
      use ExUnit.Case
      test "add", do: assert(Calc.add(2, 3) == 5)
    end
    """)

    write(project, "test/greeter_test.exs", """
    defmodule GreeterTest do
      use ExUnit.Case
      test "shout", do: assert(Greeter.shout(3) == 6)
    end
    """)
  end

  defp write_project(project) do
    write(project, "mix.exs", """
    defmodule Cov.MixProject do
      use Mix.Project
      def project, do: [app: :cov, version: "0.1.0", elixir: "~> 1.15"]
      def application, do: []
    end
    """)

    write(project, "lib/cov.ex", """
    defmodule Cov do
      def classify(x) do
        if x > 0 do
          x + 1
        else
          x - 1
        end
      end
    end
    """)

    write(project, "test/test_helper.exs", "ExUnit.start()\n")

    write(project, "test/cov_test.exs", """
    defmodule CovTest do
      use ExUnit.Case

      # Only the positive branch is ever exercised.
      test "classify positive" do
        assert Cov.classify(5) == 6
      end
    end
    """)
  end

  defp write_nested_module_project(project) do
    write(project, "mix.exs", """
    defmodule Nested.MixProject do
      use Mix.Project
      def project, do: [app: :nested, version: "0.1.0", elixir: "~> 1.15"]
      def application, do: []
    end
    """)

    write(project, "lib/outer.ex", """
    defmodule Outer do
      defmodule Inner do
        def add(a, b), do: a + b
      end
    end
    """)

    write(project, "test/test_helper.exs", "ExUnit.start()\n")

    write(project, "test/outer_test.exs", """
    defmodule OuterTest do
      use ExUnit.Case
      test "nested add", do: assert(Outer.Inner.add(2, 3) == 5)
    end
    """)
  end

  defp write(project, rel, contents) do
    path = Path.join(project, rel)
    File.mkdir_p!(Path.dirname(path))
    File.write!(path, contents)
  end
end
