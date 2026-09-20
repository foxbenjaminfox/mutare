defmodule Mutare.ResolvePipeRoundtripPropertyTest do
  @moduledoc """
  **Resolving rewrites every pipe, and nothing is lost by it.** `Mutare.Transform.Resolve` makes
  each `Kernel.|>/2` the call it is sugar for across the whole tree — the regions no later pass
  touches included: a `:raw` argument, the inside of a `:skip`ped call, a clean copy. Those
  promise "exactly as written", and keep it because the rewrite is undone exactly where it is
  observable, in rendered source (`Mutare.Transform.Render`, `Mutare.Site`), both through
  `Mutare.Transform.WrittenPipe.written/1`:

      for every module `m`, `resugar(annotate(m))` is `m`, Mutare's own stamps aside.

  What it catches: a spelling `written/1` does not invert (a stage written without parentheses,
  a structural head as a stage), and any rewrite in `Resolve` that is not the pipe's.
  """
  use ExUnit.Case, async: true
  use PropCheck

  alias Mutare.Transform.{MetaKeys, Resolve, WrittenPipe}
  alias Mutare.TransformPropertyGenerators, as: Gen

  # Generating a module dominates a case; the other transform soaks' budget.
  @numtests 50
  @max_size 16
  @moduletag timeout: 600_000
  @moduletag :property
  @internal MetaKeys.all()

  property "resolving and resugaring a module gives back the module",
    numtests: @numtests,
    max_size: @max_size do
    forall {module_ast, spelling} <- {Gen.module_gen(), elements([:piped, :direct])} do
      parsed =
        module_ast |> Gen.respell(spelling) |> Macro.to_string() |> Sourceror.parse_string!()

      resolved = Resolve.annotate(parsed)

      (comparable(WrittenPipe.resugar(resolved)) == comparable(parsed))
      |> when_fail(IO.puts(Macro.to_string(parsed)))
    end
  end

  test "the generator writes pipes for the property to rewrite" do
    rewritten =
      for seed <- 1..25,
          {:ok, module_ast} = PropCheck.produce(Gen.module_gen(), seed),
          parsed =
            module_ast |> Gen.respell(:piped) |> Macro.to_string() |> Sourceror.parse_string!(),
          {_form, _meta, _args} = node <- Macro.prewalker(Resolve.annotate(parsed)),
          WrittenPipe.written(node) != nil,
          do: node

    assert length(rewritten) > 25
  end

  # The tree less Mutare's own stamps; meta is a keyword list, whose order nothing promises.
  defp comparable(ast) do
    Macro.prewalk(ast, fn
      {form, meta, args} when is_list(meta) ->
        {form, meta |> Keyword.drop(@internal) |> Map.new(), args}

      other ->
        other
    end)
  end
end
