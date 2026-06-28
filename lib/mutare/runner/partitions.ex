defmodule Mutare.Runner.Partitions do
  @moduledoc """
  Per-worker partition slots, for DB (or any resource) isolation across the
  concurrent mutant runs.

  When `:partition_env` names an environment variable, every concurrently-running
  mutant `mix test` process is given a **distinct** partition id under that name,
  drawn from a bounded, recycled pool. The user's `config/test.exs` reads it to
  pick a per-worker database:

      config :my_app, MyApp.Repo,
        database: "my_app_test\#{System.get_env("MIX_TEST_PARTITION")}"

  — exactly the `mix test --partitions` convention (default name
  `MIX_TEST_PARTITION`), so two live runs never collide on one database.

  ## Why a pool, not `rem(index, workers)`

  `Task.async_stream` hands each item no stable lane index, and `rem(index,
  workers)` is **unsafe**: tasks don't finish in index order, so task `0` (→
  partition 1) can still be running when task `workers` (→ partition 1) starts —
  two live runs on one database. So this is a **checkout/checkin pool** of
  `workers` tokens (partitions `1..workers`): a task checks out a free partition
  before spawning `mix`, runs it (harness retries included, since they recurse
  inside the same task), then checks it back in. A counting argument makes
  checkout non-blocking: when a task checks out it is itself alive, so the other
  alive tasks (≤ `workers - 1`) hold ≤ `workers - 1` tokens, leaving ≥ 1 free.

  The baseline and coverage probe run sequentially *before* the pool, so they take
  a fixed partition (`entry/2` with `1`) rather than a pooled slot — there is no
  concurrency to isolate there, and a partitioned suite still needs *some* valid
  partition to find its database.

  ## Disabled

  A `nil` env name disables everything: `new/2` returns `:disabled`, `with_slot/2`
  yields `[]` (no extra env), and `entry/2` is `[]` — so the partition feature is
  pure opt-in and inert by default. The pool is a small `Agent` holding the free
  tokens; `Mutare.Runner` owns its lifecycle (`new/2` … `stop/1`).
  """

  @opaque t :: :disabled | {String.t(), pid(), pos_integer()}

  @doc """
  Env entries for a *fixed* partition `n` (the baseline and coverage probe use
  `1`): `[]` when partitioning is off (`env_name` is `nil`), else `[{env_name,
  "\#{n}"}]`. Pure, so the env contract is unit-testable.

      iex> Mutare.Runner.Partitions.entry(nil, 1)
      []

      iex> Mutare.Runner.Partitions.entry("MIX_TEST_PARTITION", 3)
      [{"MIX_TEST_PARTITION", "3"}]
  """
  @spec entry(String.t() | nil, pos_integer()) :: [{String.t(), String.t()}]
  def entry(nil, _n), do: []

  def entry(env_name, n) when is_binary(env_name) and is_integer(n) and n > 0,
    do: [{env_name, Integer.to_string(n)}]

  @doc """
  Build a slot pool of `size` tokens (partitions `1..size`) for the variable
  `env_name`, or `:disabled` when `env_name` is `nil`. `size` is the worker count,
  so there is exactly one token per concurrency lane.
  """
  @spec new(String.t() | nil, pos_integer()) :: t()
  def new(nil, _size), do: :disabled

  def new(env_name, size) when is_binary(env_name) and is_integer(size) and size > 0 do
    {:ok, agent} = Agent.start_link(fn -> Enum.to_list(1..size) end)
    {env_name, agent, size}
  end

  @doc """
  The `Task.async_stream` `max_concurrency` that keeps the non-blocking checkout
  invariant: the pool size when partitioning is on (one token per lane), else
  `default` (no pool, so nothing to bound — use the caller's worker count). Drive
  `max_concurrency` from this so it can never drift from the token count.

      iex> Mutare.Runner.Partitions.max_concurrency(:disabled, 8)
      8
  """
  @spec max_concurrency(t(), pos_integer()) :: pos_integer()
  def max_concurrency(:disabled, default), do: default
  def max_concurrency({_env_name, _agent, size}, _default), do: size

  @doc "Stop the pool (a no-op when disabled)."
  @spec stop(t()) :: :ok
  def stop(:disabled), do: :ok
  def stop({_env_name, agent, _size}), do: Agent.stop(agent)

  @doc """
  Check out a free partition, call `fun` with its env entries
  (`[{env_name, "\#{slot}"}]`), and check the partition back in afterwards — even
  if `fun` raises. When disabled, calls `fun.([])` (no extra env).
  """
  @spec with_slot(t(), ([{String.t(), String.t()}] -> result)) :: result when result: var
  def with_slot(:disabled, fun), do: fun.([])

  def with_slot({env_name, agent, _size}, fun) do
    slot = checkout(agent)

    try do
      fun.([{env_name, Integer.to_string(slot)}])
    after
      checkin(agent, slot)
    end
  end

  # Pop a free token. With one token per concurrency lane (`size` ==
  # `Task.async_stream`'s `max_concurrency`, now driven from `max_concurrency/2`),
  # a free token always exists when a task asks (see the moduledoc's counting
  # argument). The `[]` clause is therefore unreachable; it exists only to convert
  # a broken invariant into a clear error *in the caller* rather than an opaque
  # `FunctionClauseError` inside the Agent process.
  defp checkout(agent) do
    case Agent.get_and_update(agent, fn
           [slot | rest] -> {slot, rest}
           [] -> {:pool_exhausted, []}
         end) do
      :pool_exhausted ->
        raise "Mutare.Runner.Partitions: slot pool exhausted — every token is " <>
                "checked out. Task.async_stream's max_concurrency must equal the pool " <>
                "size; drive it from Partitions.max_concurrency/2."

      slot ->
        slot
    end
  end

  defp checkin(agent, slot), do: Agent.update(agent, &[slot | &1])
end
