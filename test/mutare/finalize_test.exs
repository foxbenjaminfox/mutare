defmodule Mutare.FinalizeTest do
  @moduledoc """
  Coverage of `c:Mutare.Mutator.finalize/2`, the one enrichment seam across both delivery
  paths: core applies it to every element of a `mutate/1`/`mutate/2` return and of every
  hosted target's `:mutants`, so a family-rich mutator's tag → filter → enrich funnel is
  defined once and cannot silently miss a delivery site.
  """
  use ExUnit.Case, async: true

  alias Mutare.Mutator.{Dispatch, Mutation, Spec}
  alias Mutare.Test.FinalizeMutator

  @source """
  defmodule M do
    def f, do: 7
  end
  """

  # A selector host whose finalize/2 filters the target's tagged mutants and attaches a note
  # — the hosted-delivery twin of Mutare.Test.FinalizeMutator's mutate/2 path.
  defmodule FinalizeHost do
    @behaviour Mutare.Mutator
    @behaviour Mutare.Mutator.MacroHost

    alias Mutare.Mutator.Mutation

    @impl Mutare.Mutator
    def name, do: :finalize_host

    @impl Mutare.Mutator
    def init(opts), do: Keyword.get(opts, :keep, :all)

    @impl Mutare.Mutator
    def variants, do: ~w(a b)

    @impl Mutare.Mutator.MacroHost
    def hosted_macros, do: []

    @impl Mutare.Mutator.MacroHost
    def host(_call, _context) do
      [
        Mutare.Mutator.MacroHost.Target.new(
          {:x, [], nil},
          [Mutation.tagged({:a, [], nil}, ["a"]), Mutation.tagged({:b, [], nil}, ["b"])],
          fn macro_node, _case_node -> macro_node end
        )
      ]
    end

    @impl Mutare.Mutator
    def finalize(%Mutation{variant: [label]} = mutation, %{config: keep}) do
      if keep == :all or label in keep,
        do: %{mutation | note: "kept #{label}"},
        else: :skip
    end
  end

  # A mutator relaying a mutation another family produced (an explicit :producer): its own
  # finalize/2 skips everything, proving relayed mutations bypass the funnel.
  defmodule RelayingFinalize do
    @behaviour Mutare.Mutator

    @impl Mutare.Mutator
    def name, do: :relaying

    @impl Mutare.Mutator
    def mutate(_node, _context) do
      [
        Mutation.new({:relayed, [], nil},
          producer: Spec.for_module(Mutare.Mutators.Arithmetic)
        ),
        {:own, [], nil}
      ]
    end

    @impl Mutare.Mutator
    def finalize(_mutation, _context), do: :skip
  end

  # A mutate/1-only mutator with a rewrapping finalize/2 — the context-free path funnels too.
  defmodule LocalFinalize do
    @behaviour Mutare.Mutator

    @impl Mutare.Mutator
    def name, do: :local

    @impl Mutare.Mutator
    def mutate(_node), do: [{:x, [], nil}]

    @impl Mutare.Mutator
    def finalize(node, _context), do: Mutation.new(node, note: "wrapped")
  end

  # finalize/2 returning bare nil is ambiguous with :skip — rejected loudly.
  defmodule NilFinalize do
    @behaviour Mutare.Mutator

    @impl Mutare.Mutator
    def name, do: :nil_finalize

    @impl Mutare.Mutator
    def mutate(_node), do: [{:x, [], nil}]

    @impl Mutare.Mutator
    def finalize(_mutation, _context), do: nil
  end

  # A producer returning a malformed element (bare nil) *with* a pass-through finalize/2:
  # core's validation must fire before plugin code sees the garbage.
  defmodule GarbageProducer do
    @behaviour Mutare.Mutator

    @impl Mutare.Mutator
    def name, do: :garbage

    @impl Mutare.Mutator
    def mutate(_node), do: [nil]

    @impl Mutare.Mutator
    def finalize(mutation, _context), do: mutation
  end

  describe "the mutate/1–mutate/2 path" do
    test "finalize/2 filters disabled families and attaches the note, end to end" do
      %{sites: sites} =
        Mutare.Transform.transform_string_with_sites(@source,
          mutators: [{FinalizeMutator, families: [:zero]}]
        )

      assert [site] = sites
      assert site.mutator == :finalized
      assert site.mutated_code == "0"
      assert site.note == "zero boundary"
      assert site.variant == ["zero"]
    end

    test "with every family enabled, each mutant arrives enriched" do
      %{sites: sites} =
        Mutare.Transform.transform_string_with_sites(@source, mutators: [FinalizeMutator])

      assert Enum.map(sites, &{&1.mutated_code, &1.note, &1.variant}) == [
               {"0", "zero boundary", ["zero"]},
               {"1", "one boundary", ["one"]}
             ]
    end

    test "a mutate/1-only mutator's return funnels through finalize/2 too" do
      assert [%Dispatch.Result{spec: spec, node: {:x, [], nil}, note: "wrapped", variant: nil}] =
               Dispatch.mutations({:+, [], [1, 2]}, [LocalFinalize])

      assert spec.name == :local
    end

    test "a relayed mutation (explicit :producer) bypasses the returning mutator's finalize" do
      assert [
               %Dispatch.Result{
                 spec: producer_spec,
                 node: {:relayed, [], nil},
                 note: nil,
                 variant: nil
               }
             ] =
               Dispatch.mutations({:+, [], [1, 2]}, [RelayingFinalize])

      # The host-authored sibling was skipped by finalize/2; the relayed mutation rode
      # through untouched and is recorded under its producer.
      assert producer_spec.name == :arithmetic
    end
  end

  describe "the hosted :mutants path" do
    defp call do
      %Mutare.CallRouting.Call{
        node: {:x, [], []},
        module: Mutare.Test.HostDSL,
        name: :x,
        arguments: [],
        pipe_mode: :unpiped,
        effective_arity: 0,
        rebuild: fn name, args -> {name, [], args} end
      }
    end

    test "finalize/2 runs on each target mutant, dropping skips and enriching the rest" do
      spec = Spec.configured(FinalizeHost, keep: ["a"])

      assert [target] = Dispatch.host_targets(spec, call(), %{pipe_mode: :unpiped})

      assert [%Dispatch.Result{spec: ^spec, node: {:a, [], nil}, note: "kept a", variant: ["a"]}] =
               target.mutants
    end

    test "a target whose mutants all skip is dropped" do
      spec = Spec.configured(FinalizeHost, keep: [])

      assert Dispatch.host_targets(spec, call(), %{pipe_mode: :unpiped}) == []
    end
  end

  describe "contract violations fail loud" do
    test "finalize/2 returning bare nil raises (ambiguous with :skip)" do
      assert_raise ArgumentError, ~r/finalize\/2 must return a mutation or :skip, got: nil/, fn ->
        Dispatch.mutations({:+, [], [1, 2]}, [NilFinalize])
      end
    end

    test "malformed producer output is rejected by core before reaching finalize/2" do
      assert_raise ArgumentError, ~r/cannot be bare nil/, fn ->
        Dispatch.mutations({:+, [], [1, 2]}, [GarbageProducer])
      end
    end
  end
end
