defmodule Mutare.RoutedCallReadingTest do
  @moduledoc """
  How the binding readers read a routed call's arguments where core did not resolve them.

  Two shapes, each a delivery that a `mutare_ecto` query — a `having:` carrying a
  `subquery(from(…))`, a `from` with a clause dropped — once lost:

    * a **syntax region** (`:raw`, `:hosted`, a keyword value under either) is the enclosing
      route's claim that the position is the macro's syntax; a registered macro nested in it
      is read as that syntax too, its names possible writes and nothing more — never as a
      call whose binding effect is *unknown*, which withholds every selector around it;
    * a **rebuilt call** is routed again as the call it is before any reader meets it
      (`rebuilt_call_routing_test.exs`); a stamp a reader nonetheless finds not fitting its
      call — a static positional route over another pair count or arity — is read as nothing.
  """
  use ExUnit.Case, async: true

  import Mutare.Test.SourcePatch, only: [assert_patches: 4]

  alias Mutare.CallRouting.Registry
  alias Mutare.Transform.{BindingEscapeEmit, Bindings, KeywordRouting, Resolve}

  # `Mutare.Test.QueryDSL.unpack/2` routed through a classifier: the positions
  # `Mutare.Test.UnpackMutator` declares statically, obtained per call.
  defmodule ClassifiedUnpack do
    @behaviour Mutare.Mutator
    @behaviour Mutare.CallRouting

    @impl Mutare.Mutator
    def name, do: :classified_unpack

    @impl Mutare.Mutator
    def mutate(_node), do: :skip

    @impl Mutare.CallRouting
    def call_routes, do: [{Mutare.Test.QueryDSL, :unpack, 2, :routing}]

    @impl Mutare.CallRouting
    def route_arguments(call),
      do: Mutare.CallRouting.ArgumentRoutes.new(call, [:binding_pattern, :expression])
  end

  # `set(query, a: …, b: …)` → `set(query, b: …)`: a whole-call rewrite that drops a keyword
  # pair from a `{:keyword, …}`-routed argument, rebuilt through core's own `rebuild` — which
  # reuses the offered call's meta, its per-pair routing stamp included.
  defmodule DropPair do
    @behaviour Mutare.Mutator

    alias Mutare.CallRouting.Call

    @impl Mutare.Mutator
    def name, do: :drop_pair

    @impl Mutare.Mutator
    def mutate(node) do
      case Mutare.Calls.resolved_routed_call(node) do
        %Call{name: :set, arguments: [query, [_first | rest]], rebuild: rebuild}
        when rest != [] ->
          [rebuild.(:set, [query, rest])]

        _other ->
          :skip
      end
    end
  end

  @where_raw [
    call_routes: [{Mutare.Test.QueryDSL, :where, 2, [:expression, :raw]}],
    clean_functions: false
  ]

  describe "a classifier nested in a syntax region is read as syntax" do
    # `where/2` expands to its query; the raw condition, `unpack` included, never runs. The
    # `div` around it carries the arithmetic mutants, and its subtree holds a classifier core
    # did not invoke — which must not withhold them.
    test "inside a static :raw position, the enclosing selector is delivered" do
      source = """
      defmodule Fixture do
        import Mutare.Test.QueryDSL

        def run(xs), do: div(where(length(xs), unpack([n], [8])), 2)
      end
      """

      sites =
        assert_patches(source, [:arithmetic, ClassifiedUnpack], [run: [[1, 2, 3, 4]]], @where_raw)

      assert Enum.any?(sites, &(&1.mutator == :arithmetic))
    end

    # `filter/2`'s comparison condition is `:hosted` (`Mutare.Test.HostMutator`); the
    # classifier sits inside the fragment the host weaves.
    test "inside a :hosted position, the enclosing selector and the weave are both delivered" do
      source = """
      defmodule Fixture do
        import Mutare.Test.HostDSL
        import Mutare.Test.QueryDSL

        def run(xs), do: div(length(filter(xs, 1 < length(unpack([n], [8])))), 2)
      end
      """

      sites =
        assert_patches(
          source,
          [:arithmetic, Mutare.Test.HostMutator, ClassifiedUnpack],
          [run: [[1, 2, 3, 4]]],
          clean_functions: false
        )

      assert Enum.any?(sites, &(&1.mutator == :arithmetic))
      assert Enum.any?(sites, &(&1.mutator == :host_filter))
    end

    # `set/2`'s non-string keyword values are routed `:raw` under `{:keyword, …}`.
    test "inside a raw keyword value, the enclosing selector is delivered" do
      source = """
      defmodule Fixture do
        import Mutare.Test.HostDSL
        import Mutare.Test.QueryDSL

        def run(xs), do: div(elem(set(length(xs), a: length(unpack([n], [8]))), 0), 2)
      end
      """

      sites =
        assert_patches(
          source,
          [:arithmetic, Mutare.Test.HostMutator, ClassifiedUnpack],
          [run: [[1, 2, 3, 4]]],
          clean_functions: false
        )

      assert Enum.any?(sites, &(&1.mutator == :arithmetic))
    end

    test "its names are possible writes, and its effect is not unknown" do
      routes = [{Mutare.Test.QueryDSL, :where, 2, [:expression, :raw]}]

      tree =
        resolved(
          "div(Mutare.Test.QueryDSL.where(xs, Mutare.Test.QueryDSL.unpack([n], [8])), 2)",
          routes,
          [ClassifiedUnpack]
        )

      refute Bindings.unknown_routing?(tree)
      assert :n in Bindings.matched_names(tree)
      assert BindingEscapeEmit.expression_bindings(tree) == []
    end

    # The contrast: under a skipped call the arguments are ordinary Elixir that runs, and a
    # classifier the skip withheld leaves what it binds unreadable.
    test "control: inside a skipped call's argument the same classifier is unknown" do
      routes = [{Kernel, :hd, 1, :skip}]

      tree =
        resolved("div(hd(Mutare.Test.QueryDSL.unpack([n], [8])), 2)", routes, [ClassifiedUnpack])

      assert Bindings.unknown_routing?(tree)
    end
  end

  describe "a stamp that does not fit its call is read as nothing" do
    test "a whole-call mutant that drops a pair from a {:keyword, …} argument is delivered" do
      source = """
      defmodule Fixture do
        import Mutare.Test.HostDSL

        def run(xs), do: set(xs, a: "x", b: "y")
      end
      """

      sites =
        assert_patches(source, [DropPair, Mutare.Test.HostMutator], [run: [[1]]],
          clean_functions: false
        )

      assert [%{mutator: :drop_pair, mutated_code: ~s|set(xs, b: "y")|}] =
               Enum.filter(sites, &(&1.mutator == :drop_pair))
    end

    test "a positional stamp at another arity guarantees nothing" do
      routes = [{Mutare.Test.QueryDSL, :unpack, 2, [:binding_pattern, :expression]}]
      {head, meta, _args} = resolved("Mutare.Test.QueryDSL.unpack([n], [8])", routes)

      assert BindingEscapeEmit.expression_bindings({head, meta, [[{:n, [], nil}], [8]]}) == [:n]

      assert BindingEscapeEmit.expression_bindings({head, meta, [[{:n, [], nil}]]}) == []
    end

    test "the decoder reads a pair count the stamp no longer fits as no route" do
      arg = Sourceror.parse_string!("[a: 1]")
      assert KeywordRouting.decode(arg, {:keyword, [:raw, :raw]}) == {:whole, :raw}
    end
  end

  defp resolved(expression, routes, providers \\ []) do
    registry = Registry.build(routes, [], providers)
    expression |> Sourceror.parse_string!() |> Resolve.annotate(registry)
  end
end
