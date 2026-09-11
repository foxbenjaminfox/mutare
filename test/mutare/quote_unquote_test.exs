defmodule Mutare.QuoteUnquoteTest do
  @moduledoc """
  Runtime `quote` handling: quoted data stays raw, but an escaping
  `unquote(expr)` or `unquote_splicing(expr)` evaluates while the quote is built
  and is therefore a real runtime mutation position.
  """
  use ExUnit.Case, async: false

  alias Mutare.{Selector, Site}

  @arith [Mutare.Mutators.Arithmetic]
  @list [Mutare.Mutators.List]
  @call_removal [Mutare.Mutators.CallRemoval]
  @pattern_swap [Mutare.Mutators.PatternSwap]
  @variable_shaped_special_forms ~w(
    alias import require use
    def defp defmodule defmacro defmacrop defdelegate defoverridable defimpl defprotocol
    case cond receive try for with quote unquote unquote_splicing if unless super
  )

  setup do
    Selector.put(Selector.baseline())
    on_exit(fn -> Selector.put(Selector.baseline()) end)
    :ok
  end

  test "mutates an escaping unquote expression inside a runtime quote" do
    source = """
    defmodule Mutare.QuoteUnquoteRuntimeFixture do
      def value(x) do
        ast = quote do
          unquote(x + 1)
        end

        {value, _binding} = Code.eval_quoted(ast)
        value
      end
    end
    """

    %{metamutant: meta, sites: sites} =
      Mutare.Transform.transform_string_with_sites(source,
        file: "quote_unquote.ex",
        mutators: @arith
      )

    assert [
             %Site{
               mutator: :arithmetic,
               kind: :in_place,
               original_code: "x + 1",
               mutated_code: "x - 1"
             } = site
           ] = sites

    [{mod, _binary}] = Mutare.Test.Compile.string(meta)

    Selector.put(Selector.baseline())
    assert mod.value(10) == 11

    Selector.put(site.id)
    assert mod.value(10) == 9
  end

  test "does not wrap a live unquote argument above a binding used after the quote" do
    source = """
    defmodule Mutare.QuoteUnquoteBindingFixture do
      def value(y) do
        ast = quote do
          unquote((x = 1) + (y + 2))
        end

        {value, _binding} = Code.eval_quoted(ast)
        {value, x}
      end
    end
    """

    %{metamutant: meta, sites: sites} =
      Mutare.Transform.transform_string_with_sites(source,
        file: "quote_unquote_binding.ex",
        mutators: @arith
      )

    assert [
             %Site{
               mutator: :arithmetic,
               kind: :in_place,
               original_code: "y + 2",
               mutated_code: "y - 2"
             } = site
           ] = sites

    [{mod, _binary}] = Mutare.Test.Compile.string(meta)

    Selector.put(Selector.baseline())
    assert mod.value(10) == {13, 1}

    Selector.put(site.id)
    assert mod.value(10) == {9, 1}
  end

  for name <- @variable_shaped_special_forms do
    test "does not mistake a live-unquote variable named #{name} for a construct" do
      assert_variable_shaped_special_form_unquotes(unquote(name))
    end
  end

  test "prunes live-unquote ancestor mutants inside scoped fn children" do
    source = """
    defmodule Mutare.QuoteUnquoteFnBindingFixture do
      def ast(y) do
        quote do
          unquote(List.wrap(fn -> (x = 1) + (y + 2); x end) ++ List.wrap(y + 3))
        end
      end
    end
    """

    %{metamutant: meta, sites: sites} =
      Mutare.Transform.transform_string_with_sites(
        source,
        file: "quote_unquote_fn_binding.ex",
        mutators: @arith ++ @list
      )

    assert %Site{
             mutator: :arithmetic,
             kind: :in_place,
             original_code: "y + 2",
             mutated_code: "y - 2"
           } = Enum.find(sites, &(&1.original_code == "y + 2"))

    assert %Site{
             mutator: :arithmetic,
             kind: :in_place,
             original_code: "y + 3",
             mutated_code: "y - 3"
           } = Enum.find(sites, &(&1.original_code == "y + 3"))

    assert %Site{mutator: :list, kind: :in_place} =
             Enum.find(sites, &(&1.mutator == :list))

    refute Enum.any?(
             sites,
             &(&1.mutator == :arithmetic and String.contains?(&1.original_code, "x = 1"))
           )

    assert [_ | _] = Mutare.Test.Compile.string(meta)
  end

  test "does not wrap a live unquote argument above a binding-pattern macro used after the quote" do
    source = """
    defmodule Mutare.QuoteUnquoteBindingMacroFixture do
      def value(y) do
        ast = quote do
          unquote(destructure([x], List.wrap(y)) ++ List.wrap(y + 2))
        end

        {value, _binding} = Code.eval_quoted(ast)
        {value, x}
      end
    end
    """

    %{metamutant: meta, sites: sites} =
      Mutare.Transform.transform_string_with_sites(
        source,
        file: "quote_unquote_binding_macro.ex",
        mutators: @arith ++ @list
      )

    assert [
             %Site{
               mutator: :arithmetic,
               kind: :in_place,
               original_code: "y + 2",
               mutated_code: "y - 2"
             } = site
           ] = sites

    [{mod, _binary}] = Mutare.Test.Compile.string(meta)

    Selector.put(Selector.baseline())
    assert mod.value(5) == {[5, 7], 5}

    Selector.put(site.id)
    assert mod.value(5) == {[5, 3], 5}
  end

  test "keeps a live-unquote ancestor mutant when a nested quote only contains quoted bindings" do
    source = """
    defmodule Mutare.QuoteUnquoteNestedQuoteBindingFixture do
      def value(y) do
        ast = quote do
          unquote(List.wrap(quote do
                    x = 1
                  end) ++ List.wrap(y + 2))
        end

        {value, _binding} = Code.eval_quoted(ast)
        value
      end
    end
    """

    %{metamutant: meta, sites: sites} =
      Mutare.Transform.transform_string_with_sites(
        source,
        file: "quote_unquote_nested_quote_binding.ex",
        mutators: @arith ++ @list
      )

    assert [
             %Site{mutator: :arithmetic, original_code: "y + 2"},
             %Site{mutator: :list}
           ] = sites

    assert %Site{
             mutator: :list,
             kind: :in_place,
             original_code: original_code,
             mutated_code: mutated_code
           } = list_site = Enum.find(sites, &(&1.mutator == :list))

    assert %Site{
             mutator: :arithmetic,
             kind: :in_place,
             original_code: "y + 2",
             mutated_code: "y - 2"
           } = arith_site = Enum.find(sites, &(&1.mutator == :arithmetic))

    assert original_code =~ "List.wrap("
    assert original_code =~ "quote do"
    assert original_code =~ "++ List.wrap(y + 2)"
    assert mutated_code =~ "List.wrap("
    assert mutated_code =~ "quote do"
    assert mutated_code =~ "-- List.wrap(y + 2)"

    [{mod, _binary}] = Mutare.Test.Compile.string(meta)

    Selector.put(Selector.baseline())
    assert mod.value(5) == [1, 7]

    Selector.put(list_site.id)
    assert mod.value(5) == [1]

    Selector.put(arith_site.id)
    assert mod.value(5) == [1, 3]
  end

  test "prunes live-unquote ancestor mutants for bindings in disabled nested quote options" do
    source = """
    defmodule Mutare.QuoteUnquoteDisabledNestedQuoteOptionFixture do
      def value(y) do
        x = :outer

        ast = quote do
          unquote(List.wrap(quote do
                    quote bind_quoted: [z: unquote((x = y))], do: z
                  end) ++ List.wrap(y + 1))
        end

        {ast, x}
      end
    end
    """

    %{metamutant: meta, sites: sites} =
      Mutare.Transform.transform_string_with_sites(
        source,
        file: "quote_unquote_disabled_nested_quote_option.ex",
        mutators: @arith ++ @list
      )

    assert [
             %Site{
               mutator: :arithmetic,
               kind: :in_place,
               original_code: "y + 1",
               mutated_code: "y - 1"
             }
           ] = sites

    refute Enum.any?(sites, &(&1.mutator == :list))
    assert [_ | _] = Mutare.Test.Compile.string(meta)
  end

  test "prunes live-unquote ancestor mutants for bindings in runtime quote option values" do
    source = """
    defmodule Mutare.QuoteUnquoteRuntimeQuoteOptionBindingFixture do
      def value(y) do
        ast = quote do
          unquote(List.wrap(quote line: (x = y) do
                    :ok
                  end) ++ List.wrap(y + 1))
        end

        {ast, x}
      end
    end
    """

    %{metamutant: meta, sites: sites} =
      Mutare.Transform.transform_string_with_sites(
        source,
        file: "quote_unquote_runtime_quote_option_binding.ex",
        mutators: @arith ++ @list
      )

    assert [
             %Site{
               mutator: :arithmetic,
               kind: :in_place,
               original_code: "y + 1",
               mutated_code: "y - 1"
             } = site
           ] = sites

    refute Enum.any?(sites, &(&1.mutator == :list))

    [{mod, _binary}] = Mutare.Test.Compile.string(meta)

    Selector.put(Selector.baseline())
    {_ast, x} = mod.value(10)
    assert x == 10

    Selector.put(site.id)
    {_ast, x} = mod.value(10)
    assert x == 10
  end

  test "keeps an outer live-unquote mutant when a case body has only branch-local bindings" do
    source = """
    defmodule Mutare.QuoteUnquoteCaseBindingFixture do
      def value(y) do
        ast = quote do
          unquote((case y do
                     _ -> x = 1
                   end) + 1)
        end

        {value, _binding} = Code.eval_quoted(ast)
        value
      end
    end
    """

    %{metamutant: meta, sites: sites} =
      Mutare.Transform.transform_string_with_sites(source,
        file: "quote_unquote_case_binding.ex",
        mutators: @arith
      )

    assert [
             %Site{
               mutator: :arithmetic,
               kind: :in_place,
               original_code: original_code,
               mutated_code: mutated_code
             } = site
           ] = sites

    assert original_code =~ "case y do"
    assert original_code =~ "+ 1"
    assert mutated_code =~ "case y do"
    assert mutated_code =~ "- 1"

    [{mod, _binary}] = Mutare.Test.Compile.string(meta)

    Selector.put(Selector.baseline())
    assert mod.value(:anything) == 2

    Selector.put(site.id)
    assert mod.value(:anything) == 0
  end

  test "keeps re-homed binding-pattern macro candidates inside a live unquote" do
    source = """
    defmodule Mutare.QuoteUnquoteMacroPatternFixture do
      def value(y) do
        ast = quote do
          unquote((destructure([x, z], y); x - z))
        end

        {value, _binding} = Code.eval_quoted(ast)
        value
      end
    end
    """

    %{metamutant: meta, sites: sites} =
      Mutare.Transform.transform_string_with_sites(
        source,
        file: "quote_unquote_macro_pattern.ex",
        mutators: @pattern_swap
      )

    assert [
             %Site{
               mutator: :pattern_swap,
               kind: :in_place,
               original_code: "[x, z]",
               mutated_code: "[z, x]"
             } = site
           ] = sites

    [{mod, _binary}] = Mutare.Test.Compile.string(meta)

    Selector.put(Selector.baseline())
    assert mod.value([3, 10]) == -7

    Selector.put(site.id)
    assert mod.value([3, 10]) == 7
  end

  test "mutates an escaping unquote_splicing expression inside a runtime quote" do
    source = """
    defmodule Mutare.QuoteUnquoteSplicingFixture do
      def value(x) do
        ast = quote do
          [unquote_splicing([x + 1])]
        end

        {value, _binding} = Code.eval_quoted(ast)
        value
      end
    end
    """

    %{metamutant: meta, sites: sites} =
      Mutare.Transform.transform_string_with_sites(source,
        file: "quote_unquote_splicing.ex",
        mutators: @arith
      )

    assert [%Site{original_code: "x + 1", mutated_code: "x - 1"} = site] = sites
    [{mod, _binary}] = Mutare.Test.Compile.string(meta)

    Selector.put(Selector.baseline())
    assert mod.value(10) == [11]

    Selector.put(site.id)
    assert mod.value(10) == [9]
  end

  test "mutates an escaping unquote expression in a bracketed quote do-block" do
    source = """
    defmodule Mutare.QuoteBracketedDoFixture do
      def value(x) do
        ast = quote [do: unquote(x + 1)]
        {value, _binding} = Code.eval_quoted(ast)
        value
      end
    end
    """

    %{metamutant: meta, sites: sites} =
      Mutare.Transform.transform_string_with_sites(source,
        file: "quote_bracketed_do.ex",
        mutators: @arith
      )

    assert [%Site{original_code: "x + 1", mutated_code: "x - 1"} = site] = sites
    [{mod, _binary}] = Mutare.Test.Compile.string(meta)

    Selector.put(Selector.baseline())
    assert mod.value(10) == 11

    Selector.put(site.id)
    assert mod.value(10) == 9
  end

  test "resolves an escaping unquote expression under the quote site's aliases" do
    source = """
    defmodule Mutare.QuoteUnquoteAliasFixture do
      alias String, as: S

      def value(s) do
        ast = quote do
          alias List, as: S
          unquote(S.trim(s))
        end

        {value, _binding} = Code.eval_quoted(ast)
        value
      end
    end
    """

    %{metamutant: meta, sites: sites} =
      Mutare.Transform.transform_string_with_sites(source,
        file: "quote_unquote_alias.ex",
        mutators: @call_removal
      )

    assert [
             %Site{
               mutator: :call_removal,
               kind: :in_place,
               original_code: "S.trim(s)",
               mutated_code: "s"
             } = site
           ] = sites

    [{mod, _binary}] = Mutare.Test.Compile.string(meta)

    Selector.put(Selector.baseline())
    assert mod.value("  padded  ") == "padded"

    Selector.put(site.id)
    assert mod.value("  padded  ") == "  padded  "
  end

  test "mutates an escaping unquote expression used as a quoted call head" do
    source = """
    defmodule Mutare.QuoteUnquoteCallHeadFixture do
      def ast(x) do
        quote do
          unquote(if x + 1 > 0, do: :foo, else: :bar)()
        end
      end
    end
    """

    %{metamutant: meta, sites: sites} =
      Mutare.Transform.transform_string_with_sites(source,
        file: "quote_unquote_call_head.ex",
        mutators: @arith
      )

    assert [%Site{original_code: "x + 1", mutated_code: "x - 1"} = site] = sites
    [{mod, _binary}] = Mutare.Test.Compile.string(meta)

    Selector.put(Selector.baseline())
    assert Macro.to_string(mod.ast(0)) == "foo()"

    Selector.put(site.id)
    assert Macro.to_string(mod.ast(0)) == "bar()"
  end

  test "resolves an escaping unquote expression used as a quoted dot receiver" do
    source = """
    defmodule Mutare.QuoteUnquoteReceiverFixture do
      alias String, as: S

      def ast(s) do
        quote do
          unquote(S.trim(s)).trim(s)
        end
      end
    end
    """

    %{metamutant: meta, sites: sites} =
      Mutare.Transform.transform_string_with_sites(source,
        file: "quote_unquote_receiver.ex",
        mutators: @call_removal
      )

    assert [
             %Site{
               mutator: :call_removal,
               kind: :in_place,
               original_code: "S.trim(s)",
               mutated_code: "s"
             } = site
           ] = sites

    [{mod, _binary}] = Mutare.Test.Compile.string(meta)

    Selector.put(Selector.baseline())
    assert Macro.to_string(mod.ast("  padded  ")) == "\"padded\".trim(s)"

    Selector.put(site.id)
    assert Macro.to_string(mod.ast("  padded  ")) == "\"  padded  \".trim(s)"
  end

  test "keeps ordinary quoted body data raw while mutating escaping unquote args" do
    source = """
    defmodule Mutare.QuoteUnquoteDataFixture do
      def ast(x) do
        quote do
          {unquote(x + 1), 1 + 2}
        end
      end
    end
    """

    %{metamutant: meta, sites: sites} =
      Mutare.Transform.transform_string_with_sites(source,
        file: "quote_data.ex",
        mutators: @arith
      )

    assert [%Site{original_code: "x + 1"}] = sites
    refute Enum.any?(sites, &(&1.original_code == "1 + 2"))
    assert [_ | _] = Mutare.Test.Compile.string(meta)
  end

  test "quote unquote: false keeps unquote calls as quoted data" do
    source = """
    defmodule Mutare.QuoteUnquoteFalseFixture do
      def ast(x) do
        quote unquote: false do
          unquote(x + 1)
        end
      end
    end
    """

    %{metamutant: meta, sites: sites} =
      Mutare.Transform.transform_string_with_sites(source,
        file: "quote_unquote_false.ex",
        mutators: @arith
      )

    assert sites == []
    assert [_ | _] = Mutare.Test.Compile.string(meta)
  end

  test "bracketed quote unquote: false keeps unquote calls as quoted data" do
    source = """
    defmodule Mutare.QuoteBracketedUnquoteFalseFixture do
      def ast(x) do
        quote [unquote: false], do: unquote(x + 1)
      end
    end
    """

    %{metamutant: meta, sites: sites} =
      Mutare.Transform.transform_string_with_sites(source,
        file: "quote_bracketed_unquote_false.ex",
        mutators: @arith
      )

    assert sites == []
    assert [_ | _] = Mutare.Test.Compile.string(meta)
  end

  test "bind_quoted keeps body unquote calls as quoted data" do
    source = """
    defmodule Mutare.QuoteBindQuotedFixture do
      def ast(x) do
        quote bind_quoted: [y: x] do
          unquote(y + 1)
        end
      end
    end
    """

    %{metamutant: meta, sites: sites} =
      Mutare.Transform.transform_string_with_sites(source,
        file: "quote_bind_quoted.ex",
        mutators: @arith
      )

    assert sites == []
    assert [_ | _] = Mutare.Test.Compile.string(meta)
  end

  test "bracketed bind_quoted keeps body unquote calls as quoted data" do
    source = """
    defmodule Mutare.QuoteBracketedBindQuotedFixture do
      def ast(x) do
        quote [bind_quoted: [y: x]], do: unquote(y + 1)
      end
    end
    """

    %{metamutant: meta, sites: sites} =
      Mutare.Transform.transform_string_with_sites(source,
        file: "quote_bracketed_bind_quoted.ex",
        mutators: @arith
      )

    assert sites == []
    assert [_ | _] = Mutare.Test.Compile.string(meta)
  end

  test "a single unquote inside a nested quote is still quoted data" do
    source = """
    defmodule Mutare.QuoteUnquoteNestedFixture do
      def ast(x) do
        quote do
          quote do
            unquote(x + 1)
          end
        end
      end
    end
    """

    %{metamutant: meta, sites: sites} =
      Mutare.Transform.transform_string_with_sites(source,
        file: "quote_nested.ex",
        mutators: @arith
      )

    assert sites == []
    assert [_ | _] = Mutare.Test.Compile.string(meta)
  end

  test "stacked unquotes inside a nested quote are still quoted data" do
    source = """
    defmodule Mutare.QuoteUnquoteStackedNestedFixture do
      def ast(x) do
        quote do
          quote do
            unquote(unquote(x + 1))
          end
        end
      end
    end
    """

    %{metamutant: meta, sites: sites} =
      Mutare.Transform.transform_string_with_sites(source,
        file: "quote_stacked_nested.ex",
        mutators: @arith
      )

    assert sites == []
    assert [_ | _] = Mutare.Test.Compile.string(meta)
  end

  defp assert_variable_shaped_special_form_unquotes(name) do
    module = "Mutare.QuoteUnquote#{Macro.camelize(name)}VariableFixture"

    source = """
    defmodule #{module} do
      def value(x) do
        #{name} = x + 1

        ast = quote do
          unquote(#{name})
        end

        {value, _binding} = Code.eval_quoted(ast)
        value
      end
    end
    """

    %{metamutant: meta, sites: sites} =
      Mutare.Transform.transform_string_with_sites(source,
        file: "quote_unquote_#{name}_variable.ex",
        mutators: @arith
      )

    assert [
             %Site{
               mutator: :arithmetic,
               kind: :in_place,
               original_code: "x + 1",
               mutated_code: "x - 1"
             } = site
           ] = sites

    [{mod, _binary}] = Mutare.Test.Compile.string(meta)

    Selector.put(Selector.baseline())
    assert mod.value(10) == 11

    Selector.put(site.id)
    assert mod.value(10) == 9
  end
end
