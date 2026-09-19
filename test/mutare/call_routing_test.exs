defmodule Mutare.CallRoutingTest do
  use ExUnit.Case, async: true

  alias Mutare.CallRouting.{ArgumentRoutes, Call, ContractError}

  doctest Call

  defp call(arguments), do: Call.new({:where, [], arguments}, Ecto.Query, :where, &{&1, [], &2})

  describe "ArgumentRoutes" do
    test "holds one normalized treatment per argument" do
      routes = ArgumentRoutes.new(call([:query, :condition]), [:raw, :hosted])

      assert ArgumentRoutes.treatments(routes) == [:raw, :hosted]
    end

    test "rejects a treatment-count mismatch" do
      assert_raise ArgumentError, ~r/expected 2 argument treatments, got 1/, fn ->
        ArgumentRoutes.new(call([:query, :condition]), [:hosted])
      end
    end
  end

  test "ContractError retains structured provider and route context" do
    error =
      ContractError.exception(
        provider: Example.Router,
        route: {Ecto.Query, :where, 2},
        callback: {:route_arguments, 1},
        value: :bad,
        reason: :invalid_result
      )

    assert error.provider == Example.Router
    assert error.route == {Ecto.Query, :where, 2}
    assert error.callback == {:route_arguments, 1}
    assert error.reason == :invalid_result
  end
end
