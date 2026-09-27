defmodule Mutare.Transform.DiagnosticsTest do
  use ExUnit.Case, async: true
  alias Mutare.Transform.Diagnostics

  test "suppression survives nested transforms and restores the caller after failure" do
    assert ExUnit.CaptureIO.capture_io(:stderr, fn ->
             assert_raise RuntimeError, "probe", fn ->
               Diagnostics.with_warnings(false, fn ->
                 Diagnostics.with_warnings(true, fn ->
                   Diagnostics.warn(fn -> raise "must not format a suppressed warning" end)
                 end)

                 raise "probe"
               end)
             end

             Diagnostics.warn(fn -> "restored" end)
           end) =~ "restored"
  end

  defmodule Misattributed do
    @behaviour Mutare.Mutator
    alias Mutare.Mutator.Mutation
    @impl true
    def name, do: :misattributed
    @impl true
    def mutate({:probe, _, [_]} = node),
      do: [Mutation.new(node, attribution: Mutation.at_drop({:missing, [], nil}))]

    def mutate(_), do: :skip
  end

  test "an island collected in a child task keeps the originating pass's warning policy" do
    registry = Mutare.CallRouting.Registry.build([], [], [])
    expression = Sourceror.parse_string!("probe(1)")

    for enabled? <- [true, false] do
      env = Mutare.Transform.Resolve.Environment.new(registry, warnings: enabled?)

      warning =
        ExUnit.CaptureIO.capture_io(:stderr, fn ->
          assert [_] =
                   Task.async(fn ->
                     Mutare.Analyze.collect_expression(expression, [Misattributed], %{
                       resolution: env
                     })
                   end)
                   |> Task.await()
        end)

      assert warning =~ "ignoring a mutation :attribution" == enabled?
    end
  end
end
