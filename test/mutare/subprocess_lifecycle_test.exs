defmodule Mutare.SubprocessLifecycleTest do
  @moduledoc """
  A sandbox `mix` must die with the Mutare process that spawned it.

  `System.cmd/3` alone doesn't guarantee that: when the owning BEAM dies
  abnormally (SIGKILL, OOM-kill, a closed terminal), the OS only closes the
  port's pipes, and a compute-bound `mix compile`/`mix test` that never touches
  stdout runs on as an orphan — observed in the wild at multi-day ages and
  double-digit-GB RSS. The injected owner-death watcher
  (`Mutare.Sandbox.Command.Invocation.owner_watch_ast/0`) closes the gap: it
  blocks reading stdin (the pipe whose write end only the owner holds) and
  halts the run on EOF.

  This test exercises the full path end-to-end — a Mutare-prepared sandbox
  (config injection included), an owner process spawning the sandbox's one-time
  compile the way `Invocation.mix/4` does, SIGKILL on the owner mid-compile —
  and asserts the compiling BEAM is gone within seconds. POSIX-only mechanics
  (`kill`), like the orphaning it guards against.
  """
  use ExUnit.Case, async: false

  alias Mutare.Schema
  alias Mutare.Sandbox
  alias Mutare.Sandbox.Command.Invocation
  alias Mutare.Test.Project

  @moduletag :runner
  @moduletag timeout: 120_000

  # The *mechanism* under test is not POSIX-specific (the OS closes a dead
  # process's pipe handles on Windows too, and the watcher halts on `:eof` and
  # `{:error, _}` alike) — but this test's harness is: it reaps and probes OS
  # pids with kill(1).
  if match?({:win32, _}, :os.type()) do
    @moduletag skip: "POSIX-only harness (kill(1)); the watcher itself is OS-neutral"
  end

  # How long the fixture parks the compile: long enough that the kill lands
  # mid-compile, short enough that a failed cleanup can't leave a long-lived
  # orphan behind on the test machine.
  @park_ms 60_000

  test "a sandbox compile dies when the process that spawned it is SIGKILLed" do
    %{base: base, project: project, sandbox: sandbox} =
      Project.build(:orphan, %{
        "lib/slow.ex" => """
        defmodule Slow do
          # Module bodies run at compile time: report the compiling BEAM's OS pid
          # through a side channel (System.cmd buffers stdout until exit, so
          # printing it would never reach the test mid-compile), then park the
          # compile so the owner can be killed mid-flight.
          File.write!(System.fetch_env!("MUTARE_ORPHAN_TEST_PID_FILE"), System.pid())
          Process.sleep(#{@park_ms})
        end
        """
      })

    # Materialise with Mutare's real injections — the config-injected watcher is
    # what must reap the compile (the test bootstrap never runs under `mix compile`).
    Sandbox.prepare(project, %Schema{}, sandbox: sandbox)

    owner_pid_file = Path.join(base, "owner.pid")
    compile_pid_file = Path.join(base, "compile.pid")

    # The owner replicates `Invocation.mix/4`'s spawn (a synchronous `System.cmd`
    # port) with the gate var sourced from the real accessor via argv, so a
    # renamed gate can't silently detach this test from the code under test.
    # (`mix/4` actually *setting* the gate is covered in `InvocationTest`.)
    owner_script = Path.join(base, "owner.exs")

    File.write!(owner_script, """
    [sandbox, owner_pid_file, gate_var, compile_pid_file] = System.argv()
    File.write!(owner_pid_file, System.pid())

    System.cmd("mix", ["compile"],
      cd: sandbox,
      stderr_to_stdout: true,
      env: [
        {"MIX_ENV", "test"},
        {gate_var, "1"},
        {"MUTARE_ORPHAN_TEST_PID_FILE", compile_pid_file}
      ]
    )
    """)

    owner_task =
      Task.async(fn ->
        System.cmd(
          "elixir",
          [owner_script, sandbox, owner_pid_file, Invocation.owner_watch_env(), compile_pid_file],
          stderr_to_stdout: true
        )
      end)

    # Whatever happens below, never leave the parked compile (or the owner)
    # running on the test machine.
    on_exit(fn ->
      for file <- [compile_pid_file, owner_pid_file] do
        case File.read(file) do
          {:ok, pid} -> System.cmd("kill", ["-9", pid], stderr_to_stdout: true)
          _ -> :ok
        end
      end
    end)

    owner_pid = await_pid_file(owner_pid_file, 30_000)
    compile_pid = await_pid_file(compile_pid_file, 60_000)
    assert os_alive?(compile_pid), "the fixture compile died before the owner was killed"

    # The regression under test: kill the owner abnormally, mid-compile.
    {_, 0} = System.cmd("kill", ["-9", owner_pid])

    # The compiling BEAM must reap itself (stdin EOF -> System.halt). Generous
    # bound for slow CI — the prototype measured ~30ms.
    assert wait_until(fn -> not os_alive?(compile_pid) end, 10_000),
           "compile #{compile_pid} outlived its owner: the orphan regression is back"

    # The owner's System.cmd collapses once its child is gone; drain the task.
    Task.await(owner_task, 30_000)
  end

  defp await_pid_file(path, timeout_ms) do
    assert wait_until(fn -> match?({:ok, <<_, _::binary>>}, File.read(path)) end, timeout_ms),
           "#{path} never appeared — the run under test failed to start"

    path |> File.read!() |> String.trim()
  end

  defp os_alive?(pid) do
    {_, status} = System.cmd("kill", ["-0", pid], stderr_to_stdout: true)
    status == 0
  end

  defp wait_until(fun, timeout_ms) do
    deadline = System.monotonic_time(:millisecond) + timeout_ms
    poll(fun, deadline)
  end

  defp poll(fun, deadline) do
    cond do
      fun.() ->
        true

      System.monotonic_time(:millisecond) > deadline ->
        false

      true ->
        Process.sleep(25)
        poll(fun, deadline)
    end
  end
end
