defmodule Mutare.DisplacedConditionalTest do
  use ExUnit.Case, async: false
  import Mutare.Test

  alias Mutare.Test.{LazyConditional, PatternBodyConditional, PatternConditional, SourcePatch}

  for form <- [:if, :unless] do
    @form form

    test "a custom #{form} honors its pattern argument route" do
      source = imported(PatternConditional, @form, "#{@form} {:ok, x}, do: x + 1")
      opts = [call_routes: [{PatternConditional, @form, 2, [:pattern, :expression]}]]

      {[module], sites} =
        compile_metamutant(source, [:if_condition, :arithmetic, :return_value], opts)

      assert module.run() == 43
      refute Enum.any?(sites, &(&1.mutator == :if_condition))

      assert {43, 41} == observe_mutant(sites, {"x + 1", "x - 1"}, &module.run/0)
    end

    test "a custom #{form}'s raw body is not a return branch" do
      call = "#{@form} {:ok, 42}, do: {:ok, _}"
      source = imported(PatternBodyConditional, @form, call)
      opts = [call_routes: [{PatternBodyConditional, @form, 2, [:expression, :raw]}]]

      sites =
        SourcePatch.assert_patches(source, [:if_condition, :return_value], [{:run, []}], opts)

      assert sites != []
      assert Enum.all?(sites, &(&1.mutator == :return_value and &1.original_code == call))
    end

    test "a custom #{form} does not hoist a binding out of a lazy argument" do
      source =
        imported(LazyConditional, @form, "#{@form} (x = send(self(), :evaluated)), do: 1 + 2")

      opts = [call_routes: [{LazyConditional, @form, 2, [:lazy_expression, :expression]}]]
      {[module], sites} = compile_metamutant(source, [:if_condition, :arithmetic], opts)

      assert module.run() == 3
      refute_received :evaluated
      assert {3, -1} == observe_mutant(sites, {"1 + 2", "1 - 2"}, &module.run/0)
      refute_received :evaluated
      refute Enum.any?(sites, &(&1.mutator == :if_condition))
    end

    test "a local #{form} is an ordinary call with mutable arguments" do
      source = """
      defmodule Local do
        import Kernel, except: [#{@form}: 2]
        def #{@form}(value, opts), do: {value, opts}
        def run, do: #{@form}(1 + 2, do: 7)
      end
      """

      {[module], sites} = compile_metamutant(source, [:if_condition, :arithmetic])

      assert module.run() == {3, [do: 7]}
      assert [site] = sites
      assert site.mutator == :arithmetic

      assert {{3, [do: 7]}, {-1, [do: 7]}} ==
               observe_mutant(sites, {"1 + 2", "1 - 2"}, &module.run/0)
    end

    test "a displaced #{form} is not a condition even when its replacement cannot be loaded" do
      for selector <- ["", ", only: [#{@form}: 2]"] do
        source = """
        defmodule Target do
          import Kernel, except: [#{@form}: 2]
          import UnavailableConditional#{selector}
          def run(x), do: #{@form}(x, do: 7)
        end
        """

        assert diffs(source, [:if_condition]) == []
      end
    end

    test "an explicitly imported Kernel.#{form} still has condition mutants" do
      source = """
      defmodule Target do
        import Kernel, only: [def: 2, #{@form}: 2]
        def run(x), do: #{@form}(x, do: 7, else: 9)
      end
      """

      assert diffs(source, [:if_condition]) == [
               {:if_condition, "x", "true"},
               {:if_condition, "x", "false"}
             ]
    end
  end

  defp imported(module, form, call) do
    """
    defmodule Target do
      import Kernel, except: [#{form}: 2]
      import #{inspect(module)}, only: [#{form}: 2]
      def run, do: #{call}
    end
    """
  end
end
