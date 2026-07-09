defmodule Mutare.SubcontractFullSetTest do
  @moduledoc """
  The **full-set sub-contract** end to end: an island inside a hosted fragment is analyzed with
  the run's complete spec set — a host-implementing mutator included through its *ordinary*
  node-level surface. `Mutare.Test.HostNodeMutator` is the plugin-shaped fixture (one module
  that both hosts `filter/2` and mutates its registered `:skip` macro `dyn/1` whole-call, the
  reduced `mutare_ecto`): a `dyn(...)` buried inside the hosted island — the inner-`dynamic`
  case — is offered back to the same module's `mutate/2`, whose own sub-contract relays the
  interior another level down to core's families. Its `host/2` stays inert inside collect
  (hosted delivery never nests), and every relayed mutant already ran its **producer's**
  `finalize/2` at generation.
  """
  # persistent_term is global; the fixture is compiled once for all tests.
  use ExUnit.Case, async: false

  alias Mutare.Selector

  @source """
  defmodule Mutare.SubcontractFullSetFixture do
    import Mutare.Test.HostDSL
    import Mutare.Test.QueryDSL

    def go(y) do
      filter([:ok], false < dyn(y > 1))
    end
  end
  """

  @compile {:no_warn_undefined, Mutare.SubcontractFullSetFixture}

  @mutators [:literal, Mutare.Test.HostNodeMutator]

  setup_all do
    {metamutant, sites, _next_id} =
      Mutare.Transform.transform_string_with_sites(@source,
        file: "subcontract_full_set.ex",
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

  alias Mutare.SubcontractFullSetFixture, as: F

  defp site(sites, mutator, mutated_code) do
    found =
      Enum.find(
        sites,
        &(&1.mutator == mutator and String.contains?(&1.mutated_code, mutated_code))
      )

    assert found, "no #{mutator} site containing #{inspect(mutated_code)}"
    found
  end

  describe "a registered macro inside a hosted island reaches its owner" do
    test "the owner's whole-call rewrite fires exactly once, relayed through the weave", %{
      sites: sites
    } do
      # The inner `dyn`'s reversal — previously mutated by nobody (its owner implements
      # `host/2`, so the old non-host sub-contract excluded its `mutate/2` too).
      inner = site(sites, :host_node, "false < dyn(y < 1)")
      assert inner.original_code == "false < dyn(y > 1)"

      # The owner's *own* hosting of the outer condition still runs alongside.
      outer = site(sites, :host_node, "false > dyn(y > 1)")
      assert outer.original_code == "false < dyn(y > 1)"

      # Two levels of sub-contract: the inner `dyn`'s own relay hands the literal `1` to core,
      # and the rebuilds ride all the way out to the hosted weave under core's family.
      succ = site(sites, :literal, "false < dyn(y > 2)")
      assert succ.variant == ["succ"]

      # Exactly one producer per position — no duplicate from any level of the recursion.
      assert Enum.frequencies_by(sites, & &1.mutator) == %{host_node: 2, literal: 2}
    end

    test "every mutant switches at runtime through the one woven selector", %{sites: sites} do
      # Baseline: `false < (2 > 1)` → `false < true` → true → the query survives.
      assert F.go(2) == [:ok]

      # The inner `dyn` reversal (`y < 1`): `false < false` → false → dropped.
      Selector.put(site(sites, :host_node, "false < dyn(y < 1)").id)
      assert F.go(2) == []

      # The relayed literal succ (`y > 2`): `2 > 2` → false → dropped.
      Selector.put(site(sites, :literal, "false < dyn(y > 2)").id)
      assert F.go(2) == []

      # The owner's own outer reversal (`false > …`) → false → dropped.
      Selector.put(site(sites, :host_node, "false > dyn(y > 1)").id)
      assert F.go(2) == []
    end
  end

  describe "the producer's finalize runs inside the seam" do
    test "a generation-time :skip removes the owner's mutants everywhere, relays included" do
      {_meta, sites, _next} =
        Mutare.Transform.transform_string_with_sites(@source,
          file: "subcontract_full_set.ex",
          mutators: [:literal, {Mutare.Test.HostNodeMutator, drop_own: true}]
        )

      # The owner's finalize dropped its own catalog at generation — both the outer reversal
      # (the host-target funnel) and the inner `dyn` reversal (the collect-time funnel, before
      # the relay). The core-family relays are untouched: their producer's funnel is theirs.
      assert Enum.frequencies_by(sites, & &1.mutator) == %{literal: 2}
    end
  end
end
