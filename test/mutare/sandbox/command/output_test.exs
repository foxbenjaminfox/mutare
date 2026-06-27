defmodule Mutare.Sandbox.Command.OutputTest do
  use ExUnit.Case, async: true

  alias Mutare.Sandbox.Command.Output

  describe "mix output vocabulary (the shared patterns live here)" do
    test "compile_error_banner/0 captures the offending file path" do
      banner = "== Compilation error in file test/foo_test.exs ==\n** (ArgumentError)"
      assert [_, "test/foo_test.exs"] = Regex.run(Output.compile_error_banner(), banner)
    end

    test "source_location_regex/0 matches any .ex/.exs file:line (Poison reads it)" do
      assert [_, "lib/foo.ex", "5"] =
               Regex.run(Output.source_location_regex(), "lib/foo.ex:5:12: error")

      assert [_, "test/foo_test.exs", "42"] =
               Regex.run(Output.source_location_regex(), "test/foo_test.exs:42")
    end

    test "test_location_regex/0 narrows to _test.exs files (Baseline reads it)" do
      assert [_, "test/foo_test.exs", "9"] =
               Regex.run(Output.test_location_regex(), "test/foo_test.exs:9")

      # A lib source or a non-test script is not a test location.
      refute Regex.run(Output.test_location_regex(), "lib/foo.ex:5")
      refute Regex.run(Output.test_location_regex(), "test/support/helper.exs:5")
    end

    test "a test location is also a source location (the narrowing is consistent)" do
      output = "test/foo_test.exs:42"
      assert Regex.run(Output.test_location_regex(), output)
      assert Regex.run(Output.source_location_regex(), output)
    end

    test "diagnostic_severity/1 classifies a line's marker (Poison reads it)" do
      assert Output.diagnostic_severity("    error: cannot use variable x as map key") == :error
      assert Output.diagnostic_severity("  warning: variable \"a\" is unused") == :warning

      assert Output.diagnostic_severity("** (CompileError) lib/foo.ex: cannot compile") ==
               :error

      # A non-marker line (a diagnostic's footer/body, or chatter) has no severity of
      # its own — it inherits the block's, which the caller threads.
      assert Output.diagnostic_severity("    └─ lib/foo.ex:5:12: Foo.bar/1") == nil
      assert Output.diagnostic_severity("Compiling 43 files (.ex)") == nil
    end

    test "output_tail/2 returns the last N lines" do
      output = Enum.map_join(1..50, "\n", &"line #{&1}")
      assert Output.output_tail(output, 3) == "line 48\nline 49\nline 50"
      # Fewer lines than asked for is returned verbatim.
      assert Output.output_tail("a\nb", 10) == "a\nb"
    end
  end

  describe "verdict-refinement discriminators (read by Command.outcome/2)" do
    @test_compile_error """
    == Compilation error in file test/plug/router_test.exs ==
    ** (ArgumentError) errors were found at the given arguments:
        (plug) lib/plug/router/utils.ex:338: Plug.Router.Utils.build_path_clause/3
        test/plug/router_test.exs:26: (module)
    """

    @atom_crash """
    no more index entries in atom_tab (max=1048576)

    Crash dump is being written to: erl_crash.dump...done
    """

    @boot_crash """
    Slogan: Runtime terminating during boot ({badarg,[{io,put_chars,[standard_error,
      [<<"** (EXIT from #PID<0.99.0>) an exception was raised:
            ** (ArgumentError) errors were found at the given arguments:
          * 1st argument: the device does not exist
                (stdlib) io.erl:98: :io.put_chars(:standard_error, [...])">>]]}]})
    """

    test "suite_compile_error?/1 matches only a .exs under a test/ dir" do
      assert Output.suite_compile_error?(@test_compile_error)
      # umbrella app test path
      assert Output.suite_compile_error?("== Compilation error in file apps/x/test/x_test.exs ==")

      # no banner, a lib .ex, or a non-test .exs script: not a suite compile error
      refute Output.suite_compile_error?("1) test foo (MyTest)\n   Assertion failed")
      refute Output.suite_compile_error?("== Compilation error in file lib/foo.ex ==")
      refute Output.suite_compile_error?("== Compilation error in file priv/seeds.exs ==")
    end

    test "atom_exhausted?/1 matches only the VM atom-table abort banner" do
      assert Output.atom_exhausted?(@atom_crash)
      # an ordinary test failure, a compile error, or other resource crash is not one
      refute Output.atom_exhausted?("1) test foo (MyTest)\n   Assertion failed")
      refute Output.atom_exhausted?(@test_compile_error)
      refute Output.atom_exhausted?("Cannot allocate 1234 bytes of memory")
    end

    test "boot_failure?/1 needs both markers (the boot abort and the torn-down device)" do
      assert Output.boot_failure?(@boot_crash)

      # Either marker alone is not the self-erasing signature: a boot crash that left a
      # recoverable error wouldn't have recursed on `standard_error`, and a stray
      # `standard_error` mention outside a boot abort isn't this at all.
      refute Output.boot_failure?("Runtime terminating during boot (some other reason)")
      refute Output.boot_failure?("** (RuntimeError) wrote to :standard_error somewhere")

      # An ordinary test failure / compile error / atom crash is not one.
      refute Output.boot_failure?("1) test foo (MyTest)\n   Assertion failed")
      refute Output.boot_failure?(@test_compile_error)
      refute Output.boot_failure?(@atom_crash)
    end
  end
end
