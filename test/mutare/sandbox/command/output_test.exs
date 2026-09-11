defmodule Mutare.Sandbox.Command.OutputTest do
  use ExUnit.Case, async: true

  alias Mutare.Sandbox.Command.Output

  doctest Output

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

  describe "dependency_issue/1" do
    test "classifies Mix's requested dependency remedy" do
      assert Output.dependency_issue(
               unchecked("the dependency is not available, run \"mix deps.get\"")
             ) ==
               :fetch

      assert Output.dependency_issue(
               unchecked(
                 "the dependency build is outdated, please run \"MIX_ENV=test mix deps.compile\""
               )
             ) == :compile

      assert Output.dependency_issue(
               "Dependencies have diverged:\n* plug (Hex package)\n  different specs were given"
             ) == :diverged

      assert Output.dependency_issue(unchecked("the dependency is not available")) ==
               :unavailable

      assert Output.dependency_issue(
               unchecked("the dependency does not match the requirement ~> 2.0, got 1.0.0")
             ) == :invalid
    end

    test "does not classify unrelated compiler output from a stray command mention" do
      refute Output.dependency_issue("** (CompileError) try running mix deps.get in this macro")
      refute Output.dependency_issue("Compiling 3 files (.ex)\nGenerated example app")
    end
  end

  describe "salient_line/1 (read by Report.HarnessDiagnostic)" do
    test "skips blank lines and routine chatter, returning the first remaining line trimmed" do
      output = """
      Compiling 3 files (.ex)
      Generated example app
      Running ExUnit with seed: 1234, max_cases: 16
      Excluding tags: [:slow]

      ....
        something odd happened
      Finished in 0.1 seconds
      """

      assert Output.salient_line(output) == "something odd happened"
    end

    test "prefers a failure head over an earlier ordinary line" do
      for head <- [
            "** (Mix) Could not start application example: exited in: Example.start(:normal, [])",
            "error: undefined function foo/0",
            "Unchecked dependencies for environment test:",
            "Dependencies have diverged:",
            "Could not start application example: exited",
            "Runtime terminating during boot (some other reason)"
          ] do
        assert Output.salient_line("a stray notice\n" <> head) == head
      end
    end

    test "returns nil when nothing but chatter was captured" do
      assert Output.salient_line("") == nil
      assert Output.salient_line("Compiling 1 file (.ex)\n...\nFinished in 0.1 seconds\n") == nil
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

  defp unchecked(status) do
    "Unchecked dependencies for environment test:\n* example (Hex package)\n  #{status}\n" <>
      "** (Mix) Can't continue due to errors on dependencies"
  end

  describe "macro_expansion_stacks/1 (the expanding-macro frames — Poison and Hint read it)" do
    test "groups frames per exception header, innermost first, each with its own call site" do
      output = """
      == Compilation error in file lib/a.ex ==
      ** (FunctionClauseError) no function clause matching in A.one/1
          expanding macro: A.one/1
          lib/a.ex:3: AMod.f/0
          (elixir #{System.version()}) expanding macro: Kernel.if/2
          lib/a.ex:2: AMod.f/0
      == Compilation error in file lib/b.ex ==
      ** (ArgumentError) argument error
          expanding macro: B.two/2
          lib/b.ex:5: BMod.g/0
      """

      assert Output.macro_expansion_stacks(output) == [
               [
                 %{name: "A.one", arity: 1, call_site: {"lib/a.ex", 3}},
                 %{name: "Kernel.if", arity: 2, call_site: {"lib/a.ex", 2}}
               ],
               [%{name: "B.two", arity: 2, call_site: {"lib/b.ex", 5}}]
             ]
    end

    test "a location before a stack's first frame — the macro's own implementation — attaches to nothing" do
      output =
        "** (RuntimeError) boom\n" <>
          "    lib/my_dsl.ex:3: MyDsl.\"MACRO-query\"/2\n" <>
          "    expanding macro: MyDsl.query/1\n" <>
          "    lib/r.ex:2: R.f/2\n"

      assert Output.macro_expansion_stacks(output) ==
               [[%{name: "MyDsl.query", arity: 1, call_site: {"lib/r.ex", 2}}]]
    end

    test "a frame no location line follows has a nil call site" do
      assert Output.macro_expansion_stacks("expanding macro: Size.megabytes/1\n") ==
               [[%{name: "Size.megabytes", arity: 1, call_site: nil}]]
    end

    test "only the first location after a frame is its call site; later ones attach to nothing" do
      output = "expanding macro: X.y/0\n    lib/x.ex:1: X.z/0\n    lib/x.ex:9: X.w/0\n"

      assert Output.macro_expansion_stacks(output) ==
               [[%{name: "X.y", arity: 0, call_site: {"lib/x.ex", 1}}]]
    end

    test "lines before the first header form a stack; a frameless stack is dropped" do
      output =
        "expanding macro: X.y/0\nlib/x.ex:1: X.z/0\n** (CompileError) nope\n    lib/x.ex:9: X.w/0\n"

      assert Output.macro_expansion_stacks(output) ==
               [[%{name: "X.y", arity: 0, call_site: {"lib/x.ex", 1}}]]
    end

    test "any raised term heads a new stack, not only an `…Error` exception" do
      # `** (exit)` is no compiler *diagnostic* for `diagnostic_severity/1`, but it does start a
      # new stacktrace — so the frame after it is a new stack's innermost, not the previous
      # stack's enclosing macro.
      assert Output.diagnostic_severity("** (exit) boom") == nil

      output =
        "expanding macro: A.a/1\nlib/a.ex:1: A.f/0\n** (exit) boom\nexpanding macro: B.b/1\nlib/b.ex:1: B.f/0\n"

      assert [[%{name: "A.a"}], [%{name: "B.b"}]] = Output.macro_expansion_stacks(output)
    end

    test "intervening non-frame lines within a stack are skipped, not stack boundaries" do
      output = """
      ** (FunctionClauseError) no function clause matching in Size.megabytes/1
          (stacktrace) Elixir.Kernel.some_helper/1
          (stacktrace) Elixir.Kernel.another_helper/2
          expanding macro: Size.megabytes/1
          lib/usage.ex:4: Usage.limit/0
      """

      assert [[%{name: "Size.megabytes", call_site: {"lib/usage.ex", 4}}]] =
               Output.macro_expansion_stacks(output)
    end

    test "no frames at all yields []" do
      assert Output.macro_expansion_stacks("") == []
      assert Output.macro_expansion_stacks("** (CompileError) undefined function foo/0\n") == []
    end

    test "requires a binary" do
      assert_raise FunctionClauseError, fn -> Output.macro_expansion_stacks(nil) end
    end
  end
end
