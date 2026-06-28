defmodule Shop.Server do
  @moduledoc """
  A tiny `GenServer` tracking a running order count.

  Here only to exercise the `genserver` family, which mutates the OTP reply tag
  of a callback (`:reply` → `:noreply`, `:noreply` → `:stop`) — a change a test
  that asserts on the *reply* will catch, and one that only fires-and-forgets
  will miss.
  """

  use GenServer

  def start_link(opts \\ []) do
    GenServer.start_link(__MODULE__, opts)
  end

  @impl true
  def init(_opts), do: {:ok, %{count: 0}}

  @impl true
  def handle_call(:count, _from, state) do
    {:reply, state.count, state}
  end

  @impl true
  def handle_cast(:record_order, state) do
    {:noreply, %{state | count: state.count + 1}}
  end
end
