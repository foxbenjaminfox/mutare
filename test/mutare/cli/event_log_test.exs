defmodule Mutare.CLI.EventLogTest do
  use ExUnit.Case, async: true

  alias Mutare.{Options, Result, Run, Schema, Site}
  alias Mutare.CLI.EventLog
  alias Mutare.Run.Context

  @moduletag :tmp_dir

  defp site(id) do
    %Site{
      id: id,
      file: "lib/a.ex",
      line: 1,
      column: 3,
      range: %{start: [line: 1, column: 3], end: [line: 1, column: 4]},
      mutator: :arithmetic,
      operation: :replace,
      mutated_code: "-"
    }
  end

  defp schema(n),
    do: %Schema{
      sites: Enum.map(1..n, &site/1),
      sources: %{"lib/a.ex" => "a + b\n"},
      metamutants: %{"lib/a.ex" => ""}
    }

  defp result(id, status \\ :killed), do: %Result{site: site(id), status: status}

  defp events(path),
    do: path |> File.read!() |> String.split("\n", trim: true) |> Enum.map(&JSON.decode!/1)

  defp start(tmp_dir) do
    path = Path.join(tmp_dir, "events.jsonl")
    {:ok, log} = EventLog.start_link(path)
    {path, log}
  end

  test "replaces the file with a start event", %{tmp_dir: tmp_dir} do
    path = Path.join(tmp_dir, "events.jsonl")
    File.write!(path, ~s({"event":"finish"}\n))

    {:ok, _log} = EventLog.start_link(path)

    assert [%{"event" => "start", "version" => 1, "elapsed_ms" => _}] = events(path)
  end

  test "a run's events land in order, each line as it is written", %{tmp_dir: tmp_dir} do
    {path, log} = start(tmp_dir)
    schema = schema(2)
    test = self()

    context =
      EventLog.observe(
        %Context{reporter: &send(test, {:reported, &1}), on_phase: &send(test, {:phase, &1})},
        log,
        schema
      )

    :ok = EventLog.scanned(log, schema)
    context.on_phase.(:compiling)
    context.on_phase.({:compiled, 120})
    context.on_phase.({:running, 2})
    context.reporter.(result(1))
    context.reporter.(result(2, :survived))

    # Each write is a call, so its line is in the file before the hook returns.
    assert [
             %{"event" => "start"},
             %{"event" => "scanned", "mutants" => 2, "files" => 1},
             %{"event" => "phase", "phase" => "compiling"},
             %{"event" => "phase", "phase" => "running", "mutants" => 2},
             %{
               "event" => "mutant",
               "evaluated" => 1,
               "id" => 1,
               "status" => "killed",
               "original" => "+",
               "replacement" => "-"
             },
             %{"event" => "mutant", "evaluated" => 2, "id" => 2, "status" => "survived"}
           ] = events(path)

    # The context's own hooks still see everything, detail events included.
    assert_received {:phase, {:compiled, 120}}
    assert_received {:reported, %Result{site: %Site{id: 2}}}

    run = %Run{
      schema: schema,
      results: [result(1), result(2, :survived)],
      sandbox: tmp_dir,
      baseline_ms: 1,
      stopped_early: true
    }

    :ok = EventLog.finished(log, run, Options.new(max_survivors: 1))

    assert %{
             "event" => "finish",
             "stopped" => "max_survivors",
             "mutants" => 2,
             "evaluated" => 2,
             "score" => 50.0
           } = List.last(events(path))
  end

  test "writes nothing after the finish", %{tmp_dir: tmp_dir} do
    {path, log} = start(tmp_dir)
    schema = schema(3)
    context = EventLog.observe(%Context{}, log, schema)

    :ok = EventLog.scanned(log, schema)
    context.reporter.(result(1))
    context.reporter.(result(2, :survived))
    :ok = EventLog.interrupted(log)
    context.reporter.(result(3))
    :ok = EventLog.failed(log, :baseline_failed, "late")

    # A SIGTERM's finish counts and scores the mutant lines the file holds.
    assert [
             _start,
             %{"event" => "scanned"},
             %{"event" => "mutant"},
             %{"event" => "mutant"},
             %{
               "event" => "finish",
               "stopped" => "sigterm",
               "mutants" => 3,
               "evaluated" => 2,
               "counts" => %{"killed" => 1, "survived" => 1, "timeout" => 0},
               "score" => 50.0
             }
           ] =
             events(path)
  end

  test "a SIGTERM during the scan finishes with the mutant count unknown", %{tmp_dir: tmp_dir} do
    {path, log} = start(tmp_dir)
    :ok = EventLog.interrupted(log)
    assert %{"stopped" => "sigterm", "mutants" => nil, "evaluated" => 0} = List.last(events(path))
  end

  test "an error finish carries the reason and message", %{tmp_dir: tmp_dir} do
    {path, log} = start(tmp_dir)
    :ok = EventLog.failed(log, :compile_failed, "the metamutant failed to compile")

    assert %{
             "stopped" => "error",
             "error" => "compile_failed",
             "message" => "the metamutant failed to compile"
           } =
             List.last(events(path))
  end

  test "a file that cannot be opened is an error, not a crash", %{tmp_dir: tmp_dir} do
    assert {:error, :enoent} =
             EventLog.start_link(Path.join([tmp_dir, "missing", "events.jsonl"]))
  end
end
