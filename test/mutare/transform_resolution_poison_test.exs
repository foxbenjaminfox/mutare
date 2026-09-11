defmodule Mutare.TransformResolutionPoisonTest do
  # Import-resolution *poison attribution*: a hidden import that would mis-resolve a bare call
  # is made to fail the compile instead, and the compiler's own stderr must let
  # `Mutare.Poison.ids/2` blame the right mutant. That contract is the real compiler output,
  # so these capture the global `:stderr` device (`compile_error_output/3`) and stay
  # `async: false`. Split from transform_resolution_test.exs, which is otherwise pure.
  use ExUnit.Case, async: false
  import Mutare.Test.Metamutant

  describe "import resolution → poison attribution" do
    test "a hidden except-plus-replacement import poisons instead of silently mis-resolving" do
      {meta, sites, _} =
        Mutare.Transform.transform_string_with_sites(
          """
          defmodule HiddenImportReplacement do
            def filter(xs, fun), do: Enum.map(xs, fun)

            defmacro __using__(_) do
              quote do
                import Enum, except: [filter: 2]
                import HiddenImportReplacement, only: [filter: 2]
              end
            end
          end

          defmodule ImpHiddenReplacement do
            import Enum
            use HiddenImportReplacement

            def f(xs, fun), do: filter(xs, fun)
          end
          """,
          mutators: [Mutare.Mutators.Collection]
        )

      assert [%{mutator: :collection, original_code: "filter(xs, fun)"} = site] = sites
      assert meta =~ "import Elixir.Enum, only: [filter: 2]"

      stderr =
        compile_error_output(
          meta,
          # Elixir <1.20: "filter/2 imported from both Enum and HiddenImportReplacement";
          # Elixir 1.20+: "conflicting filter/2 import from modules Enum and HiddenImportReplacement".
          ["filter/2", "Enum and HiddenImportReplacement"],
          "lib/hidden_import_replacement.ex"
        )

      assert Mutare.Poison.ids(stderr, %{"lib/hidden_import_replacement.ex" => meta}) ==
               MapSet.new([site.id])
    end

    test "the import witness also protects lifted guard mutants" do
      {meta, sites, _} =
        Mutare.Transform.transform_string_with_sites(
          """
          defmodule HiddenIntegerReplacement do
            defmacro is_even(n), do: quote(do: is_integer(unquote(n)))

            defmacro __using__(_) do
              quote do
                import Integer, except: [is_even: 1]
                import HiddenIntegerReplacement, only: [is_even: 1]
              end
            end
          end

          defmodule ImpHiddenGuardReplacement do
            import Integer
            use HiddenIntegerReplacement

            def f(n) when is_even(n), do: true
            def f(_), do: false
          end
          """,
          mutators: [Mutare.Mutators.IntegerCall]
        )

      assert [%{kind: :lifted, mutator: :integer_call, original_code: "is_even(n)"} = site] =
               Enum.filter(sites, &(&1.mutator == :integer_call))

      assert meta =~ "import Elixir.Integer, only: [is_even: 1]"

      stderr =
        compile_error_output(
          meta,
          # Elixir <1.20: "is_even/1 imported from both Integer and HiddenIntegerReplacement";
          # Elixir 1.20+: "conflicting is_even/1 import from modules Integer and HiddenIntegerReplacement".
          ["is_even/1", "Integer and HiddenIntegerReplacement"],
          "lib/hidden_integer_replacement.ex"
        )

      assert Mutare.Poison.ids(stderr, %{"lib/hidden_integer_replacement.ex" => meta}) ==
               MapSet.new([site.id])
    end

    for construct <- [:fn, :receive],
        scope <- [:bound, :unbound],
        hidden <- [:is_even, :is_odd] do
      expression =
        case construct do
          :fn -> "fn n when is_even(n) -> true; _ -> false end"
          :receive -> "receive do n when is_even(n) -> true after 0 -> false end"
        end

      definition =
        case scope do
          :bound -> "def f, do: (#{expression})"
          :unbound -> "def f do raise \"enter rescue\" rescue _ -> #{expression} end"
        end

      test "#{construct} guard witnesses reject hidden #{hidden} imports in #{scope} scopes" do
        hidden = unquote(hidden)
        suffix = unquote("#{construct}_#{scope}_#{hidden}")
        provider = Module.concat(__MODULE__, "HiddenInteger_#{suffix}")
        target = Module.concat(__MODULE__, "ImportedGuard_#{suffix}")

        source = """
        defmodule #{inspect(provider)} do
          defmacro #{hidden}(n), do: quote(do: is_integer(unquote(n)))

          defmacro __using__(_) do
            quote do
              import Integer, except: [#{hidden}: 1]
              import #{inspect(provider)}, only: [#{hidden}: 1]
            end
          end
        end

        defmodule #{inspect(target)} do
          import Integer
          use #{inspect(provider)}
          #{unquote(definition)}
        end
        """

        on_exit(fn ->
          for module <- [provider, target] do
            :code.purge(module)
            :code.delete(module)
          end
        end)

        opts = [mutators: [Mutare.Mutators.IntegerCall]]
        {meta, sites, next} = Mutare.Transform.transform_string_with_sites(source, opts)
        assert [%{kind: :in_place, original_code: "is_even(n)"} = site] = sites

        {recovered, _, ^next} =
          Mutare.Transform.transform_string_with_sites(
            source,
            opts ++ [skip_ids: MapSet.new([site.id])]
          )

        assert_compiles(source)
        file = "lib/hidden_integer_#{suffix}.ex"

        stderr =
          compile_error_output(meta, ["#{hidden}/1", "Integer and #{inspect(provider)}"], file)

        assert Mutare.Poison.ids(stderr, %{file => meta}) == MapSet.new([site.id])

        assert_compiles(recovered)

        {visible, [_site], _} =
          source
          |> String.replace("use #{inspect(provider)}", "")
          |> Mutare.Transform.transform_string_with_sites(opts)

        assert_compiles(visible)
      end
    end
  end
end
