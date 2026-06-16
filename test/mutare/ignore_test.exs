defmodule Mutare.IgnoreTest do
  @moduledoc "`# mutare:ignore` suppresses a mutant: not run, out of the denominator."
  use ExUnit.Case, async: false

  alias Mutare.Result
  alias Mutare.Test.Project

  describe "transform marking" do
    test "a trailing comment ignores its line; a standalone ignores the next line" do
      source = """
      defmodule Ig do
        def a(x), do: x + 1   # mutare:ignore
        def b(x), do: x + 1
        # mutare:ignore
        def c(x), do: x + 2
      end
      """

      {meta, sites, _next_id} = Mutare.transform_string(source)
      ignored? = Map.new(sites, &{&1.line, &1.ignored})

      assert ignored?[2] == true
      assert ignored?[3] == false
      assert ignored?[5] == true

      # ignored sites are still recorded (for the denominator), and the
      # metamutant still compiles.
      assert {:ok, _} = Code.string_to_quoted(meta)
    end

    test "a trailing reason is captured on the site and suppresses the whole line" do
      source = """
      defmodule Ig do
        def a(x), do: x + 1   # mutare:ignore equivalent under integer math
      end
      """

      {_meta, sites, _next_id} = Mutare.transform_string(source)

      assert sites != []
      assert Enum.all?(sites, & &1.ignored)
      assert Enum.all?(sites, &(&1.ignore_reason == "equivalent under integer math"))
    end

    test "a `[family]` filter suppresses only that family; siblings still run" do
      source = """
      defmodule Ig do
        def a(x), do: x + 1 > 2   # mutare:ignore[arithmetic] adding 1 is noise
      end
      """

      {_meta, sites, _next_id} = Mutare.transform_string(source)
      by_mutator = Enum.group_by(sites, & &1.mutator)

      # The arithmetic mutant is ignored (with its reason)...
      assert Enum.all?(by_mutator[:arithmetic], & &1.ignored)
      assert Enum.all?(by_mutator[:arithmetic], &(&1.ignore_reason == "adding 1 is noise"))

      # ...while relational/conditional/literal mutants on the same line still run.
      others = Enum.flat_map(~w(relational conditional literal)a, &(by_mutator[&1] || []))
      assert others != []
      refute Enum.any?(others, & &1.ignored)
    end

    test "a `[a, b]` filter suppresses each listed family" do
      source = """
      defmodule Ig do
        def a(x), do: x + 1 > 2   # mutare:ignore[arithmetic, relational]
      end
      """

      {_meta, sites, _next_id} = Mutare.transform_string(source)
      ignored = Enum.group_by(sites, & &1.ignored, & &1.mutator)

      assert MapSet.new(ignored[true]) == MapSet.new([:arithmetic, :relational])
      refute Enum.empty?(ignored[false])
    end

    test "an unknown family in a filter fails safe: it suppresses nothing" do
      source = """
      defmodule Ig do
        def a(x), do: x + 1   # mutare:ignore[arithmetc]
      end
      """

      {_meta, sites, _next_id} = Mutare.transform_string(source)

      # Typo'd family matches no mutator, so the mutant runs rather than hides.
      refute Enum.any?(sites, & &1.ignored)
    end

    test "a string literal that reads like the directive is not a directive" do
      # Directives come from parsed comment metadata, not a raw-text scan, so a
      # string that merely *contains* `# mutare:ignore` suppresses nothing.
      source = """
      defmodule Ig do
        def a(x), do: x + String.length("# mutare:ignore")
      end
      """

      # Pin to arithmetic so the lone site is the `+`; the default string mutator
      # would otherwise also mutate the "# mutare:ignore" *string literal*, which
      # is beside the point here (this test is about the comment directive).
      {_meta, sites, _next_id} =
        Mutare.transform_string(source, mutators: [Mutare.Mutators.Arithmetic])

      assert [%{line: 2, ignored: false}] = sites
    end
  end

  describe "directive parsing" do
    alias Mutare.Ignore
    alias Mutare.Ignore.Directive

    test "a bare directive admits every mutator and carries no reason" do
      directives = Ignore.directives("x = 1 # mutare:ignore")
      assert %Directive{line: 1, mutators: :all, reason: nil} = directive_on(directives, 1)
      assert Ignore.directive_for(directives, 1, :anything)
    end

    test "a `[...]` filter only admits the listed mutators" do
      directives = Ignore.directives("x = 1 # mutare:ignore[arithmetic, literal]")

      assert Ignore.directive_for(directives, 1, :arithmetic)
      assert Ignore.directive_for(directives, 1, :literal)
      refute Ignore.directive_for(directives, 1, :relational)
    end

    test "the filter also matches non-family mutator names (clause_drop, custom)" do
      directives = Ignore.directives("x = 1 # mutare:ignore[clause_drop]")
      assert Ignore.directive_for(directives, 1, :clause_drop)
    end

    test "a reason survives alongside a filter" do
      directives = Ignore.directives("x = 1 # mutare:ignore[arithmetic]  documented on purpose")
      assert %Directive{reason: "documented on purpose"} = directive_on(directives, 1)
    end

    test "an empty `[]` filter admits nothing (fail-safe)" do
      directives = Ignore.directives("x = 1 # mutare:ignore[]")
      refute Ignore.directive_for(directives, 1, :arithmetic)
    end

    test "a standalone directive targets the next line" do
      directives = Ignore.directives("# mutare:ignore[relational] why\nx = 1")
      assert %Directive{line: 2, reason: "why"} = directive_on(directives, 2)
    end

    defp directive_on(directives, line), do: directives |> Map.fetch!(line) |> hd()
  end

  describe "end to end" do
    @tag :runner
    @tag timeout: 180_000
    test "an ignored mutant is :ignored (not run) and kept out of the score" do
      %{project: project, sandbox: sandbox} =
        Project.build(:ig, %{
          "lib/ig.ex" => """
          defmodule Ig do
            def keep(x), do: x + 1
            def skip(x), do: x + 1 # mutare:ignore
          end
          """,
          "test/ig_test.exs" => """
          defmodule IgTest do
            use ExUnit.Case
            test "keep", do: assert(Ig.keep(1) == 2)
          end
          """
        })

      # Pin to a single operator-swap family so `skip/1` has exactly one mutant
      # (the test asserts a single ignored result); the default literal mutator
      # would add more, off-topic for what this checks.
      assert {:ok, run} =
               Mutare.run(project, sandbox: sandbox, mutators: [Mutare.Mutators.Arithmetic])

      ignored = Enum.filter(run.results, &(&1.status == :ignored))

      # `skip/1`'s mutant is suppressed — and ignore wins over no-coverage
      # (it's never run), so it's :ignored, not :no_coverage.
      assert [%Result{site: %{ignored: true}, duration_ms: 0}] = ignored
      assert Enum.all?(ignored, &(&1.site.line == skip_line()))

      # keep/1's mutant is covered and killed; with the other ignored, score is 100%.
      assert Mutare.Report.score(run.results) == 100.0
    end
  end

  defp skip_line, do: 3
end
