defmodule Mutare.CLI.PartialReportTest do
  use ExUnit.Case, async: true

  alias Mutare.{Options, Result, Schema, Site}
  alias Mutare.CLI.PartialReport
  alias Mutare.Run.Context

  @moduletag :tmp_dir

  defp site(id) do
    %Site{
      id: id,
      file: "lib/a.ex",
      line: id,
      range: %{start: [line: id, column: 1], end: [line: id, column: 2]},
      mutator: :arithmetic,
      operation: :replace,
      original_code: "+",
      mutated_code: "-"
    }
  end

  defp schema(n), do: %Schema{sites: Enum.map(1..n, &site/1), sources: %{"lib/a.ex" => "a + b"}}

  defp result(id), do: %Result{site: site(id), status: :killed, duration_ms: 1}

  defp start(tmp_dir, sites, opts \\ []) do
    json = Path.join(tmp_dir, "r.json")
    options = Options.new(reporters: [{:json, json}, {:sarif, Path.join(tmp_dir, "r.sarif")}])
    test = self()
    opts = Keyword.put(opts, :halt, &send(test, {:halt, &1}))
    {:ok, partial} = PartialReport.start_link(options, &send(test, {:scan_interrupt, &1}), opts)
    :ok = PartialReport.begin(partial, schema(sites), &send(test, {:interrupt, &1}))
    %{partial: partial, json: json, context: PartialReport.observe(%Context{}, partial)}
  end

  defp statuses(json) do
    %{"files" => %{"lib/a.ex" => %{"mutants" => mutants}}} =
      json |> File.read!() |> JSON.decode!()

    Enum.frequencies_by(mutants, & &1["status"])
  end

  test "checkpoints the JSON report at each tenth of the mutants, and never SARIF", %{
    tmp_dir: tmp_dir
  } do
    %{partial: partial, json: json, context: context} = start(tmp_dir, 20, interval_ms: 60_000)

    context.reporter.(result(1))
    :sys.get_state(partial)
    refute File.exists?(json)

    context.reporter.(result(2))
    :sys.get_state(partial)
    assert statuses(json) == %{"Killed" => 2, "Pending" => 18}

    refute File.exists?(Path.join(tmp_dir, "r.sarif"))
    assert File.ls!(tmp_dir) == ["r.json"]
  end

  test "a result short of the next tenth is checkpointed within the interval", %{tmp_dir: tmp_dir} do
    %{json: json, context: context} = start(tmp_dir, 20, interval_ms: 10)

    context.reporter.(result(1))
    assert eventually(fn -> File.exists?(json) end)
    assert statuses(json) == %{"Killed" => 1, "Pending" => 19}
  end

  test "records beside the context's own reporter", %{tmp_dir: tmp_dir} do
    %{partial: partial} = start(tmp_dir, 4)
    test = self()
    context = PartialReport.observe(%Context{reporter: &send(test, {:reported, &1})}, partial)

    context.reporter.(result(1))
    assert_received {:reported, %Result{site: %Site{id: 1}}}

    PartialReport.interrupt(partial)
    assert_received {:interrupt, [%Result{site: %Site{id: 1}}]}
  end

  test "an interrupt hands over the results so far, in the order they came", %{tmp_dir: tmp_dir} do
    %{partial: partial, context: context} = start(tmp_dir, 50, interval_ms: 60_000)

    Enum.each([1, 2, 3], &context.reporter.(result(&1)))
    PartialReport.interrupt(partial)

    assert_received {:interrupt, results}
    assert Enum.map(results, & &1.site.id) == [1, 2, 3]
  end

  test "an interrupt halts with the SIGTERM status after the callback", %{tmp_dir: tmp_dir} do
    %{partial: partial} = start(tmp_dir, 2)

    PartialReport.interrupt(partial)
    assert_received {:interrupt, []}
    assert_received {:halt, 143}
  end

  test "after close, a result is not checkpointed, and an interrupt only halts", %{
    tmp_dir: tmp_dir
  } do
    %{partial: partial, json: json, context: context} = start(tmp_dir, 2, interval_ms: 10)

    :ok = PartialReport.close(partial)
    context.reporter.(result(1))
    PartialReport.interrupt(partial)

    refute_received {:interrupt, _}
    assert_received {:halt, 143}
    Process.sleep(30)
    refute File.exists?(json)
  end

  test "the halt happens even when the callback raises", %{tmp_dir: tmp_dir} do
    test = self()
    options = Options.new(reporters: [{:json, Path.join(tmp_dir, "r.json")}])
    Process.flag(:trap_exit, true)

    {:ok, partial} =
      PartialReport.start_link(options, fn _ -> raise "boom" end, halt: &send(test, {:halt, &1}))

    ExUnit.CaptureLog.capture_log(fn -> catch_exit(PartialReport.interrupt(partial)) end)
    assert_received {:halt, 143}
  end

  test "an interrupt before the scan finished uses the callback it started with", %{
    tmp_dir: tmp_dir
  } do
    test = self()
    options = Options.new(reporters: [{:json, Path.join(tmp_dir, "r.json")}])

    {:ok, partial} =
      PartialReport.start_link(options, &send(test, {:scan_interrupt, &1}),
        halt: &send(test, {:halt, &1})
      )

    PartialReport.interrupt(partial)
    assert_received {:scan_interrupt, []}
  end

  defp eventually(check, deadline_ms \\ 2_000) do
    cond do
      check.() ->
        true

      deadline_ms <= 0 ->
        false

      true ->
        Process.sleep(5)
        eventually(check, deadline_ms - 5)
    end
  end
end
