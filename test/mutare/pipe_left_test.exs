defmodule Mutare.PipeLeftTest do
  @moduledoc """
  `Mutare.CallRouting.Call.pipe_left`: a routed call written as a pipe stage is shown the `|>`'s
  left side — its effective argument zero, which the call node does not hold — at every seam an
  adapter reads a `Call` from. Observed through `Mutare.Test.PipeLeftProbe`.
  """
  # The probe reports by message to the process running the transform, which is the test's own.
  use ExUnit.Case, async: true

  alias Mutare.CallRouting.Call
  alias Mutare.Transform.MetaKeys

  @seams [:route_arguments, :host, :mutate]

  defp transform(body, mutators \\ []) do
    source = """
    defmodule Mutare.PipeLeftFixture do
      import Mutare.Test.PipeLeftDSL

      def run(x, n) do
        #{body}
      end
    end
    """

    Mutare.Transform.transform_string_with_sites(source,
      file: "pipe_left.ex",
      mutators: mutators ++ [Mutare.Test.PipeLeftProbe]
    )
  end

  # Every `Call` the probe reported during the transform, by seam: one per routed call in the
  # source.
  defp reported do
    Stream.repeatedly(fn ->
      receive do
        {:pipe_left_probe, seam, %Call{} = call} -> {seam, call}
      after
        0 -> nil
      end
    end)
    |> Enum.take_while(& &1)
    |> Enum.group_by(&elem(&1, 0), &elem(&1, 1))
  end

  defp pipe_lefts(calls), do: Enum.map(calls, &written(&1.pipe_left))

  defp written(:unpiped), do: :unpiped
  defp written({:piped, left}), do: {:piped, Sourceror.to_string(left)}

  defp mutare_stamped?(ast) do
    {_ast, found?} =
      Macro.prewalk(ast, false, fn
        {_form, meta, _args} = node, found? when is_list(meta) ->
          {node, found? or Enum.any?(Keyword.keys(meta), &(&1 in MetaKeys.all()))}

        node, found? ->
          {node, found?}
      end)

    found?
  end

  test "a directly written call is :unpiped at every seam" do
    transform("stage(n, x > 1)")
    reported = reported()

    for seam <- @seams do
      assert pipe_lefts(reported[seam]) == [:unpiped], "at #{seam}"
    end
  end

  test "a piped call carries the pipe's left side at every seam" do
    transform("build(n + 1) |> stage(x > 1)")
    reported = reported()

    for seam <- @seams do
      assert pipe_lefts(reported[seam]) == [{:piped, "build(n + 1)"}], "at #{seam}"
    end
  end

  test "a stage mid-chain carries the whole upstream pipe, and nothing downstream" do
    transform("n |> stage(x > 1) |> stage(x > 2) |> stage(x > 3)")

    for {seam, calls} <- reported() do
      assert calls |> pipe_lefts() |> Enum.sort() ==
               [
                 {:piped, "n"},
                 {:piped, "n |> stage(x > 1)"},
                 {:piped, "n |> stage(x > 1) |> stage(x > 2)"}
               ],
             "at #{seam}"
    end
  end

  test "pipe_mode and effective_arity agree with pipe_left on every reported call" do
    transform("""
    a = stage(n, x > 1)
    b = n |> stage(x > 2) |> stage(x > 3)
    {a, b}
    """)

    calls = reported() |> Map.values() |> List.flatten()
    assert Enum.any?(calls, &(&1.pipe_left == :unpiped))
    assert Enum.any?(calls, &match?({:piped, _left}, &1.pipe_left))

    for call <- calls do
      assert call.pipe_mode == Call.pipe_mode(call.pipe_left)
      assert call.effective_arity == 2
    end
  end

  # The left side is the source AST, without the transform's own stamps — at every seam, the two
  # that read an already-resolved stage included. That is also what bounds the stamp's size: a
  # resolved left side would carry the previous stage's stamp, which carries the one before.
  test "the left side is as written: it carries none of the transform's stamps" do
    transform("n |> stage(x > 1) |> stage(x > 2) |> stage(x > 3)")

    for {seam, calls} <- reported(), %Call{pipe_left: {:piped, left}} <- calls do
      refute mutare_stamped?(left), "at #{seam}: #{Sourceror.to_string(left)}"
    end
  end

  describe "routing the piped position by the left side's shape" do
    test "a computed left side stays an expression, so the upstream code keeps its mutants" do
      %{sites: sites} = transform("build(n + 1) |> stage(x > 1)", [:arithmetic])

      assert [%{mutator: :arithmetic, original_code: "n + 1"} | _] = sites
    end

    test "a schema alias on the left is held back from the families that would swap it" do
      # Directly written, the classifier always could see the alias; piped, it could not.
      assert %{sites: []} = transform("stage(MyApp.Post, x > 1)", [:alias])
      assert %{sites: []} = transform("MyApp.Post |> stage(x > 1)", [:alias])

      # The treatment is per call, read off the shape: over a computed value the same stage
      # leaves the position an expression, and an alias inside it is an ordinary value again.
      assert %{sites: [%{mutator: :alias, original_code: "MyApp.Post"}]} =
               transform("scope(MyApp.Post) |> stage(x > 1)", [:alias])
    end

    test "a binding declaration on the left is readable, and is left as written" do
      assert %{sites: []} = transform("(p in MyApp.Post) |> stage(x > 1)", [:alias])

      assert [{:piped, {:in, _meta, [{:p, _, _}, {:__aliases__, _, [:MyApp, :Post]}]}}] =
               reported() |> Map.fetch!(:route_arguments) |> Enum.map(& &1.pipe_left)
    end
  end

  test "the piped position still cannot be :hosted — the left side is readable, not replaceable" do
    defmodule HostedLeft do
      @behaviour Mutare.Mutator
      @behaviour Mutare.CallRouting
      @behaviour Mutare.Mutator.MacroHost

      def name, do: :hosted_left
      def call_routes, do: [{Mutare.Test.PipeLeftDSL, :stage, 2, [:hosted, :raw]}]
      def hosted_macros, do: [{Mutare.Test.PipeLeftDSL, :stage, 2}]
      def host(_call, _context), do: []
    end

    error =
      assert_raise Mutare.CallRouting.ContractError, fn ->
        Mutare.Transform.transform_string_with_sites(
          """
          defmodule Mutare.PipeLeftFixture do
            import Mutare.Test.PipeLeftDSL
            def run(x, n), do: n |> stage(x > 1)
          end
          """,
          file: "pipe_left.ex",
          mutators: [HostedLeft]
        )
      end

    assert error.reason == :unhostable_pipe_argument
    assert Exception.message(error) =~ "call.pipe_left"
  end
end
