defmodule Mutare.CallRoutingTest do
  use ExUnit.Case, async: true

  alias Mutare.CallRouting.{ArgumentRoutes, Call, ContractError}

  defp call(pipe_mode, arguments) do
    %Call{
      node: {:where, [], arguments},
      module: Ecto.Query,
      name: :where,
      arguments: arguments,
      pipe_mode: pipe_mode,
      effective_arity: length(arguments) + if(pipe_mode == :piped, do: 1, else: 0),
      rebuild: fn name, args -> {name, [], args} end
    }
  end

  describe "ArgumentRoutes" do
    test "effective routes split the pipe argument from visible arguments" do
      routes = ArgumentRoutes.from_effective(call(:piped, [:condition]), [:raw, :hosted])

      assert ArgumentRoutes.piped(routes) == :raw
      assert ArgumentRoutes.visible(routes) == [:hosted]
    end

    test "visible routes default a piped argument explicitly to expression" do
      routes = ArgumentRoutes.from_visible(call(:piped, [:condition]), [:hosted])

      assert ArgumentRoutes.piped(routes) == :expression
      assert ArgumentRoutes.visible(routes) == [:hosted]
    end

    test "constructors reject a treatment-count mismatch" do
      assert_raise ArgumentError, ~r/expected 2 effective-argument treatments/, fn ->
        ArgumentRoutes.from_effective(call(:piped, [:condition]), [:hosted])
      end

      assert_raise ArgumentError, ~r/expected 1 visible-argument treatments/, fn ->
        ArgumentRoutes.from_visible(call(:unpiped, [:condition]), [])
      end
    end
  end

  test "ContractError retains structured provider and route context" do
    error =
      ContractError.exception(
        provider: Example.Router,
        route: {Ecto.Query, :where, 2},
        callback: {:route_arguments, 2},
        value: :bad,
        reason: :invalid_result
      )

    assert error.provider == Example.Router
    assert error.route == {Ecto.Query, :where, 2}
    assert error.callback == {:route_arguments, 2}
    assert error.reason == :invalid_result
  end
end
