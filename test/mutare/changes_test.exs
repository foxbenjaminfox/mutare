defmodule Mutare.ChangesTest do
  use ExUnit.Case, async: true

  alias Mutare.Changes

  # Build one committed repo once, then give each test a filesystem copy
  # (`cp_r`, no subprocess). Spawning `git init`/`config`/`add`/`commit` per test
  # dominated this module's runtime; `Changes.since` only needs a ready repo, and
  # a copied `.git` is a fully working one. Identity is set with `-c` flags on the
  # commit so no separate `git config` spawns are needed.
  setup_all do
    template = fresh_tmp("mutare_git_template")

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
    repo = fresh_tmp("mutare_git")
    File.cp_r!(template, repo)
    on_exit(fn -> File.rm_rf!(repo) end)

    %{repo: repo}
  end

  test "returns changed lines (including uncommitted) as {file, line} pairs, relative to root", %{
    repo: repo
  } do
    # Only line 2 (`def g, do: 3`) changed — line 1 and 3 are untouched.
    File.write!(Path.join(repo, "lib/b.ex"), "defmodule B do\n  def g, do: 3\nend\n")

    assert Changes.since(repo, "HEAD") == {:ok, MapSet.new([{"lib/b.ex", 2}])}
  end

  test "parses changed lines despite user diff presentation config", %{repo: repo} do
    git!(repo, ["config", "color.ui", "always"])
    git!(repo, ["config", "diff.mnemonicPrefix", "true"])
    git!(repo, ["config", "diff.srcPrefix", "old/"])
    git!(repo, ["config", "diff.dstPrefix", "new/"])

    File.write!(Path.join(repo, "lib/b.ex"), "defmodule B do\n  def g, do: 3\nend\n")

    assert Changes.since(repo, "HEAD") == {:ok, MapSet.new([{"lib/b.ex", 2}])}
  end

  test "reports every added line of a range, on both changed and new files", %{repo: repo} do
    # A two-line insertion into an existing file...
    File.write!(
      Path.join(repo, "lib/a.ex"),
      "defmodule A do\n  def f, do: 1\n  def g, do: 2\n  def h, do: 3\nend\n"
    )

    # ...and a whole new file (every line is an addition). It must be staged:
    # `git diff` ignores untracked files, exactly as the old `--name-only` did.
    File.write!(Path.join(repo, "lib/c.ex"), "defmodule C do\n  def z, do: 0\nend\n")
    git!(repo, ["add", "lib/c.ex"])

    assert Changes.since(repo, "HEAD") ==
             {:ok,
              MapSet.new([
                {"lib/a.ex", 3},
                {"lib/a.ex", 4},
                {"lib/c.ex", 1},
                {"lib/c.ex", 2},
                {"lib/c.ex", 3}
              ])}
  end

  test "a pure deletion contributes no lines (the file drops out of scope)", %{repo: repo} do
    # Delete line 2 of a.ex, leaving only additions elsewhere absent — the diff
    # is a pure deletion, so there is no new-side line to mutate.
    File.write!(Path.join(repo, "lib/a.ex"), "defmodule A do\nend\n")

    assert Changes.since(repo, "HEAD") == {:ok, MapSet.new()}
  end

  test "is empty when nothing changed", %{repo: repo} do
    assert Changes.since(repo, "HEAD") == {:ok, MapSet.new()}
  end

  test "errors on a bad ref", %{repo: repo} do
    assert {:error, detail} = Changes.since(repo, "no-such-ref")
    assert is_binary(detail)
    # The detail is trimmed: git's stderr carries a trailing newline, so a
    # non-trimmed detail would not equal its own trimmed form.
    assert detail == String.trim(detail)
    assert detail != ""
  end

  test "errors outside a git repository" do
    dir = fresh_tmp("mutare_nogit")
    File.mkdir_p!(dir)
    on_exit(fn -> File.rm_rf!(dir) end)

    assert {:error, _} = Changes.since(dir, "HEAD")
  end

  test "rescues a raised failure into an error tuple rather than crashing", %{repo: repo} do
    # The rescue clause turns any failure to even invoke git into a clean
    # `{:error, message}`. A non-binary ref makes `System.cmd/3` raise (its args
    # must all be binaries) — a deterministic, process-local way to drive the
    # rescue without mutating the global PATH (which would race the async suite).
    bad_ref = :not_a_binary

    assert {:error, message} = Changes.since(repo, bad_ref)
    assert is_binary(message)
    assert message != ""
  end

  defp git!(repo, args) do
    {_out, 0} = System.cmd("git", ["-C", repo | args], stderr_to_stdout: true)
  end

  # A tmp path that can't collide with another live process or a prior run.
  # `unique_integer` is unique only within *one* BEAM, but self-hosting runs this
  # module in many parallel `mix test` processes that share `/tmp` — and a mutant
  # that times out is `System.halt`ed, skipping `on_exit`, so its dir lingers. The
  # OS pid disambiguates concurrent processes and won't be reused while this one is
  # alive, so the name is unique by construction. We do *not* `rm_rf!` it first
  # (that could silently clobber unrelated state and mask a real collision); the
  # path must not already exist — if it does, fail loudly. The caller's `on_exit`
  # owns cleanup.
  defp fresh_tmp(prefix) do
    name = "#{prefix}_#{System.pid()}_#{System.unique_integer([:positive])}"
    path = Path.join(System.tmp_dir!(), name)

    if File.exists?(path) do
      raise "expected a fresh tmp path but #{path} already exists (stale leftover or pid reuse)"
    end

    path
  end
end
