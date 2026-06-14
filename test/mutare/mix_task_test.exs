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
      File.write!(Path.join(root, "lib/empty.ex"), "defmodule Empty do\n  def f, do: :ok\nend\n")
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
  end

  @tag :runner
  @tag timeout: 180_000
  test "end to end against the toy: prints survivors and score, and gates on --min-score" do
    sandbox = Project.tmp_dir(:task)
    on_exit(fn -> File.rm_rf!(sandbox) end)

    # The toy scores 62.5%, so a 100% floor must fail the build.
    assert_raise Mix.Error, ~r/below the required minimum/, fn ->
      Mix.Tasks.Mutare.run(["examples/toy", "--min-score", "100", "--sandbox", sandbox])
    end

    # The report is printed before the gate fires.
    messages = shell_info()
    assert Enum.any?(messages, &(&1 =~ ~r/\d+ mutants across/))
    assert Enum.any?(messages, &(&1 =~ "SURVIVED"))
    assert Enum.any?(messages, &(&1 =~ "mutation score:"))
  end

  defp shell_info(acc \\ []) do
    receive do
      {:mix_shell, :info, [msg]} -> shell_info([msg | acc])
    after
      0 -> Enum.reverse(acc)
    end
  end
end
