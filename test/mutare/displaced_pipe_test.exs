defmodule Mutare.DisplacedPipeTest do
  # A `|>` displaced out of `Kernel` is a call to somebody else's operator: no pipe position, no
  # hoisting closure, no `Kernel` desugaring.
  use ExUnit.Case, async: true
  import Mutare.Test

  alias Mutare.Test.{BindPipe, PairPipe}

  @bind_source """
  defmodule Bound do
    import Kernel, except: [|>: 2]
    import Mutare.Test.BindPipe
    def f(result), do: result |> Enum.reject(&(&1 > 1 + 1))
  end
  """

  test "a custom pipe macro is applied once, and its stage is not offered as a pipe stage" do
    {[module], sites} = compile_metamutant(@bind_source, [:collection, :integer, :relational])

    assert module.f({:ok, [1, 2, 3]}) == [1, 2]
    assert module.f(:error) == :error

    # The stage's own node is withheld (a selector there would hand the macro
    # `result |> case … end`); its arguments are ordinary values.
    refute Enum.any?(sites, &(&1.mutator == :collection))
    assert Enum.any?(sites, &(&1.mutator == :integer))
    assert Enum.any?(sites, &(&1.mutator == :relational))

    for site <- sites do
      with_active_mutant(site.id, fn ->
        refute module.f({:ok, [1, 2, 3]}) == [1, 2]
        assert module.f(:error) == :error
      end)
    end
  end

  test "the stage under a custom pipe is resolved at its written arity" do
    # `Enum.reject/1` does not exist, so no call family may read the stage as `Enum.reject/2`.
    assert [] == diffs(@bind_source, [:collection, :collection_arity, :call_removal])
  end

  test "a route on the custom operator replaces the default" do
    source = """
    defmodule Paired do
      import Kernel, except: [|>: 2]
      import Mutare.Test.PairPipe
      def f(list), do: list |> Enum.reject(list, &(&1 > 1))
    end
    """

    {[module], sites} =
      compile_metamutant(source, [:collection],
        call_routes: [{PairPipe, :|>, 2, [:expression, :expression]}]
      )

    assert module.f([1, 2]) == {[1, 2], [1]}

    assert {{[1, 2], [1]}, {[1, 2], [2]}} =
             observe_mutant(
               sites,
               {"Enum.reject(list, &(&1 > 1))", "Enum.filter(list, &(&1 > 1))"},
               fn -> module.f([1, 2]) end
             )
  end

  test "a displaced pipe keeps a pinned left side as written" do
    # `PipeEmit` expands `^x |> stage` the way `Kernel.|>/2` would; a custom operator is owed
    # its operands untouched.
    source = """
    defmodule Pinned do
      import Kernel, except: [|>: 2]
      import Mutare.Test.PairPipe
      def f(x), do: match?({^x, 2}, x |> (1 + 1))
    end
    """

    {[module], _sites} = compile_metamutant(source, [:integer, :arithmetic])
    assert module.f(:a)
  end

  test "Kernel's pipe beside an unrelated import is still the pipe" do
    source = """
    defmodule Plain do
      import Mutare.Test.PipeSyntaxDSL
      def f(list), do: list |> Enum.reject(&(&1 > 1))
    end
    """

    {[module], sites} = compile_metamutant(source, [:collection])
    assert module.f([1, 2]) == [1]

    assert {[1], [2]} =
             observe_mutant(
               sites,
               {"Enum.reject(&(&1 > 1))", "Enum.filter(&(&1 > 1))"},
               fn -> module.f([1, 2]) end
             )
  end

  test "the fixtures behave as described" do
    import Kernel, except: [|>: 2]
    import BindPipe

    assert {:ok, 1} |> Kernel.+(1) == 2
    assert :error |> Kernel.+(1) == :error
    assert PairPipe.|>(1, 2) == {1, 2}
  end
end
