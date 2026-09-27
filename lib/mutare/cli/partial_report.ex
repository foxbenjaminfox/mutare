defmodule Mutare.CLI.PartialReport do
  @moduledoc false
  # The reports of a `mix mutare` run that has not finished. It keeps every result the runner
  # accepts (the `:reporter` hook, `observe/2`) and writes them two ways:
  #
  #   * **Checkpoints** — each JSON/HTML report bound for a file is rewritten, untested mutants
  #     `Pending` (`Mutare.CLI.Outcome.checkpoint/3`), at each tenth of the mutants and within
  #     `:interval_ms` of any result not yet written. This is what survives a SIGKILL.
  #   * **On SIGTERM** — `interrupt/1` (from the task's trap) hands the results to the task's
  #     `on_interrupt` callback, which writes the partial reports, then halts with the status a
  #     SIGTERM death reports. It must halt: the VM's own SIGTERM handler runs after the trap
  #     returns, and exits 0. What to write depends on how far the run got, so `begin/3`
  #     replaces the callback the scan ran under.
  #
  # `close/1` ends both once the runner returns: the final reports go to the same paths, and a
  # checkpoint landing after them would overwrite a complete report with a partial one. A signal
  # after `close/1` finds the final reports being written (atomically) and just halts.
  # NOTES "A killed run keeps its reports".

  use GenServer

  alias Mutare.{Options, Result, Schema}
  alias Mutare.CLI.Outcome

  # Loses at most this much of a SIGKILLed run's results; matches the longest silence of the
  # plain-mode progress lines (`Mutare.Report.Live`).
  @interval_ms 120_000

  # The exit status of a process a SIGTERM killed (128 + 15).
  @sigterm_status 143

  defstruct [
    :options,
    :on_interrupt,
    :interval_ms,
    :halt,
    schema: nil,
    results: [],
    count: 0,
    tenth: 0,
    unwritten?: false,
    timer: nil,
    closed?: false
  ]

  @typedoc "Called on SIGTERM with the results accepted so far, in source order."
  @type on_interrupt :: ([Result.t()] -> any())

  @doc """
  Starts the partial report for a run configured by `options`, with the `on_interrupt` callback
  a SIGTERM during the scan gets.

  Options: `:interval_ms`, the longest a result waits to be checkpointed (two minutes), and
  `:halt`, how `interrupt/1` ends the VM (`System.halt/1`).
  """
  @spec start_link(Options.t(), on_interrupt(), keyword()) :: GenServer.on_start()
  def start_link(%Options{} = options, on_interrupt, opts \\ [])
      when is_function(on_interrupt, 1) do
    GenServer.start_link(__MODULE__, %__MODULE__{
      options: options,
      on_interrupt: on_interrupt,
      interval_ms: Keyword.get(opts, :interval_ms, @interval_ms),
      halt: Keyword.get(opts, :halt, &System.halt/1)
    })
  end

  @doc """
  The mutants the run will test, once the scan has built them, and the `on_interrupt` callback
  that now applies.
  """
  @spec begin(GenServer.server(), Schema.t(), on_interrupt()) :: :ok
  def begin(server, %Schema{} = schema, on_interrupt) when is_function(on_interrupt, 1),
    do: GenServer.call(server, {:begin, schema, on_interrupt})

  @doc "Records each result the runner accepts, after the context's own `:reporter` (if any)."
  @spec observe(Mutare.Run.Context.t(), GenServer.server()) :: Mutare.Run.Context.t()
  def observe(%{reporter: reporter} = context, server) do
    record = &GenServer.cast(server, {:record, &1})

    %{
      context
      | reporter:
          if(reporter,
            do: fn result ->
              reporter.(result)
              record.(result)
            end,
            else: record
          )
    }
  end

  @doc "Stops checkpointing: the final reports are about to be written."
  @spec close(GenServer.server()) :: :ok
  def close(server), do: GenServer.call(server, :close)

  @doc """
  On SIGTERM: hands the results so far to `on_interrupt` (unless closed), then halts with status
  143 whatever the callback did. Returns only under a `:halt` that does.
  """
  @spec interrupt(GenServer.server()) :: :ok
  def interrupt(server), do: GenServer.call(server, :interrupt, :infinity)

  @impl true
  def init(%__MODULE__{} = state), do: {:ok, state}

  @impl true
  def handle_call({:begin, schema, on_interrupt}, _from, state),
    do: {:reply, :ok, %{state | schema: schema, on_interrupt: on_interrupt}}

  def handle_call(:close, _from, state), do: {:reply, :ok, %{state | closed?: true}}

  def handle_call(:interrupt, _from, state) do
    results = Enum.reverse(state.results)

    try do
      if not state.closed?, do: state.on_interrupt.(results)
    after
      state.halt.(@sigterm_status)
    end

    {:reply, :ok, state}
  end

  @impl true
  def handle_cast({:record, _result}, %{closed?: true} = state), do: {:noreply, state}

  def handle_cast({:record, %Result{} = result}, state) do
    state = %{state | results: [result | state.results], count: state.count + 1, unwritten?: true}
    tenth = div(state.count * 10, max(Schema.count(state.schema), 1))

    if tenth > state.tenth,
      do: {:noreply, checkpoint(%{state | tenth: tenth})},
      else: {:noreply, arm(state)}
  end

  @impl true
  def handle_info({:checkpoint, ref}, %{timer: ref, closed?: false} = state),
    do: {:noreply, checkpoint(%{state | timer: nil})}

  def handle_info({:checkpoint, _orphaned}, state), do: {:noreply, state}

  # Write the checkpoint reports, if any are configured. A write that fails crashes the run: the
  # final report would fail the same way, and it is better to learn so now than hours later.
  defp checkpoint(%{unwritten?: false} = state), do: state

  defp checkpoint(state) do
    if Outcome.checkpoints?(state.options),
      do: Outcome.checkpoint(Enum.reverse(state.results), state.schema, state.options)

    %{state | unwritten?: false, timer: nil}
  end

  # Checkpoint within `interval_ms` of the oldest unwritten result. A fresh ref per timer, so a
  # timer outlived by a milestone write is recognised as orphaned rather than cancelled.
  defp arm(%{timer: nil} = state) do
    ref = make_ref()
    Process.send_after(self(), {:checkpoint, ref}, state.interval_ms)
    %{state | timer: ref}
  end

  defp arm(state), do: state
end
