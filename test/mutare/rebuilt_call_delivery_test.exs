defmodule Mutare.RebuiltCallDeliveryTest do
  @moduledoc """
  A rebuilt call's route governs its delivery, and its classifier sees written syntax.

  Two consequences of routing a rebuilt call as the call it is (`rebuilt_call_routing_test.exs`):

    * **Pipe delivery reads the replacement's route.** A stage written as a pipe is delivered
      in a closure that binds the piped value ahead of the call — right for a callee that
      evaluates its first argument, wrong for a replacement whose route reads it lazily
      (`value(x)` rebuilt as `ignored(x)`, a macro that discards it; a classifier flipping the
      position when a flag changes). Such a replacement takes the outer selector, where its
      branch evaluates its own operand in its own order — or not at all, as its source patch
      does. The direct-call spellings and an eager replacement are the controls.
    * **A classifier is asked in its own phase.** It is contracted the arguments as written —
      a nested pipe as a pipe — and a mutant's arguments have been resolved. So a call the
      mutator left unchanged keeps the classification it got on the written call, and a
      changed one is classified over its arguments spelled as written again; a classifier
      whose answer depends on the spelling (`PipeShapeRoute`) answers the same for both.
  """
  use ExUnit.Case, async: true

  import Mutare.Test.SourcePatch, only: [assert_patches: 4]

  alias Mutare.CallRouting.Registry
  alias Mutare.Transform.{BindingEscapeEmit, Resolve}

  defmodule DSL do
    def value(value), do: value
    def eager_twin(value), do: value
    defmacro ignored(_value), do: 6
    defmacro identity(value), do: value
    defmacro identity_twin(value), do: value

    defmacro choose(value, true), do: value
    defmacro choose(_value, false), do: 6
  end

  defmodule Routes do
    @behaviour Mutare.CallRouting
    alias Mutare.RebuiltCallDeliveryTest.DSL

    @impl Mutare.CallRouting
    def call_routes do
      [
        {DSL, :value, 1, [:expression]},
        {DSL, :eager_twin, 1, [:expression]},
        {DSL, :ignored, 1, [:lazy_expression]},
        {DSL, :choose, 2, :routing}
      ]
    end

    # `choose(value, true)` evaluates `value`; `choose(_, false)` discards it.
    @impl Mutare.CallRouting
    def route_arguments(%Mutare.CallRouting.Call{arguments: [_value, flag]} = call) do
      position = if literal(flag) == true, do: :expression, else: :lazy_expression
      Mutare.CallRouting.ArgumentRoutes.new(call, [position, :raw])
    end

    defp literal({:__block__, _, [value]}), do: value
    defp literal(value), do: value
  end

  defmodule RenameToLazy do
    @behaviour Mutare.Mutator
    alias Mutare.RebuiltCallDeliveryTest.DSL

    @impl Mutare.Mutator
    def name, do: :rename_to_lazy

    @impl Mutare.Mutator
    def mutate(node) do
      case Mutare.Calls.resolved_call_to(node, DSL, :value) do
        {:ok, :value, args, rebuild} -> [rebuild.(:ignored, args)]
        _ -> :skip
      end
    end
  end

  defmodule RenameToEager do
    @behaviour Mutare.Mutator
    alias Mutare.RebuiltCallDeliveryTest.DSL

    @impl Mutare.Mutator
    def name, do: :rename_to_eager

    @impl Mutare.Mutator
    def mutate(node) do
      case Mutare.Calls.resolved_call_to(node, DSL, :value) do
        {:ok, :value, args, rebuild} -> [rebuild.(:eager_twin, args)]
        _ -> :skip
      end
    end
  end

  defmodule Disable do
    @behaviour Mutare.Mutator
    alias Mutare.RebuiltCallDeliveryTest.DSL

    @impl Mutare.Mutator
    def name, do: :disable

    @impl Mutare.Mutator
    def mutate(node) do
      case Mutare.Calls.resolved_call_to(node, DSL, :choose) do
        {:ok, :choose, [value, _flag], rebuild} -> [rebuild.(:choose, [value, false])]
        _ -> :skip
      end
    end
  end

  # A classifier whose answer depends on the spelling: eager for a written pipe, lazy
  # otherwise. Both are sound for `identity/1`; the point is that resolution must not change
  # which one a call gets.
  defmodule PipeShapeRoute do
    @behaviour Mutare.CallRouting
    alias Mutare.RebuiltCallDeliveryTest.DSL

    @impl Mutare.CallRouting
    def call_routes, do: [{DSL, :identity, 1, :routing}, {DSL, :identity_twin, 1, :routing}]

    @impl Mutare.CallRouting
    def route_arguments(%Mutare.CallRouting.Call{arguments: [argument]} = call) do
      treatment = if written_pipe?(argument), do: :expression, else: :lazy_expression
      Mutare.CallRouting.ArgumentRoutes.new(call, [treatment])
    end

    defp written_pipe?({:|>, _, _}), do: true
    defp written_pipe?({:__block__, _, [node]}), do: written_pipe?(node)
    defp written_pipe?(_), do: false
  end

  defmodule RemoveAbs do
    @behaviour Mutare.Mutator

    @impl Mutare.Mutator
    def name, do: :remove_abs

    @impl Mutare.Mutator
    def mutate({:abs, _meta, [argument]}), do: [argument]
    def mutate(_), do: :skip
  end

  @dsl "Elixir.Mutare.RebuiltCallDeliveryTest.DSL"
  @opts [extensions: [Routes], clean_functions: false]

  # `input()` records that it ran. Original: `{6, true}`. A replacement that discards its
  # argument: `{6, false}` — unless the delivery ran the operand for it.
  defp effect_fixture(expression) do
    """
    defmodule Fixture do
      require #{@dsl}

      def run do
        Process.put(:rebuilt_call_delivery_seen, false)
        result = #{expression}
        {result, Process.get(:rebuilt_call_delivery_seen)}
      end

      defp input do
        Process.put(:rebuilt_call_delivery_seen, true)
        6
      end
    end
    """
  end

  describe "a piped replacement whose route reads the operand lazily" do
    test "a lazy callee: the operand is not hoisted ahead of it" do
      source = effect_fixture("input() |> #{@dsl}.value()")
      assert [_] = assert_patches(source, [RenameToLazy], [run: []], @opts)
    end

    test "a classifier turning argument zero lazy: the operand is not hoisted either" do
      source = effect_fixture("input() |> #{@dsl}.choose(true)")
      assert [_] = assert_patches(source, [Disable], [run: []], @opts)
    end

    test "control: the same lazy callee, written as a direct call" do
      source = effect_fixture("#{@dsl}.value(input())")
      assert [_] = assert_patches(source, [RenameToLazy], [run: []], @opts)
    end

    test "control: the same classifier flip, written as a direct call" do
      source = effect_fixture("#{@dsl}.choose(input(), true)")
      assert [_] = assert_patches(source, [Disable], [run: []], @opts)
    end

    test "control: a replacement that stays eager still rides the closure" do
      source = effect_fixture("input() |> #{@dsl}.value()")
      assert [_] = assert_patches(source, [RenameToEager], [run: []], @opts)
    end
  end

  describe "a classifier is asked over written syntax" do
    @call "Elixir.Mutare.RebuiltCallDeliveryTest.DSL.identity((p = -6) |> Function.identity())"

    setup do
      registry = Registry.build([], [], [PipeShapeRoute])
      node = @call |> Sourceror.parse_string!() |> Resolve.annotate(registry)
      {_module, :identity, args, rebuild} = Mutare.Calls.resolved_call(node)
      %{node: node, args: args, rebuild: rebuild}
    end

    test "an unchanged call keeps the classification of its written form", %{node: node} do
      assert Mutare.Calls.routed_treatments(node) == [:expression]
      assert BindingEscapeEmit.expression_bindings(node) == [:p]

      assert Resolve.reroute(node) == node
      assert Resolve.reroute(node, node) == node
    end

    test "a changed call is classified over its arguments spelled as written", ctx do
      rerouted = Resolve.reroute(ctx.rebuild.(:identity_twin, ctx.args), ctx.node)

      assert Mutare.Calls.routed_treatments(rerouted) == [:expression]
      assert BindingEscapeEmit.expression_bindings(rerouted) == [:p]
    end

    # `p` is fresh and read after; the `abs` removal keeps `identity`'s call, pipe and all, so
    # the eager classification — and the export of `p` — must survive into the mutant.
    defp binding_fixture do
      """
      defmodule Fixture do
        require #{@dsl}

        def run do
          result = abs(#{@dsl}.identity((p = -6) |> Function.identity()))
          {result, p}
        end
      end
      """
    end

    test "an unchanged classified child does not cost its parent a valid mutant" do
      sites =
        assert_patches(binding_fixture(), [RemoveAbs], [run: []],
          extensions: [PipeShapeRoute],
          clean_functions: false
        )

      assert [%{mutator: :remove_abs}] = sites
    end

    test "control: the same mutant under a static eager route" do
      sites =
        assert_patches(binding_fixture(), [RemoveAbs], [run: []],
          call_routes: [{DSL, :identity, 1, [:expression]}],
          clean_functions: false
        )

      assert [%{mutator: :remove_abs}] = sites
    end
  end
end
