defmodule Mutare.SourcePatchFixturesTest do
  use ExUnit.Case, async: true

  alias Mutare.Test.SourcePatchFixtures, as: F

  test "observations distinguish order and repeated evaluation, including before a failure" do
    assert {{:returned, 2}, [:first, :second, :first]} =
             F.observe(fn ->
               F.tick(1, :first)
               F.tick(2, :second)
               F.tick(2, :first)
             end)

    assert {{:raised, ArithmeticError}, [:before]} =
             F.observe(fn -> div(1, F.tick(0, :before)) end)

    assert {{:throw, :reason}, [:before]} =
             F.observe(fn -> throw(F.tick(:reason, :before)) end)

    assert {{:exit, :reason}, [:before]} =
             F.observe(fn -> exit(F.tick(:reason, :before)) end)

    assert {{:returned, :ok}, []} = F.observe(fn -> :ok end)
  end

  test "nested observations restore their caller's trace" do
    assert {{:returned, {{:returned, 2}, [:inner]}}, [:outer]} =
             F.observe(fn ->
               F.tick(1, :outer)
               F.observe(fn -> F.tick(2, :inner) end)
             end)

    refute Process.get({F, :trace})
  end
end
