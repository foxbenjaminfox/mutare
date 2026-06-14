defmodule Mutare.IgnoreTest do
  @moduledoc "`# mutare:ignore` suppresses a mutant: not run, out of the denominator."
  use ExUnit.Case, async: false

  alias Mutare.Result

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

    test "a string literal that reads like the directive is not a directive" do
      # Directives come from parsed comment metadata, not a raw-text scan, so a
      # string that merely *contains* `# mutare:ignore` suppresses nothing.
      source = """
      defmodule Ig do
        def a(x), do: x + String.length("# mutare:ignore")
      end
      """

      {_meta, sites, _next_id} = Mutare.transform_string(source)

      assert [%{line: 2, ignored: false}] = sites
    end
  end

  describe "end to end" do
    @tag :runner
    @tag timeout: 180_000
    test "an ignored mutant is :ignored (not run) and kept out of the score" do
      base = Path.join(System.tmp_dir!(), "mutare_ig_#{System.unique_integer([:positive])}")
      project = Path.join(base, "ig")
      sandbox = Path.join(base, "sandbox")
      write_project(project)
      on_exit(fn -> File.rm_rf!(base) end)

      assert {:ok, run} = Mutare.run(project, sandbox: sandbox)

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

  defp write_project(project) do
    write(project, "mix.exs", """
    defmodule Ig.MixProject do
      use Mix.Project
      def project, do: [app: :ig, version: "0.1.0", elixir: "~> 1.15"]
      def application, do: []
    end
    """)

    write(project, "lib/ig.ex", """
    defmodule Ig do
      def keep(x), do: x + 1
      def skip(x), do: x + 1 # mutare:ignore
    end
    """)

    write(project, "test/test_helper.exs", "ExUnit.start()\n")

    write(project, "test/ig_test.exs", """
    defmodule IgTest do
      use ExUnit.Case
      test "keep", do: assert(Ig.keep(1) == 2)
    end
    """)
  end

  defp write(project, rel, contents) do
    path = Path.join(project, rel)
    File.mkdir_p!(Path.dirname(path))
    File.write!(path, contents)
  end
end
