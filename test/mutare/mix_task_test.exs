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

      assert_raise Mix.Error, ~r/no mutation sites/, fn ->
        Mix.Tasks.Mutare.run([root])
      end
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
      assert_raise Mix.Error, ~r/no mutation sites/, fn ->
        Mix.Tasks.Mutare.run([root, "--line", "lib/a.ex:1"])
      end
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
