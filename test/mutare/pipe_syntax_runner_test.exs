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
end
