defmodule Mutare.Report.LiveTest do
  use ExUnit.Case, async: true

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

  describe "truncate/2" do
    test "leaves short strings untouched" do
      assert Live.truncate("hello", 80) == "hello"
    end

    test "clamps with an ellipsis" do
      assert Live.truncate("hello world", 5) == "hell…"
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
