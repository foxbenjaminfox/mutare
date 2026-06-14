defmodule Mutare.SchemaTest do
  use ExUnit.Case, async: true

  alias Mutare.Schema

  setup do
    root = Path.join(System.tmp_dir!(), "mutare_schema_#{System.unique_integer([:positive])}")
    File.mkdir_p!(Path.join(root, "lib/sub"))
    on_exit(fn -> File.rm_rf!(root) end)
    %{root: root}
  end

  defp write(root, rel, contents) do
    path = Path.join(root, rel)
    File.mkdir_p!(Path.dirname(path))
    File.write!(path, contents)
  end

  test "threads globally-unique ids across files, sorted by path", %{root: root} do
    write(root, "lib/a.ex", "defmodule A do\n  def f(x), do: x + 1\nend\n")
    write(root, "lib/sub/b.ex", "defmodule B do\n  def g(a, b), do: a >= b\nend\n")

    schema = Schema.build(root)

    # a.ex sorts before sub/b.ex: + -> - (id 1), then >= -> {>, <=} (ids 2, 3)
    assert Schema.count(schema) == 3
    assert Enum.map(schema.sites, & &1.id) == [1, 2, 3]
    assert Enum.map(schema.sites, & &1.file) == ["lib/a.ex", "lib/sub/b.ex", "lib/sub/b.ex"]
  end

  test "files with no sites are sources-only, not metamutants", %{root: root} do
    write(root, "lib/a.ex", "defmodule A do\n  def f(x), do: x + 1\nend\n")
    write(root, "lib/empty.ex", "defmodule Empty do\n  def h, do: :ok\nend\n")

    schema = Schema.build(root)

    assert Map.has_key?(schema.metamutants, "lib/a.ex")
    refute Map.has_key?(schema.metamutants, "lib/empty.ex")
    assert Map.has_key?(schema.sources, "lib/empty.ex")
  end

  test ":exclude drops matching files entirely", %{root: root} do
    write(root, "lib/a.ex", "defmodule A do\n  def f(x), do: x + 1\nend\n")
    write(root, "lib/generated/g.ex", "defmodule G do\n  def f(x), do: x + 1\nend\n")

    schema = Schema.build(root, exclude: ["lib/generated/**"])

    assert Map.keys(schema.sources) == ["lib/a.ex"]
    assert Schema.count(schema) == 1
  end

  test "unparseable files are skipped, not fatal", %{root: root} do
    write(root, "lib/ok.ex", "defmodule Ok do\n  def f(x), do: x + 1\nend\n")
    write(root, "lib/bad.ex", "defmodule Bad do\n  def ( oops\nend\n")

    schema = Schema.build(root)

    assert Schema.count(schema) == 1
    assert [{"lib/bad.ex", _reason}] = schema.skipped
  end
end
