defmodule Mutare.Report.Live do
  @moduledoc """
  Live progress for the human report.

  Progress is written to stderr so stdout remains safe for the final or machine-readable report. An interactive terminal gets a spinner, current mutant, counts, and ETA; pipes and CI logs get plain scrollback. Survivors, timeouts, and harness errors remain visible after the live display advances.

  `--verbose` prints a line for every mutant and timing details for each phase. `--quiet` suppresses live progress entirely and takes precedence over `--verbose`.

  This module owns the process, the output modes, and the terminal; the text of every line it draws is rendered by `Mutare.Report.Live.Lines`.
  """

  use GenServer

  alias Mutare.{Result, Site}
  alias Mutare.Report.Live.Lines

  @device :standard_error
  @tick_ms 80
  @default_width 80

  # The server's internal state. A struct (not a bare map) so a mistyped field access in
  # any handler is a compile error, not a silent runtime `nil`. `init/1` overrides the five
  # capability fields (`device`/`ansi`/`color`/`width`/`verbose`); the rest start at these
  # defaults. `Lines`'s rendering functions stay `map()`-typed — a `%__MODULE__{}` matches
  # their `%{phase: …}` patterns, and so do the plain maps the unit tests pass.
  defstruct device: @device,
            ansi: false,
            color: false,
            width: @default_width,
            verbose: false,
            total: 0,
            counts: %{},
            started_at: nil,
            phase: nil,
            scan: nil,
            run_config: nil,
            current: nil,
            spinner: 0,
            drawn: 0,
            ticking: false,
            finished: false

  # === client API ============================================================

  @doc """
  Starts the live reporter.

  Options:

    * `:device` — output device; defaults to `:standard_error`
    * `:ansi` — enables or disables animation; by default it is enabled when stderr
      is a terminal
    * `:color` — enables or disables colored persistent labels; by default it
      follows animation and `NO_COLOR`
    * `:width` — terminal width; defaults to the detected width or 80
    * `:verbose` — retains a line for every mutant and shows phase details;
      defaults to `false`
  """
  @spec start_link(keyword()) :: GenServer.on_start()
  def start_link(opts \\ []) do
    GenServer.start_link(__MODULE__, opts)
  end

  @type phase_event ::
          :scanning
          | :compiling
          | :baseline
          | :coverage_probe
          | {:running, non_neg_integer()}
          | {:confirming_timeouts, non_neg_integer()}
          | {:compiled, non_neg_integer()}
          | {:baseline_done, non_neg_integer()}
          | {:coverage_done, map()}
          | {:run_config, map()}
          | {:seed_app_build, map()}
          | {:inference_override_declined, map()}
          | {:poison_round, map()}
          | {:macro_poison, map()}

  @doc """
  Records a phase transition or detail event.

  Phase transitions are `:scanning`, `:compiling`, `:baseline`, `:coverage_probe`,
  `{:running, total}`, and `{:confirming_timeouts, count}` (the post-stream
  confirmation pass, announced while the phase stays `:running`). Detail events are
  verbose-only notes: `{:compiled, ms}`, `{:baseline_done, ms}`, `{:coverage_done,
  summary}`, `{:run_config, cfg}` (stashed for the `{:running, total}` label),
  `{:seed_app_build, summary}`, and `{:inference_override_declined, info}`.
  `{:poison_round, info}` (a compile-poison recovery round) and `{:macro_poison, info}`
  (the macro-expansion fallback skipping an inline DSL macro) each leave a permanent
  line in every mode, not just verbose. An event this reporter doesn't know is ignored.
  """
  @spec phase(GenServer.server(), phase_event()) :: :ok
  def phase(server, phase), do: GenServer.cast(server, {:phase, phase})

  @doc """
  Updates scanning progress with the processed file count, total file count, and
  number of mutants found.

  Animated reporters redraw the status block. Plain reporters do not print a line
  for each update.
  """
  @spec scanned(GenServer.server(), %{
          done: non_neg_integer(),
          total: non_neg_integer(),
          found: non_neg_integer()
        }) :: :ok
  def scanned(server, progress), do: GenServer.cast(server, {:scan, progress})

  @doc "Records the mutant currently being tested."
  @spec started(GenServer.server(), Site.t()) :: :ok
  def started(server, %Site{} = site), do: GenServer.cast(server, {:start, site})

  @doc "Records a completed mutant result and updates the progress display."
  @spec report(GenServer.server(), Result.t()) :: :ok
  def report(server, %Result{} = result), do: GenServer.cast(server, {:report, result})

  @doc """
  Clears the current status block without stopping the reporter.

  This call is synchronous, so the terminal is clear before subsequent output.
  """
  @spec clear(GenServer.server()) :: :ok
  def clear(server), do: GenServer.call(server, :clear)

  @doc "Stops the status display and clears its terminal lines."
  @spec finish(GenServer.server()) :: :ok
  def finish(server), do: GenServer.call(server, :finish)

  @doc """
  Returns whether the reporter is using an animated ANSI status block.

  Plain reporters emit persistent lines but do not display the current-mutant
  activity line.
  """
  @spec animating?(GenServer.server()) :: boolean()
  def animating?(server), do: GenServer.call(server, :animating?)

  @doc """
  Returns whether the default live reporter should draw its ANSI status block for
  the detected stderr terminal state.

  This is intentionally independent of `IO.ANSI.enabled?/0`: Elixir's flag is
  initialized from stdout, but Mutare's live UI is written to stderr.
  """
  @spec default_ansi?(boolean()) :: boolean()
  def default_ansi?(stderr_tty?) when is_boolean(stderr_tty?), do: stderr_tty?

  # === server ================================================================

  @impl true
  def init(opts) do
    # Animation (`ansi`) and colour are decoupled: the status block is positioning
    # (cursor codes), the leave-behind labels are the only colour. So `NO_COLOR`
    # drops the colour but keeps the live block (the convention is about colour, not
    # the whole UI); a non-tty (`ansi: false`) is already colourless.
    #
    # One stderr probe gives both the tty? flag (the default `ansi` decision) and the
    # column width — what `detect_ansi`/`detect_width` used to query twice. Do not
    # use `IO.ANSI.enabled?/0` here: Elixir initializes that flag from stdout, while
    # this reporter deliberately draws on stderr so `mix mutare > report.txt` can
    # still show the live status block in the terminal.
    {tty?, width} = detect_terminal()
    ansi = Keyword.get_lazy(opts, :ansi, fn -> default_ansi?(tty?) end)

    state = %__MODULE__{
      device: Keyword.get(opts, :device, @device),
      ansi: ansi,
      color: Keyword.get_lazy(opts, :color, fn -> ansi and color_enabled?() end),
      width: Keyword.get(opts, :width, width),
      verbose: Keyword.get(opts, :verbose, false)
    }

    {:ok, state}
  end

  # The per-mutant phase. Where phases scroll (`scrollback?/1`) it leads with a permanent
  # label line — in verbose carrying the worker count, with the live counter block kept
  # beneath it (the per-mutant lines scroll above); an animating non-verbose run only
  # starts the block.
  @impl true
  def handle_cast({:phase, {:running, total}}, state) do
    state = %{state | phase: :running, total: total, started_at: now_ms(), current: nil}

    if scrollback?(state),
      do: {:noreply, state |> tick_if_ansi() |> put_line(Lines.running_label(state, total))},
      else: {:noreply, state |> maybe_start_tick() |> redraw()}
  end

  # The verbose-only structured detail events the runner fires alongside the phase
  # starts (`{:compiled, ms}`, `{:baseline_done, ms}`, `{:coverage_done, summary}`).
  # Each renders a `✓` scrollback note via `Lines.detail_line/1` when verbose, and
  # is a no-op otherwise — so the runner emits them unconditionally without knowing
  # whether anyone is listening.
  def handle_cast({:phase, {:compiled, _ms} = event}, state),
    do: {:noreply, maybe_detail(state, event)}

  def handle_cast({:phase, {:baseline_done, _ms} = event}, state),
    do: {:noreply, maybe_detail(state, event)}

  def handle_cast({:phase, {:coverage_done, _summary} = event}, state),
    do: {:noreply, maybe_detail(state, event)}

  # The app-build `_build` seed's outcome (reported by `Mutare.Sandbox`, relayed by the runner
  # during the compile phase). A verbose-only `✓`/`↺` scrollback note surfacing the
  # reused/recompiled beam counts, or an otherwise-silent fall back to a cold compile; a
  # `:skipped` outcome (the broad-run default) leaves no line even in verbose. Inert (no
  # line) in every other mode.
  def handle_cast({:phase, {:seed_app_build, summary}}, state),
    do: {:noreply, maybe_seed_note(state, summary)}

  # A `mix.exs` whose inference override did not land (reported by `Mutare.Sandbox`, relayed by
  # the runner during the compile phase, once per file): its project compiles with
  # type-signature inference on, which can stretch the one compile from seconds to hours. A
  # verbose-only `↺` note naming the file and the reason, so a long compile does not go
  # unexplained; inert otherwise.
  def handle_cast({:phase, {:inference_override_declined, _info} = event}, state),
    do: {:noreply, maybe_detail(state, event)}

  # The run configuration (worker count, partition) is stashed, not printed: the
  # worker count rides onto the next `{:running, total}` label (verbose only).
  def handle_cast({:phase, {:run_config, cfg}}, state),
    do: {:noreply, %{state | run_config: cfg}}

  # A compile-poison recovery round: the metamutant failed to compile, the implicated
  # mutants were dropped, and a rebuild is starting. Unlike the verbose-only `✓` details,
  # this leaves a permanent line in **every** mode — each round is a full recompile, so
  # without it the whole recovery hides behind the "compiling metamutant (once)…" spinner
  # and reads as a hang.
  def handle_cast({:phase, {:poison_round, info}}, state),
    do: {:noreply, put_line(state, Lines.poison_round_line(info))}

  # The macro-expansion poison fallback fired: a mutation wouldn't compile inside an inline
  # DSL macro the compiler blamed by name, so its mutants are being skipped wholesale and the
  # metamutant rebuilt. Loud (`⚠`) and permanent in every mode — it names the macro and the
  # copy-paste `{Module, :fun, :raw}` fix inline, so a first-run user aiming at an unknown
  # DSL sees *why* the compile is being retried and how to pin it, not a silent hang.
  def handle_cast({:phase, {:macro_poison, info}}, state),
    do: {:noreply, put_line(state, Lines.macro_poison_line(info))}

  # The post-stream timeout-confirmation pass (`Mutare.Runner`): each provisional
  # `:timeout` is re-run sequentially and its final verdict arrives as a normal
  # `:report`, so this only announces the pass. The phase stays `:running` — the
  # counter block keeps animating while the confirmations report in.
  def handle_cast({:phase, {:confirming_timeouts, count}}, state) do
    if scrollback?(state),
      do: {:noreply, put_line(state, Lines.confirming_label(count))},
      else: {:noreply, redraw(state)}
  end

  # A pre-mutant phase (`:scanning`, `:compiling`, …): where phases scroll, a permanent
  # note with no block beneath it (the `✓` detail line follows right behind it in verbose);
  # an animating non-verbose run shows it in the block alone. An atom `Lines` has no label
  # for is a future event this reporter doesn't render — ignored, like the catch-all below.
  def handle_cast({:phase, phase}, state) when is_atom(phase) do
    case Lines.phase_label(phase) do
      nil ->
        {:noreply, state}

      label ->
        state = %{state | phase: phase}

        if scrollback?(state),
          do: {:noreply, note(state, label)},
          else: {:noreply, state |> maybe_start_tick() |> redraw()}
    end
  end

  # Catch-all for any future `:on_phase` event we don't render — an unknown event
  # must never crash the reporter (it owns every terminal write).
  def handle_cast({:phase, _other}, state), do: {:noreply, state}

  def handle_cast({:scan, progress}, state) do
    {:noreply, refresh(%{state | scan: progress})}
  end

  def handle_cast({:start, %Site{} = site}, state) do
    state = %{state | current: site}
    {:noreply, if(state.ansi, do: redraw(state), else: state)}
  end

  def handle_cast({:report, %Result{} = result}, state) do
    state = %{state | counts: bump(state.counts, result.status)}

    cond do
      # Verbose: every mutant leaves a line (kills included), with its duration.
      state.verbose ->
        {:noreply, put_line(state, Lines.verbose_line(result, state.color))}

      # Non-verbose: only survivors/problems leave a line; the rest move the counter.
      styled = Lines.leave_behind(result.status) ->
        {:noreply, put_line(state, Lines.leave_line(styled, result, state.color))}

      true ->
        {:noreply, refresh(state)}
    end
  end

  @impl true
  def handle_info(:tick, %{ansi: true, finished: false} = state) do
    state = %{state | spinner: state.spinner + 1}
    schedule_tick()
    {:noreply, redraw(state)}
  end

  def handle_info(:tick, state), do: {:noreply, %{state | ticking: false}}

  @impl true
  def handle_call(:animating?, _from, state), do: {:reply, state.ansi, state}

  def handle_call(:clear, _from, state) do
    # Erase the block and drop to idle, but stay live (the tick keeps running, the
    # next phase redraws). Distinct from `:finish`, which is terminal.
    {:reply, :ok, %{erase(state) | phase: :idle, scan: nil}}
  end

  def handle_call(:finish, _from, state) do
    {:reply, :ok, %{erase(state) | finished: true, phase: :idle}}
  end

  # === modes =================================================================

  # Whether phase transitions leave permanent scrollback lines: verbose narrates every
  # phase, and a plain (non-ANSI) run has no live block to show them in. Only an animating,
  # non-verbose run shows a phase in the block alone.
  defp scrollback?(%{verbose: verbose, ansi: ansi}), do: verbose or not ansi

  # Render a verbose phase-detail event as a scrollback note, or do nothing when not
  # verbose (the runner fires these unconditionally).
  defp maybe_detail(%{verbose: true} = state, event), do: note(state, Lines.detail_line(event))
  defp maybe_detail(state, _event), do: state

  # Like `maybe_detail/2`, but `Lines.seed_line/1` returns `nil` for a `:skipped` seed — leave
  # no line in that case (and in every non-verbose mode).
  defp maybe_seed_note(%{verbose: true} = state, summary) do
    case Lines.seed_line(summary) do
      nil -> state
      line -> note(state, line)
    end
  end

  defp maybe_seed_note(state, _summary), do: state

  defp bump(counts, status), do: Map.update(counts, status, 1, &(&1 + 1))

  # === terminal IO (effectful) ===============================================

  # Two ways to leave a permanent scrollback line, differing in what follows it. Both erase
  # any drawn block first (a no-op when none is drawn — always the case in plain mode, where
  # `draw/1` never draws), then write the line.

  # A permanent line with the status block re-anchored beneath it: in ANSI mode the line
  # lands above the live block, which is redrawn; in plain mode this is just the line.
  defp put_line(state, text) do
    state = erase(state)
    IO.write(state.device, [text, "\n"])
    draw(state)
  end

  # A permanent line that leaves *no* block behind it (`drawn: 0`): the phase notes and `✓`
  # detail lines, which precede the per-mutant loop, so there is no live counter to
  # re-anchor (unlike `put_line/2`).
  defp note(state, text) do
    state = erase(state)
    IO.write(state.device, [text, "\n"])
    %{state | drawn: 0}
  end

  # Start the animation tick only on a tty; in a verbose plain run there is no block
  # to animate, so the per-mutant lines are just scrollback.
  defp tick_if_ansi(%{ansi: true} = state), do: maybe_start_tick(state)
  defp tick_if_ansi(state), do: state

  defp refresh(%{ansi: true} = state), do: redraw(state)
  defp refresh(state), do: state

  defp redraw(state), do: state |> erase() |> draw()

  defp erase(%{drawn: 0} = state), do: state

  defp erase(%{drawn: n, device: device} = state) do
    IO.write(device, ["\r\e[2K", String.duplicate("\e[1A\e[2K", n - 1)])
    %{state | drawn: 0}
  end

  defp draw(%{ansi: false} = state), do: state

  defp draw(state) do
    case Lines.status_block(state, now_ms()) do
      [] ->
        %{state | drawn: 0}

      lines ->
        IO.write(state.device, Enum.intersperse(lines, "\n"))
        %{state | drawn: length(lines)}
    end
  end

  defp maybe_start_tick(%{ticking: true} = state), do: state

  defp maybe_start_tick(state) do
    schedule_tick()
    %{state | ticking: true}
  end

  defp schedule_tick, do: Process.send_after(self(), :tick, @tick_ms)

  defp now_ms, do: System.monotonic_time(:millisecond)

  # === capability detection ==================================================

  # One stderr probe for both animation and width: `:io.columns/1` succeeds only for a real
  # terminal, so a success doubles as the tty test (→ animate) *and* yields the column width;
  # a non-terminal falls back to `@default_width`. We key on stderr (where the block is drawn),
  # not stdout, so redirecting the final report never disables the live status block.
  @spec detect_terminal() :: {boolean(), pos_integer()}
  defp detect_terminal do
    case :io.columns(@device) do
      {:ok, columns} -> {true, columns}
      _ -> {false, @default_width}
    end
  end

  @doc """
  Returns whether persistent labels may use color.

  Any non-empty `NO_COLOR` value disables color. This does not disable ANSI cursor
  animation.
  """
  @spec color_enabled?() :: boolean()
  def color_enabled?, do: System.get_env("NO_COLOR") in [nil, ""]
end
