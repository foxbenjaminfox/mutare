defmodule Mutare.RebuiltCallRoutingTest do
  @moduledoc """
  A call a mutator rebuilt is routed as the call it is.

  `rebuild` reuses the offered call's meta, its routing stamp included. That stamp was the
  route's answer for the *written* call, and a classifier reads more than cardinality: a
  keyword's name, a value, the callee. A rebuilt call whose arity and pair count still fit
  the stamp can therefore carry a stamp that is false for it — `value(eval: (p = 6))`, whose
  classifier routes the `eval:` value `:expression`, rebuilt as `value(quoted: (p = 6))`,
  which the macro discards. Read by the stale stamp, the mutant branch is credited with the
  write `p = 6` it never makes, and the delivery that depends on that claim diverges from
  the mutant's own source patch — a false survivor. So core routes every stamped call in a
  mutant again where the mutant enters it (`Mutare.Transform.Resolve.reroute/1`, from
  `Mutare.Transform.Analyze.Attach.build_candidates/2`): the registry's answer for the
  rebuilt head and arity, the classifier invoked on the rebuilt arguments, no route where
  nothing matches — and an unchanged call comes back as the identical term.

  The fixture: `p` is bound on entry, an earlier sibling (`p = 8`) writes it — so the
  incoming value is not exportable — and `p == 8` reads it after. The original's macro call
  writes `p` too, so a branch that does not cannot be delivered faithfully, and the only
  correct outcome for such a mutant is to withhold it. The controls hold the outcome fixed
  where the shape changes (a dropped pair, a keyed route) and show the same mutant delivered
  where nothing conflicts.
  """
  use ExUnit.Case, async: true

  import Mutare.Test.SourcePatch, only: [assert_patches: 4]

  alias Mutare.CallRouting.Registry
  alias Mutare.Transform.{BindingEscapeEmit, Resolve}

  defmodule DSL do
    # Splices the expression under `eval:` into the caller; every other option is syntax
    # the macro discards.
    defmacro value(options), do: Keyword.get(options, :eval, 6)
    defmacro ignored(_options), do: 6
  end

  defmodule Keys do
    def atom({:__block__, _meta, [key]}) when is_atom(key), do: key
    def atom(key) when is_atom(key), do: key
    def atom(_other), do: nil

    def rename({:__block__, meta, [_old]}, name), do: {:__block__, meta, [name]}
    def rename(_old, name), do: name
  end

  # `value/1` routed through a classifier that reads the keyword *names*; `ignored/1` static.
  defmodule ShapeRoute do
    @behaviour Mutare.CallRouting
    alias Mutare.RebuiltCallRoutingTest.{DSL, Keys}

    @impl Mutare.CallRouting
    def call_routes, do: [{DSL, :value, 1, :routing}, {DSL, :ignored, 1, :raw}]

    @impl Mutare.CallRouting
    def route_arguments(%Mutare.CallRouting.Call{arguments: [pairs]} = call) do
      treatments =
        Enum.map(pairs, fn {key, _value} ->
          if Keys.atom(key) == :eval, do: :expression, else: :raw
        end)

      Mutare.CallRouting.ArgumentRoutes.new(call, [{:keyword, treatments}])
    end
  end

  # `value(eval: e, …)` → `value(quoted: e, …)`: the same pair count, another classification.
  defmodule RenameKeyword do
    @behaviour Mutare.Mutator
    alias Mutare.RebuiltCallRoutingTest.{DSL, Keys}

    @impl Mutare.Mutator
    def name, do: :rename_eval_keyword

    @impl Mutare.Mutator
    def mutate(node) do
      case Mutare.Calls.resolved_call_to(node, DSL, :value) do
        {:ok, :value, [pairs], rebuild} when is_list(pairs) ->
          changed =
            Enum.map(pairs, fn {key, value} ->
              if Keys.atom(key) == :eval,
                do: {Keys.rename(key, :quoted), value},
                else: {key, value}
            end)

          if changed == pairs, do: :skip, else: [rebuild.(:value, [changed])]

        _other ->
          :skip
      end
    end
  end

  # `value(…)` → `ignored(…)`: the same arity, another route.
  defmodule RenameCallee do
    @behaviour Mutare.Mutator
    alias Mutare.RebuiltCallRoutingTest.DSL

    @impl Mutare.Mutator
    def name, do: :rename_value_callee

    @impl Mutare.Mutator
    def mutate(node) do
      case Mutare.Calls.resolved_call_to(node, DSL, :value) do
        {:ok, :value, arguments, rebuild} -> [rebuild.(:ignored, arguments)]
        _other -> :skip
      end
    end
  end

  # `value(eval: e, raw: 0)` → `value(raw: 0)`: another pair count.
  defmodule DropPair do
    @behaviour Mutare.Mutator
    alias Mutare.RebuiltCallRoutingTest.{DSL, Keys}

    @impl Mutare.Mutator
    def name, do: :drop_eval_pair

    @impl Mutare.Mutator
    def mutate(node) do
      case Mutare.Calls.resolved_call_to(node, DSL, :value) do
        {:ok, :value, [pairs], rebuild} when is_list(pairs) ->
          kept = Enum.reject(pairs, fn {key, _value} -> Keys.atom(key) == :eval end)
          if kept == pairs, do: :skip, else: [rebuild.(:value, [kept])]

        _other ->
          :skip
      end
    end
  end

  @opts [extensions: [ShapeRoute], clean_functions: false]

  # Original: `{[8, 6], false}`. With `eval:` renamed or the callee swapped, the macro no
  # longer writes `p`, the sibling's `p = 8` stands, and the source patch gives `{[8, 6], true}`.
  @source """
  defmodule Fixture do
    require Elixir.Mutare.RebuiltCallRoutingTest.DSL

    def run do
      p = :incoming
      values = [
        p = 8,
        Elixir.Mutare.RebuiltCallRoutingTest.DSL.value(eval: (p = 6), raw: 0)
      ]
      {values, p == 8}
    end
  end
  """

  describe "a rebuilt call whose classification changed at the same shape" do
    test "a renamed keyword: the mutant is withheld, not delivered by the stale stamp" do
      assert [] = assert_patches(@source, [RenameKeyword], [run: []], @opts)
    end

    test "a renamed callee: the mutant is withheld, not delivered by the stale stamp" do
      assert [] = assert_patches(@source, [RenameCallee], [run: []], @opts)
    end
  end

  describe "controls" do
    test "a dropped pair is withheld the same way" do
      assert [] = assert_patches(@source, [DropPair], [run: []], @opts)
    end

    test "a keyed route follows the renamed key, and the mutant is withheld" do
      opts = Keyword.put(@opts, :call_routes, [{DSL, :value, 1, [[:raw, eval: :expression]]}])
      assert [] = assert_patches(@source, [RenameKeyword], [run: []], opts)
    end

    test "with no conflicting sibling write, the same mutant is delivered" do
      source = """
      defmodule Fixture do
        require Elixir.Mutare.RebuiltCallRoutingTest.DSL

        def run do
          p = :incoming
          value = Elixir.Mutare.RebuiltCallRoutingTest.DSL.value(eval: (p = 6), raw: 0)
          {value, p}
        end
      end
      """

      sites = assert_patches(source, [RenameKeyword], [run: []], @opts)
      assert [%{mutator: :rename_eval_keyword}] = sites
    end
  end

  describe "Resolve.reroute/1" do
    @call "Elixir.Mutare.RebuiltCallRoutingTest.DSL.value(eval: (p = 6), raw: 0)"

    setup do
      registry = Registry.build([], [], [ShapeRoute])
      node = @call |> Sourceror.parse_string!() |> Resolve.annotate(registry)
      {_module, :value, [pairs], rebuild} = Mutare.Calls.resolved_call(node)
      %{node: node, pairs: pairs, rebuild: rebuild}
    end

    test "an unchanged call is the identical term", %{node: node} do
      assert Mutare.Calls.routed_treatments(node) == [{:keyword, [:expression, :raw]}]
      assert Resolve.reroute(node) == node
    end

    test "a renamed keyword is classified again, and read by the new stamp", ctx do
      [{key, value}, raw] = ctx.pairs
      stale = ctx.rebuild.(:value, [[{Keys.rename(key, :quoted), value}, raw]])

      assert BindingEscapeEmit.expression_bindings(stale) == [:p]

      rerouted = Resolve.reroute(stale)
      assert Mutare.Calls.routed_treatments(rerouted) == [{:keyword, [:raw, :raw]}]
      assert BindingEscapeEmit.expression_bindings(rerouted) == []
    end

    test "a renamed callee takes its own route", ctx do
      rerouted = Resolve.reroute(ctx.rebuild.(:ignored, [ctx.pairs]))

      assert Mutare.Calls.routed_treatments(rerouted) == [:raw]

      assert %Mutare.CallRouting.Call{name: :ignored} =
               Mutare.Calls.resolved_routed_call(rerouted)

      assert BindingEscapeEmit.expression_bindings(rerouted) == []
    end

    test "a callee no route matches carries none", ctx do
      rerouted = Resolve.reroute(ctx.rebuild.(:other, [ctx.pairs]))

      assert Mutare.Calls.routed_treatments(rerouted) == nil
      assert Mutare.Calls.resolved_routed_call(rerouted) == nil
    end

    test "a rebuilt call nested in a mutant is rerouted too", ctx do
      [{key, value}, raw] = ctx.pairs
      stale = ctx.rebuild.(:value, [[{Keys.rename(key, :quoted), value}, raw]])
      mutant = {:not, [], [stale]}

      {:not, [], [rerouted]} = Resolve.reroute(mutant)
      assert Mutare.Calls.routed_treatments(rerouted) == [{:keyword, [:raw, :raw]}]
    end
  end
end
