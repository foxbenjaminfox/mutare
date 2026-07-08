defmodule Mutare.MacroPoisonTest do
  @moduledoc """
  The macro-expansion poison fallback: when a mutation splices a runtime selector `case`
  into an argument that an unknown *inline* DSL macro rewrites at compile time (an
  `Ecto.Query.from/2`-style macro), the macro raises during expansion and the compiler
  blames the macro-*call* line — which no `Mutare.Manifest` region covers, so the classic
  line-based `Poison.ids/2` finds nothing and the run would abort.

  This proves recovery now *engages* instead: the `expanding macro:` frame names the macro,
  `Poison.macro_poison/2` maps it to the mutants inside its calls, they are dropped
  wholesale, the metamutant rebuilds, and the run completes — recording those mutants
  `:poisoned` and surfacing the durable `{MyDsl, :query, :skip}` suggestion.
  """
  use ExUnit.Case, async: false

  alias Mutare.Test.Project

  @moduletag :runner
  @moduletag timeout: 300_000

  test "an inline unknown-macro poison recovers via the macro-expansion fallback" do
    %{project: project, sandbox: sandbox} =
      Project.build(:inline_dsl, %{
        # An unknown inline DSL macro that walks its argument at compile time and rejects a
        # `case` — exactly how Ecto's `from` chokes on a spliced runtime selector.
        "lib/my_dsl.ex" => """
        defmodule MyDsl do
          defmacro query(expr) do
            Macro.prewalk(expr, fn
              {:case, _meta, _args} ->
                raise "MyDsl.query/1 does not support a case expression in a query"

              node ->
                node
            end)

            quote(do: :ok)
          end
        end
        """,
        "lib/report.ex" => """
        defmodule Report do
          import MyDsl

          def big?(a, b) do
            query(a > b)
          end
        end
        """,
        "test/report_test.exs" => """
        defmodule ReportTest do
          use ExUnit.Case

          test "big?" do
            assert Report.big?(2, 1) == :ok
          end
        end
        """
      })

    assert {:ok, run} =
             Mutare.run(project, sandbox: sandbox, mutators: [Mutare.Mutators.Relational])

    # It recovered rather than aborting: the mutants inside `query(...)` are recorded
    # :poisoned (dropped wholesale by the fallback), and recovery names the macro.
    poisoned = Enum.filter(run.results, &(&1.status == :poisoned))
    assert poisoned != [], "expected the query/1 mutants to be recorded :poisoned"
    assert Enum.all?(poisoned, &(&1.site.line == 5))

    assert %{macro_skipped: [%{module: "MyDsl", macro: :query}]} = run.recovery
    assert run.recovery.rounds >= 1
  end

  test "recovers a literal-only macro poison inside a function-head default" do
    # `def limit(n \\ Size.megabytes(5))` — the macro expands in the def head, so mutating `5`
    # poisons there. The fallback must skip only the head's call shape, not its default, or the
    # `megabytes(5)` inside it is unreachable and the run aborts.
    %{project: project, sandbox: sandbox} =
      Project.build(:head_default, %{
        "lib/size.ex" => """
        defmodule Size do
          defmacro megabytes(n) when is_integer(n) do
            quote do: unquote(n) * 1024 * 1024
          end
        end
        """,
        "lib/usage.ex" => """
        defmodule Usage do
          require Size

          def limit(n \\\\ Size.megabytes(5)) do
            n
          end
        end
        """,
        "test/usage_test.exs" => """
        defmodule UsageTest do
          use ExUnit.Case
          test "limit", do: assert(Usage.limit() == 5 * 1024 * 1024)
        end
        """
      })

    assert {:ok, run} =
             Mutare.run(project, sandbox: sandbox, mutators: [Mutare.Mutators.Literal])

    assert %{macro_skipped: [%{module: "Size", macro: :megabytes}]} = run.recovery
    assert Enum.any?(run.results, &(&1.status == :poisoned))
  end

  test "recovers a poison in the PIPED value of an inline macro (`|>`)" do
    # `(a > b) |> query()` — after pipe expansion `a > b` is `query`'s argument, but its
    # selector renders on the pipe's left, before the `query()` node. The fallback must range
    # the whole pipe (not just `query()`) to attribute it, or the run aborts.
    %{project: project, sandbox: sandbox} =
      Project.build(:piped_dsl, %{
        "lib/my_dsl.ex" => """
        defmodule MyDsl do
          defmacro query(expr) do
            Macro.prewalk(expr, fn
              {:case, _m, _a} -> raise "no case in a query"
              node -> node
            end)

            quote(do: :ok)
          end
        end
        """,
        "lib/report.ex" => """
        defmodule Report do
          import MyDsl

          def q(a, b) do
            (a > b) |> query()
          end
        end
        """,
        "test/report_test.exs" => """
        defmodule ReportTest do
          use ExUnit.Case

          test "q" do
            assert Report.q(2, 1) == :ok
          end
        end
        """
      })

    assert {:ok, run} =
             Mutare.run(project, sandbox: sandbox, mutators: [Mutare.Mutators.Relational])

    assert %{macro_skipped: [%{module: "MyDsl", macro: :query}]} = run.recovery
    assert Enum.any?(run.results, &(&1.status == :poisoned))
  end

  test "recovers an UNSELECTED macro poison under a scoped (--line) run" do
    # Under `:only_lines`, `schema.sites` is filtered to the selected line, but the metamutant
    # still *reserves and renders* every mutant — so an unselected `query(...)` mutant is still
    # in the compiled file and still poisons. The fallback attributes through the metamutant
    # (every reserved id), not the filtered sites, so recovery must still engage.
    %{project: project, sandbox: sandbox} =
      Project.build(:scoped_dsl, %{
        "lib/my_dsl.ex" => """
        defmodule MyDsl do
          defmacro query(expr) do
            Macro.prewalk(expr, fn
              {:case, _m, _a} -> raise "no case in a query"
              node -> node
            end)

            quote(do: :ok)
          end
        end
        """,
        "lib/report.ex" => """
        defmodule Report do
          import MyDsl

          def plain(a, b) do
            a + b
          end

          def q(a, b) do
            query(a > b)
          end
        end
        """,
        "test/report_test.exs" => """
        defmodule ReportTest do
          use ExUnit.Case

          test "plain" do
            assert Report.plain(2, 3) == 5
          end
        end
        """
      })

    # Select only line 5 (`a + b`) — the `query(a > b)` on line 9 is unselected but still
    # rendered, so it poisons the one compile.
    assert {:ok, run} =
             Mutare.run(project,
               sandbox: sandbox,
               mutators: [Mutare.Mutators.Arithmetic, Mutare.Mutators.Relational],
               only_lines: [{"lib/report.ex", 5}]
             )

    # It recovered (didn't abort): the fallback named the unselected macro, and the selected
    # line-5 arithmetic mutant(s) actually ran.
    assert %{macro_skipped: [%{module: "MyDsl", macro: :query}]} = run.recovery
    assert Enum.all?(run.results, &(&1.site.line == 5))
    assert Enum.any?(run.results, &(&1.status in [:killed, :survived]))
  end
end
