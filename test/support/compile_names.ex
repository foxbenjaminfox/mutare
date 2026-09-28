defmodule Mutare.Test.Compile.Names do
  @moduledoc """
  Which ExUnit module execution owns each module name the suite compiles at runtime.

  `Code.compile_string/2` defines modules VM-wide, so two tests running concurrently that
  compile one name collide: the parallel checker aborts one compile ("cannot compile module
  M"), and even when both compile, one test's calls run the other's code, and one test's
  purge unloads the module the other is calling. Instead of serializing compiles, the suite
  gives every name one owner. The first *module execution* to compile a name claims it for
  the rest of the run, and a claim from any other execution raises.

  The check does not depend on timing. Two modules that compile one fixture name fail on
  every full run, whichever compiles second — not only when the scheduler happens to overlap
  them. It sees only the compiles made through `Mutare.Test.Compile`; a test that calls
  `Code.compile_string/2` directly must choose a unique name itself. A module's own tests run one at a time, so they may compile a name repeatedly. Two
  executions of one module (`:parameterize`) run concurrently and are different owners, so
  a parameterized module compiles under unique names (`Mutare.Test.compile_metamutant/3`'s
  wrapper, or `Mutare.Test.SourcePatch`'s shell).

  The owner is found as `Mutare.Test.isolate_selector/0` finds its key: by walking up from the
  caller to the process that runs the module, whose dictionary holds the running test under
  `ExUnit.Runner`. Outside ExUnit (a `mix run` script) nothing is recorded. Under ExUnit, a
  compile from a process the walk cannot place raises, as a missing owner would otherwise
  let a collision through unseen.

  The table lives in an unlinked process started on first use, so it outlives the test that
  started it. A claim lasts one suite run: `reset/0`, an `ExUnit.after_suite/1` callback in
  `test_helper.exs`, forgets the executions' claims, because `mix test --repeat-until-failure`
  reruns every module in the same VM under a new runner — a new owner of the names it compiled
  the last time.
  """
  use GenServer

  @table __MODULE__
  # A test process or `setup_all` process is one hop from its module runner; a task a test
  # starts is two.
  @walk 8

  @doc """
  Claim `names` for the calling test module execution. Raises if another execution already
  claimed one of them, or if one is a module of the test build (the `:mutare` application,
  `test/support` included), which the table holds under the owner `:build` from the start.
  """
  @spec claim!([module()]) :: :ok
  def claim!(names) when is_list(names) do
    case owner() do
      nil ->
        :ok

      owner ->
        ensure_table()
        Enum.each(names, &claim!(&1, owner))
    end
  end

  @doc """
  Forget every claim a module execution made, keeping the test build's modules. Run after each
  suite run, so a repeated run (`--repeat-until-failure`) starts with no owners.
  """
  @spec reset() :: :ok
  def reset do
    if :ets.whereis(@table) != :undefined, do: :ets.match_delete(@table, {:_, {:_, :_}})
    :ok
  end

  defp claim!(name, owner) do
    case :ets.insert_new(@table, {name, owner}) or :ets.lookup(@table, name) do
      true ->
        :ok

      [{^name, ^owner}] ->
        :ok

      [{^name, :build}] ->
        raise ArgumentError,
              "#{inspect(name)} is a module compiled into the test build; a runtime fixture " <>
                "must not redefine it (#{describe(owner)})"

      [{^name, other}] ->
        raise ArgumentError,
              "#{inspect(name)} is compiled by #{describe(other)} and by #{describe(owner)}. " <>
                "Tests running concurrently must not share a runtime-compiled module name: " <>
                "rename one fixture (see `Mutare.Test.Compile.Names`)."
    end
  end

  defp describe({module, runner}), do: "#{inspect(module)} (runner #{inspect(runner)})"

  defp owner do
    case execution(self(), @walk) do
      nil ->
        if Process.whereis(ExUnit.Server),
          do:
            raise(
              ArgumentError,
              "no ExUnit test runs above this process, so no test owns the modules it " <>
                "compiles; compile from the test process or a task it starts"
            )

      owner ->
        owner
    end
  end

  defp execution(_pid, 0), do: nil

  defp execution(pid, hops) do
    with {:dictionary, dictionary} <- Process.info(pid, :dictionary),
         nil <- test_module(List.keyfind(dictionary, ExUnit.Runner, 0)),
         {:parent, parent} when is_pid(parent) <- Process.info(pid, :parent) do
      execution(parent, hops - 1)
    else
      module when is_atom(module) and module != nil -> {module, pid}
      _ -> nil
    end
  end

  defp test_module({ExUnit.Runner, %ExUnit.Test{module: module}}), do: module
  defp test_module({ExUnit.Runner, %ExUnit.TestModule{name: module}}), do: module
  defp test_module(_), do: nil

  defp ensure_table do
    if :ets.whereis(@table) == :undefined do
      case GenServer.start(__MODULE__, nil, name: __MODULE__) do
        {:ok, pid} -> GenServer.call(pid, :ready)
        {:error, {:already_started, pid}} -> GenServer.call(pid, :ready)
      end
    end

    :ok
  end

  # The build's modules are read once, from the application spec: asking the code server
  # about each claimed name (`:code.which/1`) searches the whole code path for every name not
  # yet loaded, and the code server is the suite's one serial resource.
  @impl true
  def init(nil) do
    :ets.new(@table, [:named_table, :public, :set, read_concurrency: true])
    {:ok, modules} = :application.get_key(:mutare, :modules)
    :ets.insert(@table, Enum.map(modules, &{&1, :build}))
    {:ok, nil}
  end

  @impl true
  def handle_call(:ready, _from, state), do: {:reply, :ok, state}
end
