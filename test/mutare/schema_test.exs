defmodule Mutare.SchemaTest do
  use ExUnit.Case, async: true

  alias Mutare.Schema

  # Count-asserting tests pin the two operator-swap families so the higher-volume
  # default mutators (literals etc.) can't change the exact site totals; these
  # tests are about id threading / file scoping, not the default set.
  @probe [Mutare.Mutators.Arithmetic, Mutare.Mutators.Relational]

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

    schema = Schema.build(root, mutators: @probe)

    # a.ex sorts before sub/b.ex: + -> - (id 1), then >= -> {>, <=} (ids 2, 3)
    assert Schema.count(schema) == 3
    assert Enum.map(schema.sites, & &1.id) == [1, 2, 3]
    assert Enum.map(schema.sites, & &1.file) == ["lib/a.ex", "lib/sub/b.ex", "lib/sub/b.ex"]
  end

  test ":on_scan fires once per file with cumulative progress", %{root: root} do
    write(root, "lib/a.ex", "defmodule A do\n  def f(x), do: x + 1\nend\n")
    write(root, "lib/sub/b.ex", "defmodule B do\n  def g(a, b), do: a >= b\nend\n")

    test_pid = self()

    Schema.build(root, mutators: @probe, on_scan: &send(test_pid, {:scan, &1}))

    # One update per file, in path order, total fixed, `found` accumulating the
    # running mutant tally (a.ex: 1 site; sub/b.ex: 2 more → 3).
    assert_received {:scan, %{done: 1, total: 2, found: 1}}
    assert_received {:scan, %{done: 2, total: 2, found: 3}}
    refute_received {:scan, _}
  end

  test "rebuild re-scans silently (drops any :on_scan hook)", %{root: root} do
    write(root, "lib/a.ex", "defmodule A do\n  def f(x), do: x + 1\nend\n")

    test_pid = self()
    schema = Schema.build(root, mutators: @probe)

    Schema.rebuild(
      schema,
      root,
      [mutators: @probe, on_scan: &send(test_pid, {:scan, &1})],
      MapSet.new()
    )

    refute_received {:scan, _}
  end

  test "files with no sites are sources-only, not metamutants", %{root: root} do
    write(root, "lib/a.ex", "defmodule A do\n  def f(x), do: x + 1\nend\n")
    # `do: nil` is genuinely site-less: a `nil` tail is skipped by return-value
    # (returning nil is equivalent), and no other family mutates it.
    write(root, "lib/empty.ex", "defmodule Empty do\n  def h, do: nil\nend\n")

    schema = Schema.build(root)

    assert Map.has_key?(schema.metamutants, "lib/a.ex")
    refute Map.has_key?(schema.metamutants, "lib/empty.ex")
    assert Map.has_key?(schema.sources, "lib/empty.ex")
  end

  test "a manifest is stored for each mutated file, alongside its metamutant", %{root: root} do
    write(root, "lib/a.ex", "defmodule A do\n  def f(x), do: x + 1\nend\n")
    # `do: nil` is genuinely site-less: a `nil` tail is skipped by return-value
    # (returning nil is equivalent), and no other family mutates it.
    write(root, "lib/empty.ex", "defmodule Empty do\n  def h, do: nil\nend\n")

    schema = Schema.build(root)

    assert %Mutare.Manifest{} = schema.manifests["lib/a.ex"]
    refute Map.has_key?(schema.manifests, "lib/empty.ex")

    # every site's id appears in its file's manifest regions (Poison's mapping)
    region_ids =
      schema.manifests["lib/a.ex"].regions |> Enum.flat_map(& &1.ids) |> MapSet.new()

    assert Enum.all?(schema.sites, &MapSet.member?(region_ids, &1.id))
  end

  test ":exclude drops matching files entirely", %{root: root} do
    write(root, "lib/a.ex", "defmodule A do\n  def f(x), do: x + 1\nend\n")
    write(root, "lib/generated/g.ex", "defmodule G do\n  def f(x), do: x + 1\nend\n")

    schema = Schema.build(root, exclude: ["lib/generated/**"], mutators: @probe)

    assert Map.keys(schema.sources) == ["lib/a.ex"]
    assert Schema.count(schema) == 1
  end

  test ":only_files restricts to the given root-relative paths (e.g. --since)", %{root: root} do
    write(root, "lib/a.ex", "defmodule A do\n  def f(x), do: x + 1\nend\n")
    write(root, "lib/b.ex", "defmodule B do\n  def g(x), do: x + 1\nend\n")

    schema = Schema.build(root, only_files: MapSet.new(["lib/b.ex"]))

    assert Map.keys(schema.sources) == ["lib/b.ex"]
    assert Enum.all?(schema.sites, &(&1.file == "lib/b.ex"))
  end

  test "unparseable files are skipped, not fatal", %{root: root} do
    write(root, "lib/ok.ex", "defmodule Ok do\n  def f(x), do: x + 1\nend\n")
    write(root, "lib/bad.ex", "defmodule Bad do\n  def ( oops\nend\n")

    schema = Schema.build(root, mutators: @probe)

    assert Schema.count(schema) == 1
    assert [{"lib/bad.ex", _reason}] = schema.skipped
  end

  test "an internal error during transform crashes; it is not swallowed as a skip",
       %{root: root} do
    # Source parses fine, so the failure is in the transform itself — a tool bug,
    # not bad input. It must surface, not vanish into `schema.skipped`.
    write(root, "lib/ok.ex", "defmodule Ok do\n  def f(x), do: x + 1\nend\n")

    assert_raise RuntimeError, "boom from mutator", fn ->
      Schema.build(root, mutators: [Mutare.Test.RaisingMutator])
    end
  end
end
