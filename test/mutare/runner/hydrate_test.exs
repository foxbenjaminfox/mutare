defmodule Mutare.Runner.HydrateTest do
  use ExUnit.Case, async: true

  alias Mutare.{Result, Run, Schema}
  alias Mutare.Runner.Hydrate

  # One family keeps the fixture at exactly one site (`x + 1 → x - 1`).
  @probe [Mutare.Mutators.Arithmetic]

  setup do
    root = fresh_tmp("mutare_hydrate")
    File.mkdir_p!(Path.join(root, "lib"))
    File.write!(Path.join(root, "lib/a.ex"), "defmodule A do\n  def f(x), do: x + 1\nend\n")
    on_exit(fn -> File.rm_rf!(root) end)

    context = Run.Context.new(mutators: @probe, defer_site_code: true)
    schema = Schema.build(root, context)

    # No `Hydrate.stop/1` cleanup: the memo `Agent` is linked to this (test)
    # process, so it is torn down with the test — by `on_exit` time it's gone.
    hydrate = Hydrate.maybe_new(schema, context)

    %{root: root, schema: schema, hydrate: hydrate}
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

  test "hydrates a displayed result's deferred diff to the eager render",
       %{root: root, schema: schema, hydrate: hydrate} do
    assert [%{original_code: nil, mutated_code: nil} = site] = schema.sites

    # The eager build of the same source is the byte-for-byte reference.
    assert [eager_site] = Schema.build(root, mutators: @probe).sites

    result = Hydrate.result(hydrate, %Result{site: site, status: :survived})

    assert result.site.original_code == eager_site.original_code
    assert result.site.mutated_code == eager_site.mutated_code
  end

  # Regression: the file's `:start_id` used to be reconstructed as the smallest id among
  # `schema.sites` — but `:only_lines` filters those sites *after* ids are assigned, so a
  # `--line` run on anything but the file's first mutant re-rendered from the wrong start
  # and hydrated a survivor with an unrelated mutation's diff.
  test "hydrates the right mutant when --line drops the file's earlier sites", %{root: root} do
    # Three sites, one per line: `x + 1` (id 1), `y - 2` (id 2), `z * 3` (id 3).
    File.write!(
      Path.join(root, "lib/a.ex"),
      "defmodule A do\n  def f(x), do: x + 1\n  def g(y), do: y - 2\n  def h(z), do: z * 3\nend\n"
    )

    only = MapSet.new([{"lib/a.ex", 4}])
    context = Run.Context.new(mutators: @probe, defer_site_code: true, only_lines: only)
    schema = Schema.build(root, context)
    hydrate = Hydrate.maybe_new(schema, context)

    # Only the line-4 site is visible, and it keeps its scan-wide id (3), not a renumbered 1.
    assert [%{id: 3, line: 4, original_code: nil} = site] = schema.sites

    # The unfiltered eager build of the same file is the reference for id 3.
    eager = Schema.build(root, mutators: @probe).sites
    assert %{id: 3} = eager_site = Enum.find(eager, &(&1.id == 3))

    result = Hydrate.result(hydrate, %Result{site: site, status: :survived})

    assert result.site.original_code == eager_site.original_code
    assert result.site.mutated_code == eager_site.mutated_code
    assert result.site.original_code =~ "z * 3"
  end

  test "leaves a non-displayed result deferred", %{schema: schema, hydrate: hydrate} do
    [site] = schema.sites

    result = Hydrate.result(hydrate, %Result{site: site, status: :killed})

    assert result.site.original_code == nil
    assert result.site.mutated_code == nil
  end

  test "recovery preserves deferred rendering and hydrates from the original snapshot", %{
    root: root
  } do
    File.write!(Path.join(root, "lib/a.ex"), """
    defmodule A do
      def f(x), do: x + 1
      def g(y), do: y - 2
      def h(z), do: z * 3
    end
    """)

    context =
      Run.Context.new(
        mutators: @probe,
        defer_site_code: true,
        only_lines: MapSet.new([{"lib/a.ex", 3}, {"lib/a.ex", 4}]),
        max_mutants: 2
      )

    schema = Schema.build(root, context)
    [poisoned, survivor] = schema.sites
    assert poisoned.id == 2
    assert survivor.id == 3
    eager = Schema.build(root, mutators: @probe).sites |> Enum.find(&(&1.id == survivor.id))
    File.rm_rf!(root)

    rebuilt = Schema.rebuild(schema, MapSet.new([poisoned.id]))
    assert Enum.all?(rebuilt.sites, &is_nil(&1.original_code))
    hydrate = Hydrate.maybe_new(rebuilt, context)
    result = Hydrate.result(hydrate, %Result{site: List.last(rebuilt.sites), status: :survived})
    assert result.site.original_code == eager.original_code
    assert result.site.mutated_code == eager.mutated_code
  end

  test "a missing id fails explicitly instead of reporting an empty diff",
       %{schema: schema, hydrate: hydrate} do
    # The re-render is deterministic, so a real scan can't miss; force one by
    # asking for an id the file never produced.
    [site] = schema.sites
    missing = %{site | id: site.id + 1_000_000}

    assert_raise RuntimeError, ~r/hydration missed mutant ##{missing.id}/, fn ->
      Hydrate.result(hydrate, %Result{site: missing, status: :survived})
    end
  end
end
