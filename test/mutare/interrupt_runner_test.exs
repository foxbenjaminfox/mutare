defmodule Mutare.InterruptRunnerTest do
  @moduledoc """
  A `mix mutare` run killed by SIGTERM keeps its reports.

  Drives a real `mix mutare` OS process (a signal cannot be sent to a task running inside
  the test VM without stopping the test VM): it waits for the first JSON checkpoint, which
  shows the checkpoint path works, then sends SIGTERM and checks what the run left behind.
  POSIX-only mechanics (`kill`).
  """
  # Subprocess-bound: runs beside the in-process tests, one module at a time within its
  # group (`test_helper.exs` says why there are three).
  use ExUnit.Case, async: true, group: :subprocess_2

  alias Mutare.Test.Project

  @moduletag :runner
  @moduletag timeout: 300_000

  if match?({:win32, _}, :os.type()) do
    @moduletag skip: "POSIX-only harness (kill(1))"
  end

  test "a SIGTERM writes the JSON report with the untested mutants Pending, and no SARIF" do
    %{base: base, project: project, sandbox: sandbox} =
      Project.build(:interrupted, %{
        "lib/calc.ex" => """
        defmodule Calc do
          def add(a, b), do: a + b
          def sub(a, b), do: a - b
          def big?(x), do: x > 10
          def small?(x), do: x < 3
        end
        """,
        # Each mutant's run takes at least a second, so mutants are still untested when
        # the signal lands.
        "test/calc_test.exs" => """
        defmodule CalcTest do
          use ExUnit.Case

          test "calc" do
            Process.sleep(1_000)
            assert Calc.add(2, 3) == 5
            assert Calc.sub(5, 3) == 2
            assert Calc.big?(11)
            assert Calc.small?(2)
          end
        end
        """
      })

    json = Path.join(base, "report.json")
    sarif = Path.join(base, "report.sarif")

    port =
      Port.open({:spawn_executable, System.find_executable("mix")}, [
        :binary,
        :exit_status,
        :stderr_to_stdout,
        cd: File.cwd!(),
        env: [{~c"MIX_ENV", ~c"test"}],
        args: [
          "mutare",
          project,
          "--sandbox",
          sandbox,
          "--workers",
          "1",
          "--report",
          "json:" <> json,
          "--report",
          "sarif:" <> sarif
        ]
      ])

    {:os_pid, os_pid} = Port.info(port, :os_pid)
    output = await_file(port, json, "")

    assert %{"Pending" => pending} = statuses(json)
    assert pending > 0

    {_, 0} = System.cmd("kill", ["-TERM", to_string(os_pid)])
    {output, status} = await_exit(port, output)

    assert status == 143, output
    assert output =~ ~r/stopped on SIGTERM; evaluated \d+ of \d+ mutants/
    assert output =~ "The SARIF report was not written"
    # Written on the signal, not only left over from the checkpoint.
    assert output =~ "wrote json report to #{json}"

    final = statuses(json)
    assert final["Pending"] > 0
    assert map_size(Map.delete(final, "Pending")) > 0

    refute File.exists?(sarif)
    assert Enum.filter(File.ls!(base), &String.ends_with?(&1, ".tmp")) == []
  end

  # Collect the run's output until the checkpoint at `path` exists.
  defp await_file(port, path, output) do
    if File.exists?(path) do
      output
    else
      receive do
        {^port, {:data, data}} ->
          await_file(port, path, output <> data)

        {^port, {:exit_status, status}} ->
          flunk("exited #{status} before a checkpoint:\n#{output}")
      after
        100 -> await_file(port, path, output)
      end
    end
  end

  defp await_exit(port, output) do
    receive do
      {^port, {:data, data}} -> await_exit(port, output <> data)
      {^port, {:exit_status, status}} -> {output, status}
    after
      60_000 -> flunk("still running a minute after SIGTERM:\n#{output}")
    end
  end

  defp statuses(json) do
    %{"files" => files} = json |> File.read!() |> JSON.decode!()

    files
    |> Enum.flat_map(fn {_file, %{"mutants" => mutants}} -> mutants end)
    |> Enum.frequencies_by(& &1["status"])
  end
end
