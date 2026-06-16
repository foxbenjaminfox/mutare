defmodule Mutare.SandboxTest do
  use ExUnit.Case, async: true

  alias Mutare.{Project, Sandbox, Schema}
  alias Mutare.Test.Umbrella

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

  test "injects the bootstrap into every umbrella app's helper, not a root one" do
    %{umbrella: umbrella, sandbox: sandbox} =
      Umbrella.build(:bootstrap_demo, %{
        core: %{files: %{"lib/core.ex" => "defmodule Core do\n  def f, do: 1\nend\n"}},
        web: %{deps: [:core], files: %{"lib/web.ex" => "defmodule Web do\n  def g, do: 2\nend\n"}}
      })

    project = Project.resolve(umbrella)
    schema = Schema.build(umbrella, project: project)

    assert Sandbox.prepare(umbrella, schema, sandbox: sandbox, project: project) == sandbox

    for app <- ["core", "web"] do
      helper = File.read!(Path.join(sandbox, "apps/#{app}/test/test_helper.exs"))
      assert helper =~ "injected by Mutare: select the active mutant"
      assert helper =~ "injected by Mutare: coverage setup"
      # The app's own helper content is preserved.
      assert helper =~ "ExUnit.start()"
    end

    # An umbrella has no root suite, so no root helper should be created.
    refute File.exists?(Path.join(sandbox, "test/test_helper.exs"))
  end

  @selector_comment "select the active mutant from the environment"

  describe "keep_sandbox: true" do
    test "preserves a previous build between runs, but a fresh run wipes it", context do
      sandbox = Path.join(context.base, "sandbox")

      assert Sandbox.prepare(context.project, context.schema,
               sandbox: sandbox,
               keep_sandbox: true
             ) ==
               sandbox

      # Seed a compiled artifact the way `mix compile` would, under an excluded dir.
      cached = Path.join(sandbox, "_build/test/keep")
      File.mkdir_p!(Path.dirname(cached))
      File.write!(cached, "cached")

      # A second kept run reuses the directory in place — the build survives.
      Sandbox.prepare(context.project, context.schema, sandbox: sandbox, keep_sandbox: true)
      assert File.read!(cached) == "cached"

      # A fresh (default) run on the same owned path wipes everything.
      Sandbox.prepare(context.project, context.schema, sandbox: sandbox)
      refute File.exists?(cached)
    end

    test "leaves unchanged files untouched but rewrites changed ones", context do
      sandbox = Path.join(context.base, "sandbox")
      Sandbox.prepare(context.project, context.schema, sandbox: sandbox, keep_sandbox: true)

      kept = Path.join(sandbox, "keep.txt")
      past = 1_700_000_000
      File.touch!(kept, past)

      # Re-materialising with identical content must not rewrite the file (so its
      # mtime is unchanged and mix would skip recompiling it).
      Sandbox.prepare(context.project, context.schema, sandbox: sandbox, keep_sandbox: true)
      assert File.stat!(kept, time: :posix).mtime == past

      # Changing the source content does rewrite it.
      File.write!(context.marker, "changed")
      Sandbox.prepare(context.project, context.schema, sandbox: sandbox, keep_sandbox: true)
      assert File.read!(kept) == "changed"
      assert File.stat!(kept, time: :posix).mtime != past
    end

    test "prunes files removed from the source since the last run", context do
      sandbox = Path.join(context.base, "sandbox")
      gone = Path.join(context.project, "gone.txt")
      File.write!(gone, "x")

      Sandbox.prepare(context.project, context.schema, sandbox: sandbox, keep_sandbox: true)
      assert File.exists?(Path.join(sandbox, "gone.txt"))

      File.rm!(gone)
      Sandbox.prepare(context.project, context.schema, sandbox: sandbox, keep_sandbox: true)
      refute File.exists?(Path.join(sandbox, "gone.txt"))
    end

    test "injects the bootstrap exactly once across repeated runs", context do
      sandbox = Path.join(context.base, "sandbox")
      Sandbox.prepare(context.project, context.schema, sandbox: sandbox, keep_sandbox: true)
      Sandbox.prepare(context.project, context.schema, sandbox: sandbox, keep_sandbox: true)

      helper = File.read!(Path.join(sandbox, "test/test_helper.exs"))
      occurrences = helper |> String.split(@selector_comment) |> length()
      assert occurrences == 2, "expected one bootstrap block, got #{occurrences - 1}"
    end

    test "reuses the coverage helper at a stable path (no accumulation)", context do
      sandbox = Path.join(context.base, "sandbox")
      Sandbox.prepare(context.project, context.schema, sandbox: sandbox, keep_sandbox: true)
      Sandbox.prepare(context.project, context.schema, sandbox: sandbox, keep_sandbox: true)

      assert File.regular?(Path.join(sandbox, "lib/__mutare__/coverage_helper.ex"))
      refute File.exists?(Path.join(sandbox, "lib/__mutare__/coverage_helper_1.ex"))
    end

    test "with no :sandbox, derives a stable per-project temp dir", context do
      first = Sandbox.prepare(context.project, context.schema, keep_sandbox: true)
      on_exit(fn -> File.rm_rf!(first) end)
      second = Sandbox.prepare(context.project, context.schema, keep_sandbox: true)

      assert first == second
      assert String.starts_with?(first, System.tmp_dir!())
    end

    test "materializes umbrella helpers and support app without accumulating" do
      %{umbrella: umbrella, sandbox: sandbox} =
        Umbrella.build(:kept_bootstrap_demo, %{
          core: %{files: %{"lib/core.ex" => "defmodule Core do\n  def f, do: 1\nend\n"}},
          web: %{files: %{"lib/web.ex" => "defmodule Web do\n  def g, do: 2\nend\n"}}
        })

      project = Project.resolve(umbrella)
      schema = Schema.build(umbrella, project: project)

      assert Sandbox.prepare(umbrella, schema,
               sandbox: sandbox,
               project: project,
               keep_sandbox: true
             ) == sandbox

      assert Sandbox.prepare(umbrella, schema,
               sandbox: sandbox,
               project: project,
               keep_sandbox: true
             ) == sandbox

      for app <- ["core", "web"] do
        helper = File.read!(Path.join(sandbox, "apps/#{app}/test/test_helper.exs"))
        assert helper =~ "injected by Mutare: select the active mutant"
        assert helper =~ "injected by Mutare: coverage setup"
        assert helper =~ "ExUnit.start()"
      end

      refute File.exists?(Path.join(sandbox, "test/test_helper.exs"))
      assert File.regular?(Path.join(sandbox, "apps/mutare_support/mix.exs"))
      assert File.regular?(Path.join(sandbox, "apps/mutare_support/lib/mutare_cov.ex"))
      refute File.exists?(Path.join(sandbox, "apps/mutare_support_1"))
    end
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
