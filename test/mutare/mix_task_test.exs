defmodule Mix.Tasks.MutareTest do
  use ExUnit.Case, async: false

  alias Mutare.Report.Live
  alias Mutare.Test.{Project, Umbrella}

  setup do
    # Capture Mix.shell output as messages to this process.
    Mix.shell(Mix.Shell.Process)
    on_exit(fn -> Mix.shell(Mix.Shell.IO) end)
    :ok
  end

  describe "fast failure paths (no subprocess)" do
    test "raises when there are no mutation sites" do
      root = Project.tmp_dir(:task)
      File.mkdir_p!(Path.join(root, "lib"))
      # `do: nil` has no mutation sites (a `nil` tail is skipped by return-value);
      # `do: :ok` would now yield a `:ok → nil` return mutant.
      File.write!(Path.join(root, "lib/empty.ex"), "defmodule Empty do\n  def f, do: nil\nend\n")
      on_exit(fn -> File.rm_rf!(root) end)

      # Capture stderr so the live reporter's scan note doesn't leak into test
      # output; the assertion is about the error, not the progress.
      ExUnit.CaptureIO.capture_io(:stderr, fn ->
        assert_raise Mix.Error, ~r/no mutation sites/, fn ->
          Mix.Tasks.Mutare.run([root])
        end
      end)
    end

    test "a nonexistent --only path aborts with the target-relative hint" do
      # `--only phoenix/lib/…` typed from one level up is the classic cwd-relative
      # miss (paths resolve against the target project); the abort should say so.
      root = Project.tmp_dir(:task)
      File.mkdir_p!(Path.join(root, "lib"))
      File.write!(Path.join(root, "lib/a.ex"), "defmodule A do\n  def f(x), do: x + 1\nend\n")
      on_exit(fn -> File.rm_rf!(root) end)

      ExUnit.CaptureIO.capture_io(:stderr, fn ->
        assert_raise Mix.Error, ~r/resolved relative to the target project/, fn ->
          Mix.Tasks.Mutare.run([root, "--only", "lib/nonexistent.ex"])
        end
      end)
    end

    test "an existing path with no sites aborts WITHOUT the target-relative hint" do
      # The path is fine — the file just has nothing to mutate. Suggesting a path
      # resolution problem would mislead.
      root = Project.tmp_dir(:task)
      File.mkdir_p!(Path.join(root, "lib"))
      File.write!(Path.join(root, "lib/empty.ex"), "defmodule Empty do\n  def f, do: nil\nend\n")
      on_exit(fn -> File.rm_rf!(root) end)

      ExUnit.CaptureIO.capture_io(:stderr, fn ->
        error =
          assert_raise Mix.Error, ~r/no mutation sites/, fn ->
            Mix.Tasks.Mutare.run([root, "--only", "lib/empty.ex"])
          end

        refute error.message =~ "resolved relative"
      end)
    end

    test "raises a clean Mix error on a bad --mutators value" do
      assert_raise Mix.Error, fn ->
        Mix.Tasks.Mutare.run([".", "--mutators", "definitely-not-a-family"])
      end
    end

    test "raises a clean Mix error on a malformed --line value" do
      assert_raise Mix.Error, ~r/--line expects FILE:LINE/, fn ->
        Mix.Tasks.Mutare.run([".", "--line", "lib/foo.ex"])
      end
    end

    test "raises a clean Mix error on parser syntax errors" do
      assert_raise Mix.Error, ~r/--line : Missing argument of type string/, fn ->
        Mix.Tasks.Mutare.run(["--line"])
      end
    end

    test "--line scoping to a line with no mutants yields no sites" do
      root = Project.tmp_dir(:task)
      File.mkdir_p!(Path.join(root, "lib"))
      File.write!(Path.join(root, "lib/a.ex"), "defmodule A do\n  def f(x), do: x + 1\nend\n")
      on_exit(fn -> File.rm_rf!(root) end)

      # Line 1 (`defmodule A do`) has nothing to mutate, so the run scopes to zero
      # sites and fails fast (before compiling) rather than testing the whole file.
      # Capture stderr so the live reporter's scan note doesn't leak into test output.
      ExUnit.CaptureIO.capture_io(:stderr, fn ->
        assert_raise Mix.Error, ~r/no mutation sites/, fn ->
          Mix.Tasks.Mutare.run([root, "--line", "lib/a.ex:1"])
        end
      end)
    end

    test "--quiet suppresses the live stderr progress" do
      root = Project.tmp_dir(:task)
      File.mkdir_p!(Path.join(root, "lib"))
      File.write!(Path.join(root, "lib/empty.ex"), "defmodule Empty do\n  def f, do: nil\nend\n")
      on_exit(fn -> File.rm_rf!(root) end)

      # Without --quiet the live reporter notes the scan phase on stderr (plain mode
      # in the non-tty test env), before the run fails fast on no sites.
      noisy =
        ExUnit.CaptureIO.capture_io(:stderr, fn ->
          assert_raise Mix.Error, ~r/no mutation sites/, fn -> Mix.Tasks.Mutare.run([root]) end
        end)

      assert noisy =~ "scanning for mutants"

      # With --quiet, `Mutare.Report.Live` is never started, so stderr stays silent.
      quiet =
        ExUnit.CaptureIO.capture_io(:stderr, fn ->
          assert_raise Mix.Error, ~r/no mutation sites/, fn ->
            Mix.Tasks.Mutare.run([root, "--quiet"])
          end
        end)

      assert quiet == ""
    end

    test "finishes the live scan display when a custom mutator throws" do
      root = bare_project("defmodule A do\n  def f(x), do: x + 1\nend\n")
      write_config(root, "[mutators: [Mutare.Test.ThrowingScanMutator]]")
      before = linked_pids()

      ExUnit.CaptureIO.capture_io(:stderr, fn ->
        assert catch_throw(Mix.Tasks.Mutare.run([root])) == :mutare_scan_throw
      end)

      assert_new_live_finished(before)
    end

    test "finishes the live scan display when a custom mutator exits" do
      root = bare_project("defmodule A do\n  def f(x), do: x + 1\nend\n")
      write_config(root, "[mutators: [Mutare.Test.ExitingScanMutator]]")
      before = linked_pids()

      ExUnit.CaptureIO.capture_io(:stderr, fn ->
        assert catch_exit(Mix.Tasks.Mutare.run([root])) == :mutare_scan_exit
      end)

      assert_new_live_finished(before)
    end

    test "warns about ineffective filtered ignores with stable labels and location" do
      root = Project.tmp_dir(:task)
      File.mkdir_p!(Path.join(root, "lib"))

      File.write!(
        Path.join(root, "lib/a.ex"),
        "defmodule A do\n  def f, do: nil # mutare:ignore[relational, arithmetic]\nend\n"
      )

      on_exit(fn -> File.rm_rf!(root) end)

      stderr =
        ExUnit.CaptureIO.capture_io(:stderr, fn ->
          assert_raise Mix.Error, ~r/no mutation sites/, fn -> Mix.Tasks.Mutare.run([root]) end
        end)

      assert stderr =~
               "warning: # mutare:ignore[arithmetic, relational] at lib/a.ex:2 suppressed no mutant"
    end

    test "a directive misplaced on a pipe's first line warns with the right step's line" do
      root = Project.tmp_dir(:task)
      File.mkdir_p!(Path.join(root, "lib"))

      File.write!(Path.join(root, "lib/a.ex"), """
      defmodule A do
        def run(list) do
          # mutare:ignore[arithmetic]
          list
          |> Enum.map(fn x -> x + 1 end)
          |> Enum.sum()
        end
      end
      """)

      on_exit(fn -> File.rm_rf!(root) end)

      stderr =
        ExUnit.CaptureIO.capture_io(:stderr, fn ->
          # --strict-ignores aborts right after the scan warnings, keeping this cheap.
          assert_raise Mix.Error, ~r/--strict-ignores/, fn ->
            Mix.Tasks.Mutare.run([root, "--strict-ignores"])
          end
        end)

      # Located at the directive comment (line 3), naming the step that has the
      # mutants (line 5) — the "annotate the pipe from the top" miss, corrected.
      assert stderr =~
               "warning: # mutare:ignore[arithmetic] at lib/a.ex:3 suppressed no mutant"

      assert stderr =~ "on line 5 of the same multi-line expression"
      assert stderr =~ "place it directly above line 5"
    end

    test "--strict-ignores aborts (with a stderr warning) on an ineffective directive" do
      root = Project.tmp_dir(:task)
      File.mkdir_p!(Path.join(root, "lib"))

      File.write!(
        Path.join(root, "lib/a.ex"),
        "defmodule A do\n  def f(x), do: x + 1 # mutare:ignore[bogus]\nend\n"
      )

      on_exit(fn -> File.rm_rf!(root) end)

      test_pid = self()

      stderr =
        ExUnit.CaptureIO.capture_io(:stderr, fn ->
          error =
            assert_raise Mix.Error, fn ->
              Mix.Tasks.Mutare.run([root, "--strict-ignores"])
            end

          send(test_pid, {:strict_ignores_error, error})
        end)

      assert_receive {:strict_ignores_error, error}

      assert error.message ==
               "--strict-ignores: 1 `# mutare:ignore` directive suppressed no mutant (see the warnings above)"

      assert stderr =~ "warning: # mutare:ignore[bogus] at lib/a.ex:2 suppressed no mutant"
    end

    test "warns on an unrecognized `mutare:` comment; --strict-ignores counts both kinds" do
      root = Project.tmp_dir(:task)
      File.mkdir_p!(Path.join(root, "lib"))

      # Line 2: a colon-detached verb (an unrecognized `mutare:` comment, near-miss hint);
      # line 3: a real directive with a typo'd family (ineffective). Both must warn, and
      # --strict-ignores must count each kind in its abort message.
      File.write!(
        Path.join(root, "lib/a.ex"),
        "defmodule A do\n  def f(x), do: x + 1 # mutare: ignore\n" <>
          "  def g(x), do: x + 1 # mutare:ignore[bogus]\nend\n"
      )

      on_exit(fn -> File.rm_rf!(root) end)

      test_pid = self()

      stderr =
        ExUnit.CaptureIO.capture_io(:stderr, fn ->
          error =
            assert_raise Mix.Error, fn ->
              Mix.Tasks.Mutare.run([root, "--strict-ignores"])
            end

          send(test_pid, {:strict_unknown_error, error})
        end)

      assert_receive {:strict_unknown_error, error}

      assert error.message ==
               "--strict-ignores: 1 `# mutare:ignore` directive suppressed no mutant; " <>
                 "1 `# mutare:` comment named no recognized directive (see the warnings above)"

      assert stderr =~
               "warning: # mutare: ignore at lib/a.ex:2 is not a recognized directive; " <>
                 "did you mean # mutare:ignore?"

      assert stderr =~ "warning: # mutare:ignore[bogus] at lib/a.ex:3 suppressed no mutant"
    end

    test "announces the counted scope and configured caps before a no-site run aborts" do
      root = Project.tmp_dir(:task)
      File.mkdir_p!(Path.join(root, "lib"))
      File.write!(Path.join(root, "lib/empty.ex"), "defmodule Empty do\n  def f, do: nil\nend\n")
      on_exit(fn -> File.rm_rf!(root) end)

      ExUnit.CaptureIO.capture_io(:stderr, fn ->
        assert_raise Mix.Error, ~r/no mutation sites/, fn ->
          Mix.Tasks.Mutare.run([
            root,
            "--max-mutants",
            "7",
            "--max-survivors",
            "2"
          ])
        end
      end)

      output = drain_shell_info()

      assert output =~
               "mutare in #{root}: 0 mutants (--max-mutants 7) (stop after 2 survivors) across 0 file(s)"
    end
  end

  describe "--list-mutators" do
    test "prints every registered family, derived from the registry, and exits without running" do
      # No project resolution, no sandbox, no `no mutation sites` raise: the flag
      # short-circuits before any of that.
      Mix.Tasks.Mutare.run(["--list-mutators"])

      output = drain_shell_info()

      assert output =~ "Built-in mutator families"

      # Every family in the single source-of-truth registry is listed — so the
      # catalog can never drift from what actually runs.
      for family <- Mutare.Mutators.families() do
        assert output =~ to_string(family), "expected #{family} in the catalog"
      end

      # A summary line is rendered from a family's @moduledoc, and the usage hint
      # names the comma-separated form.
      assert output =~ "Mutates arithmetic operators"
      assert output =~ "--mutators relational,arithmetic"

      # An opted-in family lists its `# mutare:ignore[family:label]` qualifier labels;
      # a bare-only family (no variant vocabulary) shows no label line.
      assert output =~ "ignore labels: zero succ pred"
      assert output =~ "ignore labels: negate"
      assert output =~ ~r/relational\b.*\n\s+ignore labels: .*>=/
    end
  end

  describe "inspect-and-exit flags (no run)" do
    test "--version prints the version" do
      Mix.Tasks.Mutare.run(["--version"])
      assert drain_shell_info() =~ ~r/^mutare \d+\.\d+/
    end

    test "--explain prints a family's full moduledoc" do
      Mix.Tasks.Mutare.run(["--explain", "relational"])
      output = drain_shell_info()
      assert output =~ "Mutare.Mutators.Relational"
      assert output =~ "Relational/equality operator swaps"
    end

    test "--explain raises a clean Mix error on an unknown mutator" do
      assert_raise Mix.Error, ~r/unknown mutator/, fn ->
        Mix.Tasks.Mutare.run(["--explain", "definitely-not-a-family"])
      end
    end

    test "--explain resolves a dynamically-compiled mutator that has no beam on disk" do
      # A module compiled at runtime (`Code.compile_string/1` here; `:code.load_binary/3`
      # behaves the same) is loaded but leaves no `.beam` on the code path, so the resolver
      # must accept it via its already-interned atom rather than requiring a beam file.
      [{mod, _bin}] =
        Code.compile_string("""
        defmodule MutareDynamicExplainFixture do
          @moduledoc "Dynamically compiled mutator fixture."
          def name, do: :dynamic_explain_fixture
        end
        """)

      on_exit(fn ->
        :code.purge(mod)
        :code.delete(mod)
      end)

      # Must not raise "unknown mutator"; the resolved family + module are printed.
      Mix.Tasks.Mutare.run(["--explain", "MutareDynamicExplainFixture"])
      output = drain_shell_info()
      assert output =~ "dynamic_explain_fixture"
      assert output =~ "MutareDynamicExplainFixture"

      # The explicitly `Elixir.`-qualified form (the same one `--mutators` accepts) must
      # fold the prefix, not search for `Elixir.Elixir.MutareDynamicExplainFixture`.
      Mix.Tasks.Mutare.run(["--explain", "Elixir.MutareDynamicExplainFixture"])
      assert drain_shell_info() =~ "MutareDynamicExplainFixture"
    end

    test "--show-config prints the merged effective options" do
      root = bare_project("defmodule A do\n  def f(x), do: x + 1\nend\n")

      Mix.Tasks.Mutare.run([
        root,
        "--show-config",
        "--mutators",
        "relational,arithmetic",
        "--workers",
        "3"
      ])

      output = drain_shell_info()
      assert output =~ "Effective configuration"
      assert output =~ "relational, arithmetic"
      assert output =~ ~r/workers\s+3/
    end

    test "--show-config defaults to the current project when no target is supplied" do
      Mix.Tasks.Mutare.run(["--show-config"])
      output = drain_shell_info()

      assert output =~ ~r/target\s+\./
    end

    test "--show-config uses the first positional target" do
      first = bare_project("defmodule FirstTarget do\n  def f(x), do: x + 1\nend\n")
      second = bare_project("defmodule SecondTarget do\n  def f(x), do: x + 2\nend\n")

      Mix.Tasks.Mutare.run([first, second, "--show-config"])
      output = drain_shell_info()

      assert output =~ ~r/target\s+#{Regex.escape(first)}/
      refute output =~ ~r/target\s+#{Regex.escape(second)}/
    end

    test "--since intersects an explicit --line filter" do
      root =
        bare_project("""
        defmodule A do
          def f(x), do: x + 1
          def g(x), do: x + 2
        end
        """)

      git!(root, ["init", "-q"])
      git!(root, ["add", "."])

      git!(root, [
        "-c",
        "user.email=test@example.com",
        "-c",
        "user.name=Test",
        "commit",
        "-q",
        "-m",
        "init"
      ])

      File.write!(
        Path.join(root, "lib/a.ex"),
        """
        defmodule A do
          def f(x), do: x + 9
          def g(x), do: x + 2
        end
        """
      )

      Mix.Tasks.Mutare.run([
        root,
        "--show-config",
        "--since",
        "HEAD",
        "--line",
        "lib/a.ex:3"
      ])

      output = drain_shell_info()

      assert output =~ ~r/only_lines\s+MapSet\.new\(\[\]\)/
      refute output =~ ~s({"lib/a.ex", 2})
    end

    test "--show-config scopes umbrella apps from comma-separated --app values" do
      %{umbrella: umbrella} =
        Umbrella.build(:task_scope_umbrella, %{
          core: %{files: %{"lib/core.ex" => "defmodule Core do\n  def f, do: :ok\nend\n"}},
          solo: %{files: %{"lib/solo.ex" => "defmodule Solo do\n  def f, do: :ok\nend\n"}},
          web: %{files: %{"lib/web.ex" => "defmodule Web do\n  def f, do: :ok\nend\n"}}
        })

      Mix.Tasks.Mutare.run([umbrella, "--show-config", "--app", "core, web"])
      output = drain_shell_info()

      assert output =~ ~r/target\s+#{Regex.escape(umbrella)} \(umbrella apps: core, web\)/
      refute output =~ "solo"
    end

    test "--show-config lets --workspace override a narrower --app scope" do
      %{umbrella: umbrella} =
        Umbrella.build(:task_workspace_umbrella, %{
          core: %{files: %{"lib/core.ex" => "defmodule Core do\n  def f, do: :ok\nend\n"}},
          solo: %{files: %{"lib/solo.ex" => "defmodule Solo do\n  def f, do: :ok\nend\n"}},
          web: %{files: %{"lib/web.ex" => "defmodule Web do\n  def f, do: :ok\nend\n"}}
        })

      Mix.Tasks.Mutare.run([umbrella, "--show-config", "--app", "core", "--workspace"])
      output = drain_shell_info()

      assert output =~
               ~r/target\s+#{Regex.escape(umbrella)} \(umbrella apps: core, solo, web\)/
    end

    test "--list-macros prints the known-macro registry, including the built-ins" do
      root = bare_project("defmodule A do\n  def f(x), do: x + 1\nend\n")

      Mix.Tasks.Mutare.run([root, "--list-macros"])
      output = drain_shell_info()

      assert output =~ "Known macros"
      assert output =~ "Kernel.match?/2"
      assert output =~ "Kernel.destructure/2"
    end

    test "--list-macros includes extension-contributed macros (build/3, not build/2)" do
      root = bare_project("defmodule A do\n  def f(x), do: x + 1\nend\n")
      write_config(root, "[extensions: [Mutare.Test.GettextLikeExtension]]")

      Mix.Tasks.Mutare.run([root, "--list-macros"])
      output = drain_shell_info()

      # The extension's `macro_routes/0` registrations must appear in the effective registry —
      # omitting `options.extensions` (the old `build/2` call) would hide them.
      assert output =~ "Mutare.Test.GettextLikeMacros.translate/1"
      assert output =~ "Mutare.Test.GettextLikeMacros.ntranslate/3"
    end

    test "--show-config prints the configured extensions" do
      root = bare_project("defmodule A do\n  def f(x), do: x + 1\nend\n")
      write_config(root, "[extensions: [Mutare.Test.GettextLikeExtension]]")

      Mix.Tasks.Mutare.run([root, "--show-config"])
      output = drain_shell_info()

      assert output =~ ~r/extensions\s+Mutare.Test.GettextLikeExtension/
    end

    test "--show-config reports no extensions when none are configured" do
      root = bare_project("defmodule A do\n  def f(x), do: x + 1\nend\n")

      Mix.Tasks.Mutare.run([root, "--show-config"])
      output = drain_shell_info()

      assert output =~ ~r/extensions\s+\(none\)/
    end

    test "--dry-run lists the mutants per file without running them" do
      root = bare_project("defmodule A do\n  def f(x), do: x >= 1\nend\n")

      Mix.Tasks.Mutare.run([root, "--dry-run", "--mutators", "relational"])
      output = drain_shell_info()

      assert output =~ ~r/\d+ mutants? across .* files?/
      assert output =~ "lib/a.ex"
      assert output =~ "→"
      assert output =~ "nothing compiled or executed"
    end

    test "--list-ignores flags active and ineffective directives" do
      root =
        bare_project("""
        defmodule A do
          def f(x), do: x + 1 # mutare:ignore[arithmetic]
          def g(x), do: x - 1 # mutare:ignore[bogus]
        end
        """)

      Mix.Tasks.Mutare.run([root, "--list-ignores"])
      output = drain_shell_info()

      assert output =~ "active"
      assert output =~ "ineffective"
      assert output =~ "[arithmetic]"
      assert output =~ "[bogus]"
    end

    test "--list-ignores names a scoped directive's reach" do
      root =
        bare_project("""
        # mutare:ignore-file[bogus] nothing here is bogus-family, so ineffective
        defmodule A do
          # mutare:ignore-start table
          def f(x), do: x + 1
          # mutare:ignore-end
        end
        """)

      Mix.Tasks.Mutare.run([root, "--list-ignores"])
      output = drain_shell_info()

      assert output =~ "whole file, [bogus]"
      assert output =~ "lines 3-5, all families — table"
      assert output =~ "active"
      assert output =~ "ineffective"
    end

    test "--list-ignores renders a broken region pairing as a clean Mix abort" do
      root =
        bare_project("""
        defmodule A do
          # mutare:ignore-start
          def f(x), do: x + 1
        end
        """)

      err = assert_raise Mix.Error, fn -> Mix.Tasks.Mutare.run([root, "--list-ignores"]) end
      assert err.message =~ "# mutare:ignore-start is never closed"
    end

    test "--list-ignores renders a bad qualifier as a clean Mix abort, not a raw stacktrace" do
      # `--list-ignores`/`--dry-run` build a schema *outside* the mutation-run try/rescue, so the
      # qualifier `SpecError` must be caught at the dispatch level and surfaced as a clean Mix abort.
      root =
        bare_project("""
        defmodule A do
          def f(x), do: x + 1 # mutare:ignore[arithmetic:bogus]
        end
        """)

      err = assert_raise Mix.Error, fn -> Mix.Tasks.Mutare.run([root, "--list-ignores"]) end
      assert err.message =~ ~s("bogus" is not a arithmetic variant)
    end
  end

  # A throwaway project with a single `lib/a.ex`, cleaned up after the test.
  defp bare_project(source) do
    root = Project.tmp_dir(:task)
    File.mkdir_p!(Path.join(root, "lib"))
    File.write!(Path.join(root, "lib/a.ex"), source)
    on_exit(fn -> File.rm_rf!(root) end)
    root
  end

  # Write a `.mutare.exs` (a keyword-list literal) into a bare project's root.
  defp write_config(root, contents) do
    File.write!(Path.join(root, ".mutare.exs"), contents)
  end

  defp git!(root, args) do
    {_out, 0} = System.cmd("git", ["-C", root | args], stderr_to_stdout: true)
  end

  defp linked_pids do
    {:links, links} = Process.info(self(), :links)
    links |> Enum.filter(&is_pid/1) |> MapSet.new()
  end

  defp assert_new_live_finished(before) do
    assert {pid, %Live{finished: true, phase: :idle}} = new_live_state(before)

    Process.unlink(pid)
    Process.exit(pid, :kill)
  end

  defp new_live_state(before) do
    linked_pids()
    |> MapSet.difference(before)
    |> Enum.find_value(&live_state/1)
  end

  defp live_state(pid) do
    case :sys.get_state(pid, 100) do
      %Live{} = state -> {pid, state}
      _other -> nil
    end
  catch
    :exit, _reason -> nil
  end

  # Drain every `Mix.shell().info/1` message captured by `Mix.Shell.Process`.
  defp drain_shell_info(acc \\ []) do
    receive do
      {:mix_shell, :info, [msg]} -> drain_shell_info([msg | acc])
    after
      0 -> acc |> Enum.reverse() |> Enum.join("\n")
    end
  end

  describe "--check (compile-only preflight)" do
    @tag :runner
    @tag timeout: 180_000
    test "a clean project reports a first-attempt compile and runs no tests" do
      %{project: project, sandbox: sandbox} =
        Project.build(:checkclean, %{
          "lib/c.ex" => """
          defmodule C do
            def add(a, b), do: a + b
          end
          """
        })

      ExUnit.CaptureIO.capture_io(:stderr, fn ->
        assert Mix.Tasks.Mutare.run([project, "--check", "--sandbox", sandbox]) == :ok
      end)

      out = shell_info() |> Enum.join("\n")
      assert out =~ "metamutant compiled"
      assert out =~ "no tests run"
      assert out =~ "compiled on the first attempt"
      # No baseline / per-mutant phase ran.
      refute out =~ "baseline"
      refute out =~ "SURVIVED"
    end

    @tag :runner
    @tag timeout: 180_000
    test "an escalating DSL prints the copy-pasteable macro_routes fix" do
      # Same hostile block macro as PoisonTest: `guarded :guard do …` splices its body
      # into a `when` guard, so the injected selector `case` poisons and the whole block
      # is escalated (skipped wholesale). --check must name it and suggest the route.
      %{project: project, sandbox: sandbox} =
        Project.build(:checkdsl, %{
          "lib/guard_dsl.ex" => """
          defmodule GuardDSL do
            defmacro guarded(:guard, do: body) do
              quote do
                def g(x) when unquote(unwrap(body)), do: x
              end
            end

            defp unwrap({:__block__, _meta, [single]}), do: single
            defp unwrap(other), do: other
          end
          """,
          "lib/uses.ex" => """
          defmodule Uses do
            import GuardDSL

            guarded :guard do
              1 < 2
            end
          end
          """
        })

      mutators = "relational,integer,arithmetic"

      ExUnit.CaptureIO.capture_io(:stderr, fn ->
        assert Mix.Tasks.Mutare.run([
                 project,
                 "--check",
                 "--mutators",
                 mutators,
                 "--sandbox",
                 sandbox
               ]) == :ok
      end)

      out = shell_info() |> Enum.join("\n")
      assert out =~ "poison-recovery rebuild"
      assert out =~ "skipped wholesale"
      assert out =~ "guarded"
      assert out =~ "{:*, :guarded, :skip}"
    end

    @tag :runner
    @tag timeout: 180_000
    test "warns about module-level `use`s that could not be expanded" do
      # `use(MyDSL, @opts)` and `use\tMyDSL, @opts` both compile fine in the sandbox (the
      # attribute resolves at compile time), but at scan time `@opts` is not a compile-time
      # literal, so Mutare can't expand the `use` — a :skip route keyed on what MyDSL injects
      # would be dead. --check must name them. (This is the compilable degradation; a genuinely
      # unloadable module would fail the sandbox compile itself, aborting before the report.)
      %{project: project, sandbox: sandbox} =
        Project.build(:checkuse, %{
          "lib/my_dsl.ex" => """
          defmodule MyDSL do
            defmacro __using__(_opts) do
              quote do
                import MyDSL
              end
            end

            defmacro thing(x), do: x
          end
          """,
          "lib/c.ex" => """
          defmodule C do
            @opts :controller
            use(MyDSL, @opts)
            def add(a, b), do: a + b
          end
          """,
          "lib/d.ex" => """
          defmodule D do
            @opts :controller
            use\tMyDSL, @opts
            def sub(a, b), do: a - b
          end
          """
        })

      ExUnit.CaptureIO.capture_io(:stderr, fn ->
        assert Mix.Tasks.Mutare.run([project, "--check", "--sandbox", sandbox]) == :ok
      end)

      out = shell_info() |> Enum.join("\n")
      assert out =~ "2 module-level `use` statements"
      assert out =~ "lib/c.ex:3"
      assert out =~ "lib/d.ex:3"
      assert out =~ "could not be expanded"
      assert out =~ "use MyDSL"
      assert out =~ "not a compile-time literal"
    end
  end

  @tag :runner
  @tag timeout: 180_000
  test "end to end against an example: prints survivors, writes a JSON report, and gates on --min-score" do
    sandbox = Project.tmp_dir(:task)
    out = Path.join(System.tmp_dir!(), "mutare_report_#{System.unique_integer([:positive])}.json")
    on_exit(fn -> File.rm_rf!(sandbox) end)
    on_exit(fn -> File.rm(out) end)

    # The example has surviving mutants (well under 100%), so a 100% floor must
    # fail. `--report json:PATH` adds a file reporter; both reporters run
    # *before* the gate, so the human report prints and the JSON is written even
    # on a fail.
    ExUnit.CaptureIO.capture_io(:stderr, fn ->
      assert_raise Mix.Error, ~r/below the required minimum/, fn ->
        Mix.Tasks.Mutare.run([
          "examples/auth",
          "--min-score",
          "100",
          "--report",
          "json:" <> out,
          "--sandbox",
          sandbox
        ])
      end
    end)

    # The human report is printed before the gate fires.
    messages = shell_info()
    assert Enum.any?(messages, &(&1 =~ ~r/\d+ mutants across/))
    assert Enum.any?(messages, &(&1 =~ "SURVIVED"))
    assert Enum.any?(messages, &(&1 =~ "mutation score:"))
    assert Enum.any?(messages, &(&1 =~ "wrote json report to #{out}"))

    # …and the machine report was written and is a valid report-schema document.
    doc = out |> File.read!() |> JSON.decode!()
    assert doc["schemaVersion"] == "1.0"
    assert map_size(doc["files"]) > 0

    mutants = all_report_mutants(doc)

    assert Enum.any?(
             mutants,
             &(&1["status"] == "Killed" and &1["replacement"] not in [nil, ""])
           )
  end

  defp shell_info(acc \\ []) do
    receive do
      {:mix_shell, :info, [msg]} -> shell_info([msg | acc])
    after
      0 -> Enum.reverse(acc)
    end
  end

  defp all_report_mutants(doc) do
    doc["files"]
    |> Map.values()
    |> Enum.flat_map(& &1["mutants"])
  end
end
