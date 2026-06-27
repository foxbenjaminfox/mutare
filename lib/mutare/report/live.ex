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

  ## Output modes

  All output goes to **stderr** so it never corrupts a machine report written to
  stdout (`--format json` piped to a file). A real terminal on stderr with ANSI
  enabled gets the live status block (a spinner and a redrawn counter); anything
  else (a pipe, a CI log) degrades to plain scrollback — phase transitions and the
  leave-behind lines, no cursor tricks, no spinner. Colour is decided separately:
  the `NO_COLOR` convention drops the leave-behind label colour while keeping the
  live block. `--quiet` suppresses the reporter entirely (the Mix task simply
  doesn't start it).

  ## Verbose mode

  `--verbose` (the `:verbose` start option) turns the compact display into a full
  behind-the-scenes narrative: a permanent scrollback line for **every** mutant as
  it finishes (not just survivors/problems), each with its outcome label and
  duration, plus a `✓` detail line after each phase — the one compile's time, the
  baseline timing, the coverage breakdown + derived timeout cap, and the worker
  count on the testing line. The extra phase numbers ride on the same `:on_phase`
  hook as structured detail events (`{:compiled, ms}`, `{:baseline_done, ms}`,
  `{:coverage_done, summary}`, `{:run_config, cfg}`) that the runner fires
  unconditionally; this reporter renders them only when `verbose` is set, so the
  runner stays ignorant of the display. `--quiet` wins over `--verbose` (a quiet
  run starts no reporter at all).
  """

  use GenServer

  alias Mutare.{Result, Site}
  alias Mutare.Result.Status

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

  # Which result statuses leave a permanent line behind, and how each is styled —
  # the `:leave_behind` field of each `Mutare.Result.Status` descriptor (a status
  # with none only moves the counter). Survivors are the product; timeouts,
  # atom-table crashes, and harness errors are problems worth surfacing the moment
  # they happen. Derived from the registry so a new status's styling lives with its
  # other facts (CLAUDE.md "Result statuses").
  @leave_behind for d <- Status.all(), d.leave_behind, into: %{}, do: {d.name, d.leave_behind}

  # Every status's `{label, colour}` for `--verbose`, which leaves a line behind for
  # *all* outcomes (kills included), not just the survivors/problems `@leave_behind`
  # covers. Required on every descriptor, so this map is total — `verbose_leave/1`
  # uses `Map.fetch!` and an unregistered status is a loud bug.
  @verbose_labels for d <- Status.all(), into: %{}, do: {d.name, d.verbose_label}

  # The only-when-nonzero tail of the live counter: each status carrying an
  # `:extra_label` (i.e. everything but `:killed`/`:survived`, which own the counter
  # headline), in render order.
  @extras for d <- Status.all(), d.extra_label, do: {d.name, d.extra_label}

  # The server's internal state. A struct (not a bare map) so a mistyped field access in
  # any handler is a compile error, not a silent runtime `nil`. `init/1` overrides the five
  # capability fields (`device`/`ansi`/`color`/`width`/`verbose`); the rest start at these
  # defaults. The pure rendering functions stay `map()`-typed — a `%__MODULE__{}` matches
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
  Start the live reporter. Options (all optional, for testing):

    * `:device` — IO device to write to (default `:standard_error`)
    * `:ansi` — force animation on/off (default: stderr is a tty *and* `IO.ANSI.enabled?/0`)
    * `:color` — force the leave-behind label colour on/off (default: animation on
      *and* `NO_COLOR` unset; see `color_enabled?/0`)
    * `:width` — terminal width for truncation (default: detected, else 80)
    * `:verbose` — leave a line behind for every mutant and render the per-phase
      detail notes (default `false`); see the "Verbose mode" section above
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
    #
    # One stderr probe gives both the tty? flag (ANDed with `IO.ANSI.enabled?/0` for `ansi`)
    # and the column width — what `detect_ansi`/`detect_width` used to query twice.
    {tty?, width} = detect_terminal()
    ansi = Keyword.get_lazy(opts, :ansi, fn -> tty? and IO.ANSI.enabled?() end)

    state = %__MODULE__{
      device: Keyword.get(opts, :device, @device),
      ansi: ansi,
      color: Keyword.get_lazy(opts, :color, fn -> ansi and color_enabled?() end),
      width: Keyword.get(opts, :width, width),
      verbose: Keyword.get(opts, :verbose, false)
    }

    {:ok, state}
  end

  @impl true
  def handle_cast({:phase, {:running, total}}, state) do
    state = %{state | phase: :running, total: total, started_at: now_ms(), current: nil}

    cond do
      # Verbose keeps the live counter block (the per-mutant lines scroll above it),
      # and leads with a permanent label line carrying the worker count.
      state.verbose ->
        {:noreply, state |> tick_if_ansi() |> put_line(running_label(state, total))}

      state.ansi ->
        {:noreply, state |> maybe_start_tick() |> redraw()}

      true ->
        {:noreply, plain_line(state, running_label(state, total))}
    end
  end

  # The verbose-only structured detail events the runner fires alongside the phase
  # starts (`{:compiled, ms}`, `{:baseline_done, ms}`, `{:coverage_done, summary}`).
  # Each renders a `✓` scrollback note via the pure `detail_line/1` when verbose, and
  # is a no-op otherwise — so the runner emits them unconditionally without knowing
  # whether anyone is listening.
  def handle_cast({:phase, {:compiled, _ms} = event}, state),
    do: {:noreply, maybe_detail(state, event)}

  def handle_cast({:phase, {:baseline_done, _ms} = event}, state),
    do: {:noreply, maybe_detail(state, event)}

  def handle_cast({:phase, {:coverage_done, _summary} = event}, state),
    do: {:noreply, maybe_detail(state, event)}

  # The run configuration (worker count, partition) is stashed, not printed: the
  # worker count rides onto the next `{:running, total}` label (verbose only).
  def handle_cast({:phase, {:run_config, cfg}}, state),
    do: {:noreply, %{state | run_config: cfg}}

  def handle_cast({:phase, phase}, state) when is_map_key(@phase_labels, phase) do
    state = %{state | phase: phase}

    cond do
      # Verbose: a permanent scrollback note (no animated block for the pre-mutant
      # phases — the `✓` detail line follows right behind it).
      state.verbose ->
        {:noreply, verbose_note(state, @phase_labels[phase])}

      state.ansi ->
        {:noreply, state |> maybe_start_tick() |> redraw()}

      true ->
        {:noreply, plain_line(state, @phase_labels[phase])}
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
        {:noreply, put_line(state, format_verbose(result, state.color))}

      # Non-verbose: only survivors/problems leave a line; the rest move the counter.
      styled = leave_behind(result.status) ->
        {:noreply, put_line(state, format_leave(styled, result.site, state.color))}

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

  @doc """
  The `{label, colour}` for a status in `--verbose` mode, where every outcome (kills
  included) earns a permanent line. Total over the status vocabulary — raises on an
  unregistered name, since every descriptor carries a `verbose_label`.
  """
  @spec verbose_leave(Result.status()) :: {String.t(), atom()}
  def verbose_leave(status), do: Map.fetch!(@verbose_labels, status)

  @doc """
  The `✓` scrollback note for a verbose phase-detail event — the pure render of a
  `{:compiled, ms}` / `{:baseline_done, ms}` / `{:coverage_done, summary}` event the
  runner fires on `:on_phase`.
  """
  @spec detail_line(tuple()) :: String.t()
  def detail_line({:compiled, ms}), do: "  ✓ compiled in #{humanize_ms(ms)}"
  def detail_line({:baseline_done, ms}), do: "  ✓ baseline green in #{humanize_ms(ms)}"
  def detail_line({:coverage_done, summary}), do: "  ✓ " <> coverage_note(summary)

  @doc "Seconds as `Ns` (under a minute) or `Nm Ss`."
  @spec humanize_secs(non_neg_integer()) :: String.t()
  def humanize_secs(s) when s < 60, do: "#{s}s"
  def humanize_secs(s), do: "#{div(s, 60)}m #{rem(s, 60)}s"

  @doc "Milliseconds as one-decimal seconds (e.g. `450 → \"0.5s\"`, `3100 → \"3.1s\"`)."
  @spec humanize_ms(non_neg_integer()) :: String.t()
  def humanize_ms(ms), do: "#{:erlang.float_to_binary(ms / 1000, decimals: 1)}s"

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

  # The `:running` phase label. In verbose mode it appends the worker count from the
  # stashed `:run_config` (`{:run_config, cfg}` always fires just before
  # `{:running, total}`); the non-verbose label is unchanged.
  defp running_label(%{verbose: true, run_config: %{workers: w}}, total) when is_integer(w) do
    "testing #{total} mutant(s) · #{w} worker#{plural(w)}…"
  end

  defp running_label(_state, total), do: "testing #{total} mutant(s)…"

  # The coverage-probe detail (verbose): the per-mutant selection breakdown and the
  # derived per-mutant timeout cap. `run_all?` means coverage was unusable/uncertain,
  # so every covered mutant runs the whole suite (no per-mutant selection).
  defp coverage_note(%{run_all?: true, cap_ms: cap}) do
    "coverage: run-all (no per-mutant selection) · cap #{humanize_ms(cap)}"
  end

  defp coverage_note(%{covered: covered, no_coverage: no_coverage, cap_ms: cap}) do
    "coverage: #{covered} covered · #{no_coverage} no-coverage · cap #{humanize_ms(cap)}"
  end

  defp plural(1), do: ""
  defp plural(_n), do: "s"

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
    Enum.map_join(@extras, fn {status, label} ->
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

  # The verbose per-mutant line: every status's `verbose_label` (coloured when
  # `color?`), the shared descriptor, and a duration suffix for a mutant that
  # actually ran (`duration_ms > 0` — so a no-coverage/ignored/poisoned mutant, which
  # launched no suite, shows no time).
  defp format_verbose(%Result{site: site, status: status, duration_ms: ms}, color?) do
    format_leave(verbose_leave(status), site, color?) <> duration_suffix(ms)
  end

  defp duration_suffix(ms) when is_integer(ms) and ms > 0, do: "  " <> humanize_ms(ms)
  defp duration_suffix(_ms), do: ""

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

  # A permanent scrollback line that leaves *no* block behind it (drawn: 0): the
  # verbose phase notes and `✓` detail lines, which precede the per-mutant loop, so
  # there is no live counter to re-anchor (unlike `put_line/2`). Erases any block
  # first (a no-op when none is drawn), then writes — works in both ANSI and plain.
  defp verbose_note(state, text) do
    state = erase(state)
    IO.write(state.device, [text, "\n"])
    %{state | drawn: 0}
  end

  # Render a verbose phase-detail event as a scrollback note, or do nothing when not
  # verbose (the runner fires these unconditionally).
  defp maybe_detail(%{verbose: true} = state, event), do: verbose_note(state, detail_line(event))
  defp maybe_detail(state, _event), do: state

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

  # One stderr probe for both animation and width: `:io.columns/1` succeeds only for a real
  # terminal, so a success doubles as the tty test (→ animate) *and* yields the column width;
  # a non-terminal falls back to `@default_width`. We key on stderr (where the block is drawn),
  # not stdout, so piping the machine report to a file never tricks us into painting cursor
  # codes into it. The caller ANDs the tty? flag with `IO.ANSI.enabled?/0` (which honours the
  # Elixir `--no-color` switch, `TERM=dumb`, etc.) for the final `ansi` decision.
  @spec detect_terminal() :: {boolean(), pos_integer()}
  defp detect_terminal do
    case :io.columns(@device) do
      {:ok, columns} -> {true, columns}
      _ -> {false, @default_width}
    end
  end

  @doc """
  Whether the leave-behind labels may be coloured: the `NO_COLOR` env var is unset
  or empty (the https://no-color.org convention — *any* non-empty value disables
  colour). Distinct from the `ansi` decision (`detect_terminal/0` + `IO.ANSI.enabled?/0`):
  `NO_COLOR` drops the colour but keeps the live block, since the convention is about
  colour, not the whole terminal UI. `IO.ANSI.enabled?/0` (folded into `ansi`) does not
  check `NO_COLOR`, so this does.
  """
  @spec color_enabled?() :: boolean()
  def color_enabled?, do: System.get_env("NO_COLOR") in [nil, ""]
end
