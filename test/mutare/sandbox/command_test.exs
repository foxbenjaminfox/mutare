defmodule Mutare.Sandbox.CommandTest do
  # Not async: the inert-watcher check touches the process-global timeout env var.
  use ExUnit.Case, async: false

  alias Mutare.Sandbox
  alias Mutare.Sandbox.Command

  setup do
    on_exit(fn -> System.delete_env(Command.timeout_env()) end)
  end

  test "timeout contract constants" do
    assert Command.timeout_env() == "MUTARE_TIMEOUT"
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

  describe "mix output vocabulary (the shared patterns live here)" do
    test "compile_error_banner/0 captures the offending file path" do
      banner = "== Compilation error in file test/foo_test.exs ==\n** (ArgumentError)"
      assert [_, "test/foo_test.exs"] = Regex.run(Command.compile_error_banner(), banner)
    end

    test "source_location_regex/0 matches any .ex/.exs file:line (Poison reads it)" do
      assert [_, "lib/foo.ex", "5"] =
               Regex.run(Command.source_location_regex(), "lib/foo.ex:5:12: error")

      assert [_, "test/foo_test.exs", "42"] =
               Regex.run(Command.source_location_regex(), "test/foo_test.exs:42")
    end

    test "test_location_regex/0 narrows to _test.exs files (Baseline reads it)" do
      assert [_, "test/foo_test.exs", "9"] =
               Regex.run(Command.test_location_regex(), "test/foo_test.exs:9")

      # A lib source or a non-test script is not a test location.
      refute Regex.run(Command.test_location_regex(), "lib/foo.ex:5")
      refute Regex.run(Command.test_location_regex(), "test/support/helper.exs:5")
    end

    test "a test location is also a source location (the narrowing is consistent)" do
      output = "test/foo_test.exs:42"
      assert Regex.run(Command.test_location_regex(), output)
      assert Regex.run(Command.source_location_regex(), output)
    end

    test "diagnostic_severity/1 classifies a line's marker (Poison reads it)" do
      assert Command.diagnostic_severity("    error: cannot use variable x as map key") == :error
      assert Command.diagnostic_severity("  warning: variable \"a\" is unused") == :warning

      assert Command.diagnostic_severity("** (CompileError) lib/foo.ex: cannot compile") ==
               :error

      # A non-marker line (a diagnostic's footer/body, or chatter) has no severity of
      # its own — it inherits the block's, which the caller threads.
      assert Command.diagnostic_severity("    └─ lib/foo.ex:5:12: Foo.bar/1") == nil
      assert Command.diagnostic_severity("Compiling 43 files (.ex)") == nil
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

    test "every other exit code is a harness error, never a kill" do
      # 1 = compile error / missing dep / broken helper; 2 = ExUnit default were
      # --exit-status ever dropped; 137 = 128 + SIGKILL (e.g. OOM). None is a kill.
      for status <- [1, 2, 3, 127, 137, 255] do
        assert Command.outcome(status) == :harness_error,
               "exit #{status} must not be miscounted as a kill"
      end
    end
  end

  describe "outcome/2 refines a harness error with the run's output" do
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
      refute Command.suite_compile_error?(lib_error)
    end

    test "output never overrides a real verdict (pass/fail/timeout win)" do
      # The refinement only applies to the otherwise-`:harness_error` case.
      assert Command.outcome(0, @test_compile_error) == :passed
      assert Command.outcome(Command.failure_exit(), @test_compile_error) == :failed
      assert Command.outcome(Command.timeout_exit(), @test_compile_error) == :timeout
    end

    test "suite_compile_error?/1 matches only a .exs under a test/ dir" do
      assert Command.suite_compile_error?(@test_compile_error)
      # umbrella app test path
      assert Command.suite_compile_error?(
               "== Compilation error in file apps/x/test/x_test.exs =="
             )

      # no banner, a lib .ex, or a non-test .exs script: not a suite compile error
      refute Command.suite_compile_error?("1) test foo (MyTest)\n   Assertion failed")
      refute Command.suite_compile_error?("== Compilation error in file lib/foo.ex ==")
      refute Command.suite_compile_error?("== Compilation error in file priv/seeds.exs ==")
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

    test "atom_exhausted?/1 matches only the VM atom-table abort banner" do
      assert Command.atom_exhausted?(@atom_crash)
      # an ordinary test failure, a compile error, or other resource crash is not one
      refute Command.atom_exhausted?("1) test foo (MyTest)\n   Assertion failed")
      refute Command.atom_exhausted?(@test_compile_error)
      refute Command.atom_exhausted?("Cannot allocate 1234 bytes of memory")
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

    test "appends the caller's test args (file-granular selection) after the flags" do
      argv = Command.test_argv(["test/foo_test.exs", "test/bar_test.exs"])
      # The forced flags come first; the selection is appended verbatim at the tail.
      assert List.starts_with?(argv, ["test", "--exit-status", "101", "--max-failures", "1"])
      assert Enum.take(argv, -2) == ["test/foo_test.exs", "test/bar_test.exs"]
    end

    test "a whole-suite run ([] args) carries only the forced flags" do
      assert Command.test_argv([]) == ["test", "--exit-status", "101", "--max-failures", "1"]
    end
  end

  test "watcher AST carries the timeout env var and exit code" do
    rendered = Macro.to_string(Command.watcher_ast())

    assert rendered =~ ~s|System.get_env("#{Command.timeout_env()}")|
    assert rendered =~ "System.halt(#{Command.timeout_exit()})"
  end

  test "watcher AST is inert when no cap is set" do
    System.delete_env(Command.timeout_env())
    # nil branch returns :ok and spawns nothing — safe to evaluate in-process.
    assert {:ok, _binding} = Code.eval_quoted(Command.watcher_ast())
  end

  test "sandbox renders the canonical watcher AST" do
    assert Sandbox.bootstrap() =~ Macro.to_string(Command.watcher_ast())
  end

  describe "erl_compiler_options/1 (metamutant compile speed)" do
    # Parse the produced string as Erlang terms, so every case proves we emit a
    # well-formed list the compiler can read (never a malformed value that could
    # break the single build).
    defp parse_terms(str) do
      {:ok, tokens, _} = :erl_scan.string(String.to_charlist(str <> ". "))
      {:ok, term} = :erl_parse.parse_term(tokens)
      term
    end

    test "with no inherited options, yields just the alias-pass-off option" do
      for none <- [nil, "", "   "] do
        assert Command.erl_compiler_options(none) == "[no_ssa_opt_alias]"
        assert parse_terms(Command.erl_compiler_options(none)) == [:no_ssa_opt_alias]
      end
    end

    test "an empty inherited list collapses to just our option" do
      assert Command.erl_compiler_options("[]") == "[no_ssa_opt_alias]"
    end

    test "prepends our option to an inherited list, preserving the rest" do
      result = Command.erl_compiler_options("[bin_opt_info, warn_missing_spec]")
      assert result == "[no_ssa_opt_alias, bin_opt_info, warn_missing_spec]"
      assert parse_terms(result) == [:no_ssa_opt_alias, :bin_opt_info, :warn_missing_spec]
    end

    test "wraps a bare (non-list) inherited term into a list with our option" do
      assert Command.erl_compiler_options("bin_opt_info") == "[no_ssa_opt_alias, bin_opt_info]"
    end

    test "preserves a nested term in the inherited list (strips outer brackets only)" do
      result = Command.erl_compiler_options("[{d, [debug]}]")
      assert result == "[no_ssa_opt_alias, {d, [debug]}]"
      assert parse_terms(result) == [:no_ssa_opt_alias, {:d, [:debug]}]
    end

    test "always parses as an Erlang term list containing our option" do
      for inherited <- [nil, "", "[]", "[a, b]", "bare", "[{d, [x]}]"] do
        terms = parse_terms(Command.erl_compiler_options(inherited))
        assert is_list(terms)
        assert :no_ssa_opt_alias in terms
      end
    end
  end

  test "compiler_env/0 sets ERL_COMPILER_OPTIONS with the alias-pass-off option" do
    assert [{"ERL_COMPILER_OPTIONS", value}] = Command.compiler_env()
    assert value =~ "no_ssa_opt_alias"
  end
end
