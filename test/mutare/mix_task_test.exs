defmodule Mix.Tasks.MutareTest do
  use ExUnit.Case, async: false

  alias Mutare.Test.Project

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

    test "--strict-ignores aborts (with a stderr warning) on an ineffective directive" do
      root = Project.tmp_dir(:task)
      File.mkdir_p!(Path.join(root, "lib"))
      # A real arithmetic mutant on line 2 (so the run has sites), but the
      # `[bogus]` filter matches no mutant there — the directive suppresses nothing.
      File.write!(
        Path.join(root, "lib/a.ex"),
        "defmodule A do\n  def f(x), do: x + 1 # mutare:ignore[bogus]\nend\n"
      )

      on_exit(fn -> File.rm_rf!(root) end)

      stderr =
        ExUnit.CaptureIO.capture_io(:stderr, fn ->
          assert_raise Mix.Error, ~r/strict-ignores/, fn ->
            Mix.Tasks.Mutare.run([root, "--strict-ignores"])
          end
        end)

      assert stderr =~ "mutare:ignore[bogus]"
      assert stderr =~ "suppressed no mutant"
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
      assert output =~ "Arithmetic operator swaps"
      assert output =~ "--mutators relational,arithmetic"
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

    test "--list-macros prints the known-macro registry, including the built-ins" do
      root = bare_project("defmodule A do\n  def f(x), do: x + 1\nend\n")

      Mix.Tasks.Mutare.run([root, "--list-macros"])
      output = drain_shell_info()

      assert output =~ "Known macros"
      assert output =~ "Kernel.match?/2"
      assert output =~ "Kernel.destructure/2"
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
  end

  # A throwaway project with a single `lib/a.ex`, cleaned up after the test.
  defp bare_project(source) do
    root = Project.tmp_dir(:task)
    File.mkdir_p!(Path.join(root, "lib"))
    File.write!(Path.join(root, "lib/a.ex"), source)
    on_exit(fn -> File.rm_rf!(root) end)
    root
  end

  # Drain every `Mix.shell().info/1` message captured by `Mix.Shell.Process`.
  defp drain_shell_info(acc \\ []) do
    receive do
      {:mix_shell, :info, [msg]} -> drain_shell_info([msg | acc])
    after
      0 -> acc |> Enum.reverse() |> Enum.join("\n")
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
    # fail. `--format json --output` adds a file reporter; both reporters run
    # *before* the gate, so the human report prints and the JSON is written even
    # on a fail.
    assert_raise Mix.Error, ~r/below the required minimum/, fn ->
      Mix.Tasks.Mutare.run([
        "examples/auth",
        "--min-score",
        "100",
        "--format",
        "json",
        "--output",
        out,
        "--sandbox",
        sandbox
      ])
    end

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
  end

  defp shell_info(acc \\ []) do
    receive do
      {:mix_shell, :info, [msg]} -> shell_info([msg | acc])
    after
      0 -> Enum.reverse(acc)
    end
  end
end
