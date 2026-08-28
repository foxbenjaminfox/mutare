defmodule Mutare.SchemaTest do
  use ExUnit.Case, async: true

  alias Mutare.Schema

  defmodule DriftingMutator do
    @behaviour Mutare.Mutator

    @key {__MODULE__, :calls}

    @impl Mutare.Mutator
    def name, do: :drifting

    @impl Mutare.Mutator
    def mutate({:+, meta, [left, right]}) do
      calls = :persistent_term.get(@key, 0)
      :persistent_term.put(@key, calls + 1)

      case calls do
        0 -> [{:-, meta, [left, right]}]
        _ -> [{:-, meta, [left, right]}, {:*, meta, [left, right]}]
      end
    end

    def mutate(_node), do: :skip

    def reset, do: :persistent_term.put(@key, 0)
    def clear, do: :persistent_term.erase(@key)
  end

  defmodule ExitingMutator do
    @behaviour Mutare.Mutator

    @impl Mutare.Mutator
    def name, do: :exiting

    @impl Mutare.Mutator
    def mutate({:+, _meta, [_left, _right]}), do: exit(:mutare_schema_test_exit)
    def mutate(_node), do: :skip
  end

  defmodule SlowFirstMutator do
    @behaviour Mutare.Mutator

    @impl Mutare.Mutator
    def name, do: :slow_first

    @impl Mutare.Mutator
    def mutate({:+, meta, [left, 1]}) do
      Process.sleep(75)
      [{:-, meta, [left, 1]}]
    end

    def mutate({:+, meta, [left, right]}), do: [{:-, meta, [left, right]}]
    def mutate(_node), do: :skip
  end

  # Count-asserting tests pin the two operator-swap families so the higher-volume
  # default mutators (literals etc.) can't change the exact site totals; these
  # tests are about id threading / file scoping, not the default set.
  @probe [Mutare.Mutators.Arithmetic, Mutare.Mutators.Relational]

  setup do
    root = fresh_tmp("mutare_schema")
    File.mkdir_p!(Path.join(root, "lib/sub"))
    on_exit(fn -> File.rm_rf!(root) end)
    %{root: root}
  end

  # `unique_integer/1` is unique only inside one BEAM. Self-hosting runs this
  # module in several parallel `mix test` processes that share /tmp, so using it
  # alone lets one test process delete another's fixture during `on_exit`.
  defp fresh_tmp(prefix) do
    name = "#{prefix}_#{System.pid()}_#{System.unique_integer([:positive])}"
    path = Path.join(System.tmp_dir!(), name)

    if File.exists?(path) do
      raise "expected a fresh tmp path but #{path} already exists (stale leftover or pid reuse)"
    end

    path
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
    write(root, "lib/a.ex", "defmodule A do\n  def g(a, b), do: a >= b\nend\n")
    write(root, "lib/empty.ex", "defmodule Empty do\n  def h, do: nil\nend\n")
    write(root, "lib/sub/b.ex", "defmodule B do\n  def f(x), do: x + 1\nend\n")

    test_pid = self()

    Schema.build(root, mutators: @probe, on_scan: &send(test_pid, {:scan, &1}))

    # One update per file, in path order, total fixed, `found` accumulating only
    # real sites (a.ex: 2 sites; empty.ex: 0; sub/b.ex: 1 more → 3).
    assert_received {:scan, %{done: 1, total: 3, found: 2}}
    assert_received {:scan, %{done: 2, total: 3, found: 2}}
    assert_received {:scan, %{done: 3, total: 3, found: 3}}
    refute_received {:scan, _}
  end

  test "scan preserves input order even when a later worker finishes first", %{root: root} do
    write(root, "lib/a.ex", "defmodule A do\n  def f(x), do: x + 1\nend\n")
    write(root, "lib/b.ex", "defmodule B do\n  def f(x), do: x + 2\nend\n")

    schema = Schema.build(root, mutators: [SlowFirstMutator])

    assert Enum.map(schema.sites, & &1.file) == ["lib/a.ex", "lib/b.ex"]
    assert Enum.map(schema.sites, & &1.id) == [1, 2]
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

  test ":start_ids records each sited file's id-range origin, prefix-summed in path order",
       %{root: root} do
    write(root, "lib/a.ex", "defmodule A do\n  def f(x), do: x + 1\nend\n")
    write(root, "lib/empty.ex", "defmodule Empty do\n  def h, do: nil\nend\n")
    write(root, "lib/sub/b.ex", "defmodule B do\n  def g(a, b), do: a >= b\nend\n")

    schema = Schema.build(root, mutators: @probe)

    # a.ex claims id 1; sub/b.ex starts where a.ex's range ends. A site-less file has no
    # range and no entry.
    assert schema.start_ids == %{"lib/a.ex" => 1, "lib/sub/b.ex" => 2}
  end

  test ":start_ids is the pre-filter origin, unchanged by :only_lines and :max_mutants",
       %{root: root} do
    write(
      root,
      "lib/a.ex",
      "defmodule A do\n  def f(x), do: x + 1\n  def g(a, b), do: a >= b\nend\n"
    )

    write(root, "lib/b.ex", "defmodule B do\n  def h(x), do: x - 2\nend\n")

    # `--line lib/a.ex:3` keeps only a.ex's `>=` sites (ids 2, 3) — the smallest *visible*
    # id is 2, but the file's range still starts at 1. A report-time re-render must start
    # there, or id 2 would be handed id 1's code.
    lined = Schema.build(root, mutators: @probe, only_lines: MapSet.new([{"lib/a.ex", 3}]))
    assert Enum.map(lined.sites, & &1.id) == [2, 3]
    assert lined.start_ids == %{"lib/a.ex" => 1}

    # `--max-mutants 1` drops b.ex from `:sites` entirely, but its range was still assigned.
    capped = Schema.build(root, mutators: @probe, max_mutants: 1)
    assert Enum.map(capped.sites, & &1.id) == [1]
    assert capped.start_ids == %{"lib/a.ex" => 1, "lib/b.ex" => 4}
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

  test "every parser-error type is skipped (not re-raised), and in source order", %{root: root} do
    write(root, "lib/ok.ex", "defmodule Ok do\n  def f(x), do: x + 1\nend\n")
    # One file per exception the count pass (`count_one/3`) rescues, named so they sort
    # ahead of ok.ex: a MismatchedDelimiterError, a SyntaxError, a TokenMissingError.
    write(root, "lib/e1_mismatch.ex", "defmodule M do\n  def ( oops\nend\n")
    write(root, "lib/e2_syntax.ex", "x = %{a: }\n")
    write(root, "lib/e3_token.ex", "[1, 2")

    schema = Schema.build(root, mutators: @probe)

    # The good file still mutates; all three malformed files are skipped rather than
    # crashing the build, and `finalize/1` puts `skipped` back into source (path) order.
    assert Schema.count(schema) == 1

    assert Enum.map(schema.skipped, &elem(&1, 0)) ==
             ["lib/e1_mismatch.ex", "lib/e2_syntax.ex", "lib/e3_token.ex"]
  end

  test "discover dedups overlapping paths and orders them (threading order, not map order)",
       %{root: root} do
    write(root, "lib/a.ex", "defmodule A do\n  def f(x), do: x + 1\nend\n")
    write(root, "lib/sub/b.ex", "defmodule B do\n  def g(a, b), do: a >= b\nend\n")
    write(root, "other/c.ex", "defmodule C do\n  def h(x), do: x + 2\nend\n")

    # Paths listed out of order and overlapping (`lib` recursively ⊇ `lib/a.ex`).
    schema = Schema.build(root, paths: ["other/c.ex", "lib", "lib/a.ex"], mutators: @probe)

    # `schema.files` is a *list* recording the discovery/threading order, so it exposes
    # both the sort and the dedup that `schema.sources` (a map) silently normalizes away.
    assert schema.files == ["lib/a.ex", "lib/sub/b.ex", "other/c.ex"]
    assert schema.files == Enum.uniq(schema.files)
  end

  test "a directive in a site-less file is detected (per-file site lookup defaults to [])",
       %{root: root} do
    # The file parses (so it's in `sources`) and contains `mutare:ignore`, but produces
    # zero sites — so it is not a key in the per-file site map. The lookup must default
    # to `[]`, not `nil` (an `Enum.map(nil, …)` would crash the ineffective scan).
    write(root, "lib/c.ex", """
    defmodule C do
      # mutare:ignore
      @moduledoc "x"
    end
    """)

    schema = Schema.build(root, mutators: @probe)

    assert Schema.count(schema) == 0
    assert [{"lib/c.ex", %{line: 3}, _hint}] = schema.ineffective_ignores
  end

  test "an unrecognized `mutare:` comment is recorded, even in a file with no `mutare:ignore`",
       %{root: root} do
    # The file contains no `mutare:ignore` substring at all — detection must prefilter
    # on the wider `mutare:`, or a typo'd verb in an otherwise directive-free file
    # would never be parsed for diagnostics.
    write(root, "lib/u.ex", """
    defmodule U do
      # mutare:ingore
      def f(a, b), do: a + b
    end
    """)

    schema = Schema.build(root, mutators: @probe)

    assert schema.unknown_directives == [{"lib/u.ex", 2, "mutare:ingore"}]
    # The typo'd comment is not an ignore directive, so it is not *ineffective* —
    # the unknown-verb entry is the only signal.
    assert schema.ineffective_ignores == []
  end

  test "unknown `mutare:` comments are sorted across files", %{root: root} do
    write(root, "lib/b.ex", "defmodule B do\n  def f(x), do: x + 1 # mutare:frobnicate\nend\n")
    write(root, "lib/a.ex", "defmodule A do\n  def f(x), do: x + 1 # mutare: ignore\nend\n")

    schema = Schema.build(root, mutators: @probe)

    assert schema.unknown_directives == [
             {"lib/a.ex", 2, "mutare: ignore"},
             {"lib/b.ex", 2, "mutare:frobnicate"}
           ]
  end

  test "ineffective directives are ordered by line", %{root: root} do
    write(root, "lib/a.ex", """
    defmodule A do
      def f(x), do: x   # mutare:ignore[bogus1]
      def g(x), do: x   # mutare:ignore[bogus2]
    end
    """)

    schema = Schema.build(root, mutators: @probe)

    # Both typo'd filters suppress nothing; the recorded list is line-ordered, not
    # reversed (the `for`-comprehension input order).
    assert Enum.map(schema.ineffective_ignores, fn {_f, d, _h} -> d.line end) == [2, 3]
  end

  test "a scoped directive rides the schema: sites in a region come back ignored, an empty ignore-file is warned",
       %{root: root} do
    write(root, "lib/a.ex", """
    defmodule A do
      def keep(x), do: x + 1
      # mutare:ignore-start spot-checked table
      def enc(x), do: x + 2
      # mutare:ignore-end
    end
    """)

    # No @probe site here at all, so the file-wide suppression is ineffective.
    write(root, "lib/b.ex", """
    # mutare:ignore-file generated
    defmodule B do
      def f(x), do: x
    end
    """)

    schema = Schema.build(root, mutators: @probe)

    by_line = Enum.group_by(schema.sites, & &1.line)
    refute Enum.any?(by_line[2], & &1.ignored)
    assert Enum.all?(by_line[4], & &1.ignored)
    assert Enum.all?(by_line[4], &(&1.ignore_reason == "spot-checked table"))

    assert [{"lib/b.ex", %{scope: :file}, nil}] = schema.ineffective_ignores
  end

  test "a broken region pairing aborts the scan with a located SpecError", %{root: root} do
    # Even in a zero-site file — the count path is the only transform that sees it.
    write(root, "lib/a.ex", """
    defmodule A do
      # mutare:ignore-start
      @moduledoc "x"
    end
    """)

    err =
      assert_raise(Mutare.Ignore.SpecError, fn -> Schema.build(root, mutators: @probe) end)

    assert err.reason == :unterminated_region
    assert err.message =~ "lib/a.ex:2"
  end

  test "ineffective directives are sorted across files (the `sources` map iterates unordered)",
       %{root: root} do
    # Past 32 keys a map is a hashmap that iterates in an *unordered* sequence, so the
    # final `Enum.sort_by/2` is what actually orders the cross-file result. Use enough
    # files (each with one ineffective directive) that the comprehension's input order is
    # neither sorted nor its reverse — so a dropped/constant/reversed sort all reorder.
    rels = for i <- 0..40, do: "lib/f#{String.pad_leading(to_string(i), 2, "0")}.ex"

    for rel <- rels do
      # `def f(x), do: x` has no @probe site, so `[bogus]` suppresses nothing → ineffective.
      write(
        root,
        rel,
        "defmodule #{Path.basename(rel, ".ex")} do\n  def f(x), do: x   # mutare:ignore[bogus]\nend\n"
      )
    end

    schema = Schema.build(root, mutators: @probe)

    got = Enum.map(schema.ineffective_ignores, fn {f, _d, _h} -> f end)
    assert got == Enum.sort(rels)
  end

  test "from_files dedups a file passed more than once (no overlapping ids)", %{root: root} do
    write(
      root,
      "lib/a.ex",
      "defmodule A do\n  def f(x), do: x + 1\n  def g(a, b), do: a >= b\nend\n"
    )

    path = Path.join(root, "lib/a.ex")
    opts = [mutators: @probe]

    once = Schema.from_files([path], root, opts, MapSet.new())
    twice = Schema.from_files([path, path], root, opts, MapSet.new())

    # Passing the same file twice must not double its mutants or collide ids: without
    # the dedup the second occurrence renders under a higher `:start_id` but clobbers the
    # first on its relative-path key, so both sites would carry the *last* render's ids
    # (e.g. [4, 5, 6, 4, 5, 6]) — duplicate ids, a broken schema.
    assert Enum.map(twice.sites, & &1.id) == Enum.map(once.sites, & &1.id)
    assert twice.files == ["lib/a.ex"]
    assert map_size(twice.metamutants) == 1
    assert twice.metamutants == once.metamutants
  end

  test "from_files default root records paths relative to the current directory", %{root: root} do
    write(root, "lib/a.ex", "defmodule A do\n  def f(x), do: x + 1\nend\n")

    cwd_rel = Path.relative_to(Path.join(root, "lib/a.ex"), File.cwd!())

    schema = Schema.from_files([cwd_rel])

    assert schema.files == [cwd_rel]
    assert Map.keys(schema.sources) == [cwd_rel]
  end

  test "from_files preserves explicit input order for sites and skipped files", %{root: root} do
    write(root, "lib/a.ex", "defmodule A do\n  def f(x), do: x + 1\nend\n")
    write(root, "lib/b.ex", "defmodule B do\n  def f(x), do: x + 2\nend\n")
    write(root, "lib/a_bad.ex", "defmodule ABad do\n  def ( oops\nend\n")
    write(root, "lib/z_bad.ex", "defmodule ZBad do\n  def ( oops\nend\n")

    schema =
      Schema.from_files(
        [
          Path.join(root, "lib/b.ex"),
          Path.join(root, "lib/a.ex"),
          Path.join(root, "lib/z_bad.ex"),
          Path.join(root, "lib/a_bad.ex")
        ],
        root,
        mutators: @probe
      )

    assert schema.files == ["lib/b.ex", "lib/a.ex", "lib/z_bad.ex", "lib/a_bad.ex"]
    assert Enum.map(schema.sites, & &1.file) == ["lib/b.ex", "lib/a.ex"]
    assert Enum.map(schema.skipped, &elem(&1, 0)) == ["lib/z_bad.ex", "lib/a_bad.ex"]
  end

  describe "forwards options through to the transform" do
    test ":skip_ids reaches the transform (poison recovery renders the mutant raw)", %{root: root} do
      write(
        root,
        "lib/a.ex",
        "defmodule A do\n  def f(x), do: x + 1\n  def g(a, b), do: a >= b\nend\n"
      )

      files = [Path.join(root, "lib/a.ex")]
      opts = [mutators: @probe]

      full = Schema.from_files(files, root, opts, MapSet.new())
      skipped = Schema.from_files(files, root, opts, MapSet.new([1]))

      # The id counter advances even for skipped ids, so the site list is unchanged —
      # but mutant 1's selector is rendered raw, so the metamutant source must differ.
      assert Enum.map(full.sites, & &1.id) == Enum.map(skipped.sites, & &1.id)
      assert full.metamutants["lib/a.ex"] != skipped.metamutants["lib/a.ex"]
    end

    test ":expand_uses reaches the transform (a use-injected import is seen only when on)",
         %{root: root} do
      # `use Mutare.Test.ControllerUsing` injects `import Enum, only: [reject: 2]`, so the
      # bare `reject/2` is a mutable `Enum.reject` only once use-expansion runs.
      write(root, "lib/u.ex", """
      defmodule U do
        use Mutare.Test.ControllerUsing
        def f(xs), do: reject(xs, fn x -> x end)
      end
      """)

      coll = [Mutare.Mutators.Collection]
      on = Schema.build(root, paths: ["lib/u.ex"], mutators: coll, expand_uses: true)
      off = Schema.build(root, paths: ["lib/u.ex"], mutators: coll, expand_uses: false)

      assert Schema.count(on) > 0
      assert Schema.count(off) == 0
    end

    test ":macro_routes reaches the transform (a :skip routing keeps core out of the DSL body)",
         %{root: root} do
      write(root, "lib/q.ex", """
      defmodule UsesQuery do
        import Mutare.Test.QueryDSL
        def run(y), do: query(where: 1 == y, select: 2)
      end
      """)

      build = fn macros ->
        Schema.build(root,
          paths: ["lib/q.ex"],
          mutators: [Mutare.Mutators.Relational, Mutare.Mutators.IntegerLiteral],
          macro_routes: macros
        )
      end

      # Without the routing the DSL body's `1 == y` / literals mutate; with the `:skip`
      # routing forwarded, core leaves the opaque body untouched.
      assert Schema.count(build.([])) > 0
      assert Schema.count(build.([{Mutare.Test.QueryDSL, :query, 1, :skip}])) == 0
    end

    test ":defer_site_code controls diff rendering and :summarize_sites controls summaries",
         %{root: root} do
      write(root, "lib/a.ex", "defmodule A do\n  def f(x), do: x + 1\nend\n")

      eager = Schema.build(root, mutators: @probe)
      deferred = Schema.build(root, mutators: @probe, defer_site_code: true)

      summarized =
        Schema.build(root, mutators: @probe, defer_site_code: true, summarize_sites: true)

      assert [%{original_code: original, mutated_code: mutated, summary: nil}] = eager.sites
      assert is_binary(original)
      assert is_binary(mutated)

      assert [%{original_code: nil, mutated_code: nil, summary: nil}] = deferred.sites
      assert [%{original_code: nil, mutated_code: nil, summary: summary}] = summarized.sites
      assert summary == "arithmetic  x + 1 → x - 1"
    end
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

  test "an exiting transform worker exits the caller with the original reason", %{root: root} do
    write(root, "lib/ok.ex", "defmodule Ok do\n  def f(x), do: x + 1\nend\n")

    test_pid = self()

    {pid, ref} =
      spawn_monitor(fn ->
        Schema.build(root, mutators: [ExitingMutator])
        send(test_pid, :schema_build_returned)
      end)

    # Generous timeout: Schema.build spawns transform workers first, and on a
    # loaded CI machine the exit can take longer than the default 100ms.
    assert_receive {:DOWN, ^ref, :process, ^pid, :mutare_schema_test_exit}, 5_000
    refute_received :schema_build_returned
  end

  test "count/render mutant-count drift crashes before overlapping ids can be returned",
       %{root: root} do
    write(root, "lib/a.ex", "defmodule A do\n  def f(x), do: x + 1\nend\n")

    DriftingMutator.reset()
    on_exit(&DriftingMutator.clear/0)

    assert_raise RuntimeError, ~r/mutant-count drift .* counted 1, rendered 2/, fn ->
      Schema.build(root, mutators: [DriftingMutator])
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
    assert [{"lib/a.ex", %{line: 2, mutators: set}, _hint}] = schema.ineffective_ignores
    assert MapSet.member?(set, {"bogus", :any})
  end

  test "an ineffective directive on a pipe's first line carries a misplacement hint",
       %{root: root} do
    # The directive covers the pipe's first line (4), but the arithmetic mutant
    # lives two `|>` steps down (5) — the recorded hint names that line so the
    # warning can say where to move the directive.
    write(root, "lib/p.ex", """
    defmodule P do
      def run(list) do
        # mutare:ignore[arithmetic]
        list
        |> Enum.map(fn x -> x + 1 end)
        |> Enum.sum()
      end
    end
    """)

    schema = Schema.build(root, mutators: @probe)

    assert [{"lib/p.ex", %{line: 4, comment_line: 3}, 5}] = schema.ineffective_ignores
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

  test "records :skip_lifting entries that matched no function", %{root: root} do
    write(root, "lib/a.ex", """
    defmodule SchemaSkipLiftA do
      def f(x) when x > 0, do: x + 1
      def f(x), do: x - 1
    end
    """)

    ExUnit.CaptureLog.capture_log(fn ->
      schema =
        Schema.build(root,
          mutators: @probe,
          skip_lifting: [
            # Matches f/1 above — must NOT be recorded.
            {SchemaSkipLiftA, :f, 1},
            # Wrong arity (the *written* head arity is what matches) — recorded.
            {SchemaSkipLiftA, :f, 2},
            # No such module anywhere — recorded.
            {SchemaSkipLift.Missing, :g, 1}
          ]
        )

      assert schema.ineffective_skip_lifting == [
               {SchemaSkipLift.Missing, "g", 1},
               {SchemaSkipLiftA, "f", 2}
             ]
    end)
  end

  test "a narrowed scan records no ineffective :skip_lifting entries", %{root: root} do
    write(root, "lib/a.ex", """
    defmodule SchemaSkipLiftB do
      def f(x) when x > 0, do: x + 1
      def f(x), do: x - 1
    end
    """)

    # `--since`/`--only`/`--line` narrow the file set, so an entry's absence there
    # proves nothing — the diagnostic must stay silent rather than false-positive.
    schema =
      Schema.build(root,
        mutators: @probe,
        skip_lifting: [{SchemaSkipLift.Elsewhere, :g, 1}],
        only_files: ["lib/a.ex"]
      )

    assert schema.ineffective_skip_lifting == []
  end
end
