defmodule Mutare.CLI.OutcomeTest do
  use ExUnit.Case, async: true

  import ExUnit.CaptureIO

  alias Mutare.{Options, Result, Run, Schema, Site}
  alias Mutare.CLI.Outcome
  alias Mutare.Run.BrokenPartition

  @moduletag :tmp_dir

  @site %Site{
    id: 1,
    file: "lib/a.ex",
    line: 1,
    range: %{start: [line: 1, column: 1], end: [line: 1, column: 2]},
    mutator: :arithmetic,
    operation: :replace,
    original_code: "+",
    mutated_code: "-"
  }

  @broken %BrokenPartition{partition: 2, mutant: 1, failure: :app_start, reason: nil}

  defp run(broken_partitions) do
    %Run{
      schema: %Schema{sites: [@site], sources: %{"lib/a.ex" => "a + b"}},
      results: [%Result{site: @site, status: :killed, partition: 2, duration_ms: 1}],
      sandbox: "unused",
      baseline_ms: 1,
      stopped_early: false,
      broken_partitions: broken_partitions
    }
  end

  describe "scope/2" do
    test "is nil for a run over the whole project" do
      assert Outcome.scope([min_score: 80], Options.new([])) == nil
    end

    test "names each scoping flag as written, in a fixed order" do
      flags = [line: "lib/a.ex:3", only: "lib/a", since: "main", exclude: "lib/a/gen_*.ex"]

      assert Outcome.scope(flags, Options.new(max_mutants: 50)) ==
               "--since main --only lib/a --exclude lib/a/gen_*.ex --line lib/a.ex:3 " <>
                 "--max-mutants 50"
    end

    test "counts a repeatable flag's values past the third" do
      flags = for line <- 1..5, do: {:line, "lib/a.ex:#{line}"}

      assert Outcome.scope(flags, Options.new([])) ==
               "--line lib/a.ex:1 --line lib/a.ex:2 --line lib/a.ex:3 (+2 more --line)"
    end
  end

  test "a finished run's broken partitions reach the reports and fail the score gate", %{
    tmp_dir: tmp_dir
  } do
    json = Path.join(tmp_dir, "r.json")
    options = Options.new(reporters: [{:human, nil}, {:json, json}], min_score: 50)

    stdout =
      capture_io(fn ->
        assert_raise Mix.Error, ~r/cannot be checked against the required minimum/, fn ->
          Outcome.report(run([@broken]), options, nil)
        end
      end)

    assert stdout =~ "partition 2  BROKEN"

    %{"files" => %{"lib/a.ex" => %{"mutants" => [mutant]}}} =
      json |> File.read!() |> JSON.decode!()

    assert mutant["statusReason"] =~ "This kill may be false"
  end

  test "without one, the same run passes the gate", %{tmp_dir: tmp_dir} do
    options = Options.new(reporters: [{:json, Path.join(tmp_dir, "r.json")}], min_score: 50)
    capture_io(fn -> assert Outcome.report(run([]), options, nil) == :ok end)
  end

  # `--no-keep-sandbox` runs in a different directory, so it cannot reset the kept one: the
  # messages that suspect it name it for deletion instead.
  describe "format_error/4 and a kept sandbox" do
    @sandbox "/tmp/mutare_sandbox_abc"

    test "names the kept sandbox to delete when the baseline fails" do
      kept = Outcome.format_error(:baseline_failed, "1 test, 1 failure", "/proj", @sandbox)
      fresh = Outcome.format_error(:baseline_failed, "1 test, 1 failure", "/proj", nil)

      assert kept =~ "kept sandbox at:\n  #{@sandbox}\n"
      assert kept =~ "delete that directory"
      assert kept =~ "1 test, 1 failure"
      refute fresh =~ "kept sandbox"
      refute kept =~ "--no-keep-sandbox"
    end

    test "names the kept sandbox to delete when harness errors abort the run" do
      detail = "3 mutant run(s) failed at the harness level"
      kept = Outcome.format_error(:too_many_harness_errors, detail, "/proj", @sandbox)

      assert String.starts_with?(kept, detail)
      assert kept =~ "If this persists across runs, a stale or corrupted build artifact"
      assert kept =~ @sandbox
      assert Outcome.format_error(:too_many_harness_errors, detail, "/proj", nil) == detail
    end
  end
end
