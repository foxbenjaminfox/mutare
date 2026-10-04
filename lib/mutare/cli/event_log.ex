defmodule Mutare.CLI.EventLog do
  @moduledoc false
  # The `--events FILE` writer of a `mix mutare` run: one line per event, each written as it
  # happens, in the format `Mutare.Report.Events` documents (and builds). The task opens it
  # before the scan, so a previous run's events are gone by the time anyone could mistake them
  # for this run's; `observe/3` hooks it into the runner's `:reporter` and `:on_phase`; and the
  # task ends it with one `finish` event — `finished/3`, `unchanged/1`, `failed/3` or
  # `interrupted/1` — after which it writes nothing, so `finish` is the last line even when a
  # SIGTERM's `finish` races the results still arriving from the runner.
  #
  # Each write is a call: the server orders the events of the runner's process and of the SIGTERM
  # handler's, and the line is in the file when the caller moves on. The file is opened unbuffered,
  # so a reader tailing it sees each line as it is written.

  use GenServer

  alias Mutare.{Options, Result, Run, Schema}
  alias Mutare.CLI.Outcome
  alias Mutare.Report.Events
  alias Mutare.Run.Context

  @doc """
  Truncates `path` and writes the `start` event to it, or returns why the file cannot be opened.
  The file is opened by the calling process, which owns it from then on.
  """
  @spec start_link(Path.t()) :: GenServer.on_start() | {:error, File.posix()}
  def start_link(path) do
    with {:ok, device} <- File.open(path, [:write, :binary]) do
      GenServer.start_link(__MODULE__, device)
    end
  end

  @doc "Writes the `scanned` event for `schema`."
  @spec scanned(GenServer.server(), Schema.t()) :: :ok
  def scanned(log, %Schema{} = schema),
    do: GenServer.call(log, {:scanned, Events.scanned(schema), Schema.count(schema)})

  @doc """
  Records each phase the runner enters and each result it accepts, after the context's own hooks
  (if any). `schema` holds the sources the `mutant` events read their patches from.
  """
  @spec observe(Context.t(), GenServer.server(), Schema.t()) :: Context.t()
  def observe(%Context{} = context, log, %Schema{} = schema) do
    context
    |> Context.listen(:reporter, fn result ->
      GenServer.call(log, {:mutant, result, Map.fetch!(schema.sources, result.site.file)})
    end)
    |> Context.listen(:on_phase, fn phase ->
      if event = Events.phase(phase), do: GenServer.call(log, {:write, event})
    end)
  end

  @doc "Writes the `finish` event of a run that returned `run`."
  @spec finished(GenServer.server(), Run.t(), Options.t()) :: :ok
  def finished(log, %Run{} = run, %Options{} = options) do
    finish(
      log,
      Events.finish(
        Outcome.stop_reason(run, options),
        Schema.count(run.schema),
        Enum.frequencies_by(run.results, & &1.status)
      )
    )
  end

  @doc "Writes the `finish` event of a `--since` run with no mutant on the changed lines."
  @spec unchanged(GenServer.server()) :: :ok
  def unchanged(log), do: finish(log, Events.finish(:complete, 0, %{}))

  @doc "Writes the `finish` event of a run that ended in the error `reason`, told as `message`."
  @spec failed(GenServer.server(), atom(), String.t()) :: :ok
  def failed(log, reason, message), do: finish(log, Events.error(reason, message))

  @doc """
  Writes the `finish` event of a run a SIGTERM stopped, over the mutants this log has written —
  not the partial report's results, which a result in flight between the two can put one ahead
  or behind: the file agrees with itself.
  """
  @spec interrupted(GenServer.server()) :: :ok
  def interrupted(log), do: GenServer.call(log, :interrupted)

  @doc "Closes the file and stops the writer."
  @spec stop(GenServer.server()) :: :ok
  def stop(log), do: GenServer.stop(log)

  defp finish(log, event), do: GenServer.call(log, {:finish, event})

  # `mutants` is the scan's count once `scanned/2` gives it, `tally` how many `mutant` lines
  # carry each status (all a SIGTERM's `finish` counts and scores; keeping the results, each
  # with its site, would copy what the partial report already holds), and `evaluated` how many
  # there are. A `mutant` line is built here, not by the caller, because its `evaluated` is its
  # place in the file.
  @impl true
  def init(device) do
    state = %{
      device: device,
      started: now(),
      finished?: false,
      mutants: nil,
      evaluated: 0,
      tally: %{}
    }

    {:ok, emit(state, Events.start())}
  end

  @impl true
  def handle_call(_request, _from, %{finished?: true} = state), do: {:reply, :ok, state}
  def handle_call({:write, event}, _from, state), do: {:reply, :ok, emit(state, event)}

  def handle_call({:scanned, event, mutants}, _from, state),
    do: {:reply, :ok, %{emit(state, event) | mutants: mutants}}

  def handle_call({:mutant, %Result{} = result, source}, _from, state) do
    evaluated = state.evaluated + 1
    state = emit(state, Events.mutant(result, source, evaluated))
    tally = Map.update(state.tally, result.status, 1, &(&1 + 1))
    {:reply, :ok, %{state | evaluated: evaluated, tally: tally}}
  end

  def handle_call(:interrupted, _from, state) do
    event = Events.finish(:sigterm, state.mutants, state.tally)
    {:reply, :ok, %{emit(state, event) | finished?: true}}
  end

  def handle_call({:finish, event}, _from, state),
    do: {:reply, :ok, %{emit(state, event) | finished?: true}}

  @impl true
  def terminate(_reason, state), do: File.close(state.device)

  # A write that fails crashes the run, as a failing checkpoint does: an agent following the file
  # would otherwise wait on a run that has stopped telling it anything.
  defp emit(state, event) do
    :ok = IO.binwrite(state.device, Events.encode(event, now() - state.started))
    state
  end

  defp now, do: System.monotonic_time(:millisecond)
end
