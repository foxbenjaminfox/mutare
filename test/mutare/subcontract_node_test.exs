defmodule Mutare.SubcontractNodeTest do
  @moduledoc """
  The **whole-call sub-contract** end to end (the free-standing-`dynamic` seam): a node-level
  mutator that registered a `:skip` macro receives the run's enabled non-host specs on the
  whole-call offer (`context.mutators`), hands the raw condition's island to
  `Mutare.Analyze.expression_mutations/3`, and relays each rebuild as an ordinary whole-call
  rewrite tagged `producer:` — the recorded Sites belong to the **producing core family** (its
  name, its variant vocabulary, its `# mutare:ignore` qualifiers) while the mutator's own catalog
  stays under its family, and every relayed mutant switches through the ordinary in-place
  selector. Plus parity: the same island yields the same logical core mutants as the hosted-weave
  path.
  """
  # persistent_term is global; the fixture is compiled once for all tests.
  use ExUnit.Case, async: false

  alias Mutare.Selector

  @source """
  defmodule Mutare.SubcontractNodeFixture do
    import Mutare.Test.QueryDSL

    def go(x, min) do
      dyn(x > min + 1)
    end

    def outside(x, min) do
      x > min + 1
    end

    def suppressed(x, min) do
      dyn(x > min + 1)   # mutare:ignore[literal:succ] boundary reviewed
    end

    def own_suppressed(x, min) do
      dyn(x > min + 1)   # mutare:ignore[node_sub]
    end
  end
  """

  @compile {:no_warn_undefined, Mutare.SubcontractNodeFixture}

  @mutators [:arithmetic, :literal, Mutare.Test.SubcontractNodeMutator]

  setup_all do
    {metamutant, sites, _next_id} =
      Mutare.Transform.transform_string_with_sites(@source,
        file: "subcontract_node.ex",
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

  alias Mutare.SubcontractNodeFixture, as: F

  # Match on containment, not equality: on a `# mutare:ignore` line the node's Sourceror
  # comment meta rides into the rendered code (a pre-existing rendering wart shared with the
  # built-in in-place families, orthogonal to the sub-contract under test).
  defp site(sites, mutator, mutated_code, line) do
    found =
      Enum.find(
        sites,
        &(&1.mutator == mutator and &1.line == line and
            String.contains?(&1.mutated_code, mutated_code))
      )

    assert found, "no #{mutator} site #{inspect(mutated_code)} on line #{line}"
    found
  end

  describe "producer attribution" do
    test "an island mutant records under the producing core family, not the relayer", %{
      sites: sites
    } do
      # The interior `min + 1` mutants report as core's families — with core's conventions —
      # while the relayer's own comparison reversal stays under its family. All are ordinary
      # in-place whole-call rewrites of the same `dyn` call.
      arithmetic = site(sites, :arithmetic, "dyn(x > min - 1)", 5)
      succ = site(sites, :literal, "dyn(x > min + 2)", 5)
      merged = site(sites, :literal, "dyn(x > min + 0)", 5)
      reversal = site(sites, :node_sub, "dyn(x < min + 1)", 5)

      for s <- [arithmetic, succ, merged, reversal] do
        assert s.kind == :in_place
        assert s.original_code == "dyn(x > min + 1)"
      end

      # The producer's variant vocabulary rides too — resolved at the node level by collect
      # (a Site-time derivation over the rebuilt call pair could never see the `+`).
      assert arithmetic.variant == ["-"]
      assert succ.variant == ["succ"]
      assert merged.variant == ["pred", "zero"]
      assert reversal.variant == []
    end

    test "exactly one producer per position — no double production", %{sites: sites} do
      line5 = Enum.filter(sites, &(&1.line == 5))

      # The relayer's reversal + arithmetic's swap + literal's succ/pred-zero: nothing else —
      # core kept the `:skip` argument raw, and the relays didn't duplicate its emission.
      assert Enum.frequencies_by(line5, & &1.mutator) == %{
               node_sub: 1,
               arithmetic: 1,
               literal: 2
             }
    end

    test "outside the registered macro, core's own emission is the only producer", %{
      sites: sites
    } do
      # The identical expression in ordinary position: core's families fire once each and the
      # sub-contracting mutator contributes nothing (no registered call, no `context.mutators`).
      line9 = Enum.filter(sites, &(&1.line == 9))

      assert Enum.frequencies_by(line9, & &1.mutator) == %{arithmetic: 1, literal: 2}
    end

    test "with no core families enabled, the island mutates to nothing" do
      {_meta, sites, _next} =
        Mutare.Transform.transform_string_with_sites(@source,
          file: "subcontract_node.ex",
          mutators: [Mutare.Test.SubcontractNodeMutator]
        )

      line5 = Enum.filter(sites, &(&1.line == 5))
      assert Enum.map(line5, & &1.mutator) == [:node_sub]
    end
  end

  describe "qualified ignores resolve against the producer's vocabulary" do
    test "[literal:succ] suppresses only the in-island succ mutant", %{sites: sites} do
      assert site(sites, :literal, "dyn(x > min + 2)", 13).ignored
      assert site(sites, :literal, "dyn(x > min + 2)", 13).ignore_reason == "boundary reviewed"

      refute site(sites, :literal, "dyn(x > min + 0)", 13).ignored
      refute site(sites, :arithmetic, "dyn(x > min - 1)", 13).ignored
      refute site(sites, :node_sub, "dyn(x < min + 1)", 13).ignored
    end

    test "[node_sub] suppresses the relayer's own mutant but no producer-attributed one", %{
      sites: sites
    } do
      assert site(sites, :node_sub, "dyn(x < min + 1)", 17).ignored

      refute site(sites, :arithmetic, "dyn(x > min - 1)", 17).ignored
      refute site(sites, :literal, "dyn(x > min + 2)", 17).ignored
      refute site(sites, :literal, "dyn(x > min + 0)", 17).ignored
    end
  end

  describe "delivery is the ordinary in-place selector" do
    test "island mutants switch at runtime through the whole-call rewrite", %{sites: sites} do
      # Baseline: `1 > 1 + 1` is false.
      refute F.go(1, 1)

      # The arithmetic island mutant (`x > min - 1`): `1 > 0` → true.
      Selector.put(site(sites, :arithmetic, "dyn(x > min - 1)", 5).id)
      assert F.go(1, 1)

      # The literal pred/zero island mutant (`x > min + 0`): `2 > 1` → true where the
      # baseline (`2 > 2`) is false.
      Selector.put(Selector.baseline())
      refute F.go(2, 1)
      Selector.put(site(sites, :literal, "dyn(x > min + 0)", 5).id)
      assert F.go(2, 1)

      # The relayer's own reversal still switches alongside them (`1 < 2` → true).
      Selector.put(site(sites, :node_sub, "dyn(x < min + 1)", 5).id)
      assert F.go(1, 1)
    end
  end

  describe "parity with the hosted sub-contract" do
    test "the same island yields the same logical core mutants on both delivery paths" do
      host_source = """
      defmodule Mutare.SubcontractParityHostFixture do
        import Mutare.Test.HostDSL

        def go(x, min) do
          filter([:ok], x > min + 1)
        end
      end
      """

      node_source = """
      defmodule Mutare.SubcontractParityNodeFixture do
        import Mutare.Test.QueryDSL

        def go(x, min) do
          dyn(x > min + 1)
        end
      end
      """

      {_meta, host_sites, _next} =
        Mutare.Transform.transform_string_with_sites(host_source,
          file: "parity_host.ex",
          mutators: [:arithmetic, :literal, Mutare.Test.SubcontractHostMutator]
        )

      {_meta, node_sites, _next} =
        Mutare.Transform.transform_string_with_sites(node_source,
          file: "parity_node.ex",
          mutators: [:arithmetic, :literal, Mutare.Test.SubcontractNodeMutator]
        )

      assert core_mutants(host_sites) == core_mutants(node_sites)
    end

    # The producer-attributed mutants as `{family, variant, condition}` — the hosted path
    # records the fragment diff, the whole-call path the rebuilt call, so strip the `dyn(...)`
    # wrapper down to the condition both share.
    defp core_mutants(sites) do
      sites
      |> Enum.filter(&(&1.mutator in [:arithmetic, :literal]))
      |> Enum.map(&{&1.mutator, &1.variant, condition(&1.mutated_code)})
      |> Enum.sort()
    end

    defp condition("dyn(" <> rest), do: String.trim_trailing(rest, ")")
    defp condition(code), do: code
  end
end
