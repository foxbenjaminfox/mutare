defmodule Shop.ServerTest do
  use ExUnit.Case

  test "the server counts recorded orders" do
    {:ok, pid} = Shop.Server.start_link()
    assert GenServer.call(pid, :count) == 0

    GenServer.cast(pid, :record_order)
    assert GenServer.call(pid, :count) == 1
  end
end
