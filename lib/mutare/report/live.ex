defmodule Mutare.Report.Live do
  @moduledoc """
  The live, cargo-mutants-style console progress for the human run.

  This is the *interactive* face of a run, distinct from `Mutare.Report` (the
  final survivor diffs + score) and the machine renderers under `Mutare.Report.*`:
  it shows what the run is **currently doing** as it goes — starting with the
  pre-run **scan** (per-file mutant discovery, via `scanned/2`), then the runner's
  phases — leaves a permanent line behind for each mutant it finds (survivors) or
  trips over (timeouts, harness errors), and — when attached to a terminal — paints
  a live-updating status block at the bottom (a spinner, the activity line, and a
  counter with an ETA).

  The scan runs *before* the runner (in the Mix task), so its progress is driven
  directly rather than through `:on_phase`; `clear/1` tears the scan block down
  before the mutant count prints to stdout so the two don't collide on one line.

  ## Why a process

  The runner calls the `:reporter`/`:on_start` callbacks from many concurrent
  worker processes (one per in-flight mutant), so every terminal write must be
  serialized through a single owner — this `GenServer`. It also owns a tick timer
  so the spinner/elapsed/ETA animate even while the foreground process is blocked
  inside `Task.async_stream`.

  ## Two output modes, one path

  All output goes to **stderr** so it never corrupts a machine report written to
  stdout (`--format json` piped to a file). Whether to animate is decided once at
  start by `detect_ansi/0`: a real terminal on stderr with ANSI enabled gets the
  live status block (cursor moves erase and redraw it); anything else (a pipe, a
  CI log) degrades to plain mode — phase transitions and the leave-behind lines
  print as ordinary scrollback, with no cursor tricks and no spinner. Colour is
  decided separately (`color_enabled?/0`): the `NO_COLOR` convention drops the
  leave-behind label colour while keeping the live block.

  ## Testing

  The stateful IO shell is deliberately thin; the rendering is pure. `status_block/2`,
  `leave_behind/1`, `humanize_secs/1`, `truncate/2`, and `eta_secs/3` take a plain
  state map (or scalars) and return strings, so the visible output is unit-tested
  without a terminal or a clock — the server only wraps them in cursor codes and a
  `System.monotonic_time/1` reading.
  """

  use GenServer

  alias Mutare.{Result, Site}

  @device :standard_error
  @tick_ms 80
  @label_width 8
  @default_width 80

  # A braille spinner — one frame per tick. Cosmetic; only drawn in ANSI mode.
  @frames ~w(⠋ ⠙ ⠹ ⠸ ⠼ ⠴ ⠦ ⠧ ⠇ ⠏)

  # The pre-mutant phases announced, in order, and how each reads. `:scanning` is
  # the pre-run mutant discovery (driven by the Mix task, before the runner); the
  # rest are the runner's. `:scanning` carries live per-file progress on top of
  # this label — see `scan_activity/1`.
  @phase_labels %{
    scanning: "scanning for mutants…",
    compiling: "compiling metamutant (once)…",
    baseline: "running baseline suite…",
    coverage_probe: "probing coverage…"
  }

  # Which result statuses leave a permanent line behind, and how each is styled.
  # Survivors are the product; timeouts, atom-table crashes, and harness errors are
  # problems worth surfacing the moment they happen. Everything else only moves the
  # counter. (`:atom_exhausted` is a kill, like `:timeout`, but still worth a line —
  # an unusual divergence the author probably wants to see.)
  @leave_behind %{
    survived: {"SURVIVED", :red},
    timeout: {"TIMEOUT", :yellow},
    atom_exhausted: {"ATOMS", :yellow},
    harness_error: {"ERROR", :magenta}
  }

  # === client API ============================================================

  @doc """
  Start the live reporter. Options (all optional, for testing):

    * `:device` — IO device to write to (default `:standard_error`)
    * `:ansi` — force animation on/off (default: `detect_ansi/0`)
    * `:color` — force the leave-behind label colour on/off (default: animation on
      *and* `NO_COLOR` unset; see `color_enabled?/0`)
    * `:width` — terminal width for truncation (default: detected, else 80)
  """
  @spec start_link(keyword()) :: GenServer.on_start()
  def start_link(opts \\ []) do
    GenServer.start_link(__MODULE__, opts)
  end

  @doc "Announce a phase transition (`:scanning`, `:compiling`, `:baseline`, `:coverage_probe`, `{:running, total}`)."
  @spec phase(GenServer.server(), atom() | {:running, non_neg_integer()}) :: :ok
  def phase(server, phase), do: GenServer.cast(server, {:phase, phase})

  @doc """
  Update scan progress during the `:scanning` phase: files processed so far out of
  the total, and the running count of mutants found. Refreshes the status block
  (animated only in ANSI mode — in plain mode the one-time `:scanning` note already
  printed, so per-file ticks are silent).
  """
  @spec scanned(GenServer.server(), %{
          done: non_neg_integer(),
          total: non_neg_integer(),
          found: non_neg_integer()
        }) :: :ok
  def scanned(server, progress), do: GenServer.cast(server, {:scan, progress})

  @doc "Note that a mutant run has started (drives the current-activity line)."
  @spec started(GenServer.server(), Site.t()) :: :ok
  def started(server, %Site{} = site), do: GenServer.cast(server, {:start, site})

  @doc "Record a completed mutant result (moves the counter; may leave a line behind)."
  @spec report(GenServer.server(), Result.t()) :: :ok
  def report(server, %Result{} = result), do: GenServer.cast(server, {:report, result})

  @doc """
  Erase the current status block but keep the reporter live — used to clear the
  scan block before the mutant count prints to stdout, so the two don't collide on
  one line. A synchronous `call` so the erase is flushed before the caller writes.
  """
  @spec clear(GenServer.server()) :: :ok
  def clear(server), do: GenServer.call(server, :clear)

  @doc "Tear down the status block, leaving the terminal clean for the final report."
  @spec finish(GenServer.server()) :: :ok
  def finish(server), do: GenServer.call(server, :finish)

  # === server ================================================================

  @impl true
  def init(opts) do
    # Animation (`ansi`) and colour are decoupled: the status block is positioning
    # (cursor codes), the leave-behind labels are the only colour. So `NO_COLOR`
    # drops the colour but keeps the live block (the convention is about colour, not
    # the whole UI); a non-tty (`ansi: false`) is already colourless.
    ansi = Keyword.get_lazy(opts, :ansi, &detect_ansi/0)

    state = %{
      device: Keyword.get(opts, :device, @device),
      ansi: ansi,
      color: Keyword.get_lazy(opts, :color, fn -> ansi and color_enabled?() end),
      width: Keyword.get_lazy(opts, :width, &detect_width/0),
      total: 0,
      counts: %{},
      started_at: nil,
      phase: nil,
      scan: nil,
      current: nil,
      spinner: 0,
      drawn: 0,
      ticking: false,
      finished: false
    }

    {:ok, state}
  end

  @impl true
  def handle_cast({:phase, {:running, total}}, state) do
    state = %{state | phase: :running, total: total, started_at: now_ms(), current: nil}

    if state.ansi do
      {:noreply, state |> maybe_start_tick() |> redraw()}
    else
      {:noreply, plain_line(state, "testing #{total} mutant(s)…")}
    end
  end

  def handle_cast({:phase, phase}, state) when is_map_key(@phase_labels, phase) do
    state = %{state | phase: phase}

    if state.ansi do
      {:noreply, state |> maybe_start_tick() |> redraw()}
    else
      {:noreply, plain_line(state, @phase_labels[phase])}
    end
  end

  def handle_cast({:scan, progress}, state) do
    {:noreply, refresh(%{state | scan: progress})}
  end

  def handle_cast({:start, %Site{} = site}, state) do
    state = %{state | current: site}
    {:noreply, if(state.ansi, do: redraw(state), else: state)}
  end

  def handle_cast({:report, %Result{} = result}, state) do
    state = %{state | counts: bump(state.counts, result.status)}

    case leave_behind(result.status) do
      nil -> {:noreply, refresh(state)}
      styled -> {:noreply, put_line(state, format_leave(styled, result.site, state.color))}
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
  def handle_call(:clear, _from, state) do
    # Erase the block and drop to idle, but stay live (the tick keeps running, the
    # next phase redraws). Distinct from `:finish`, which is terminal.
    {:reply, :ok, %{erase(state) | phase: :idle, scan: nil}}
  end

  def handle_call(:finish, _from, state) do
    {:reply, :ok, %{erase(state) | finished: true, phase: :idle}}
  end

  # === rendering (pure) ======================================================

  @doc """
  The lines of the bottom status block for `state` at `now_ms` (monotonic),
  *without* any cursor codes. Two lines while testing mutants (activity +
  counter), one line during a pre-mutant phase (the phase label), none when idle.
  """
  @spec status_block(map(), integer()) :: [String.t()]
  def status_block(%{phase: :running} = state, now) do
    [
      truncate(spin(state) <> " " <> activity(state), state.width),
      truncate(counter(state, now), state.width)
    ]
  end

  def status_block(%{phase: :scanning} = state, _now) do
    [truncate(spin(state) <> " " <> scan_activity(state), state.width)]
  end

  def status_block(%{phase: phase} = state, _now) when is_map_key(@phase_labels, phase) do
    [truncate(spin(state) <> " " <> @phase_labels[phase], state.width)]
  end

  def status_block(_state, _now), do: []

  @doc """
  The `{label, colour}` styling for a result status that earns a permanent line,
  or `nil` for one that only moves the counter (killed, no-coverage, ignored,
  poisoned).
  """
  @spec leave_behind(Result.status()) :: {String.t(), atom()} | nil
  def leave_behind(status), do: Map.get(@leave_behind, status)

  @doc "Seconds as `Ns` (under a minute) or `Nm Ss`."
  @spec humanize_secs(non_neg_integer()) :: String.t()
  def humanize_secs(s) when s < 60, do: "#{s}s"
  def humanize_secs(s), do: "#{div(s, 60)}m #{rem(s, 60)}s"

  @doc """
  Estimated seconds remaining: `remaining / rate`, where `rate = done /
  elapsed_secs`. `nil` when there is nothing to extrapolate from yet (no elapsed
  time or nothing finished).
  """
  @spec eta_secs(non_neg_integer(), non_neg_integer(), non_neg_integer()) ::
          non_neg_integer() | nil
  def eta_secs(done, _remaining, _elapsed) when done == 0, do: nil
  def eta_secs(_done, _remaining, elapsed) when elapsed == 0, do: nil

  def eta_secs(done, remaining, elapsed) do
    round(remaining * elapsed / done)
  end

  @doc "Clamp `str` to `max` display columns, marking truncation with an ellipsis."
  @spec truncate(String.t(), pos_integer()) :: String.t()
  def truncate(str, max) when max > 1 do
    if String.length(str) > max, do: String.slice(str, 0, max - 1) <> "…", else: str
  end

  def truncate(str, _max), do: str

  # The activity line's payload: the mutant currently being tested, or a
  # placeholder before the first one is picked up.
  defp activity(%{current: nil}), do: "testing mutants…"
  defp activity(%{current: %Site{} = site}), do: "testing #{descriptor(site)}"

  # The scanning line's payload: per-file progress with a running mutant tally
  # once the first file is in, else the bare label (during file discovery).
  defp scan_activity(%{scan: %{done: done, total: total, found: found}}) do
    "scanning for mutants — #{done}/#{total} file(s) · #{found} found"
  end

  defp scan_activity(_state), do: @phase_labels.scanning

  # `done/total · X survived · Y killed[ · …extras] · elapsed[ · ~eta left]`.
  defp counter(state, now) do
    done = state.counts |> Map.values() |> Enum.sum()
    elapsed = elapsed_secs(state, now)

    headline =
      "#{done}/#{state.total} · #{count(state, :survived)} survived · #{count(state, :killed)} killed"

    headline <>
      extras(state) <> " · #{humanize_secs(elapsed)} elapsed" <> eta(done, state, elapsed)
  end

  # Optional, only-when-nonzero tail of the counter (the unusual outcomes).
  defp extras(state) do
    [
      {:timeout, "timeout"},
      {:atom_exhausted, "atom-table"},
      {:no_coverage, "no-coverage"},
      {:ignored, "ignored"},
      {:poisoned, "poisoned"},
      {:harness_error, "errors"}
    ]
    |> Enum.map_join(fn {status, label} ->
      case count(state, status) do
        0 -> ""
        n -> " · #{n} #{label}"
      end
    end)
  end

  defp eta(done, state, elapsed) do
    remaining = state.total - done

    case eta_secs(done, remaining, elapsed) do
      nil -> ""
      _ when remaining <= 0 -> ""
      secs -> " · ~#{humanize_secs(secs)} left"
    end
  end

  # `file:line  <describe>`, the shared one-liner for activity + leave-behind.
  defp descriptor(%Site{} = site), do: "#{site.file}:#{site.line}  #{Site.describe(site)}"

  # A permanent line: a padded status label (coloured when `color?`) then the mutant
  # descriptor. `color?` is decoupled from animation, so `NO_COLOR` yields a plain
  # label even with the live block running.
  defp format_leave({label, colour}, %Site{} = site, color?) do
    padded = String.pad_trailing(label, @label_width)
    tag = if color?, do: ansi_to_binary([colour, :bright, padded, :reset]), else: padded
    "  " <> tag <> "  " <> descriptor(site)
  end

  defp count(state, status), do: Map.get(state.counts, status, 0)

  defp bump(counts, status), do: Map.update(counts, status, 1, &(&1 + 1))

  defp spin(%{spinner: i}), do: Enum.at(@frames, rem(i, length(@frames)))

  defp elapsed_secs(%{started_at: nil}, _now), do: 0
  defp elapsed_secs(%{started_at: start}, now), do: max(div(now - start, 1000), 0)

  # === terminal IO (effectful) ===============================================

  # Print a permanent scrollback line, then re-anchor the status block beneath it.
  # In plain mode this is just a line; in ANSI mode we erase the block first so
  # the new line lands above it, then redraw.
  defp put_line(state, text) do
    state = erase(state)
    IO.write(state.device, [text, "\n"])
    draw(state)
  end

  # Plain-mode-only line (a phase note). In ANSI mode phases live in the block,
  # so this is a no-op there.
  defp plain_line(%{ansi: true} = state, _text), do: state

  defp plain_line(state, text) do
    IO.write(state.device, [text, "\n"])
    state
  end

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
    case status_block(state, now_ms()) do
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

  defp ansi_to_binary(data), do: data |> IO.ANSI.format(true) |> IO.iodata_to_binary()

  # === capability detection ==================================================

  # Animate only when stderr is a real terminal *and* ANSI is enabled. We key on
  # stderr (where the block is drawn), not stdout, so piping the machine report
  # to a file never tricks us into painting cursor codes into it; `IO.ANSI` honours
  # the Elixir `--no-color` switch, `TERM=dumb`, etc.
  defp detect_ansi do
    tty_stderr?() and IO.ANSI.enabled?()
  end

  @doc """
  Whether the leave-behind labels may be coloured: the `NO_COLOR` env var is unset
  or empty (the https://no-color.org convention — *any* non-empty value disables
  colour). Distinct from `detect_ansi/0`: `NO_COLOR` drops the colour but keeps the
  live block, since the convention is about colour, not the whole terminal UI.
  `IO.ANSI.enabled?/0` (folded into `detect_ansi/0`) does not check `NO_COLOR`, so
  this does.
  """
  @spec color_enabled?() :: boolean()
  def color_enabled?, do: System.get_env("NO_COLOR") in [nil, ""]

  defp detect_width do
    case :io.columns(@device) do
      {:ok, columns} -> columns
      _ -> @default_width
    end
  end

  # `:io.columns/1` only succeeds for a terminal, so it doubles as a tty probe.
  defp tty_stderr?, do: match?({:ok, _}, :io.columns(@device))
end
