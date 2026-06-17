defmodule Mutare.ChangesTest do
  use ExUnit.Case, async: true

  alias Mutare.Changes

  # Build one committed repo once, then give each test a filesystem copy
  # (`cp_r`, no subprocess). Spawning `git init`/`config`/`add`/`commit` per test
  # dominated this module's runtime; `Changes.since` only needs a ready repo, and
  # a copied `.git` is a fully working one. Identity is set with `-c` flags on the
  # commit so no separate `git config` spawns are needed.
  setup_all do
    template =
      Path.join(System.tmp_dir!(), "mutare_git_template_#{System.unique_integer([:positive])}")

    File.mkdir_p!(Path.join(template, "lib"))
    on_exit(fn -> File.rm_rf!(template) end)

    git!(template, ["init", "-q"])
    File.write!(Path.join(template, "lib/a.ex"), "defmodule A do\n  def f, do: 1\nend\n")
    File.write!(Path.join(template, "lib/b.ex"), "defmodule B do\n  def g, do: 2\nend\n")
    git!(template, ["add", "."])

    git!(template, [
      "-c",
      "user.email=test@example.com",
      "-c",
      "user.name=Test",
      "commit",
      "-q",
      "-m",
      "init"
    ])

    %{template: template}
  end

  setup %{template: template} do
    repo = Path.join(System.tmp_dir!(), "mutare_git_#{System.unique_integer([:positive])}")
    File.cp_r!(template, repo)
    on_exit(fn -> File.rm_rf!(repo) end)

    %{repo: repo}
  end

  test "returns files changed (including uncommitted) versus a ref, relative to root", %{
    repo: repo
  } do
    File.write!(Path.join(repo, "lib/b.ex"), "defmodule B do\n  def g, do: 3\nend\n")

    assert Changes.since(repo, "HEAD") == {:ok, MapSet.new(["lib/b.ex"])}
  end

  test "is empty when nothing changed", %{repo: repo} do
    assert Changes.since(repo, "HEAD") == {:ok, MapSet.new()}
  end

  test "errors on a bad ref", %{repo: repo} do
    assert {:error, detail} = Changes.since(repo, "no-such-ref")
    assert is_binary(detail)
  end

  test "errors outside a git repository" do
    dir = Path.join(System.tmp_dir!(), "mutare_nogit_#{System.unique_integer([:positive])}")
    File.mkdir_p!(dir)
    on_exit(fn -> File.rm_rf!(dir) end)

    assert {:error, _} = Changes.since(dir, "HEAD")
  end

  defp git!(repo, args) do
    {_out, 0} = System.cmd("git", ["-C", repo | args], stderr_to_stdout: true)
  end
end
