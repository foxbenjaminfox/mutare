defmodule Mutare.SandboxTest do
  use ExUnit.Case, async: true

  alias Mutare.{Sandbox, Schema}

  setup do
    base =
      Path.join(System.tmp_dir!(), "mutare_sandbox_test_#{System.unique_integer([:positive])}")

    project = Path.join(base, "project")
    marker = Path.join(project, "keep.txt")

    File.mkdir_p!(project)
    File.write!(marker, "keep")

    on_exit(fn -> File.rm_rf!(base) end)

    %{base: base, marker: marker, project: project, schema: %Schema{}}
  end

  test "rejects the project root before deleting anything", context do
    assert_unsafe(context.project, context.project, context.schema, "is the project root")
    assert File.read!(context.marker) == "keep"
  end

  test "rejects a sandbox inside the project before deleting anything", context do
    sandbox = Path.join(context.project, "sandbox")
    sandbox_marker = Path.join(sandbox, "keep.txt")
    File.mkdir_p!(sandbox)
    File.write!(sandbox_marker, "keep")

    assert_unsafe(context.project, sandbox, context.schema, "is inside the project root")
    assert File.read!(sandbox_marker) == "keep"
  end

  test "rejects a sandbox that contains the project before deleting anything", context do
    assert_unsafe(context.project, context.base, context.schema, "contains the project root")
    assert File.read!(context.marker) == "keep"
  end

  test "resolves symlinked parents when checking for a nested sandbox", context do
    project_alias = Path.join(context.base, "project_alias")
    :ok = File.ln_s(context.project, project_alias)

    sandbox = Path.join(project_alias, "sandbox")

    assert_unsafe(context.project, sandbox, context.schema, "is inside the project root")
    assert File.read!(context.marker) == "keep"
  end

  test "checks where a final symlink will be replaced after deletion", context do
    outside = Path.join(context.base, "outside")
    sandbox = Path.join(context.project, "sandbox_link")
    File.mkdir_p!(outside)
    :ok = File.ln_s(outside, sandbox)

    assert_unsafe(context.project, sandbox, context.schema, "is inside the project root")
    assert File.read_link!(sandbox) == outside
  end

  test "allows a sibling sandbox", context do
    sandbox = Path.join(context.base, "sandbox")

    assert Sandbox.prepare(context.project, context.schema, sandbox: sandbox) == sandbox
    assert File.read!(Path.join(sandbox, "keep.txt")) == "keep"
  end

  @marker ".mutare_sandbox"

  test "creates the sandbox and leaves an ownership marker when it is absent", context do
    sandbox = Path.join(context.base, "sandbox")
    refute File.exists?(sandbox)

    assert Sandbox.prepare(context.project, context.schema, sandbox: sandbox) == sandbox
    assert File.read!(Path.join(sandbox, "keep.txt")) == "keep"
    assert File.regular?(Path.join(sandbox, @marker))
  end

  test "adopts an existing empty directory", context do
    sandbox = Path.join(context.base, "sandbox")
    File.mkdir_p!(sandbox)

    assert Sandbox.prepare(context.project, context.schema, sandbox: sandbox) == sandbox
    assert File.read!(Path.join(sandbox, "keep.txt")) == "keep"
    assert File.regular?(Path.join(sandbox, @marker))
  end

  test "reuses a marked sandbox, clearing its stale contents", context do
    sandbox = Path.join(context.base, "sandbox")

    # First run marks and populates it.
    assert Sandbox.prepare(context.project, context.schema, sandbox: sandbox) == sandbox
    stale = Path.join(sandbox, "stale.txt")
    File.write!(stale, "stale")

    # Second run on the same (now owned) path wipes the stale file and rebuilds.
    assert Sandbox.prepare(context.project, context.schema, sandbox: sandbox) == sandbox
    refute File.exists?(stale)
    assert File.read!(Path.join(sandbox, "keep.txt")) == "keep"
    assert File.regular?(Path.join(sandbox, @marker))
  end

  test "refuses a non-empty directory it does not own, untouched", context do
    sandbox = Path.join(context.base, "sandbox")
    bystander = Path.join(sandbox, "important.txt")
    File.mkdir_p!(sandbox)
    File.write!(bystander, "precious")

    assert_refused(context.project, sandbox, context.schema)
    assert File.read!(bystander) == "precious"
    refute File.exists?(Path.join(sandbox, @marker))
  end

  test "refuses a directory whose marker has foreign contents", context do
    sandbox = Path.join(context.base, "sandbox")
    File.mkdir_p!(sandbox)
    File.write!(Path.join(sandbox, @marker), "not really ours")
    File.write!(Path.join(sandbox, "important.txt"), "precious")

    assert_refused(context.project, sandbox, context.schema)
    assert File.read!(Path.join(sandbox, "important.txt")) == "precious"
  end

  test "refuses a regular file at the sandbox path, untouched", context do
    sandbox = Path.join(context.base, "sandbox")
    File.write!(sandbox, "i am a file")

    assert_refused(context.project, sandbox, context.schema)
    assert File.read!(sandbox) == "i am a file"
  end

  defp assert_refused(root, sandbox, schema) do
    error =
      assert_raise ArgumentError, fn ->
        Sandbox.prepare(root, schema, sandbox: sandbox)
      end

    assert Exception.message(error) =~ "refusing to use sandbox"
  end

  defp assert_unsafe(root, sandbox, schema, relation) do
    error =
      assert_raise ArgumentError, fn ->
        Sandbox.prepare(root, schema, sandbox: sandbox)
      end

    assert Exception.message(error) =~ "unsafe sandbox path"
    assert Exception.message(error) =~ relation
  end
end
