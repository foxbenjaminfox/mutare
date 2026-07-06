defmodule Mutare.Sandbox.CommandTest do
  use ExUnit.Case, async: true

  alias Mutare.Sandbox.Command

  test "timeout exit code constant" do
    assert Command.timeout_exit() == 124
  end

  test "failure exit is distinct from the codes a harness failure can produce" do
    assert Command.failure_exit() == 101
    # 0 = success, 1 = mix/compile failure, 2 = ExUnit default, 124 = timeout.
    refute Command.failure_exit() in [0, 1, 2, Command.timeout_exit()]
  end

  describe "success?/1 is the single home for \"0 means success\"" do
    test "0 is the only success code" do
      assert Command.success?(0)
    end

    test "every other exit code is not success" do
      for status <- [1, 2, 3, Command.failure_exit(), Command.timeout_exit(), 137, 255] do
        refute Command.success?(status), "exit #{status} must not read as success"
      end
    end

    test "agrees with outcome/1 on the pass code" do
      # The two readings of exit 0 must never drift apart.
      assert Command.success?(0) == (Command.outcome(0) == :passed)
    end
  end

  describe "outcome/1 decodes the exit-code contract" do
    test "0 is a pass (the mutation survived)" do
      assert Command.outcome(0) == :passed
    end

    test "the forced failure exit is a clean test failure (a kill)" do
      assert Command.outcome(Command.failure_exit()) == :failed
    end

    test "the watcher's exit code is a timeout" do
      assert Command.outcome(Command.timeout_exit()) == :timeout
    end

    test "an OS SIGKILL (128 + 9, the OOM killer's signature) is :sigkilled" do
      # A harness error by verdict, but decoded distinctly so the runner never
      # retries it — a likely-OOM mutant re-detonates on a back-to-back re-run.
      assert Command.outcome(Command.sigkill_exit()) == :sigkilled
      assert Command.sigkill_exit() == 137
    end

    test "every other exit code is a harness error, never a kill" do
      # 1 = compile error / missing dep / broken helper; 2 = ExUnit default were
      # --exit-status ever dropped; 139 = 128 + SIGSEGV. None is a kill.
      for status <- [1, 2, 3, 127, 139, 255] do
        assert Command.outcome(status) == :harness_error,
               "exit #{status} must not be miscounted as a kill"
      end
    end
  end

  describe "outcome/2 refines a harness error with the run's output" do
    # The discriminators these decode against are unit-tested in
    # `Mutare.Sandbox.Command.Output`; here we pin the *decoder* — that each
    # refinement maps to the right outcome and never overrides a real verdict.
    @test_compile_error """
    == Compilation error in file test/plug/router_test.exs ==
    ** (ArgumentError) errors were found at the given arguments:
        (plug) lib/plug/router/utils.ex:338: Plug.Router.Utils.build_path_clause/3
        test/plug/router_test.exs:26: (module)
    """

    test "a per-mutant test-suite compile failure (exit 1) is a kill, not infra" do
      # The mutation broke code that runs at the test modules' compile time, so the
      # suite can't build with it — detected. The lib compiled once at baseline, so
      # this fresh compile error can only be a re-evaluated test script.
      assert Command.outcome(1, @test_compile_error) == :suite_compile_error
    end

    test "a real harness error (missing dep, exit 1) stays a harness error" do
      missing_dep = "Unchecked dependencies for environment test:\n* mime (Hex package)"
      assert Command.outcome(1, missing_dep) == :harness_error
    end

    test "a lib-file compile error is not a suite compile error (fail safe)" do
      # A compile error in a lib source is unexpected (the lib compiled at
      # baseline) — treat it as infra, never silently as a kill.
      lib_error = "== Compilation error in file lib/plug/router/utils.ex ==\n** (CompileError)"
      assert Command.outcome(1, lib_error) == :harness_error
    end

    test "output never overrides a real verdict (pass/fail/timeout win)" do
      # The refinement only applies to the otherwise-`:harness_error` case.
      assert Command.outcome(0, @test_compile_error) == :passed
      assert Command.outcome(Command.failure_exit(), @test_compile_error) == :failed
      assert Command.outcome(Command.timeout_exit(), @test_compile_error) == :timeout
    end

    # The BEAM prints this to stderr (merged into the captured output) and aborts
    # the node when the atom table fills — a mutation minting unbounded atoms.
    @atom_crash """
    no more index entries in atom_tab (max=1048576)

    Crash dump is being written to: erl_crash.dump...done
    """

    test "an atom-table exhaustion is a kill (resource-divergence), not infra" do
      # The VM crashed before the timeout watcher could self-halt, so it lands on a
      # generic harness exit code — exit 1, or a signal code if the abort raised one.
      assert Command.outcome(1, @atom_crash) == :atom_exhausted
      assert Command.outcome(134, @atom_crash) == :atom_exhausted
    end

    test "the atom banner never overrides a real verdict (pass/fail/timeout win)" do
      assert Command.outcome(0, @atom_crash) == :passed
      assert Command.outcome(Command.failure_exit(), @atom_crash) == :failed
      assert Command.outcome(Command.timeout_exit(), @atom_crash) == :timeout
    end

    # The emulator's self-erasing boot crash: a supervised child fails to start under
    # contention, the node tears down mid-boot, and the CLI exit-reporter's attempt to
    # print the cause recurses on a torn-down `:standard_error`, replacing the original
    # reason. The truncated slogan that reaches us still carries both markers.
    @boot_crash """
    Slogan: Runtime terminating during boot ({badarg,[{io,put_chars,[standard_error,
      [<<"** (EXIT from #PID<0.99.0>) an exception was raised:
            ** (ArgumentError) errors were found at the given arguments:
          * 1st argument: the device does not exist
                (stdlib) io.erl:98: :io.put_chars(:standard_error, [...])">>]]}]})
    """

    test "a self-erasing boot crash is a (named) harness error, not a kill" do
      # The node died before any verdict, so it lands on a generic harness exit code
      # (exit 1, or a signal code if the abort raised one). The refinement *names* the
      # cause (`:boot_failure`) so the runner can retry/message it — but it stays out
      # of the score, never charged as a kill.
      assert Command.outcome(1, @boot_crash) == :boot_failure
      assert Command.outcome(158, @boot_crash) == :boot_failure
    end

    test "the boot banner never overrides a real verdict (pass/fail/timeout win)" do
      assert Command.outcome(0, @boot_crash) == :passed
      assert Command.outcome(Command.failure_exit(), @boot_crash) == :failed
      assert Command.outcome(Command.timeout_exit(), @boot_crash) == :timeout
    end

    test "a detected kill is never masked by a co-occurring boot banner" do
      # Contrived (a node dead at boot never filled the atom table), but precedence
      # is fail-safe toward the kill — the verdict wins over the cause label.
      assert Command.outcome(1, @atom_crash <> @boot_crash) == :atom_exhausted
    end

    test "a SIGKILL bypasses the output refinements (truncated output is unreliable)" do
      # A SIGKILLed run's output stops wherever the kill landed, so banner-matching
      # against it would be guesswork — and none of the markers' causes exits via
      # SIGKILL anyway (a compile error exits 1; atom exhaustion aborts the VM itself).
      assert Command.outcome(Command.sigkill_exit(), "") == :sigkilled
      assert Command.outcome(Command.sigkill_exit(), @test_compile_error) == :sigkilled
      assert Command.outcome(Command.sigkill_exit(), @atom_crash) == :sigkilled
      assert Command.outcome(Command.sigkill_exit(), @boot_crash) == :sigkilled
    end
  end

  describe "test_argv/1 builds the kill-detection mix test argv" do
    # A flag and its value are passed as two adjacent argv elements.
    defp flag_value(argv, flag) do
      case Enum.find_index(argv, &(&1 == flag)) do
        nil -> nil
        i -> Enum.at(argv, i + 1)
      end
    end

    test "forces the failure exit status so a kill is distinct from a harness error" do
      assert flag_value(Command.test_argv([]), "--exit-status") ==
               Integer.to_string(Command.failure_exit())
    end

    test "forces --max-failures 1, since one failure is enough to declare a kill" do
      assert flag_value(Command.test_argv([]), "--max-failures") == "1"
    end

    test "skips mix startup checks that are pure overhead under the one-compile invariant" do
      argv = Command.test_argv([])
      # Sources never change between per-mutant runs, so the compile-staleness scan and the
      # deps/archives checks are redundant work paid N times — see `@boot_skip_flags`.
      assert "--no-compile" in argv
      assert "--no-deps-check" in argv
      assert "--no-archives-check" in argv
    end

    test "appends the caller's test args (file-granular selection) after the flags" do
      argv = Command.test_argv(["test/foo_test.exs", "test/bar_test.exs"])
      # The forced flags come first; the selection is appended verbatim at the tail.
      assert List.starts_with?(argv, ["test", "--exit-status", "101", "--max-failures", "1"])
      assert Enum.take(argv, -2) == ["test/foo_test.exs", "test/bar_test.exs"]
    end

    test "a whole-suite run ([] args) carries the forced + boot-skip flags, no selection" do
      assert Command.test_argv([]) ==
               ["test", "--exit-status", "101", "--max-failures", "1"] ++
                 ["--no-compile", "--no-deps-check", "--no-archives-check"]
    end
  end
end
