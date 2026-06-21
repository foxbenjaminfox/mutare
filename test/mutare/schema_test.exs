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

  test ":max_mutants caps the schema to the first N sites (in source order)", %{root: root} do
    write(root, "lib/a.ex", "defmodule A do\n  def f(x), do: x + 1\nend\n")
    write(root, "lib/sub/b.ex", "defmodule B do\n  def g(a, b), do: a >= b\nend\n")

    # Without the cap there are 3 sites (see the id-threading test above).
    schema = Schema.build(root, mutators: @probe, max_mutants: 2)

    assert Schema.count(schema) == 2
    assert Enum.map(schema.sites, & &1.id) == [1, 2]
  end

  test ":max_mutants is a no-op when there are fewer mutants than the cap", %{root: root} do
    write(root, "lib/a.ex", "defmodule A do\n  def f(x), do: x + 1\nend\n")

    schema = Schema.build(root, mutators: @probe, max_mutants: 10)

    assert Schema.count(schema) == 1
  end

  test ":max_mutants survives a poison rebuild, keeping the cap and stable ids", %{root: root} do
    write(root, "lib/a.ex", "defmodule A do\n  def f(x), do: x + 1\nend\n")
    write(root, "lib/sub/b.ex", "defmodule B do\n  def g(a, b), do: a >= b\nend\n")

    schema = Schema.build(root, mutators: @probe, max_mutants: 2)

    # Poison recovery re-runs `from_files` (via `rebuild`); the cap must be
    # reapplied there, not silently lost, so the run stays bounded after recovery.
    rebuilt = Schema.rebuild(schema, root, [mutators: @probe, max_mutants: 2], MapSet.new())

    assert Schema.count(rebuilt) == 2
    assert Enum.map(rebuilt.sites, & &1.id) == [1, 2]
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

  test "no manifest is stored eagerly; Poison can still build one from the metamutant",
       %{root: root} do
    write(root, "lib/a.ex", "defmodule A do\n  def f(x), do: x + 1\nend\n")
    # `do: nil` is genuinely site-less: a `nil` tail is skipped by return-value
    # (returning nil is equivalent), and no other family mutates it.
    write(root, "lib/empty.ex", "defmodule Empty do\n  def h, do: nil\nend\n")

    schema = Schema.build(root)

    # Manifests are no longer precomputed by the scan — that re-parse is the
    # scan's dominant cost and is read only on a failed compile. The schema keeps
    # the metamutant source; Poison re-derives the manifest from it on demand.
    refute Map.has_key?(Map.from_struct(schema), :manifests)
    assert Map.has_key?(schema.metamutants, "lib/a.ex")

    # Built lazily from the stored metamutant, every site's id is still mappable
    # (the property Poison's compile-error → id mapping relies on).
    manifest = Mutare.Manifest.from_source(schema.metamutants["lib/a.ex"])
    region_ids = manifest.regions |> Enum.flat_map(& &1.ids) |> MapSet.new()

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

  test ":paths may name a single .ex file, not just a directory", %{root: root} do
    write(root, "lib/a.ex", "defmodule A do\n  def f(x), do: x + 1\nend\n")
    write(root, "lib/sub/b.ex", "defmodule B do\n  def g(a, b), do: a >= b\nend\n")

    schema = Schema.build(root, paths: ["lib/sub/b.ex"], mutators: @probe)

    assert Map.keys(schema.sources) == ["lib/sub/b.ex"]
    assert Enum.all?(schema.sites, &(&1.file == "lib/sub/b.ex"))
  end

  test ":paths mixes file and directory entries (deduping overlap)", %{root: root} do
    write(root, "lib/a.ex", "defmodule A do\n  def f(x), do: x + 1\nend\n")
    write(root, "lib/sub/b.ex", "defmodule B do\n  def g(a, b), do: a >= b\nend\n")
    write(root, "other/c.ex", "defmodule C do\n  def h(x), do: x + 2\nend\n")

    # `lib` (directory, recursive) ∪ `other/c.ex` (file); `lib/a.ex` is already
    # under `lib`, so naming it too must not duplicate it.
    schema = Schema.build(root, paths: ["lib", "lib/a.ex", "other/c.ex"], mutators: @probe)

    assert Map.keys(schema.sources) |> Enum.sort() == ["lib/a.ex", "lib/sub/b.ex", "other/c.ex"]
  end

  test ":paths entry naming a missing file yields nothing (not fatal)", %{root: root} do
    write(root, "lib/a.ex", "defmodule A do\n  def f(x), do: x + 1\nend\n")

    schema = Schema.build(root, paths: ["lib/does_not_exist.ex"], mutators: @probe)

    assert schema.sources == %{}
    assert Schema.count(schema) == 0
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
