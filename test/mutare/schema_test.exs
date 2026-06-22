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

  test ":only_lines keeps only the sites on the named file:line(s) (--line)", %{root: root} do
    write(
      root,
      "lib/a.ex",
      "defmodule A do\n  def f(x), do: x + 1\n  def g(a, b), do: a >= b\nend\n"
    )

    # Without the filter: + on line 2 (1 site), >= on line 3 (2 sites) = 3 sites.
    schema = Schema.build(root, mutators: @probe, only_lines: MapSet.new([{"lib/a.ex", 3}]))

    assert Enum.all?(schema.sites, &(&1.line == 3))
    assert Enum.map(schema.sites, & &1.mutator) == [:relational, :relational]
  end

  test ":only_lines keeps the union of several file:line(s), across files, and nothing else",
       %{root: root} do
    write(
      root,
      "lib/a.ex",
      "defmodule A do\n  def f(x), do: x + 1\n  def g(a, b), do: a >= b\nend\n"
    )

    write(root, "lib/b.ex", "defmodule B do\n  def h(x), do: x - 2\n  def k(y), do: y * 3\nend\n")

    # Request three lines spanning both files (a.ex:2 `+`, a.ex:3 `>=`, b.ex:3 `*`),
    # deliberately leaving b.ex:2 (`-`) out — it must be dropped.
    only =
      MapSet.new([{"lib/a.ex", 2}, {"lib/a.ex", 3}, {"lib/b.ex", 3}])

    schema = Schema.build(root, mutators: @probe, only_lines: only)

    kept = schema.sites |> Enum.map(&{&1.file, &1.line}) |> Enum.uniq() |> Enum.sort()
    assert kept == [{"lib/a.ex", 2}, {"lib/a.ex", 3}, {"lib/b.ex", 3}]
    # b.ex:2 (`-`) was not requested, so none of its sites survive.
    refute Enum.any?(schema.sites, &(&1.file == "lib/b.ex" and &1.line == 2))
  end

  test ":only_lines narrows the scanned files to those named (a fast narrow run)", %{root: root} do
    write(root, "lib/a.ex", "defmodule A do\n  def f(x), do: x + 1\nend\n")
    write(root, "lib/b.ex", "defmodule B do\n  def g(a, b), do: a >= b\nend\n")

    # Only b.ex:2 is requested, so a.ex never needs transforming — the metamutant
    # (and the one compile) stays small.
    schema = Schema.build(root, mutators: @probe, only_lines: MapSet.new([{"lib/b.ex", 2}]))

    assert Map.keys(schema.metamutants) == ["lib/b.ex"]
    assert Enum.all?(schema.sites, &(&1.file == "lib/b.ex" and &1.line == 2))
  end

  test ":only_lines yields no sites for a line with no mutants", %{root: root} do
    write(root, "lib/a.ex", "defmodule A do\n  def f(x), do: x + 1\nend\n")

    # Line 1 is `defmodule A do` — nothing to mutate there.
    schema = Schema.build(root, mutators: @probe, only_lines: MapSet.new([{"lib/a.ex", 1}]))

    assert Schema.count(schema) == 0
  end

  test ":only_lines survives a poison rebuild (reapplied inside from_files)", %{root: root} do
    write(
      root,
      "lib/a.ex",
      "defmodule A do\n  def f(x), do: x + 1\n  def g(a, b), do: a >= b\nend\n"
    )

    opts = [mutators: @probe, only_lines: MapSet.new([{"lib/a.ex", 3}])]
    schema = Schema.build(root, opts)

    rebuilt = Schema.rebuild(schema, root, opts, MapSet.new())

    assert Enum.map(rebuilt.sites, & &1.id) == Enum.map(schema.sites, & &1.id)
    assert Enum.all?(rebuilt.sites, &(&1.line == 3))
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

  test "records `# mutare:ignore` directives that suppressed no mutant", %{root: root} do
    write(root, "lib/a.ex", """
    defmodule A do
      def f(x), do: x + 1   # mutare:ignore[bogus]
      def g(x), do: x + 1   # mutare:ignore[arithmetic]
    end
    """)

    # A file with no directive at all is never re-parsed and contributes nothing.
    write(root, "lib/b.ex", "defmodule B do\n  def h(x), do: x + 1\nend\n")

    schema = Schema.build(root, mutators: @probe)

    # The `[bogus]` typo (line 2) suppressed nothing; the `[arithmetic]` (line 3)
    # matched the real arithmetic mutant on its line, so it is not flagged.
    assert [{"lib/a.ex", %{line: 2, mutators: set}}] = schema.ineffective_ignores
    assert MapSet.member?(set, "bogus")
  end

  test "ineffective detection uses the full site set, before --max-mutants trims", %{root: root} do
    # The directive on line 3 matches a real mutant there. Capping the run to the
    # first mutant (line 2's) must not make line 3's directive look ineffective.
    write(root, "lib/a.ex", """
    defmodule A do
      def f(x), do: x + 1
      def g(x), do: x + 1   # mutare:ignore[arithmetic]
    end
    """)

    schema = Schema.build(root, mutators: @probe, max_mutants: 1)

    assert Schema.count(schema) == 1
    assert schema.ineffective_ignores == []
  end
end
