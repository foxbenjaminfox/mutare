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
    * **The written call needs no route for its replacement's to be found.** `value/1` is an
      ordinary function and is not routed here; the route that governs the mutant is the
      replacement's, static or classifier-backed, looked up for a replacement built with
      the offered call's meta (`rebuild`) or without it (a mutator's own node) alike. An
      explicit all-expression route on the written call is a control: it must change
      nothing.
    * **A classifier is asked in its own phase.** It is contracted the arguments as written —
      a nested pipe as a pipe — and a mutant's arguments have been resolved. So a call the
      mutator left unchanged keeps the classification it got on the written call, and a
      changed one is classified over its arguments spelled as written again; a classifier
      whose answer depends on the spelling (`PipeShapeRoute`) answers the same for both.
    * **A replacement is source, and is resolved as source.** A mutator may return a freshly
      written pipe (`quote do: unquote(x) |> DSL.ignored()`) rather than the direct call;
      `Kernel.|>/2` inserts the operand into the stage, so the stage's route is the one for
      `ignored/1`, not `ignored/0`, and the mutant is the direct call the walk makes of any
      written pipe — routed, and delivered, as such. A fresh pipe into an eager callee, and
      a fresh pipe replacing a call written directly, are the controls.
  """
  use ExUnit.Case, async: true

  import Mutare.Test.SourcePatch, only: [assert_patches: 4]

  alias Mutare.CallRouting.Registry
  alias Mutare.Transform.{BindingEscapeEmit, Resolve}

  defmodule DSL do
    def value(value), do: value
    def eager_twin(value), do: value
    defmacro ignored(_value), do: 6
    defmacro ignored_twin(_value), do: 6
    defmacro identity(value), do: value
    defmacro identity_twin(value), do: value

    defmacro choose(value, true), do: value
    defmacro choose(_value, false), do: 6
  end

  defmodule Routes do
    @behaviour Mutare.CallRouting
    alias Mutare.RebuiltCallDeliveryTest.DSL

    # `value/1`, the written callee, is deliberately not here: an ordinary function needs no
    # route, and the replacement's route must be found without one.
    @impl Mutare.CallRouting
    def call_routes do
      [
        {DSL, :eager_twin, 1, [:expression]},
        {DSL, :ignored, 1, [:lazy_expression]},
        {DSL, :ignored_twin, 1, :routing},
        {DSL, :choose, 2, :routing}
      ]
    end

    # `choose(value, true)` evaluates `value`; `choose(_, false)` discards it.
    @impl Mutare.CallRouting
    def route_arguments(%Mutare.CallRouting.Call{name: :choose, arguments: [_value, flag]} = call) do
      position = if literal(flag) == true, do: :expression, else: :lazy_expression
      Mutare.CallRouting.ArgumentRoutes.new(call, [position, :raw])
    end

    # `ignored_twin/1` discards its argument too, and says so through a classifier.
    def route_arguments(%Mutare.CallRouting.Call{name: :ignored_twin} = call),
      do: Mutare.CallRouting.ArgumentRoutes.new(call, [:lazy_expression])

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

  defmodule RenameToClassifiedLazy do
    @behaviour Mutare.Mutator
    alias Mutare.RebuiltCallDeliveryTest.DSL

    @impl Mutare.Mutator
    def name, do: :rename_to_classified_lazy

    @impl Mutare.Mutator
    def mutate(node) do
      case Mutare.Calls.resolved_call_to(node, DSL, :value) do
        {:ok, :value, args, rebuild} -> [rebuild.(:ignored_twin, args)]
        _ -> :skip
      end
    end
  end

  # The same replacement built without the offered call's meta — a mutator's own node, as a
  # `quote` in the mutator would produce — so it carries no stamp and no environment of its
  # own.
  defmodule RenameToLazyFresh do
    @behaviour Mutare.Mutator
    alias Mutare.RebuiltCallDeliveryTest.DSL

    @impl Mutare.Mutator
    def name, do: :rename_to_lazy_fresh

    @impl Mutare.Mutator
    def mutate(node) do
      case Mutare.Calls.resolved_call_to(node, DSL, :value) do
        {:ok, :value, args, _rebuild} ->
          path = DSL |> Module.split() |> Enum.map(&String.to_atom/1)
          [{{:., [], [{:__aliases__, [], path}, :ignored]}, [], args}]

        _ ->
          :skip
      end
    end
  end

  # `value(x)` → `x |> DSL.<target>()`: a freshly written pipe, its operand reused exactly.
  defmodule RenameToPipe do
    @behaviour Mutare.Mutator
    alias Mutare.RebuiltCallDeliveryTest.DSL

    @impl Mutare.Mutator
    def name, do: :rename_to_pipe

    @impl Mutare.Mutator
    def mutate(node, %{opts: opts}) do
      case Mutare.Calls.resolved_call_to(node, DSL, :value) do
        {:ok, :value, [argument], _rebuild} ->
          stage = {{:., [], [DSL, Keyword.fetch!(opts, :target)]}, [], []}
          [{:|>, [], [argument, stage]}]

        _ ->
          :skip
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

  # `value/1` carries no route (`Routes`); the cases above already run without one. These
  # pin the other ways the replacement's route is reached, and that a route on the written
  # call is not what reaches it.
  describe "a written call without a route, rebuilt into a routed one" do
    test "the replacement's classifier is asked, and its lazy answer honoured" do
      source = effect_fixture("input() |> #{@dsl}.value()")
      assert [_] = assert_patches(source, [RenameToClassifiedLazy], [run: []], @opts)
    end

    test "a replacement built without the offered call's meta is routed where it is patched" do
      source = effect_fixture("input() |> #{@dsl}.value()")
      assert [_] = assert_patches(source, [RenameToLazyFresh], [run: []], @opts)
    end

    test "control: the same fresh replacement, written as a direct call" do
      source = effect_fixture("#{@dsl}.value(input())")
      assert [_] = assert_patches(source, [RenameToLazyFresh], [run: []], @opts)
    end

    test "control: an explicit all-expression route on the written call changes nothing" do
      source = effect_fixture("input() |> #{@dsl}.value()")
      opts = Keyword.put(@opts, :call_routes, [{DSL, :value, 1, [:expression]}])
      assert [_] = assert_patches(source, [RenameToLazy], [run: []], opts)
    end
  end

  describe "a replacement written as a fresh pipe" do
    test "into a lazy callee: the stage is routed at its piped arity, and the operand not hoisted" do
      source = effect_fixture("input() |> #{@dsl}.value()")
      assert [_] = assert_patches(source, [{RenameToPipe, target: :ignored}], [run: []], @opts)
    end

    test "into a classified lazy callee: the classifier is asked at the piped arity" do
      source = effect_fixture("input() |> #{@dsl}.value()")

      assert [_] =
               assert_patches(source, [{RenameToPipe, target: :ignored_twin}], [run: []], @opts)
    end

    test "control: a fresh pipe into an eager callee still runs its operand" do
      source = effect_fixture("input() |> #{@dsl}.value()")

      assert [_] =
               assert_patches(source, [{RenameToPipe, target: :eager_twin}], [run: []], @opts)
    end

    test "control: a fresh pipe replacing a call written directly" do
      source = effect_fixture("#{@dsl}.value(input())")
      assert [_] = assert_patches(source, [{RenameToPipe, target: :ignored}], [run: []], @opts)
    end

    test "Resolve.reroute/2 makes the fresh pipe the direct call it is sugar for" do
      registry = Registry.build([], [], [Routes])
      call = "Elixir.Mutare.RebuiltCallDeliveryTest.DSL.value(input())"
      node = call |> Sourceror.parse_string!() |> Resolve.annotate(registry)
      [mutant] = RenameToPipe.mutate(node, %{opts: [target: :ignored]})

      rerouted = Resolve.reroute(mutant, node)

      assert {_module, :ignored, [operand], _rebuild} = Mutare.Calls.resolved_call(rerouted)
      assert {_module, :value, [^operand], _rebuild} = Mutare.Calls.resolved_call(node)
      assert Mutare.Calls.routed_treatments(rerouted) == [:lazy_expression]
      assert is_list(Mutare.Transform.Meta.written_pipe_meta(rerouted))
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
