defmodule Mutare.Test.Compile.Lock do
  @moduledoc """
  The suite-wide lock `Mutare.Test.Compile` serializes compiles behind: a queue, granted in
  arrival order, the moment it frees.

  It replaces `:global.trans/2`, which does not queue. A caller that finds a `:global` lock
  taken sleeps a random time and tries again, and the sleep grows to as much as eight seconds
  once it has missed five times. The critical section here is a compile of some 50 ms, asked
  for by dozens of `async: true` tests at once, so waiters slept through most of the time the
  lock was free: over the fast loop, 54 s of compiling cost 196 s of waiting, the longest
  single wait 20 s. Slower compiles (a loaded machine, the property soaks) mean more misses
  and longer sleeps, and tests then died at their 60 s timeout inside `:global.random_sleep/1`.

  The server is started on first use and is not linked, so it outlives the test that happened
  to start it. A holder that dies — a test killed at its timeout — releases the lock; a waiter
  that died while queued is skipped, since monitoring a dead process reports it down at once.
  """
  use GenServer

  @doc "Run `fun` holding the lock."
  @spec with_lock((-> result)) :: result when result: var
  def with_lock(fun) when is_function(fun, 0) do
    server = server()
    :ok = GenServer.call(server, :acquire, :infinity)

    try do
      fun.()
    after
      GenServer.cast(server, {:release, self()})
    end
  end

  defp server do
    case GenServer.start(__MODULE__, nil, name: __MODULE__) do
      {:ok, pid} -> pid
      {:error, {:already_started, pid}} -> pid
    end
  end

  @impl true
  def init(nil), do: {:ok, %{holder: nil, waiting: :queue.new()}}

  @impl true
  def handle_call(:acquire, from, %{holder: nil} = state), do: {:noreply, grant(from, state)}

  def handle_call(:acquire, from, state),
    do: {:noreply, %{state | waiting: :queue.in(from, state.waiting)}}

  @impl true
  def handle_cast({:release, pid}, %{holder: {pid, monitor}} = state) do
    Process.demonitor(monitor, [:flush])
    {:noreply, next(%{state | holder: nil})}
  end

  def handle_cast({:release, _pid}, state), do: {:noreply, state}

  @impl true
  def handle_info({:DOWN, monitor, :process, pid, _reason}, %{holder: {pid, monitor}} = state),
    do: {:noreply, next(%{state | holder: nil})}

  def handle_info(_message, state), do: {:noreply, state}

  defp next(state) do
    case :queue.out(state.waiting) do
      {{:value, from}, waiting} -> grant(from, %{state | waiting: waiting})
      {:empty, _waiting} -> state
    end
  end

  defp grant({pid, _tag} = from, state) do
    monitor = Process.monitor(pid)
    GenServer.reply(from, :ok)
    %{state | holder: {pid, monitor}}
  end
end
