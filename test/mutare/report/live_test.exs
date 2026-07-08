defmodule Mutare.Report.LiveTest do
  use ExUnit.Case, async: false

  alias Mutare.Report.Live
  alias Mutare.{Result, Site}

  defp site(opts \\ []) do
    %Site{
      id: Keyword.get(opts, :id, 1),
      file: Keyword.get(opts, :file, "lib/x.ex"),
      line: Keyword.get(opts, :line, 12),
      mutator: Keyword.get(opts, :mutator, :relational),
      operation: Keyword.get(opts, :operation, :replace),
      original_code: Keyword.get(opts, :original_code, ">="),
      mutated_code: Keyword.get(opts, :mutated_code, ">")
    }
  end

  defp result(status, site_opts \\ []) do
    %Result{site: site(site_opts), status: status, duration_ms: 1, output: nil}
  end

  describe "humanize_secs/1" do
    test "renders sub-minute as seconds" do
      assert Live.humanize_secs(0) == "0s"
      assert Live.humanize_secs(41) == "41s"
    end

    test "renders a minute or more as minutes + seconds" do
      assert Live.humanize_secs(60) == "1m 0s"
      assert Live.humanize_secs(75) == "1m 15s"
    end
  end

  describe "eta_secs/3" do
    test "extrapolates remaining from rate so far" do
      # 4 done in 41s ⇒ ~10.25s each ⇒ 6 remaining ≈ 62s.
      assert Live.eta_secs(4, 6, 41) == 62
    end

    test "is nil before there is anything to extrapolate from" do
      assert Live.eta_secs(0, 5, 10) == nil
      assert Live.eta_secs(2, 8, 0) == nil
    end
  end

  describe "leave_behind/1" do
    test "survivors and problems earn a permanent line" do
      assert {"SURVIVED", :red} = Live.leave_behind(:survived)
      assert {"TIMEOUT", :yellow} = Live.leave_behind(:timeout)
      assert {"ATOMS", :yellow} = Live.leave_behind(:atom_exhausted)
      assert {"ERROR", :magenta} = Live.leave_behind(:harness_error)
    end

    test "ordinary outcomes only move the counter" do
      for status <- [:killed, :no_coverage, :ignored, :poisoned] do
        assert Live.leave_behind(status) == nil
      end
    end
  end

  describe "status_block/2" do
    test "a pre-mutant phase is one labelled line" do
      state = %{phase: :compiling, width: 80, spinner: 0}
      assert Live.status_block(state, 0) == ["⠋ compiling metamutant (once)…"]
    end

    test "the scanning phase shows the bare label before any file is in" do
      state = %{phase: :scanning, scan: nil, width: 80, spinner: 0}
      assert Live.status_block(state, 0) == ["⠋ scanning for mutants…"]
    end

    test "the scanning phase shows per-file progress and a running mutant tally" do
      state = %{
        phase: :scanning,
        scan: %{done: 3, total: 12, found: 47},
        width: 80,
        spinner: 0
      }

      assert Live.status_block(state, 0) == ["⠋ scanning for mutants — 3/12 file(s) · 47 found"]
    end

    test "idle / finished shows nothing" do
      assert Live.status_block(%{phase: :idle}, 0) == []
    end

    test "the running phase shows an activity line and a counter with an ETA" do
      state = %{
        phase: :running,
        width: 120,
        spinner: 0,
        current: site(file: "lib/cache.ex", line: 22),
        total: 10,
        counts: %{killed: 3, survived: 1},
        started_at: 0
      }

      [activity, counter] = Live.status_block(state, 41_000)

      assert activity =~ "testing lib/cache.ex:22"
      assert activity =~ "relational  >= → >"
      assert counter =~ "4/10"
      assert counter =~ "1 survived"
      assert counter =~ "3 killed"
      assert counter =~ "41s elapsed"
      assert counter =~ "~1m 2s left"
    end

    test "the in-flight line uses the cheap summary for a deferred (un-rendered) site" do
      # On a `mix mutare` scan the in-flight site carries no Sourceror `*_code` (deferred), only
      # the cheap `Macro` `summary`. The activity line must read that, not crash trying to render
      # `nil` (the original FunctionClauseError in String.replace/4).
      deferred = %Site{
        id: 1,
        file: "lib/rate_limits.ex",
        line: 56,
        mutator: :return_value,
        original_code: nil,
        mutated_code: nil,
        summary: "return_value  compute(x) → []"
      }

      state = %{
        phase: :running,
        width: 120,
        spinner: 0,
        current: deferred,
        total: 10,
        counts: %{},
        started_at: 0
      }

      [activity, _counter] = Live.status_block(state, 1_000)

      assert activity =~ "testing lib/rate_limits.ex:56"
      assert activity =~ "return_value  compute(x) → []"
    end

    test "the counter surfaces unusual outcomes only when present" do
      state = %{
        phase: :running,
        width: 120,
        spinner: 0,
        current: nil,
        total: 5,
        counts: %{killed: 1, timeout: 1, harness_error: 1},
        started_at: 0
      }

      [activity, counter] = Live.status_block(state, 5_000)

      assert activity =~ "testing mutants…"
      assert counter =~ "1 timeout"
      assert counter =~ "1 errors"
      refute counter =~ "no-coverage"
    end
  end

  describe "colour (decoupled from animation; NO_COLOR)" do
    test "color_enabled?/0 follows the NO_COLOR env var" do
      original = System.get_env("NO_COLOR")

      on_exit(fn ->
        if original, do: System.put_env("NO_COLOR", original), else: System.delete_env("NO_COLOR")
      end)

      System.delete_env("NO_COLOR")
      assert Live.color_enabled?()

      # Any non-empty value disables colour; an empty string does not (no-color.org).
      System.put_env("NO_COLOR", "1")
      refute Live.color_enabled?()

      System.put_env("NO_COLOR", "")
      assert Live.color_enabled?()
    end

    test "an ANSI run colours the leave-behind label" do
      {:ok, io} = StringIO.open("")
      {:ok, live} = Live.start_link(device: io, ansi: true, color: true, width: 200)

      Live.report(live, result(:survived, file: "lib/cache.ex", line: 22))
      Live.finish(live)

      {_in, out} = StringIO.contents(io)
      assert out =~ "SURVIVED"
      # Red foreground SGR — the label is styled.
      assert out =~ "\e[31m"
    end

    test "NO_COLOR (color: false) keeps the live block but drops the label colour" do
      {:ok, io} = StringIO.open("")
      # `ansi: true, color: false` is the tty-with-NO_COLOR case: the block may still
      # animate, but labels are plain.
      {:ok, live} = Live.start_link(device: io, ansi: true, color: false, width: 200)

      Live.report(live, result(:survived, file: "lib/cache.ex", line: 22))
      Live.finish(live)

      {_in, out} = StringIO.contents(io)
      assert out =~ "SURVIVED  lib/cache.ex:22"
      # No colour SGR codes around the label.
      refute out =~ "\e[31m"
      refute out =~ "\e[1m"
    end
  end

  describe "humanize_ms/1" do
    test "renders milliseconds as one-decimal seconds" do
      assert Live.humanize_ms(0) == "0.0s"
      assert Live.humanize_ms(400) == "0.4s"
      assert Live.humanize_ms(3100) == "3.1s"
      assert Live.humanize_ms(12_340) == "12.3s"
    end
  end

  describe "verbose_leave/1" do
    test "returns a {label, colour} for every status (kills included)" do
      assert {"KILLED", :green} = Live.verbose_leave(:killed)
      assert {"SURVIVED", :red} = Live.verbose_leave(:survived)
      assert {"NOCOV", _} = Live.verbose_leave(:no_coverage)
      assert {"POISON", _} = Live.verbose_leave(:poisoned)
    end
  end

  describe "animating?/1" do
    test "the default ANSI gate follows stderr tty detection, not Elixir's stdout ANSI flag" do
      original = Application.get_env(:elixir, :ansi_enabled, :__unset__)

      on_exit(fn ->
        case original do
          :__unset__ -> Application.delete_env(:elixir, :ansi_enabled)
          value -> Application.put_env(:elixir, :ansi_enabled, value)
        end
      end)

      # Elixir initializes this flag from stdout. In the bug case, stdout is redirected
      # so this is false even though stderr is still a terminal.
      Application.put_env(:elixir, :ansi_enabled, false)

      assert Live.default_ansi?(true)
      refute Live.default_ansi?(false)
    end

    test "reports the ANSI mode (the Mix task's summary gate reads it)" do
      {:ok, io} = StringIO.open("")

      {:ok, ansi} = Live.start_link(device: io, ansi: true, width: 80)
      assert Live.animating?(ansi)

      # A plain (piped/CI) reporter does not animate — it never draws the in-flight line, so the
      # Mix task must not build a per-site summary nothing will consume.
      {:ok, plain} = Live.start_link(device: io, ansi: false, width: 80)
      refute Live.animating?(plain)
    end
  end

  describe "detail_line/1" do
    test "renders the per-phase ✓ notes" do
      assert Live.detail_line({:compiled, 4200}) == "  ✓ compiled in 4.2s"
      assert Live.detail_line({:baseline_done, 3100}) == "  ✓ baseline green in 3.1s"

      assert Live.detail_line(
               {:coverage_done, %{covered: 134, no_coverage: 8, run_all?: false, cap_ms: 9300}}
             ) == "  ✓ coverage: 134 covered · 8 no-coverage · cap 9.3s"
    end

    test "a run-all coverage outcome names the fallback instead of counts" do
      assert Live.detail_line({:coverage_done, %{run_all?: true, cap_ms: 9300}}) ==
               "  ✓ coverage: run-all (no per-mutant selection) · cap 9.3s"
    end
  end

  describe "seed_line/1" do
    test "a seeded app build names the reused vs recompiling beam counts" do
      assert Live.seed_line(%{outcome: :seeded, reused: 12, recompiled: 1}) ==
               "  ✓ reused 12 app beams, recompiling 1 metamutant beam"
    end

    test "singular/plural agree with the counts" do
      assert Live.seed_line(%{outcome: :seeded, reused: 1, recompiled: 2}) ==
               "  ✓ reused 1 app beam, recompiling 2 metamutant beams"
    end

    test "a partial seed names how many apps fell back (umbrella per-app miss)" do
      assert Live.seed_line(%{outcome: :partial, reused: 12, recompiled: 1, fell_back: 1}) ==
               "  ↺ reused 12 app beams (recompiling 1), but 1 app fell back to a cold compile"
    end

    test "a fallback names the otherwise-silent cold compile" do
      assert Live.seed_line(%{outcome: :fallback, reason: "the seed raised: boom"}) ==
               "  ↺ app-build seed fell back to a cold compile (the seed raised: boom)"
    end

    test "a skipped seed renders no line (nil), so verbose stays quiet on the broad-run default" do
      assert Live.seed_line(%{outcome: :skipped}) == nil
    end
  end

  describe "poison_round_line/1" do
    test "names the dropped mutant count" do
      line =
        Live.poison_round_line(%{
          dropped: [%{id: 3, file: "lib/a.ex", line: 2, mutator: :arithmetic}],
          escalated: []
        })

      assert line == "  ⟳ compile-poison: dropped 1 mutant — rebuilding…"
    end

    test "pluralises and names escalated block macros" do
      line =
        Live.poison_round_line(%{
          dropped: [
            %{id: 3, file: "lib/a.ex", line: 2, mutator: :arithmetic},
            %{id: 4, file: "lib/a.ex", line: 3, mutator: :literal}
          ],
          escalated: [%{macro: :guarded, file: "lib/a.ex", line: 5, count: 6}]
        })

      assert line ==
               "  ⟳ compile-poison: dropped 2 mutants, " <>
                 "skipped 1 unknown block macro wholesale (guarded) — rebuilding…"
    end

    test "a round that only escalates still reads (zero individual drops)" do
      line =
        Live.poison_round_line(%{
          dropped: [],
          escalated: [
            %{macro: :guarded, file: "lib/a.ex", line: 5, count: 6},
            %{macro: :parsec, file: "lib/b.ex", line: 1, count: 2}
          ]
        })

      assert line ==
               "  ⟳ compile-poison: dropped 0 mutants, " <>
                 "skipped 2 unknown block macros wholesale (guarded, parsec) — rebuilding…"
    end
  end

  describe "macro_poison_line/1" do
    test "names one inline macro and its module-qualified skip route" do
      line = Live.macro_poison_line(%{macros: [%{module: "Ecto.Query", macro: :from, count: 3}]})

      assert line ==
               "  ⚠ compile-poison inside macro Ecto.Query.from — a mutation there won't " <>
                 "compile; skipping its mutants and rebuilding. Pin to skip up front: " <>
                 "{Ecto.Query, :from, :skip}"
    end

    test "pluralises and lists several macros with their routes" do
      line =
        Live.macro_poison_line(%{
          macros: [
            %{module: "MyDsl", macro: :query, count: 2},
            %{module: "Other", macro: :build, count: 1}
          ]
        })

      assert line ==
               "  ⚠ compile-poison inside macros MyDsl.query, Other.build — a mutation there " <>
                 "won't compile; skipping its mutants and rebuilding. Pin to skip up front: " <>
                 "{MyDsl, :query, :skip}, {Other, :build, :skip}"
    end
  end

  describe "poison-round narration (end to end)" do
    test "leaves a permanent line in plain mode, even when not verbose" do
      {:ok, io} = StringIO.open("")
      {:ok, live} = Live.start_link(device: io, ansi: false, verbose: false, width: 200)

      Live.phase(live, :compiling)

      Live.phase(
        live,
        {:poison_round,
         %{
           dropped: [%{id: 1, file: "lib/a.ex", line: 2, mutator: :arithmetic}],
           escalated: [%{macro: :guarded, file: "lib/a.ex", line: 5, count: 3}]
         }}
      )

      Live.finish(live)
      {_in, out} = StringIO.contents(io)

      assert out =~ "⟳ compile-poison: dropped 1 mutant"
      assert out =~ "skipped 1 unknown block macro wholesale (guarded)"
    end
  end

  describe "verbose mode (plain)" do
    test "non-verbose harness-error lines include the diagnostic" do
      {:ok, io} = StringIO.open("")
      {:ok, live} = Live.start_link(device: io, ansi: false, verbose: false, width: 200)

      Live.report(live, %Result{
        site: site(file: "lib/a.ex", line: 3),
        status: :harness_error,
        duration_ms: 400,
        exit_status: 99,
        output: "** (RuntimeError) checkout failed"
      })

      Live.finish(live)
      {_in, out} = StringIO.contents(io)

      assert out =~
               "ERROR     lib/a.ex:3  relational  >= → >  — exit 99; ** (RuntimeError) checkout failed"
    end

    test "narrates each phase with detail and leaves a line per mutant, with durations" do
      {:ok, io} = StringIO.open("")
      {:ok, live} = Live.start_link(device: io, ansi: false, verbose: true, width: 200)

      Live.phase(live, :compiling)
      Live.phase(live, {:compiled, 4200})
      Live.phase(live, :baseline)
      Live.phase(live, {:baseline_done, 3100})
      Live.phase(live, :coverage_probe)

      Live.phase(
        live,
        {:coverage_done, %{covered: 134, no_coverage: 8, run_all?: false, cap_ms: 9300}}
      )

      Live.phase(live, {:run_config, %{workers: 8, partition_env: nil}})
      Live.phase(live, {:running, 142})
      Live.started(live, site())

      Live.report(live, %Result{
        site: site(file: "lib/a.ex", line: 3, original_code: ">=", mutated_code: ">"),
        status: :killed,
        duration_ms: 400,
        output: nil
      })

      Live.report(live, %Result{
        site:
          site(
            file: "lib/a.ex",
            line: 7,
            mutator: :arithmetic,
            original_code: "+",
            mutated_code: "-"
          ),
        status: :survived,
        duration_ms: 600,
        output: nil
      })

      # A no-coverage mutant launched no suite, so it shows no duration suffix.
      Live.report(live, %Result{
        site: site(file: "lib/b.ex", line: 2),
        status: :no_coverage,
        duration_ms: 0,
        output: nil
      })

      Live.report(live, %Result{
        site: site(file: "lib/c.ex", line: 4),
        status: :harness_error,
        duration_ms: 500,
        exit_status: 99,
        output: "** (RuntimeError) checkout failed"
      })

      Live.finish(live)
      {_in, out} = StringIO.contents(io)

      # Per-phase detail notes.
      assert out =~ "compiling metamutant (once)…"
      assert out =~ "✓ compiled in 4.2s"
      assert out =~ "running baseline suite…"
      assert out =~ "✓ baseline green in 3.1s"
      assert out =~ "✓ coverage: 134 covered · 8 no-coverage · cap 9.3s"
      # The worker count rides onto the running line.
      assert out =~ "testing 142 mutant(s) · 8 workers…"

      # A line per mutant — kills included (unlike non-verbose) — with durations.
      # The label is padded to 8 then a 2-space gap, so "KILLED" → 4 trailing spaces,
      # "NOCOV" → 5; a no-coverage mutant (duration 0) gets no time suffix.
      assert out =~ "KILLED    lib/a.ex:3  relational  >= → >  0.4s"
      assert out =~ "SURVIVED  lib/a.ex:7  arithmetic  + → -  0.6s"
      assert out =~ "NOCOV     lib/b.ex:2  relational"

      assert out =~
               "ERROR     lib/c.ex:4  relational  >= → >  0.5s  — exit 99; ** (RuntimeError) checkout failed"

      refute out =~ "NOCOV     lib/b.ex:2  relational  >= → >  0.0s"

      # Plain mode emits no cursor-control codes.
      refute out =~ "\e["
    end
  end

  describe "end to end (ansi)" do
    test "a deferred (un-rendered) in-flight site draws its summary without crashing" do
      # Regression: a `mix mutare` scan hands `{:start, site}` an un-rendered Site (`*_code` nil).
      # With ansi on, the start cast redraws the in-flight line — which used to crash in
      # String.replace(nil, …). It must now draw the cheap `summary` instead.
      {:ok, io} = StringIO.open("")
      {:ok, live} = Live.start_link(device: io, ansi: true, color: false, width: 101)

      deferred = %Site{
        id: 1,
        file: "lib/importfeed/rate_limits.ex",
        line: 56,
        mutator: :return_value,
        original_code: nil,
        mutated_code: nil,
        summary: "return_value  bucket(key) → []"
      }

      Live.phase(live, {:running, 109})

      # The crash path: handle_cast({:start, …}) → redraw → draw → activity → summary_line.
      Live.started(live, deferred)
      # The GenServer is still alive (a crash would have taken it down).
      assert Process.alive?(live)
      Live.finish(live)

      {_in, out} = StringIO.contents(io)
      assert out =~ "testing lib/importfeed/rate_limits.ex:56"
      assert out =~ "return_value  bucket(key) → []"
    end
  end

  describe "end to end (plain mode)" do
    test "the scan phase notes once and per-file ticks stay silent (no scrollback spam)" do
      {:ok, io} = StringIO.open("")
      {:ok, live} = Live.start_link(device: io, ansi: false, width: 80)

      Live.phase(live, :scanning)
      Live.scanned(live, %{done: 1, total: 2, found: 4})
      Live.scanned(live, %{done: 2, total: 2, found: 9})
      # `clear/1` (a call) flushes; it leaves the reporter live for the run that follows.
      Live.clear(live)
      Live.phase(live, :compiling)
      Live.finish(live)

      {_in, out} = StringIO.contents(io)

      assert out =~ "scanning for mutants…"
      assert out =~ "compiling metamutant (once)…"
      # Plain mode never prints the per-file progress line (it would flood CI logs).
      refute out =~ "1/2"
      refute out =~ "2/2 file(s)"
      refute out =~ "\e["
    end

    test "writes phase notes and a line per survivor/problem, but not per kill" do
      {:ok, io} = StringIO.open("")
      {:ok, live} = Live.start_link(device: io, ansi: false, width: 80)

      Live.phase(live, :compiling)
      Live.phase(live, :baseline)
      Live.phase(live, {:running, 3})
      Live.started(live, site())
      Live.report(live, result(:killed))
      Live.report(live, result(:survived, file: "lib/cache.ex", line: 22))
      Live.report(live, result(:timeout, file: "lib/loop.ex", line: 9))
      Live.finish(live)

      {_in, out} = StringIO.contents(io)

      assert out =~ "compiling metamutant (once)…"
      assert out =~ "running baseline suite…"
      assert out =~ "testing 3 mutant(s)…"
      assert out =~ "SURVIVED  lib/cache.ex:22  relational  >= → >"
      assert out =~ "TIMEOUT   lib/loop.ex:9"
      # A kill never leaves a line behind (it only moves the counter).
      refute out =~ "lib/x.ex:12"
      # Plain mode emits no cursor-control codes.
      refute out =~ "\e["
    end
  end
end
