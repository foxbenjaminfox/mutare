defmodule Mutare.WrittenPipeTest do
  # `Mutare.Transform.Resolve` makes a `Kernel.|>/2` the call it is sugar for and stamps that
  # call with the operator's meta alone; `WrittenPipe.written/1` rebuilds the pipe from the call.
  # Two things follow, and both are pinned here: the rebuild is an exact inverse for every
  # spelling `Kernel.|>/2` pipes into, and the stamp costs a chain nothing per upstream stage.
  use ExUnit.Case, async: true

  alias Mutare.Transform.{Meta, MetaKeys, Resolve, WrittenPipe}

  @internal MetaKeys.all()

  defp parsed(code), do: Sourceror.parse_string!(code)
  defp resolved(code), do: code |> parsed() |> Resolve.annotate()

  # The tree less Mutare's own stamps; meta is a keyword list, whose order nothing promises.
  defp comparable(ast) do
    Macro.prewalk(ast, fn
      {form, meta, args} when is_list(meta) ->
        {form, meta |> Keyword.drop(@internal) |> Map.new(), args}

      other ->
        other
    end)
  end

  for code <- [
        "xs |> Enum.take(2)",
        "xs |> Enum.count()",
        "x |> (abs() |> div(2))",
        "x |> (abs() |> (div(2) |> rem(3)))",
        "x |> ((abs() |> div(2)) |> rem(3))",
        "(x |> (abs() |> div(2))) |> rem(3)",
        "x |> (abs |> (div(2) |> (rem(3) |> to_string)))",
        "x |> (\n  # first stage\n  abs()\n  |> div(2)\n)",
        "n |> to_string",
        "n |> to_string()",
        "n |> Integer.to_string",
        "n |> fun.()",
        "n |> fun.(1)",
        "n |> case do\n  1 -> :one\n  _ -> :other\nend",
        "(a + b) |> Kernel.+(1)",
        "xs |> Enum.map(&(&1 + 1)) |> Enum.sum()",
        "keep(xs |> Enum.map(&(&1 |> abs())), ys |> Enum.sum())"
      ] do
    test "resolving `#{String.replace(code, "\n", " ")}` leaves no pipe, and resugar/1 restores it exactly" do
      call = resolved(unquote(code))

      refute Macro.prewalker(call) |> Enum.any?(&match?({:|>, _meta, _operands}, &1))
      assert call |> WrittenPipe.resugar() |> comparable() == comparable(parsed(unquote(code)))
    end
  end

  test "written/1 rebuilds the pipe around whatever argument 0 the call now holds" do
    {head, meta, [_xs | rest]} = resolved("xs |> Enum.take(2)")
    ys = {:ys, [], nil}

    assert {:|>, _pipe_meta, [^ys, _stage]} = WrittenPipe.written({head, meta, [ys | rest]})
  end

  test "right-nested stages resolve with their complete arities" do
    call = resolved("x |> (abs() |> div(2))")
    assert {:div, _, [{:abs, _, [{:x, _, nil}]}, {:__block__, _, [2]}]} = call
  end

  test "a node built on a piped call's meta that is no stage has no written form" do
    {_head, meta, [n, two]} = resolved("n |> div(2)")

    # What a mutator that keeps the offered call's meta may build: an operator, a literal.
    for node <- [
          {:-, meta, [n, two]},
          {:-, meta, [n]},
          {:__block__, meta, [0]},
          {:*, meta, [n, two]}
        ] do
      assert WrittenPipe.written(node) == nil
      assert WrittenPipe.resugar(node) == node
    end

    # A renamed call is still a stage.
    assert {:|>, _pipe_meta, [^n, {:rem, _meta, [^two]}]} =
             WrittenPipe.written({:rem, meta, [n, two]})
  end

  test "a node that was not written as a pipe has no written form" do
    assert WrittenPipe.written(resolved("Enum.take(xs, 2)")) == nil
    assert WrittenPipe.written(:atom) == nil
  end

  test "the stamp is the operator's meta, and holds no operand" do
    {:|>, pipe_meta, _operands} = parsed("xs |> Enum.map(&(&1 + 1)) |> Enum.sum()")
    stamp = Meta.written_pipe_meta(resolved("xs |> Enum.map(&(&1 + 1)) |> Enum.sum()"))

    assert Keyword.drop(stamp, @internal) == pipe_meta
  end

  # Flat size is what a copy costs — a message, ETS, `term_to_binary`. A stamp holding the
  # written pipe made that a sum of the chain's prefixes (33x at 64 stages); the meta alone
  # keeps it linear. The environment every call retains is one shared reference, released
  # before the tree is retained or copied (`Resolve.forget/1`), so it is measured without.
  test "a resolved chain is no larger, copied, than a small multiple of the chain as written" do
    chain = Enum.map_join(1..64, "\n", fn i -> "|> Enum.map(&(&1 + #{i}))" end)

    assert :erts_debug.flat_size(Resolve.forget(resolved("xs\n" <> chain))) <
             2 * :erts_debug.flat_size(parsed("xs\n" <> chain))
  end

  test "nested groups do not double their enclosing context at every rotation" do
    size = fn n ->
      stages = Enum.reduce(2..n, "abs()", fn _, stages -> "(#{stages} |> abs())" end)
      :erts_debug.flat_size(resolved("x |> " <> stages))
    end

    # Grouped prefixes carry the remaining stages for source patches: quadratic is expected,
    # but copying that continuation into the grouping history as well makes it exponential.
    assert size.(16) < 5 * size.(8)
  end
end
