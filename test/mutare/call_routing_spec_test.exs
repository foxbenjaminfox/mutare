defmodule Mutare.CallRouting.SpecGrammarTest do
  # The route grammar's new words: the call-level `:skip` (bare only), `:raw`, `:interior`, and
  # keyed refinements — their normalization, their tiering, and the pointed errors a mistake gets.
  use ExUnit.Case, async: true

  alias Mutare.CallRouting.{ArgumentRoutes, Call, Registry, Spec}

  describe "the call-level :skip" do
    test "is accepted bare and reported by skip?/1 and routing/2" do
      spec = Spec.new(Mixpanel, :track, 3, :skip)
      assert spec.args == :skip
      assert Spec.skip?(spec)
      assert Spec.routing(spec, 3) == :skip
      refute Spec.host_required?(spec)
      refute Spec.adapter_graded?(spec)
      refute Spec.skip?(Spec.new(Mixpanel, :track, 3, :raw))
    end

    test "inside a per-position list it is rejected with a message naming :raw" do
      assert_raise ArgumentError, ~r/to leave one argument as written, use :raw/, fn ->
        Spec.new(MyApp.Schema, :field, 2, [:expression, :skip])
      end

      assert_raise ArgumentError, ~r/use :raw/, fn ->
        Spec.new(Foo, :set, 2, [:expression, {:keyword, [:skip]}])
      end

      assert_raise ArgumentError, ~r/use :raw/, fn ->
        Spec.new(Foo, :get, 2, [:expression, [timeout: :skip]])
      end
    end

    test "is accepted from configuration (user tier), like :raw and :interior" do
      registry =
        Registry.build(
          [
            {Mixpanel, :track, 3, :skip},
            {Ecto.Query, :from, :raw},
            {MyApp, :render, 2, [:expression, :interior]},
            {MyApp, :get, 2, [:expression, [timeout: :raw]]}
          ],
          []
        )

      assert %{spec: %Spec{args: :skip}} = Registry.lookup(registry, [:Mixpanel], :track, 3)
      assert %{spec: %Spec{args: :raw}} = Registry.lookup(registry, [:Ecto, :Query], :from, 2)

      assert %{spec: %Spec{args: [:expression, :interior]}} =
               Registry.lookup(registry, [:MyApp], :render, 2)
    end

    test "a keyed refinement with an adapter-grade value is still rejected from configuration" do
      assert_raise ArgumentError, ~r/adapter-grade/, fn ->
        Registry.build([{MyApp, :get, 2, [:expression, [x: :interpolated]]}], [])
      end
    end
  end

  describe "keyed refinements" do
    test "normalize to {:keyed, leading, pairs}, the leading treatment defaulting to :expression" do
      assert Spec.normalize_position!(timeout: :raw) == {:keyed, :expression, [timeout: :raw]}

      assert Spec.normalize_position!([:raw, limit: :expression]) ==
               {:keyed, :raw, [limit: :expression]}

      assert Spec.new(MyApp, :get, 2, [:expression, [timeout: :raw]]).args ==
               [:expression, {:keyed, :expression, [timeout: :raw]}]
    end

    test "nest, and round-trip back to the author form" do
      normalized = Spec.normalize_position!(retry: [max_retries: :raw])

      assert normalized ==
               {:keyed, :expression, [retry: {:keyed, :expression, [max_retries: :raw]}]}

      assert Spec.author_position(normalized) == [
               :expression,
               retry: [:expression, max_retries: :raw]
             ]
    end

    test "reject an empty list, a refinement with no keys, a non-atom key, and a duplicate key" do
      assert_raise ArgumentError, ~r/empty list is not a position/, fn ->
        Spec.normalize_position!([])
      end

      assert_raise ArgumentError, ~r/names at least one key/, fn ->
        Spec.normalize_position!([:expression])
      end

      assert_raise ArgumentError, ~r/atom-keyed pairs/, fn ->
        Spec.normalize_position!([:expression, :raw])
      end

      assert_raise ArgumentError, ~r/atom-keyed pairs/, fn ->
        Spec.normalize_position!([{"timeout", :raw}])
      end

      assert_raise ArgumentError, ~r/each key once/, fn ->
        Spec.normalize_position!(timeout: :raw, timeout: :expression)
      end
    end

    test "are tiered by their contents" do
      refute Spec.adapter_graded?(Spec.new(M, :f, 2, [:expression, [timeout: :raw]]))
      assert Spec.adapter_graded?(Spec.new(M, :f, 2, [:expression, [x: :interpolated]]))
      assert Spec.host_required?(Spec.new(M, :f, 2, [:expression, [x: :hosted]]))
      refute Spec.host_required?(Spec.new(M, :f, 2, [:expression, [x: :raw]]))
    end

    test "are normalized by the ArgumentRoutes constructors and validator alike" do
      call = %Call{
        node: {:f, [], [{:q, [], nil}, [timeout: 5]]},
        module: M,
        name: :f,
        arguments: [{:q, [], nil}, [timeout: 5]],
        pipe_mode: :unpiped,
        effective_arity: 2,
        rebuild: fn _n, _a -> nil end
      }

      routes = ArgumentRoutes.from_visible(call, [:expression, [timeout: :raw]])

      assert ArgumentRoutes.visible(routes) == [
               :expression,
               {:keyed, :expression, [timeout: :raw]}
             ]

      forged = %ArgumentRoutes{visible: [:expression, [timeout: :raw]], piped: nil}
      assert {:ok, normalized} = ArgumentRoutes.validate(forged, call)

      assert ArgumentRoutes.visible(normalized) == [
               :expression,
               {:keyed, :expression, [timeout: :raw]}
             ]

      assert_raise ArgumentError, ~r/use :raw/, fn ->
        ArgumentRoutes.from_visible(call, [:expression, :skip])
      end

      assert {:error, _} =
               ArgumentRoutes.validate(
                 %ArgumentRoutes{visible: [:expression, :skip], piped: nil},
                 call
               )
    end
  end

  describe "structural heads (Mutare.Transform.StructuralForms)" do
    test "a structural form accepts :skip and nothing else" do
      assert Mutare.CallRouting.Spec.new(Kernel, :if, 2, :skip).args == :skip
      assert Mutare.CallRouting.Spec.new(Kernel.SpecialForms, :case, :any, :skip).args == :skip

      for args <- [:raw, [:raw, :expression], :routing, [:expression, [do: :raw]]] do
        assert_raise ArgumentError,
                     ~r/Kernel\.if is analyzed structurally.*accepts only :skip/,
                     fn -> Mutare.CallRouting.Spec.new(Kernel, :if, 2, args) end
      end

      assert_raise ArgumentError, ~r/Kernel\.SpecialForms\.case is analyzed structurally/, fn ->
        Mutare.CallRouting.Spec.new(Kernel.SpecialForms, :case, :any, :raw)
      end

      for name <- [:unless, :|>, :!, :not, :in, :and, :or, :&&, :||] do
        assert_raise ArgumentError, ~r/accepts only :skip/, fn ->
          Mutare.CallRouting.Spec.new(Kernel, name, :any, :raw)
        end
      end
    end

    test "a definition accepts no route at all, :skip included" do
      names = [:def, :defp, :defmacro, :defmacrop, :defmodule, :defimpl, :defprotocol]

      for name <- names ++ [:defdelegate, :use, :@], args <- [:skip, :raw] do
        assert_raise ArgumentError, ~r/is a definition, not a call/, fn ->
          Mutare.CallRouting.Spec.new(Kernel, name, :any, args)
        end
      end
    end

    test "every other Kernel export, and any wildcard, is an ordinary call" do
      alias Mutare.CallRouting.Spec

      assert %Spec{} = Spec.new(Kernel, :inspect, 2, [:expression, :raw])
      # The built-in route.
      assert %Spec{} = Spec.new(Kernel, :match?, 2, [:pattern])
      assert %Spec{} = Spec.new(Kernel, :+, 2, :skip)
      # Whole-module: its positions are declined per structural head at stamp time.
      assert %Spec{} = Spec.new(Kernel, :*, :any, :raw)
      # Name-only: may be a DSL's `if` under a displaced Kernel import.
      assert %Spec{} = Spec.new(:*, :if, 2, :raw)
    end
  end

  test "the treatment vocabulary is the argument words only" do
    assert Spec.treatments() == [
             :expression,
             :interior,
             :raw,
             :pattern,
             :binding_pattern,
             :hosted,
             :interpolated
           ]

    assert_raise ArgumentError, ~r/or :skip for the whole call/, fn ->
      Spec.new(Foo, :bar, 1, :bogus)
    end
  end
end
