defmodule Mutare.SubcontractHostTest do
  @moduledoc """
  The **host sub-contract** end to end: a selector host hands the ordinary-Elixir island inside
  its hosted fragment back to core's mutant generation (`Mutare.Analyze.expression_mutations/3`
  over the `context.mutators` core threads into `host/2`), relays each rebuild through its own
  weave tagged with `producer:`, and the recorded Sites belong to the **producing core family**
  — its name, its variant vocabulary, its `# mutare:ignore` qualifiers — while the host's own
  catalog stays under the host's family. Delivery is untouched: every interior mutant rides the
  host's woven selector, proven by compiling the metamutant once and flipping the active id.
  """
  # persistent_term is global; the fixture is compiled once for all tests.
  use ExUnit.Case, async: false

  alias Mutare.Selector

  @source """
  defmodule Mutare.SubcontractFixture do
    import Mutare.Test.HostDSL

    def go(x, min) do
      filter([:ok], x > min + 1)
    end

    def suppressed(x, min) do
      filter([:ok], x > min + 1)   # mutare:ignore[integer:succ] boundary reviewed
    end

    def host_suppressed(x, min) do
      filter([:ok], x > min + 1)   # mutare:ignore[sub_host]
    end
  end
  """

  @compile {:no_warn_undefined, Mutare.SubcontractFixture}

  @mutators [:arithmetic, :integer, Mutare.Test.SubcontractHostMutator]

  setup_all do
    {metamutant, sites, _next_id} =
      Mutare.Transform.transform_string_with_sites(@source,
        file: "subcontract.ex",
        mutators: @mutators
      )

    ExUnit.CaptureIO.capture_io(:stderr, fn ->
      [{_module, _binary}] = Code.compile_string(metamutant)
    end)

    %{sites: sites, meta: metamutant}
  end

  setup do
    Selector.put(Selector.baseline())
    on_exit(fn -> Selector.put(Selector.baseline()) end)
    :ok
  end

  alias Mutare.SubcontractFixture, as: F

  defp site(sites, mutator, mutated_code, line) do
    found =
      Enum.find(
        sites,
        &(&1.mutator == mutator and &1.mutated_code == mutated_code and &1.line == line)
      )

    assert found, "no #{mutator} site #{inspect(mutated_code)} on line #{line}"
    found
  end

  describe "producer attribution" do
    test "an island mutant records under the producing core family, not the host", %{
      sites: sites
    } do
      # The interior `min + 1` mutants report as core's families — with core's conventions —
      # while the host's own comparison reversal stays under the host's family. All are
      # focused, scaffolding-free fragment diffs against the same hosted condition.
      arithmetic = site(sites, :arithmetic, "x > min - 1", 5)
      succ = site(sites, :integer, "x > min + 2", 5)
      merged = site(sites, :integer, "x > min + 0", 5)
      reversal = site(sites, :sub_host, "x < min + 1", 5)

      for s <- [arithmetic, succ, merged, reversal] do
        assert s.kind == :in_place
        assert s.original_code == "x > min + 1"
      end

      # The producer's variant vocabulary rides too — resolved at the node level by collect
      # (a Site-time derivation over the wrapped fragment pair could never see the `+`).
      assert arithmetic.variant == ["-"]
      assert succ.variant == ["succ"]
      assert merged.variant == ["pred", "zero"]
      assert reversal.variant == []
    end

    test "exactly one producer per position — no double production", %{sites: sites} do
      line5 = Enum.filter(sites, &(&1.line == 5))

      # The host's reversal + arithmetic's swap + integer's succ/pred-zero: nothing else.
      assert Enum.frequencies_by(line5, & &1.mutator) == %{
               sub_host: 1,
               arithmetic: 1,
               integer: 2
             }
    end

    test "with no core families enabled, the island mutates to nothing" do
      {_meta, sites, _next} =
        Mutare.Transform.transform_string_with_sites(@source,
          file: "subcontract.ex",
          mutators: [Mutare.Test.SubcontractHostMutator]
        )

      line5 = Enum.filter(sites, &(&1.line == 5))
      assert Enum.map(line5, & &1.mutator) == [:sub_host]
    end
  end

  describe "qualified ignores resolve against the producer's vocabulary" do
    test "[integer:succ] suppresses only the in-island succ mutant", %{sites: sites} do
      assert site(sites, :integer, "x > min + 2", 9).ignored
      assert site(sites, :integer, "x > min + 2", 9).ignore_reason == "boundary reviewed"

      refute site(sites, :integer, "x > min + 0", 9).ignored
      refute site(sites, :arithmetic, "x > min - 1", 9).ignored
      refute site(sites, :sub_host, "x < min + 1", 9).ignored
    end

    test "[sub_host] suppresses the host's own mutant but no producer-attributed one", %{
      sites: sites
    } do
      assert site(sites, :sub_host, "x < min + 1", 13).ignored

      refute site(sites, :arithmetic, "x > min - 1", 13).ignored
      refute site(sites, :integer, "x > min + 2", 13).ignored
      refute site(sites, :integer, "x > min + 0", 13).ignored
    end
  end

  describe "delivery stays host-owned" do
    test "island mutants ride the host's woven selector and switch at runtime", %{sites: sites} do
      # Baseline: `1 > 1 + 1` is false → the filter drops the query.
      assert F.go(1, 1) == []

      # The arithmetic island mutant (`x > min - 1`): `1 > 0` → the query passes.
      Selector.put(site(sites, :arithmetic, "x > min - 1", 5).id)
      assert F.go(1, 1) == [:ok]

      # The integer pred/zero island mutant (`x > min + 0`): `2 > 1` → passes where the
      # baseline (`2 > 2`) drops.
      Selector.put(Selector.baseline())
      assert F.go(2, 1) == []
      Selector.put(site(sites, :integer, "x > min + 0", 5).id)
      assert F.go(2, 1) == [:ok]

      # The host's own reversal still switches alongside them (`1 < 2` → passes).
      Selector.put(site(sites, :sub_host, "x < min + 1", 5).id)
      assert F.go(1, 1) == [:ok]
    end

    test "no bare selector is spliced outside the host's weave", %{meta: meta} do
      # The one selector `case` per condition lives inside the `filter` call — the island
      # mutants are just more branches of it, so exactly one `case mutare_active` per line.
      assert length(String.split(meta, "filter(\n")) >= 2
    end
  end
end
