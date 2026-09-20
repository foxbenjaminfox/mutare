defmodule Mutare.DisplacedPipeTest do
  # A `|>` displaced out of `Kernel` is a call to somebody else's operator: no pipe position, no
  # hoisting closure, no `Kernel` desugaring.
  # `with_active_mutant/2` sets the VM-wide selector, so these cannot run beside other tests.
  use ExUnit.Case, async: false
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

  describe "however the operator was displaced" do
    import Mutare.Test.SourcePatch

    @mutators [:collection, :integer, :relational, :arithmetic]

    test "by a `use` Mutare can expand" do
      source = """
      defmodule Used do
        use Mutare.Test.UsesBindPipe
        def run(result), do: result |> Enum.reject(&(&1 > 1 + 1))
      end
      """

      sites = assert_patches(source, @mutators, run: [{:ok, [1, 2, 3]}], run: [:error])
      refute Enum.any?(sites, &(&1.mutator == :collection))
    end

    test "inside one function only: the rest of the module still has Kernel's pipe" do
      source = """
      defmodule Scoped do
        def bound(result) do
          import Kernel, except: [|>: 2]
          import Mutare.Test.BindPipe
          result |> Enum.reject(&(&1 > 2))
        end

        def plain(list), do: list |> Enum.reject(&(&1 > 2))
      end
      """

      sites =
        assert_patches(source, @mutators,
          bound: [{:ok, [1, 2, 3]}],
          bound: [:error],
          plain: [[1, 2, 3]]
        )

      # Only `plain/1`'s stage is a pipe stage to Mutare, so only it gets the whole-call swap.
      assert [%{line: 8}] = Enum.filter(sites, &(&1.mutator == :collection))
    end

    test "by `only:` narrowing" do
      # Literal mutants only: the operator families do not read a narrowed `Kernel` import, so a
      # swap to an operator `only:` left out is poison by design (`Mutare.Transform.Imports`).
      source = """
      defmodule Narrowed do
        import Kernel, only: [def: 2, >: 2, +: 2]
        import Mutare.Test.PairPipe

        def run(list), do: list |> Enum.reject(list, &(&1 > 1 + 1))
      end
      """

      assert [_ | _] = assert_patches(source, [:integer], run: [[1, 2, 3]])
    end

    test "by an operator the module defines itself" do
      source = """
      defmodule Local do
        import Kernel, except: [|>: 2]

        defmacro left |> right do
          quote do: {unquote(left), unquote(right)}
        end

        def run(list), do: list |> Enum.reject(list, &(&1 > 1 + 1))
      end
      """

      sites = assert_patches(source, @mutators, run: [[1, 2, 3]])
      refute Enum.any?(sites, &(&1.mutator == :collection))
    end

    test "chained: each custom stage is applied once, in order" do
      source = """
      defmodule Chained do
        import Kernel, except: [|>: 2]
        import Mutare.Test.BindPipe

        def run(result) do
          result |> wrap(1 + 1) |> wrap(10)
        end

        defp wrap(value, n), do: {:ok, value + n}
      end
      """

      assert [_ | _] = assert_patches(source, @mutators, run: [{:ok, 1}], run: [:error])
    end

    test "a routed call on a custom pipe's right is read at its written arity, and not as piped" do
      source = """
      defmodule RoutedRight do
        import Kernel, except: [|>: 2]
        import Mutare.Test.BindPipe
        import Mutare.Test.LazyDSL

        def run(result, on?), do: result |> lazy(on?)
      end
      """

      routes = [{Mutare.Test.LazyDSL, :lazy, 2, [:lazy_expression, :expression]}]

      sites =
        assert_patches(source, [Mutare.Test.LazyStageMutator, :boolean], [run: [{:ok, 1}, true]],
          call_routes: routes
        )

      # `lazy(on?)` is `lazy/1` as written: the `lazy/2` route does not reach it, and the stage's
      # own node is withheld under a custom pipe — so the whole-call mutator has nothing to offer.
      assert sites == []

      refute Mutare.Test.metamutant_source(source, [Mutare.Test.LazyStageMutator],
               call_routes: routes
             ) =~ "lazy(result,"
    end
  end
end
