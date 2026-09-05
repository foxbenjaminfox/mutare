defmodule Mutare.Report.Live do
  @moduledoc """
  Live progress for the human report.

  Progress is written to stderr so stdout remains safe for the final or machine-readable report. An interactive terminal gets a spinner, current mutant, counts, and ETA; pipes and CI logs get plain scrollback. Survivors, timeouts, and harness errors remain visible after the live display advances.

  `--verbose` prints a line for every mutant and timing details for each phase. `--quiet` suppresses live progress entirely and takes precedence over `--verbose`.
  """

  use GenServer

  alias Mutare.{CLI, Result, Site}
  alias Mutare.Report.HarnessDiagnostic
  alias Mutare.Result.Status
  alias Mutare.Transform.StructuralForms

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
          | {:compiled, non_neg_integer()}
          | {:baseline_done, non_neg_integer()}
          | {:coverage_done, map()}
          | {:run_config, map()}
          | {:poison_round, map()}
          | {:macro_poison, map()}

  @doc """
  Records a phase transition or verbose detail event.

  Phase transitions are `:scanning`, `:compiling`, `:baseline`,
  `:coverage_probe`, and `{:running, total}`. Detail events are
  `{:compiled, ms}`, `{:baseline_done, ms}`, `{:coverage_done, summary}`, and
  `{:run_config, cfg}`. `{:poison_round, info}` (a compile-poison recovery round) and
  `{:macro_poison, info}` (the macro-expansion fallback skipping an inline DSL macro)
  each leave a permanent line in every mode, not just verbose.
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

  # The app-build `_build` seed's outcome (fired by `Mutare.Sandbox` during the compile
  # phase). A verbose-only `✓`/`↺` scrollback note surfacing the reused/recompiled beam
  # counts, or an otherwise-silent fall back to a cold compile; a `:skipped` outcome (the
  # broad-run default) leaves no line even in verbose. Inert (no line) in every other mode.
  def handle_cast({:phase, {:seed_app_build, summary}}, state),
    do: {:noreply, maybe_seed_note(state, summary)}

  # The run configuration (worker count, partition) is stashed, not printed: the
  # worker count rides onto the next `{:running, total}` label (verbose only).
  def handle_cast({:phase, {:run_config, cfg}}, state),
    do: {:noreply, %{state | run_config: cfg}}

  # A compile-poison recovery round: the metamutant failed to compile, the implicated
  # mutants were dropped, and a rebuild is starting. Unlike the verbose-only `✓` details,
  # this leaves a permanent line in **every** mode — each round is a full recompile, so
  # without it the whole recovery hides behind the "compiling metamutant (once)…" spinner
  # and reads as a hang. In ANSI mode `put_line/2` lands it above the live block and
  # re-anchors; plain mode just writes it.
  def handle_cast({:phase, {:poison_round, info}}, state) do
    line = poison_round_line(info)

    if state.ansi,
      do: {:noreply, put_line(state, line)},
      else: {:noreply, plain_line(state, line)}
  end

  # The macro-expansion poison fallback fired: a mutation wouldn't compile inside an inline
  # DSL macro the compiler blamed by name, so its mutants are being skipped wholesale and the
  # metamutant rebuilt. Loud (`⚠`) and permanent in every mode — it names the macro and the
  # copy-paste `{Module, :fun, :raw}` fix inline, so a first-run user aiming at an unknown
  # DSL sees *why* the compile is being retried and how to pin it, not a silent hang.
  def handle_cast({:phase, {:macro_poison, info}}, state) do
    line = macro_poison_line(info)

    if state.ansi,
      do: {:noreply, put_line(state, line)},
      else: {:noreply, plain_line(state, line)}
  end

  # The post-stream timeout-confirmation pass (`Mutare.Runner`): each provisional
  # `:timeout` is re-run sequentially and its final verdict arrives as a normal
  # `:report`, so this only announces the pass. The phase stays `:running` — the
  # counter block keeps animating while the confirmations report in.
  def handle_cast({:phase, {:confirming_timeouts, count}}, state) do
    label = "confirming #{count} timeout#{plural(count)} without contention…"

    cond do
      state.verbose -> {:noreply, put_line(state, label)}
      state.ansi -> {:noreply, redraw(state)}
      true -> {:noreply, plain_line(state, label)}
    end
  end

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
        {:noreply, put_line(state, format_leave(styled, result, state.color))}

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

  # === rendering (pure) ======================================================

  @doc """
  Returns the status-block lines for `state` at monotonic time `now_ms`.

  A running phase has an activity line and a counter. A pre-run phase has one
  line. An idle state has none. Cursor-control sequences are not included.
  """
  @spec status_block(map(), integer()) :: [String.t()]
  def status_block(%{phase: :running} = state, now) do
    [
      CLI.truncate(spin(state) <> " " <> activity(state), state.width),
      CLI.truncate(counter(state, now), state.width)
    ]
  end

  def status_block(%{phase: :scanning} = state, _now) do
    [CLI.truncate(spin(state) <> " " <> scan_activity(state), state.width)]
  end

  def status_block(%{phase: phase} = state, _now) when is_map_key(@phase_labels, phase) do
    [CLI.truncate(spin(state) <> " " <> @phase_labels[phase], state.width)]
  end

  def status_block(_state, _now), do: []

  @doc """
  Returns the persistent `{label, color}` for `status`, or `nil` when the status
  only updates the counter.
  """
  @spec leave_behind(Result.status()) :: {String.t(), atom()} | nil
  def leave_behind(status), do: Map.get(@leave_behind, status)

  @doc """
  Returns the persistent `{label, color}` for `status` in verbose mode.

  Every registered status has a verbose label. An unknown status raises.
  """
  @spec verbose_leave(Result.status()) :: {String.t(), atom()}
  def verbose_leave(status), do: Map.fetch!(@verbose_labels, status)

  @doc """
  Renders a verbose phase-completion event as a persistent status line.
  """
  @spec detail_line(tuple()) :: String.t()
  def detail_line({:compiled, ms}), do: "  ✓ compiled in #{humanize_ms(ms)}"
  def detail_line({:baseline_done, ms}), do: "  ✓ baseline green in #{humanize_ms(ms)}"
  def detail_line({:coverage_done, summary}), do: "  ✓ " <> coverage_note(summary)

  @doc """
  Renders the app-build seed's outcome (`Mutare.Sandbox.Seed.summary/0`) as a persistent
  status line, or `nil` for a `:skipped` seed (the broad-run default — no line even in
  verbose). `:seeded` shows the reused vs recompiling beam counts; `:partial` adds how many
  apps fell back (an umbrella per-app miss); `:fallback` names the otherwise-silent fall
  back to a cold compile.
  """
  @spec seed_line(map()) :: String.t() | nil
  def seed_line(%{outcome: :seeded, reused: reused, recompiled: recompiled}) do
    "  ✓ reused #{reused} app beam#{plural(reused)}, recompiling " <>
      "#{recompiled} metamutant beam#{plural(recompiled)}"
  end

  def seed_line(%{outcome: :partial, reused: reused, recompiled: recompiled, fell_back: fell}) do
    "  ↺ reused #{reused} app beam#{plural(reused)} (recompiling #{recompiled}), but " <>
      "#{fell} app#{plural(fell)} fell back to a cold compile"
  end

  def seed_line(%{outcome: :fallback, reason: reason}),
    do: "  ↺ app-build seed fell back to a cold compile (#{reason})"

  def seed_line(%{outcome: :skipped}), do: nil

  @doc """
  Renders one compile-poison recovery round as a persistent status line: how many
  mutants were dropped and how many block macros were escalated (skipped wholesale),
  naming the escalated macros so the line explains *why* the compile is being retried.
  """
  @spec poison_round_line(map()) :: String.t()
  def poison_round_line(%{dropped: dropped, escalated: escalated}) do
    dropped_n = length(dropped)
    parts = ["dropped #{dropped_n} mutant#{plural(dropped_n)}" | escalation_parts(escalated)]
    "  ⟳ compile-poison: " <> Enum.join(parts, ", ") <> " — rebuilding…"
  end

  # The escalation clause of the poison-round line: nothing when no block was widened this
  # round, else `skipped N macro(s): name, name` — the actionable part, since an escalated
  # macro is the one a `:call_routes` entry should target.
  defp escalation_parts([]), do: []

  defp escalation_parts(escalated) do
    names = escalated |> Enum.map(&to_string(&1.macro)) |> Enum.uniq() |> Enum.join(", ")
    n = length(escalated)
    ["skipped #{n} unknown block macro#{plural(n)} wholesale (#{names})"]
  end

  @doc """
  Renders the macro-expansion poison fallback as a loud, persistent warning: names the
  inline DSL macro(s) whose argument wouldn't compile with a mutation spliced in, and the
  copy-paste route to pin the skip up front — `:raw` for a call, `:skip` for a head Mutare
  analyzes structurally (`Kernel.in`), and a `# mutare:ignore` pointer for a head no route can
  name (the classification `Mutare.Poison.Hint` uses).
  """
  @spec macro_poison_line(map()) :: String.t()
  def macro_poison_line(%{macros: macros}) do
    named = Enum.map_join(macros, ", ", fn m -> "#{m.module}.#{m.macro}" end)
    n = length(macros)

    routes =
      Enum.flat_map(macros, fn m ->
        case StructuralForms.hint_treatment_for(m.module, m.macro) do
          nil -> []
          treatment -> ["{#{m.module}, #{inspect(m.macro)}, #{inspect(treatment)}}"]
        end
      end)

    pin =
      case routes do
        [] ->
          "no call route can name #{if(n == 1, do: "it", else: "them")}; use `# mutare:ignore` " <>
            "around the offending code"

        routes ->
          "Pin to skip up front: #{Enum.join(routes, ", ")}"
      end

    "  ⚠ compile-poison inside macro#{plural(n)} #{named} — a mutation there won't compile; " <>
      "skipping its mutants and rebuilding. #{pin}"
  end

  @doc "Seconds as `Ns` (under a minute) or `Nm Ss`."
  @spec humanize_secs(non_neg_integer()) :: String.t()
  def humanize_secs(s) when s < 60, do: "#{s}s"
  def humanize_secs(s), do: "#{div(s, 60)}m #{rem(s, 60)}s"

  @doc "Milliseconds as one-decimal seconds (e.g. `450 → \"0.5s\"`, `3100 → \"3.1s\"`)."
  @spec humanize_ms(non_neg_integer()) :: String.t()
  def humanize_ms(ms), do: "#{:erlang.float_to_binary(ms / 1000, decimals: 1)}s"

  @doc """
  Estimates remaining seconds from completed work, remaining work, and elapsed
  seconds.

  Returns `nil` until at least one item has completed and elapsed time is non-zero.
  """
  @spec eta_secs(non_neg_integer(), non_neg_integer(), non_neg_integer()) ::
          non_neg_integer() | nil
  def eta_secs(done, _remaining, _elapsed) when done == 0, do: nil
  def eta_secs(_done, _remaining, elapsed) when elapsed == 0, do: nil

  def eta_secs(done, remaining, elapsed) do
    round(remaining * elapsed / done)
  end

  # The activity line's payload: the mutant currently being tested, or a
  # placeholder before the first one is picked up. The in-flight line uses the cheap
  # `Site.summary_line/1` (the `Macro` `summary`, present on a non-`--quiet` run), so a deferred
  # scan's un-hydrated site needs no `Sourceror` render just to show progress; the permanent
  # leave-behind / verbose lines below stay on `descriptor/1` (hydrated `*_code`).
  defp activity(%{current: nil}), do: "testing mutants…"
  defp activity(%{current: %Site{} = site}), do: "testing #{live_descriptor(site)}"

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

  # `file:line  <describe>`, the one-liner for the permanent leave-behind / verbose lines (whose
  # result sites carry `*_code` — eager, or hydrated for survivors).
  defp descriptor(%Site{} = site), do: "#{site.file}:#{site.line}  #{Site.describe(site)}"

  # The same shape for the live in-flight line, but via `Site.summary_line/1` — the cheap `Macro`
  # `summary` when present, else `describe/1`. Lets the activity line render an un-hydrated
  # (deferred-scan) site without a `Sourceror` round-trip.
  defp live_descriptor(%Site{} = site),
    do: "#{site.file}:#{site.line}  #{Site.summary_line(site)}"

  # A permanent line: a padded status label (coloured when `color?`) then the mutant
  # descriptor. `color?` is decoupled from animation, so `NO_COLOR` yields a plain
  # label even with the live block running.
  defp format_leave({label, colour}, %Site{} = site, color?) do
    padded = String.pad_trailing(label, @label_width)
    tag = if color?, do: ansi_to_binary([colour, :bright, padded, :reset]), else: padded
    "  " <> tag <> "  " <> descriptor(site)
  end

  defp format_leave(label, %Result{site: site} = result, color?) do
    format_leave(label, site, color?) <> diagnostic_suffix(result)
  end

  # The verbose per-mutant line: every status's `verbose_label` (coloured when
  # `color?`), the shared descriptor, and a duration suffix for a mutant that
  # actually ran (`duration_ms > 0` — so a no-coverage/ignored/poisoned mutant, which
  # launched no suite, shows no time).
  defp format_verbose(%Result{status: status, duration_ms: ms} = result, color?) do
    format_leave(verbose_leave(status), result.site, color?) <>
      duration_suffix(ms) <> diagnostic_suffix(result)
  end

  defp diagnostic_suffix(%Result{status: :harness_error} = result),
    do: "  — " <> HarnessDiagnostic.summary(result)

  defp diagnostic_suffix(%Result{}), do: ""

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

  # A plain-mode phase note. Only ever reached from the non-ANSI (`true ->`) branch of the phase
  # casts — in ANSI mode phases live in the animated block, never as a scrollback line — so it
  # writes unconditionally. (An `%{ansi: true}` no-op clause here would be dead code: the call sites
  # narrow `ansi` to `false`, which Elixir 1.20's type checker proves and flags.)
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

  # Like `maybe_detail/2`, but `seed_line/1` returns `nil` for a `:skipped` seed — leave no
  # line in that case (and in every non-verbose mode).
  defp maybe_seed_note(%{verbose: true} = state, summary) do
    case seed_line(summary) do
      nil -> state
      line -> verbose_note(state, line)
    end
  end

  defp maybe_seed_note(state, _summary), do: state

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
