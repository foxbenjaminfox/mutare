defmodule Mutare.QuoteUnquoteTest do
  @moduledoc """
  Runtime `quote` handling: quoted data stays raw, but an escaping
  `unquote(expr)` or `unquote_splicing(expr)` evaluates while the quote is built
  and is therefore a real runtime mutation position.
  """
  use ExUnit.Case, async: false

  alias Mutare.{Selector, Site}

  @arith [Mutare.Mutators.Arithmetic]
  @call_removal [Mutare.Mutators.CallRemoval]

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

    {meta, sites, _next_id} =
      Mutare.transform_string(source, file: "quote_unquote.ex", mutators: @arith)

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

    {meta, sites, _next_id} =
      Mutare.transform_string(source, file: "quote_unquote_splicing.ex", mutators: @arith)

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

    {meta, sites, _next_id} =
      Mutare.transform_string(source, file: "quote_bracketed_do.ex", mutators: @arith)

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

    {meta, sites, _next_id} =
      Mutare.transform_string(source, file: "quote_unquote_alias.ex", mutators: @call_removal)

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

    {meta, sites, _next_id} =
      Mutare.transform_string(source, file: "quote_unquote_call_head.ex", mutators: @arith)

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

    {meta, sites, _next_id} =
      Mutare.transform_string(source, file: "quote_unquote_receiver.ex", mutators: @call_removal)

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

    {meta, sites, _next_id} =
      Mutare.transform_string(source, file: "quote_data.ex", mutators: @arith)

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

    {meta, sites, _next_id} =
      Mutare.transform_string(source, file: "quote_unquote_false.ex", mutators: @arith)

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

    {meta, sites, _next_id} =
      Mutare.transform_string(source, file: "quote_bracketed_unquote_false.ex", mutators: @arith)

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

    {meta, sites, _next_id} =
      Mutare.transform_string(source, file: "quote_bind_quoted.ex", mutators: @arith)

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

    {meta, sites, _next_id} =
      Mutare.transform_string(source, file: "quote_bracketed_bind_quoted.ex", mutators: @arith)

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

    {meta, sites, _next_id} =
      Mutare.transform_string(source, file: "quote_nested.ex", mutators: @arith)

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

    {meta, sites, _next_id} =
      Mutare.transform_string(source, file: "quote_stacked_nested.ex", mutators: @arith)

    assert sites == []
    assert [_ | _] = Mutare.Test.Compile.string(meta)
  end
end
