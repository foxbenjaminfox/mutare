defmodule Mutare.PipeRegionsTest do
  # Where a piped routed stage is, and is not, made the direct call — and the facilities that
  # share a call with a route (marks, the ineffective-route diagnostic, a skipped `|>`).
  use ExUnit.Case, async: true

  alias Mutare.Test.{PipeSyntaxDSL, PipeSyntaxMutator}
  alias Mutare.Transform

  defp transform(source, mutators, opts \\ []) do
    Transform.transform_string_with_sites(
      source,
      [file: "regions.ex", mutators: mutators] ++ opts
    )
  end

  describe "regions left as written keep the pipe" do
    test "the raw bodies of lifted head-mutant clauses, beside the instrumented one" do
      source = """
      defmodule Lifted do
        import Mutare.Test.PipeSyntaxDSL
        def g(1), do: 5 |> plus(1)
        def g(n), do: n |> plus(2)
      end
      """

      emitted = transform(source, [PipeSyntaxMutator, :integer, :pattern_swap]).metamutant

      # A head mutant's clause runs the body as the user wrote it …
      assert emitted =~ "5 |> plus(1)"
      # … and the instrumented clause runs the analyzed one, its piped value bound once.
      assert emitted =~ "mutare_piped |> plus(1)"
      Mutare.Test.Metamutant.assert_compiles(emitted)
    end

    test "the raw part of a keyed refinement, while the routed key is analyzed" do
      source = """
      defmodule Keyed do
        import Mutare.Test.PipeSyntaxDSL
        def f(n), do: opts(label: n |> plus(1), value: n |> plus(2))
        defp opts(list), do: list
      end
      """

      routes = [{:*, :opts, 1, [[:raw, value: :expression]]}]
      emitted = transform(source, [PipeSyntaxMutator], call_routes: routes).metamutant

      assert emitted =~ "label: n |> plus(1)"
      assert emitted =~ "mutare_piped |> plus(2)"
      refute emitted =~ "mutare_piped |> plus(1)"
    end

    test "a :hosted fragment no host claims" do
      defmodule InertHost do
        @behaviour Mutare.Mutator
        @behaviour Mutare.CallRouting
        @behaviour Mutare.Mutator.MacroHost

        def name, do: :inert_host
        def call_routes, do: [{Mutare.Test.PipedCallDSL, :stage, 2, [:hosted, :expression]}]
        def hosted_macros, do: [{Mutare.Test.PipedCallDSL, :stage, 2}]
        def host(_call, _context), do: []
      end

      source = """
      defmodule Hosted do
        import Mutare.Test.PipedCallDSL
        import Mutare.Test.PipeSyntaxDSL
        def f(n, x), do: stage(n |> plus(1), x > 41)
      end
      """

      result = transform(source, [InertHost, PipeSyntaxMutator, :integer])
      assert Enum.map(result.sites, & &1.original_code) == ["41", "41", "41"]
      assert result.metamutant =~ ~r/stage\(\s*n \|> plus\(1\),/
      refute result.metamutant =~ "plus(n, 1)"
    end

    test "a module-level pipe, which is never analyzed as runtime code" do
      source = """
      defmodule Scaffold do
        import Mutare.Test.PipeSyntaxDSL
        @limit 5 |> plus(1)
        def f(n), do: n + @limit + 41
      end
      """

      result = transform(source, [PipeSyntaxMutator, :integer])
      assert result.metamutant =~ "@limit 5 |> plus(1)"
      refute Enum.any?(result.sites, &(&1.mutator == :pipe_syntax))
      Mutare.Test.Metamutant.assert_compiles(result.metamutant)
    end
  end

  describe "a route and an argument mark on the same call" do
    # `Process.sleep/1`'s argument carries core's timeout mark. Routing the call must not change
    # what the mark holds back, in either spelling: piped, the marked position is reached through
    # the direct form's index 0.
    @sleeps ["Process.sleep(1000)", "1000 |> Process.sleep()"]

    test "the mark holds in both spellings, routed or not" do
      for spelling <- @sleeps, routes <- [[], [{Process, :sleep, 1, [:expression]}]] do
        source = """
        defmodule Marked do
          def f do
            #{spelling}
            :done
          end
        end
        """

        unmarked = "defmodule Plain do\n  def f, do: send(self(), 1000)\nend\n"

        marked_sites = transform(source, [:integer], call_routes: routes).sites
        plain_sites = transform(unmarked, [:integer]).sites

        assert length(marked_sites) < length(plain_sites),
               "#{spelling} with routes #{inspect(routes)}: #{inspect(Enum.map(marked_sites, & &1.mutated_code))}"
      end
    end

    test "both spellings yield the same mutants" do
      routes = [{Process, :sleep, 1, [:expression]}]

      [direct, piped] =
        for spelling <- @sleeps do
          source = "defmodule Marked do\n  def f do\n    #{spelling}\n    :done\n  end\nend\n"

          transform(source, [:integer], call_routes: routes).sites
          |> Enum.map(&{&1.original_code, &1.mutated_code})
          |> Enum.sort()
        end

      assert direct == piped
    end
  end

  describe "the ineffective-route diagnostic" do
    defp matched_routes(source, routes) do
      Transform.count_report(source,
        file: "regions.ex",
        mutators: [:integer],
        call_routes: routes
      ).matches.routes
    end

    test "counts a route matched only by piped call sites" do
      source = """
      defmodule Matched do
        import Mutare.Test.PipeSyntaxDSL
        def f(n), do: n |> tagged(5)
        defp tagged(a, _b), do: a
      end
      """

      assert MapSet.size(matched_routes(source, [{:*, :tagged, 2, [:expression, :raw]}])) == 1
      assert MapSet.size(matched_routes(source, [{:*, :tagged, 1, [:raw]}])) == 0
    end

    test "counts one matched beneath a skipped `|>`, and one matched at the skipped stage itself" do
      source = """
      defmodule Skipped do
        def f(n), do: n |> tagged(5)
        defp tagged(a, _b), do: a
      end
      """

      routes = [{Kernel, :|>, 2, :skip}, {:*, :tagged, 2, [:expression, :raw]}]
      assert MapSet.size(matched_routes(source, routes)) == 2
    end
  end

  describe "a skipped `|>`" do
    test "is an inert leaf: its routed stage stays a pipe and nothing inside mutates" do
      source = """
      defmodule SkippedPipe do
        import Mutare.Test.PipeSyntaxDSL
        def f(n) do
          _ = 41
          (n + 1) |> plus(2)
        end
      end
      """

      result =
        transform(source, [PipeSyntaxMutator, :integer, :arithmetic],
          call_routes: [{Kernel, :|>, 2, :skip}]
        )

      assert Enum.map(result.sites, & &1.original_code) |> Enum.uniq() == ["41"]
      assert result.metamutant =~ "(n + 1) |> plus(2)"
      Mutare.Test.Metamutant.assert_compiles(result.metamutant)
    end
  end

  test "the fixtures' routes are the ones these tests assume" do
    assert {PipeSyntaxDSL, :plus, 2, [:expression, :expression]} in PipeSyntaxMutator.call_routes()
  end
end
