defmodule Mutare.ChangesTest do
  use ExUnit.Case, async: true

  alias Mutare.Changes

  setup do
    repo = Path.join(System.tmp_dir!(), "mutare_git_#{System.unique_integer([:positive])}")
    File.mkdir_p!(Path.join(repo, "lib"))
    on_exit(fn -> File.rm_rf!(repo) end)

    git!(repo, ["init", "-q"])
    git!(repo, ["config", "user.email", "test@example.com"])
    git!(repo, ["config", "user.name", "Test"])
    File.write!(Path.join(repo, "lib/a.ex"), "defmodule A do\n  def f, do: 1\nend\n")
    File.write!(Path.join(repo, "lib/b.ex"), "defmodule B do\n  def g, do: 2\nend\n")
    git!(repo, ["add", "."])
    git!(repo, ["commit", "-q", "-m", "init"])

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
