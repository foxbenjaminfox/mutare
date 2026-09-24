defmodule Mutare.SelectorIsolationExecutionTest do
  # ExUnit runs each `:parameterize` entry of an async module as its own execution of the
  # module, concurrently with the others: the same module name, in different runner
  # processes. A selector key derived from the module name alone would be one slot shared
  # by both — each instance's `with_active_mutant/2` writes it, and the other instance's
  # fixture reads it — and saving and restoring a shared slot is not mutual exclusion. The
  # key is per execution (`isolate_selector/0`). This holds two executions inside one
  # selected interval, by message, and reads both fixtures there: each must see its own
  # mutant. A sleep would turn the definite collision into a probabilistic one.
  use ExUnit.Case, async: true, parameterize: [%{instance: 0}, %{instance: 1}]
  import Mutare.Test

  @moduletag timeout: 180_000

  # `4 + 2 - 1`: the arithmetic family offers a mutant per operator — one for each
  # instance, distinct from the baseline and from each other.
  @source """
  defmodule Fixture do
    def n, do: 4 + 2 - 1
  end
  """
  @baseline 5
  @mutants %{0 => {{"4 + 2", "4 - 2"}, 1}, 1 => {{"4 + 2 - 1", "4 + 2 + 1"}, 7}}

  # How long an execution waits for the other to arrive in its selected interval. The
  # other instance is queued right behind this one, so it starts as soon as any running
  # module frees a slot.
  @meet 120_000

  setup_all :isolate_selector

  setup_all do
    {[mod], sites} = compile_metamutant(@source, [:arithmetic])
    %{mod: mod, sites: sites}
  end

  test "two executions of one module select on different keys, concurrently",
       %{instance: i, mod: mod, sites: sites, mutare_selector_key: setup_key} do
    Process.register(self(), name(i))
    key = isolate_selector()
    assert key == setup_key, "setup_all and the test disagree on the module's key"
    assert String.contains?(Atom.to_string(key), inspect(__MODULE__))

    {pattern, mutated} = @mutants[i]
    id = site_id(sites, pattern)
    assert mod.n() == @baseline

    with_active_mutant(id, fn ->
      assert mod.n() == mutated

      case meet(i, key) do
        :alone ->
          :ok

        other_key ->
          refute other_key == key, "both executions took #{inspect(key)}"
          assert mod.n() == mutated
      end
    end)

    assert mod.n() == @baseline
  end

  # Exchange keys with the other execution, returning once both are inside their selected
  # intervals: each announces itself only after selecting, and returns only on the other's
  # announcement (the reply covers the announcer having arrived before the other was
  # registered). `:alone` when the suite cannot run two modules at once.
  defp meet(i, key) do
    if ExUnit.configuration()[:max_cases] < 2 do
      :alone
    else
      announce(name(1 - i), key)

      receive do
        {:selected, from, other_key} ->
          send(from, {:selected, self(), key})
          other_key

        {:DOWN, _ref, :process, _pid, _reason} ->
          flunk("the other execution ended before reaching its selected interval")
      after
        @meet -> flunk("the other execution did not reach its selected interval in time")
      end
    end
  end

  defp announce(other, key) do
    case Process.whereis(other) do
      nil ->
        :ok

      pid ->
        Process.monitor(pid)
        send(pid, {:selected, self(), key})
    end
  end

  defp name(i), do: :"#{__MODULE__}.#{i}"
end
