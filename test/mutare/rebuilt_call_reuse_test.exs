defmodule Mutare.RebuiltCallReuseTest do
  @moduledoc """
  A replacement's walk returns a node as it is only where the node was resolved, and
  resolved in the environment now in force — not wherever the term happens to occur in the
  offered node.

  Two ways the weaker reading (any subtree of the offered node is "already resolved") went
  wrong, both false survivors the source patch would have killed:

  A subtree the offered call's route kept as syntax — the `:raw` argument of `keep(value,
  _syntax)` — was never resolved, so it carries no route. A mutator that returns that
  subtree makes it executable source, and the walk must resolve it there for the first
  time: `DSL.ignored(p = 7)` is a routed macro that discards its argument, and a reader
  that takes it as an ordinary call credits the write `p = 7` the macro never makes.

  A call the walk did resolve can be moved beneath a directive that changes what it
  resolves to. `alias Discard, as: Local; Local.value(p = 6)` wraps the offered
  `Local.value(p = 6)` — the identical term — in a block whose alias shadows the file's,
  and the compiler resolves the patch by the new alias. The walk must too: the retained
  environment says `Eager.value/1`, an ordinary function, where the call is now the macro
  `Discard.value/1`.

  The end-to-end tests accept either faithful delivery or a withheld mutant; the unit tests
  pin what the rerouted node reads as. Each hazard has a control that reaches the same
  source through fresh syntax (a reparsed copy of the same term), which the walk always
  resolved — the difference between hazard and control is provenance alone.
  """
  use ExUnit.Case, async: true

  import Mutare.Test.SourcePatch, only: [assert_patches: 4]

  alias Mutare.CallRouting.Registry
  alias Mutare.Transform.{BindingEscapeEmit, Resolve}

  defmodule DSL do
    # Splices `value` into the caller; the second argument is syntax the macro discards.
    defmacro keep(value, _syntax), do: value
    defmacro ignored(_expression), do: 6
  end

  defmodule Eager do
    def value(value), do: value
  end

  defmodule Discard do
    defmacro value(_expression), do: 6
  end

  # `keep(first, second)` → `second`: the raw argument, made executable. With `reparse:`
  # the same source through fresh syntax.
  defmodule SelectSecond do
    @behaviour Mutare.Mutator
    alias Mutare.RebuiltCallReuseTest.DSL

    @impl Mutare.Mutator
    def name, do: :select_second

    @impl Mutare.Mutator
    def mutate(node, %{opts: opts}) do
      case Mutare.Calls.resolved_call_to(node, DSL, :keep) do
        {:ok, :keep, [_first, second], _rebuild} -> [maybe_reparse(second, opts)]
        _other -> :skip
      end
    end

    def maybe_reparse(node, opts) do
      if Keyword.get(opts, :reparse, false),
        do: node |> Macro.to_string() |> Code.string_to_quoted!(),
        else: node
    end
  end

  # `Local.value(e)` → `(alias Discard, as: Local; Local.value(e))`: the offered call, the
  # identical term, beneath an alias that changes its callee.
  defmodule ShadowAlias do
    @behaviour Mutare.Mutator
    alias Mutare.RebuiltCallReuseTest.{Discard, Eager, SelectSecond}

    @impl Mutare.Mutator
    def name, do: :shadow_alias

    @impl Mutare.Mutator
    def mutate(node, %{opts: opts}) do
      case Mutare.Calls.resolved_call_to(node, Eager, :value) do
        {:ok, :value, _arguments, _rebuild} ->
          directive = Code.string_to_quoted!("alias #{inspect(Discard)}, as: Local")
          [{:__block__, [], [directive, SelectSecond.maybe_reparse(node, opts)]}]

        _other ->
          :skip
      end
    end
  end

  # `ignored/1` through a classifier, so the test can see whether one was asked.
  defmodule ClassifiedIgnored do
    @behaviour Mutare.CallRouting
    alias Mutare.RebuiltCallReuseTest.DSL

    @impl Mutare.CallRouting
    def call_routes, do: [{DSL, :ignored, 1, :routing}]

    @impl Mutare.CallRouting
    def route_arguments(call) do
      send(self(), {__MODULE__, :classified})
      Mutare.CallRouting.ArgumentRoutes.new(call, [:lazy_expression])
    end
  end

  @dsl inspect(DSL)
  @eager inspect(Eager)
  @discard inspect(Discard)

  @syntax_routes [{DSL, :keep, 2, [:expression, :raw]}, {DSL, :ignored, 1, [:lazy_expression]}]
  @syntax_opts [call_routes: @syntax_routes, clean_functions: false]

  @alias_routes [{Discard, :value, 1, [:lazy_expression]}]
  @alias_opts [call_routes: @alias_routes, clean_functions: false]

  # Original `{[8, 6], false}`: `keep` splices `p = 6`. Selecting the raw argument gives
  # `{[8, 6], true}`: `ignored` discards `p = 7`, and the sibling's `p = 8` is the outgoing
  # binding — a write the mutant drops, which no branch may export over.
  @syntax_source """
  defmodule Fixture do
    require #{@dsl}

    def run do
      p = :incoming
      values = [p = 8, #{@dsl}.keep(p = 6, #{@dsl}.ignored(p = 7))]
      {values, p == 8}
    end
  end
  """

  # Original `{[8, 6], false}`: `Local` is `Eager`. Under the shadowing alias `Local.value`
  # is the macro that discards `p = 6`, so the patch gives `{[8, 6], true}`.
  @alias_source """
  defmodule Fixture do
    alias #{@eager}, as: Local
    require #{@discard}

    def run do
      p = :incoming
      values = [p = 8, Local.value(p = 6)]
      {values, p == 8}
    end
  end
  """

  defp resolve(expression, routes, extensions \\ []) do
    registry = Registry.build(routes, [], extensions)
    expression |> Sourceror.parse_string!() |> Resolve.annotate(registry)
  end

  defp keep_call(routes \\ @syntax_routes, extensions \\ []),
    do: resolve("#{@dsl}.keep(p = 6, #{@dsl}.ignored(p = 7))", routes, extensions)

  defp aliased_call do
    {:__block__, _meta, [_directive, call]} =
      resolve("alias #{@eager}, as: Local\nLocal.value(p = 6)", @alias_routes)

    call
  end

  describe "a raw argument a mutant makes executable" do
    test "is resolved there for the first time: routed, and read by its route" do
      {_head, _meta, [_first, raw]} = original = keep_call()
      assert Mutare.Calls.routed_treatments(raw) == nil
      assert BindingEscapeEmit.expression_bindings(raw) == [:p]

      rerouted = Resolve.reroute(raw, original)
      assert Mutare.Calls.routed_treatments(rerouted) == [:lazy_expression]
      assert BindingEscapeEmit.expression_bindings(rerouted) == []
    end

    test "has its destination's classifier asked, which its raw position never did" do
      {_head, _meta, [_first, raw]} =
        original = keep_call([{DSL, :keep, 2, [:expression, :raw]}], [ClassifiedIgnored])

      refute_received {ClassifiedIgnored, :classified}

      rerouted = Resolve.reroute(raw, original)
      assert_received {ClassifiedIgnored, :classified}
      assert Mutare.Calls.routed_treatments(rerouted) == [:lazy_expression]
    end

    test "behaves as the patch that makes it executable" do
      assert_patches(@syntax_source, [SelectSecond], [run: []], @syntax_opts)
    end

    test "control: the same source through fresh syntax is withheld for the dropped write" do
      assert [] =
               assert_patches(
                 @syntax_source,
                 [{SelectSecond, reparse: true}],
                 [run: []],
                 @syntax_opts
               )
    end
  end

  describe "a resolved call a mutant moves beneath a fresh alias" do
    test "is resolved again by that alias" do
      original = aliased_call()
      assert {:ok, :value, _args, _rebuild} = Mutare.Calls.resolved_call_to(original, Eager)

      directive = Code.string_to_quoted!("alias #{@discard}, as: Local")

      {:__block__, _meta, [_directive, call]} =
        Resolve.reroute({:__block__, [], [directive, original]}, original)

      assert {:ok, :value, _args, _rebuild} = Mutare.Calls.resolved_call_to(call, Discard)
      assert Mutare.Calls.routed_treatments(call) == [:lazy_expression]
      assert BindingEscapeEmit.expression_bindings(call) == []
    end

    test "behaves as its patch" do
      assert_patches(@alias_source, [ShadowAlias], [run: []], @alias_opts)
    end

    test "control: the same source through fresh syntax is withheld for the dropped write" do
      assert [] =
               assert_patches(
                 @alias_source,
                 [{ShadowAlias, reparse: true}],
                 [run: []],
                 @alias_opts
               )
    end

    test "control: in the environment it was resolved in, it is the identical term" do
      original = aliased_call()
      assert Resolve.reroute(original, original) == original

      # Beneath a block that changes nothing it resolves by, too.
      {:__block__, _meta, [call]} = Resolve.reroute({:__block__, [], [original]}, original)
      assert call == original
    end
  end
end
