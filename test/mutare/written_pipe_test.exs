defmodule Mutare.WrittenPipeTest do
  # `WrittenPipe.direct/1` makes a `|>` the call it is sugar for and stamps that call with the
  # operator's meta alone; `written/1` rebuilds the pipe from the call. Two things follow, and
  # both are pinned here: the rebuild is an exact inverse for every spelling `Kernel.|>/2`
  # pipes into, and the stamp costs a chain nothing per upstream stage.
  use ExUnit.Case, async: true

  alias Mutare.Transform.{Meta, MetaKeys, Resolve, WrittenPipe}

  defp resolved(code), do: code |> Sourceror.parse_string!() |> Resolve.annotate()

  # `direct/1` hands the call the pipe's node identity and `written/1` leaves it there; meta
  # is a keyword list, whose order neither promises.
  defp comparable({:|>, pipe_meta, [left, {head, stage_meta, args}]}) do
    {:|>, pipe_meta,
     [left, {head, stage_meta |> Keyword.delete(MetaKeys.nid_key()) |> Map.new(), args}]}
  end

  for code <- [
        "xs |> Enum.take(2)",
        "xs |> Enum.count()",
        "n |> to_string",
        "n |> to_string()",
        "n |> Integer.to_string",
        "n |> fun.()",
        "n |> fun.(1)",
        "n |> case do\n  1 -> :one\n  _ -> :other\nend",
        "(a + b) |> Kernel.+(1)",
        "xs |> Enum.map(&(&1 + 1)) |> Enum.sum()"
      ] do
    test "written/1 undoes direct/1 for `#{String.replace(code, "\n", " ")}`" do
      pipe = resolved(unquote(code))
      call = WrittenPipe.direct(pipe)

      refute match?({:|>, _meta, _operands}, call)
      assert comparable(WrittenPipe.written(call)) == comparable(pipe)
    end
  end

  test "the rebuilt stage is marked, so it cannot be read one argument short" do
    {:|>, _meta, [_left, stage]} =
      "xs |> Enum.take(2)" |> resolved() |> WrittenPipe.direct() |> WrittenPipe.written()

    assert Meta.routed_direct?(stage)
  end

  test "written/1 rebuilds the pipe around whatever argument 0 the call now holds" do
    {head, meta, [_xs | rest]} = "xs |> Enum.take(2)" |> resolved() |> WrittenPipe.direct()
    ys = {:ys, [], nil}

    assert {:|>, _pipe_meta, [^ys, _stage]} = WrittenPipe.written({head, meta, [ys | rest]})
  end

  test "a node that was not written as a pipe has no written form" do
    assert WrittenPipe.written(resolved("Enum.take(xs, 2)")) == nil
    assert WrittenPipe.written(:atom) == nil
  end

  test "the stamp is the operator's meta, and holds no operand" do
    {:|>, pipe_meta, _operands} = pipe = resolved("xs |> Enum.map(&(&1 + 1)) |> Enum.sum()")

    assert Meta.written_pipe_meta(WrittenPipe.direct(pipe)) == pipe_meta
  end

  # Flat size is what a copy costs — a message, ETS, `term_to_binary`. A stamp holding the
  # written pipe made that a sum of the chain's prefixes (33x at 64 stages); the meta alone
  # keeps it linear.
  test "a rewritten chain is no larger, copied, than a small multiple of the chain as written" do
    chain = Enum.map_join(1..64, "\n", fn i -> "|> Enum.map(&(&1 + #{i}))" end)
    pipe = resolved("xs\n" <> chain)
    rewritten = Macro.prewalk(pipe, &WrittenPipe.direct/1)

    refute match?({:|>, _meta, _operands}, rewritten)
    assert :erts_debug.flat_size(rewritten) < 2 * :erts_debug.flat_size(pipe)
  end

  test "resugar/1 spells every rewritten call in a node as the pipe it was" do
    pipe = resolved("xs |> Enum.map(&(&1 + 1)) |> Enum.sum()")
    rewritten = Macro.prewalk(pipe, &WrittenPipe.direct/1)

    assert rewritten |> WrittenPipe.resugar() |> Sourceror.to_string() ==
             "xs |> Enum.map(&(&1 + 1)) |> Enum.sum()"
  end
end
