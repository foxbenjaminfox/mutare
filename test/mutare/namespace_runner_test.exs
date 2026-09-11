defmodule Mutare.NamespaceRunnerTest do
  use ExUnit.Case, async: false

  alias Mutare.{Coverage, RuntimeId, Sandbox, Schema}
  alias Mutare.Sandbox.Command.Invocation
  alias Mutare.Test.Project

  @moduletag :runner
  @moduletag timeout: 180_000

  setup do
    Project.build(:namespace_runner, %{
      "lib/a.ex" => "defmodule NamespaceA do\n def f(x), do: x + 2\nend\n",
      "lib/b.ex" => "defmodule NamespaceB do\n def f(x), do: x + 3\nend\n",
      "test/a_test.exs" => """
      defmodule NamespaceATest do
        use ExUnit.Case
        test "a", do: assert NamespaceA.f(5) == 7
        test "both" do
          assert NamespaceA.f(5) == 7
          assert NamespaceB.f(5) == 8
        end
      end
      """,
      "test/b_test.exs" => """
      defmodule NamespaceBTest do
        use ExUnit.Case
        test "b", do: assert NamespaceB.f(5) == 8
      end
      """
    })
  end

  test "coverage and selection follow report ids while a retained build reuses unchanged B", %{
    project: root,
    sandbox: sandbox
  } do
    opts = [sandbox: sandbox, keep_sandbox: true, mutators: [:arithmetic], workers: 2]
    assert {:ok, run} = Mutare.run(root, opts)
    assert Enum.map(run.results, &{&1.site.id, &1.status}) == [{1, :killed}, {2, :killed}]
    assert Enum.map(run.schema.sites, &RuntimeId.of/1) == [{"lib/a.ex", 1}, {"lib/b.ex", 1}]

    assert {:ok, coverage} =
             Coverage.read_dump(
               Path.join(sandbox, "mutare_cov.terms"),
               RuntimeId.index(run.schema.sites)
             )

    assert coverage.by_file == %{
             "test/a_test.exs" => MapSet.new([1, 2]),
             "test/b_test.exs" => MapSet.new([2])
           }

    assert coverage.by_test == %{
             1 => MapSet.new(["test a", "test both"]),
             2 => MapSet.new(["test b", "test both"])
           }

    {unchanged, 0} = Invocation.mix(sandbox, ["compile", "--verbose"], 0)
    refute unchanged =~ "Compiled lib/"
    old_b = File.read!(Path.join(sandbox, "lib/b.ex"))
    old_mtime = File.stat!(Path.join(sandbox, "lib/b.ex"), time: :posix).mtime

    File.write!(
      Path.join(root, "lib/a.ex"),
      "defmodule NamespaceA do\n def f(x), do: x + 2 + 3\nend\n"
    )

    test_a = Path.join(root, "test/a_test.exs")
    File.write!(test_a, String.replace(File.read!(test_a), "== 7", "== 10"))
    schema = Schema.build(root, mutators: [:arithmetic])
    assert {^sandbox, _} = Sandbox.prepare(root, schema, opts)
    assert File.read!(Path.join(sandbox, "lib/b.ex")) == old_b
    assert File.stat!(Path.join(sandbox, "lib/b.ex"), time: :posix).mtime == old_mtime
    {changed, 0} = Invocation.mix(sandbox, ["compile", "--verbose"], 0)
    assert changed =~ "Compiled lib/a.ex"
    refute changed =~ "Compiled lib/b.ex"

    assert {:ok, rerun} = Mutare.run(root, opts)

    assert Enum.map(rerun.results, &{&1.site.id, &1.status}) == [
             {1, :killed},
             {2, :killed},
             {3, :killed}
           ]

    b = Enum.find(rerun.results, &(&1.site.file == "lib/b.ex"))
    assert b.site.runtime_id == {"lib/b.ex", 1}
    assert b.site.id == 3
    assert b.site.mutated_code == "x - 3"
  end

  test "compile recovery drops each file's poison without confusing their local ids", %{
    project: root,
    sandbox: sandbox
  } do
    assert {:ok, run} =
             Mutare.run(root,
               sandbox: sandbox,
               mutators: [:arithmetic, Mutare.Test.PoisonMutator]
             )

    assert run.recovery.dropped == MapSet.new([2, 4])

    assert Enum.map(run.results, &{&1.site.id, &1.status}) ==
             [{1, :killed}, {2, :poisoned}, {3, :killed}, {4, :poisoned}]

    assert Enum.map(run.schema.sites, &RuntimeId.of/1) ==
             [{"lib/a.ex", 1}, {"lib/a.ex", 2}, {"lib/b.ex", 1}, {"lib/b.ex", 2}]
  end
end
