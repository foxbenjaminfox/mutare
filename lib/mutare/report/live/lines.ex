defmodule Mutare.Report.Live.Lines do
  @moduledoc """
  The text of the live display, rendered from the reporter's state.

  `Mutare.Report.Live` owns the process, the output modes, and the terminal; every line it
  draws or leaves in scrollback is rendered here — the animated status block
  (`status_block/2`), a mutant's leave-behind or `--verbose` line, a phase's label or
  detail note, and the compile-poison narration. Nothing here touches the terminal, so
  each line is testable on its own. Cursor-control sequences are the reporter's, never
  part of a line.
  """

  alias Mutare.{CLI, Result, Site}
  alias Mutare.Poison.Hint
  alias Mutare.Report.HarnessDiagnostic
  alias Mutare.Result.Status

  @label_width 8

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

  # === phase lines ===========================================================

  @doc """
  The label of a pre-mutant phase (`:scanning`, `:compiling`, `:baseline`,
  `:coverage_probe`), or `nil` for anything else.
  """
  @spec phase_label(term()) :: String.t() | nil
  def phase_label(phase), do: Map.get(@phase_labels, phase)

  @doc """
  The `:running` phase's label. In verbose mode it appends the worker count from the
  stashed `:run_config` (`{:run_config, cfg}` always fires just before
  `{:running, total}`); the non-verbose label is unchanged.
  """
  @spec running_label(map(), non_neg_integer()) :: String.t()
  def running_label(%{verbose: true, run_config: %{workers: w}}, total) when is_integer(w) do
    "testing #{total} mutant(s) · #{w} worker#{plural(w)}…"
  end

  def running_label(_state, total), do: "testing #{total} mutant(s)…"

  @doc "The label announcing the post-stream timeout-confirmation pass."
  @spec confirming_label(non_neg_integer()) :: String.t()
  def confirming_label(count),
    do: "confirming #{count} timeout#{plural(count)} without contention…"

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
  Renders a verbose detail event as a persistent status line: a phase's completion, or a
  `mix.exs` whose inference override did not land.
  """
  @spec detail_line(tuple()) :: String.t()
  def detail_line({:compiled, ms}), do: "  ✓ compiled in #{humanize_ms(ms)}"
  def detail_line({:baseline_done, ms}), do: "  ✓ baseline green in #{humanize_ms(ms)}"
  def detail_line({:coverage_done, summary}), do: "  ✓ " <> coverage_note(summary)

  def detail_line({:inference_override_declined, %{file: file, reason: reason}}) do
    "  ↺ could not disable type-signature inference for #{file} (#{reason}); " <>
      "the compile may be much slower"
  end

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
  copy-paste route to pin the skip up front (`Mutare.Poison.Hint.route_tuple/2` — `:raw`
  for a call, `:skip` for a head Mutare analyzes structurally), or a `# mutare:ignore`
  pointer when no route can name any of them.
  """
  @spec macro_poison_line(map()) :: String.t()
  def macro_poison_line(%{macros: macros}) do
    named = Enum.map_join(macros, ", ", fn m -> "#{m.module}.#{m.macro}" end)
    n = length(macros)

    pin =
      case Enum.flat_map(macros, &List.wrap(Hint.route_tuple(&1.module, &1.macro))) do
        [] ->
          "no call route can name #{if(n == 1, do: "it", else: "them")}; use `# mutare:ignore` " <>
            "around the offending code"

        routes ->
          "Pin to skip up front: #{Enum.join(routes, ", ")}"
      end

    "  ⚠ compile-poison inside macro#{plural(n)} #{named} — a mutation there won't compile; " <>
      "skipping its mutants and rebuilding. #{pin}"
  end

  # === mutant lines ==========================================================

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
  A mutant's permanent line: its `leave_behind/1` styling (coloured when `color?`), the
  mutant descriptor, and — for a harness error — the compact diagnostic.
  """
  @spec leave_line({String.t(), atom()}, Result.t(), boolean()) :: String.t()
  def leave_line(styled, %Result{site: site} = result, color?) do
    labelled(styled, site, color?) <> diagnostic_suffix(result)
  end

  @doc """
  The verbose per-mutant line: every status's `verbose_leave/1` label (coloured when
  `color?`), the shared descriptor, and a duration suffix for a mutant that actually ran
  (`duration_ms > 0` — so a no-coverage/ignored/poisoned mutant, which launched no suite,
  shows no time).
  """
  @spec verbose_line(Result.t(), boolean()) :: String.t()
  def verbose_line(%Result{status: status, duration_ms: ms} = result, color?) do
    labelled(verbose_leave(status), result.site, color?) <>
      duration_suffix(ms) <> diagnostic_suffix(result)
  end

  # A padded status label (coloured when `color?`) then the mutant descriptor. `color?` is
  # decoupled from animation, so `NO_COLOR` yields a plain label even with the live block
  # running.
  defp labelled({label, colour}, %Site{} = site, color?) do
    padded = String.pad_trailing(label, @label_width)
    tag = if color?, do: ansi_to_binary([colour, :bright, padded, :reset]), else: padded
    "  " <> tag <> "  " <> descriptor(site)
  end

  defp diagnostic_suffix(%Result{status: :harness_error} = result),
    do: "  — " <> HarnessDiagnostic.summary(result)

  defp diagnostic_suffix(%Result{}), do: ""

  defp duration_suffix(ms) when is_integer(ms) and ms > 0, do: "  " <> humanize_ms(ms)
  defp duration_suffix(_ms), do: ""

  # `file:line  <describe>`, the one-liner for the permanent leave-behind / verbose lines (whose
  # result sites carry `*_code` — eager, or hydrated for survivors).
  defp descriptor(%Site{} = site), do: "#{site.file}:#{site.line}  #{Site.describe(site)}"

  # The same shape for the live in-flight line, but via `Site.summary_line/1` — the cheap `Macro`
  # `summary` when present, else `describe/1`. Lets the activity line render an un-hydrated
  # (deferred-scan) site without a `Sourceror` round-trip.
  defp live_descriptor(%Site{} = site),
    do: "#{site.file}:#{site.line}  #{Site.summary_line(site)}"

  defp ansi_to_binary(data), do: data |> IO.ANSI.format(true) |> IO.iodata_to_binary()

  # === durations =============================================================

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

  # === the status block's parts ==============================================

  # The activity line's payload: the mutant currently being tested, or a
  # placeholder before the first one is picked up. The in-flight line uses the cheap
  # `Site.summary_line/1` (the `Macro` `summary`, present on a non-`--quiet` run), so a deferred
  # scan's un-hydrated site needs no `Sourceror` render just to show progress; the permanent
  # leave-behind / verbose lines stay on `descriptor/1` (hydrated `*_code`).
  defp activity(%{current: nil}), do: "testing mutants…"
  defp activity(%{current: %Site{} = site}), do: "testing #{live_descriptor(site)}"

  # The scanning line's payload: per-file progress with a running mutant tally
  # once the first file is in, else the bare label (during file discovery).
  defp scan_activity(%{scan: %{done: done, total: total, found: found}}) do
    "scanning for mutants — #{done}/#{total} file(s) · #{found} found"
  end

  defp scan_activity(_state), do: @phase_labels.scanning

  # The coverage-probe detail (verbose): the per-mutant selection breakdown and the
  # derived per-mutant timeout cap. `run_all?` means coverage was unusable/uncertain,
  # so every covered mutant runs the whole suite (no per-mutant selection).
  defp coverage_note(%{run_all?: true, cap_ms: cap}) do
    "coverage: run-all (no per-mutant selection) · cap #{humanize_ms(cap)}"
  end

  defp coverage_note(%{covered: covered, no_coverage: no_coverage, cap_ms: cap}) do
    "coverage: #{covered} covered · #{no_coverage} no-coverage · cap #{humanize_ms(cap)}"
  end

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

  defp count(state, status), do: Map.get(state.counts, status, 0)

  defp spin(%{spinner: i}), do: Enum.at(@frames, rem(i, length(@frames)))

  defp elapsed_secs(%{started_at: nil}, _now), do: 0
  defp elapsed_secs(%{started_at: start}, now), do: max(div(now - start, 1000), 0)

  defp plural(1), do: ""
  defp plural(_n), do: "s"
end
