defmodule Mutare.PipeSyntaxRunnerTest do
  use ExUnit.Case, async: false
  @moduletag :runner
  @moduletag timeout: 180_000

  test "syntax-valued pipes run without poisoning same-named macro calls" do
    %{project: project, sandbox: sandbox} =
      Mutare.Test.Project.build(:pipe_syntax, %{
        "lib/dsl.ex" => """
        defmodule Mutare.Test.PipeSyntaxDSL do
          defmacro raw({:in, _, [binding, source]}, body) do
            quote do
              unquote(binding) = unquote(source)
              unquote(body)
            end
          end
        end
        """,
        "lib/usage.ex" => """
        defmodule Usage do
          import Mutare.Test.PipeSyntaxDSL
          def piped(n), do: (x in n) |> raw(x + 1)
          def direct(n), do: raw(x in n, x + 2)
          def sibling(n), do: raw(x in n, x + 3)
        end
        """,
        "test/usage_test.exs" => """
        defmodule UsageTest do
          use ExUnit.Case
          test "piped", do: assert(Usage.piped(10) == 11)
          test "direct", do: assert(Usage.direct(10) == 12)
          test "sibling", do: assert(Usage.sibling(10) == 13)
        end
        """
      })

    assert {:ok, run} =
             Mutare.run(project,
               sandbox: sandbox,
               only_files: ["lib/usage.ex"],
               mutators: [Mutare.Test.PipeSyntaxMutator],
               verify_invariants: true
             )

    assert Enum.map(run.results, &{&1.site.original_code, &1.status}) == [
             {"raw(x + 1)", :killed},
             {"raw(x in n, x + 2)", :killed},
             {"raw(x in n, x + 3)", :killed}
           ]

    assert run.recovery == nil
  end

  test "routed chains run for real: bound stages, a lazy stage left lazy, coverage through the closure" do
    %{project: project, sandbox: sandbox} =
      Mutare.Test.Project.build(:pipe_routed_chain, %{
        "lib/dsl.ex" => """
        defmodule Mutare.Test.PipeSyntaxDSL do
          defmacro plus(source, amount), do: quote(do: unquote(source) + unquote(amount))

          defmacro lazy_plus(source, amount) do
            quote do
              case unquote(amount) do
                amount when amount > 0 -> unquote(source) + amount
                _ -> 0
              end
            end
          end
        end
        """,
        "lib/usage.ex" => """
        defmodule Usage do
          import Mutare.Test.PipeSyntaxDSL

          def chain(n), do: n |> plus(1) |> plus(10)
          def lazy(sink, k), do: tick(sink) |> lazy_plus(k)
          def uncovered(n), do: n |> plus(5)

          defp tick(sink) do
            send(sink, :ticked)
            100
          end
        end
        """,
        # The project's own suite pins the laziness: were the piped operand evaluated ahead of
        # `lazy_plus`, the baseline would fail before any mutant ran.
        "test/usage_test.exs" => """
        defmodule UsageTest do
          use ExUnit.Case

          test "chain", do: assert(Usage.chain(0) == 11)

          test "lazy_plus does not evaluate its source for a non-positive amount" do
            assert Usage.lazy(self(), -1) == 0
            refute_received :ticked
          end

          test "lazy_plus adds to its source otherwise" do
            assert Usage.lazy(self(), 2) == 102
            assert_received :ticked
          end
        end
        """
      })

    assert {:ok, run} =
             Mutare.run(project,
               sandbox: sandbox,
               only_files: ["lib/usage.ex"],
               mutators: [Mutare.Test.PipeSyntaxMutator],
               verify_invariants: true
             )

    assert Enum.map(run.results, &{&1.site.original_code, &1.status}) == [
             {"plus(1)", :killed},
             {"plus(10)", :killed},
             {"lazy_plus(k)", :killed},
             {"plus(5)", :no_coverage}
           ]

    assert run.recovery == nil
  end
end
