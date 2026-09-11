defmodule Mutare.InitMutatorTest do
  @moduledoc """
  End-to-end coverage of the `c:Mutare.Mutator.init/1` path: options are parsed once at
  spec resolution, the result travels as `context.config` to every context-aware callback
  (`mutate/2`, the structural arities, `host/2`), and an invalid option raises at startup —
  at `Mutare.Mutators.resolve/1` / `Mutare.Options.new/1` — not on the first mutated node.
  """
  use ExUnit.Case, async: true

  alias Mutare.Mutator.{Dispatch, Spec}
  alias Mutare.Test.InitMutator

  @source """
  defmodule M do
    def f, do: 7
  end
  """

  # Counts init/1 invocations by messaging the resolving process, so the once-per-spec
  # contract is observable.
  defmodule CountingInit do
    @behaviour Mutare.Mutator

    @impl Mutare.Mutator
    def name, do: :counting

    @impl Mutare.Mutator
    def init(opts) do
      send(self(), {:init_ran, opts})
      opts
    end

    @impl Mutare.Mutator
    def mutate(_node, _context), do: :skip
  end

  # A structural mutator whose replacement comes from context.config.
  defmodule StructuralConfig do
    @behaviour Mutare.Mutator
    @behaviour Mutare.Mutator.Structural

    @impl Mutare.Mutator
    def name, do: :structural_config

    @impl Mutare.Mutator
    def init(opts), do: %{tail: Keyword.fetch!(opts, :tail)}

    @impl Mutare.Mutator.Structural
    def return_replacements(_tail, %{config: %{tail: value}}),
      do: [Mutare.AST.literal(value)]
  end

  # A selector host that reports the context it receives.
  defmodule HostConfig do
    @behaviour Mutare.Mutator
    @behaviour Mutare.Mutator.MacroHost

    @impl Mutare.Mutator
    def name, do: :host_config

    @impl Mutare.Mutator
    def init(opts), do: %{parsed: Keyword.fetch!(opts, :raw)}

    @impl Mutare.Mutator.MacroHost
    def hosted_macros, do: []

    @impl Mutare.Mutator.MacroHost
    def host(_call, context) do
      send(self(), {:host_context, context})
      []
    end
  end

  describe "config delivery" do
    test "init/1's return reaches mutate/2 as context.config and drives the mutation" do
      %{metamutant: metamutant, sites: sites} =
        Mutare.Transform.transform_string_with_sites(@source,
          mutators: [{InitMutator, replacement: 99}]
        )

      assert [site] = sites
      assert site.mutator == :initialized
      assert site.mutated_code == "99"
      assert metamutant =~ "99"
    end

    test "a bare module gets init/1([]) — parsed defaults, here no mutants" do
      %{sites: sites} =
        Mutare.Transform.transform_string_with_sites(@source, mutators: [InitMutator])

      assert sites == []
    end

    test "a mutator without init/1 gets config == opts" do
      [spec] = Mutare.Mutators.resolve([{Mutare.Test.ConfigurableMutator, replacement: 3}])
      assert spec.config == spec.opts
      assert spec.config == [replacement: 3]
    end

    test "the structural context carries config" do
      spec = Spec.configured(StructuralConfig, tail: 5)
      assert [replacement] = Dispatch.return_replacements(spec, Mutare.AST.literal(:orig))
      assert Mutare.AST.to_string(replacement) == "5"
    end

    test "the host context carries config alongside opts and behaviours" do
      spec = Spec.configured(HostConfig, raw: :value)
      assert Dispatch.host_targets(spec, :call, %{pipe_mode: :unpiped}) == []
      assert_received {:host_context, context}
      assert context.config == %{parsed: :value}
      assert context.opts == [raw: :value]
      assert context.behaviours == MapSet.new()
    end
  end

  describe "when init/1 runs" do
    test "once per resolved spec, receiving that entry's own opts (:as stripped)" do
      Mutare.Mutators.resolve([
        {CountingInit, as: :a, flavor: 1},
        {CountingInit, as: :b, flavor: 2}
      ])

      assert_received {:init_ran, flavor: 1}
      assert_received {:init_ran, flavor: 2}
      refute_received {:init_ran, _}
    end

    test "not re-run when already-resolved specs reach the transform" do
      specs = Mutare.Mutators.resolve([{CountingInit, flavor: 1}])
      assert_received {:init_ran, _}

      Mutare.Transform.transform_string_with_sites(@source, mutators: specs)
      refute_received {:init_ran, _}
    end
  end

  describe "invalid options fail at startup" do
    test "at Mutare.Mutators.resolve/1" do
      assert_raise ArgumentError, ~r/unknown Mutare.Test.InitMutator options: \[:bogus\]/, fn ->
        Mutare.Mutators.resolve([{InitMutator, bogus: 1}])
      end
    end

    test "at Mutare.Options.new/1, next to core's own option validation" do
      assert_raise ArgumentError, ~r/unknown Mutare.Test.InitMutator options/, fn ->
        Mutare.Options.new(mutators: [{InitMutator, bogus: 1}])
      end
    end
  end
end
