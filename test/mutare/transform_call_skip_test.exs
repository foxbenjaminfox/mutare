defmodule Mutare.TransformCallSkipTest do
  # The user-tier call-routing vocabulary beyond `:raw`: the call-level `:skip` (an inert leaf),
  # the `:interior` treatment (contents mutate, container doesn't), and keyed refinements
  # (`[leading, key: treatment, …]` over a literal keyword argument). Functions and macros alike —
  # routing keys on the resolved `{module, fun, arity}`, never on macro-ness. See NOTES "Call
  # routing: `:skip`, `:raw`, `:interior`, keyed refinements".
  use ExUnit.Case, async: true

  # A mutator that rewrites the *whole* `Mixpanel.track/3` call node — the head, not an argument.
  # Under `:raw` the node is still offered, so this fires; under `:skip` it must not.
  defmodule TrackMutator do
    @behaviour Mutare.Mutator

    @impl true
    def name, do: :track

    @impl true
    def mutate(node) do
      case Mutare.Calls.resolved_call_to(node, Mixpanel, :track) do
        {:ok, :track, args, rebuild} -> [rebuild.(:untrack, args)]
        :error -> :skip
      end
    end
  end

  @values [
    Mutare.Mutators.IntegerLiteral,
    Mutare.Mutators.StringLiteral,
    Mutare.Mutators.AtomLiteral,
    Mutare.Mutators.MapLiteral,
    Mutare.Mutators.List
  ]

  describe "the call-level :skip — an inert leaf" do
    @track_source """
    defmodule Demo do
      alias Mixpanel, as: MP
      import Mixpanel, only: [track: 3]

      def qualified(user), do: Mixpanel.track("signup", %{plan: 1 + 1}, distinct_id: user.id)
      def aliased(user), do: MP.track("aliased", %{n: 2}, [])
      def bare(user), do: track("bare", %{n: 3}, [])
      def piped(user), do: user |> Mixpanel.track("piped", %{n: 4})
      def control(x), do: x + 1
    end
    """

    test "every mutant inside the call is gone, in every written form (qualified, aliased, imported, piped)" do
      {meta, sites, _} =
        Mutare.Transform.transform_string_with_sites(@track_source,
          mutators: @values ++ [Mutare.Mutators.Arithmetic],
          call_routes: [{Mixpanel, :track, 3, :skip}]
        )

      # Only the control line's mutants remain: the arithmetic swap and the `1`.
      assert Enum.map(sites, & &1.line) |> Enum.uniq() == [9]
      assert :arithmetic in Enum.map(sites, & &1.mutator)
      assert {:ok, _} = Code.string_to_quoted(meta)
    end

    test "without the route the same calls mutate (the :skip is doing the work)" do
      {_meta, sites, _} =
        Mutare.Transform.transform_string_with_sites(@track_source, mutators: @values)

      assert Enum.any?(sites, &(&1.original_code == ~s("signup")))
      assert Enum.any?(sites, &(&1.original_code == ~s("piped")))
    end

    test "a whole-module wildcard :skip covers every function of the module" do
      {_meta, sites, _} =
        Mutare.Transform.transform_string_with_sites(@track_source,
          mutators: @values,
          call_routes: [{Mixpanel, :*, :skip}]
        )

      assert Enum.map(sites, & &1.line) |> Enum.uniq() == [9]
    end

    test ":skip suppresses the whole-node offer that :raw keeps" do
      source = """
      defmodule Offer do
        def f(u), do: Mixpanel.track(u, "e", %{})
      end
      """

      {_meta, raw_sites, _} =
        Mutare.Transform.transform_string_with_sites(source,
          mutators: [TrackMutator],
          call_routes: [{Mixpanel, :track, 3, :raw}]
        )

      # `:raw` leaves the arguments alone but still offers the call node: the head rewrite fires.
      assert [%{mutator: :track, mutated_code: mutated}] = raw_sites
      assert mutated =~ "untrack"

      {_meta, skip_sites, _} =
        Mutare.Transform.transform_string_with_sites(source,
          mutators: [TrackMutator],
          call_routes: [{Mixpanel, :track, 3, :skip}]
        )

      assert skip_sites == []
    end

    test "a piped receiver is a sibling of the skipped call, not part of it — its mutants survive" do
      # `Repo.insert!(u) |> Mixpanel.track(…)`: the receiver flows *into* the skipped call but is
      # written outside it. Skipping the call must not silently drop the receiver's mutants.
      source = """
      defmodule Piped do
        def f(x), do: (x + 1) |> Mixpanel.track("e", %{n: 2})
        def g(x), do: Mixpanel.track(x + 1, "e", %{n: 2})
      end
      """

      {meta, sites, _} =
        Mutare.Transform.transform_string_with_sites(source,
          mutators: [Mutare.Mutators.Arithmetic, Mutare.Mutators.IntegerLiteral],
          call_routes: [{Mixpanel, :track, 3, :skip}]
        )

      # Line 2: the piped `x + 1` mutates (arithmetic swap + the `1`); nothing from inside the
      # parentheses (`"e"`, `2`). Line 3: the same expression *inside* the parentheses is interior
      # to the leaf, so nothing at all.
      assert Enum.map(sites, & &1.line) |> Enum.uniq() == [2]
      assert Enum.any?(sites, &(&1.mutator == :arithmetic))
      refute Enum.any?(sites, &(&1.original_code == "2"))
      assert_compiles(meta)
    end

    test "a skipped call in tail position keeps its return-value mutants (a mutation of the function)" do
      source = """
      defmodule Tail do
        def f(u), do: Mixpanel.track(u, "e", %{})
      end
      """

      {meta, sites, _} =
        Mutare.Transform.transform_string_with_sites(source,
          mutators: @values ++ [Mutare.Mutators.ReturnValue],
          call_routes: [{Mixpanel, :track, 3, :skip}]
        )

      assert sites != []
      assert Enum.all?(sites, &(&1.mutator == :return_value))
      assert_compiles(meta)
    end

    test "a macro is skipped the same way — routing keys on the resolved call, not on macro-ness" do
      source = """
      defmodule SkippedMacro do
        import Mutare.Test.QueryDSL

        def run(q), do: query([q, 1 + 1, "x"])
      end
      """

      {meta, sites, _} =
        Mutare.Transform.transform_string_with_sites(source,
          mutators: [
            Mutare.Mutators.Arithmetic,
            Mutare.Mutators.StringLiteral,
            Mutare.Test.QueryMutator
          ],
          call_routes: [{Mutare.Test.QueryDSL, :query, 1, :skip}]
        )

      # `QueryMutator` registers `query/1` as `:raw` and rewrites the whole call — the config
      # `:skip` for the same key overrides it, so neither core nor the mutator produces anything.
      assert sites == []
      assert_compiles(meta)
    end

    test "a skipped module-level block macro is left whole" do
      source = """
      defmodule UsesSchema do
        import Mutare.Test.SchemaDSL

        schema do
          field(:age, default: 1 + 1)
        end
      end
      """

      {meta, sites, _} =
        Mutare.Transform.transform_string_with_sites(source,
          mutators: [Mutare.Mutators.Arithmetic, Mutare.Mutators.IntegerLiteral],
          call_routes: [{Mutare.Test.SchemaDSL, :schema, 1, :skip}]
        )

      assert sites == []
      assert_compiles(meta)
    end

    test "routing is honoured in a guard too: a skipped guard call is inert, a :raw argument is left as written" do
      # The guard path (`Mutare.Transform.Tag`) offers nodes separately from the body path, so it
      # must read the same route stamp — otherwise a routed call in a `when` leaks mutants.
      body = "def f(x) when is_integer(123), do: x"

      for route <- [{Kernel, :is_integer, 1, :skip}, {Kernel, :is_integer, 1, [:raw]}] do
        {_m, sites, _} =
          Mutare.Transform.transform_string_with_sites("defmodule G do\n  #{body}\nend\n",
            mutators: [Mutare.Mutators.IntegerLiteral],
            call_routes: [route]
          )

        assert sites == [], "expected the guard literal held back under #{inspect(route)}"
      end

      # Not vacuous: unrouted, the guard literal mutates.
      {_m, plain, _} =
        Mutare.Transform.transform_string_with_sites("defmodule G do\n  #{body}\nend\n",
          mutators: [Mutare.Mutators.IntegerLiteral]
        )

      assert Enum.any?(plain, &(&1.original_code == "123"))
    end

    test "Mutare.Calls.routed_treatments/1 reports :skip for a skipped call" do
      node =
        "Mixpanel.track(u, \"e\", %{})"
        |> Sourceror.parse_string!()
        |> Mutare.Transform.Resolve.annotate(
          Mutare.CallRouting.Registry.build([{Mixpanel, :track, 3, :skip}], [])
        )

      assert Mutare.Calls.routed_treatments(node) == :skip

      assert %Mutare.CallRouting.Call{module: Mixpanel, name: :track} =
               Mutare.Calls.resolved_routed_call(node)
    end

    test "a configured :skip may displace an adapter's hosted route without a contract error" do
      # `Mutare.Test.HostMutator` routes `HostDSL.filter` shape-aware and hosts it. A user who
      # skips `filter` wholesale has made the host unreachable *on purpose*; that is not the
      # adapter's contract violation the reachability check exists to catch.
      source = """
      defmodule Displaced do
        import Mutare.Test.HostDSL

        def f(q, x), do: filter(q, x > 1)
      end
      """

      {meta, sites, _} =
        Mutare.Transform.transform_string_with_sites(source,
          mutators: [Mutare.Test.HostMutator, Mutare.Mutators.Relational],
          call_routes: [{Mutare.Test.HostDSL, :filter, :any, :skip}]
        )

      assert sites == []
      assert_compiles(meta)
    end
  end

  describe "the :interior treatment — contents mutate, the container doesn't" do
    test "a map argument keeps its value mutants but loses its own collapse" do
      source = """
      defmodule Assigns do
        def f(conn), do: MyApp.render(conn, %{a: 1, b: [2]})
      end
      """

      {meta, sites, _} =
        Mutare.Transform.transform_string_with_sites(source,
          mutators: [
            Mutare.Mutators.MapLiteral,
            Mutare.Mutators.IntegerLiteral,
            Mutare.Mutators.List
          ],
          call_routes: [{MyApp, :render, 2, [:expression, :interior]}]
        )

      triples = for s <- sites, do: {s.mutator, s.original_code, s.mutated_code}

      # The map's own collapse is gone…
      refute Enum.any?(triples, fn {m, _o, _} -> m == :map end)
      # …while its values mutate, including a nested container's own collapse (a descendant).
      assert {:integer, "1", "0"} in triples
      assert {:integer, "2", "0"} in triples
      assert {:list, "[2]", "[]"} in triples
      assert_compiles(meta)
    end

    test "not vacuous: the same map collapses when the position is :expression" do
      source = """
      defmodule Assigns do
        def f(conn), do: MyApp.render(conn, %{a: 1})
      end
      """

      {_meta, sites, _} =
        Mutare.Transform.transform_string_with_sites(source,
          mutators: [Mutare.Mutators.MapLiteral],
          call_routes: [{MyApp, :render, 2, [:expression, :expression]}]
        )

      assert Enum.any?(sites, &(&1.mutator == :map))
    end

    test "an explicit list argument keeps its element mutants but loses its collapse" do
      {_meta, sites, _} =
        Mutare.Transform.transform_string_with_sites(
          "defmodule L do\n  def f(c), do: MyApp.render(c, [1, 2])\nend\n",
          mutators: [Mutare.Mutators.List, Mutare.Mutators.IntegerLiteral],
          call_routes: [{MyApp, :render, 2, [:expression, :interior]}]
        )

      refute Enum.any?(sites, &(&1.mutator == :list))
      assert Enum.any?(sites, &(&1.original_code == "1"))
    end

    test "an :interior argument that is itself a call keeps the call head but mutates its arguments" do
      # `Enum.sum/1` → `Enum.product/1` is a rewrite of the argument node's *own* head; the `1` inside
      # is a descendant.
      {_meta, sites, _} =
        Mutare.Transform.transform_string_with_sites(
          "defmodule C do\n  def f(c, xs), do: MyApp.render(c, Enum.sum([1 | xs]))\nend\n",
          mutators: [Mutare.Mutators.Collection, Mutare.Mutators.IntegerLiteral],
          call_routes: [{MyApp, :render, 2, [:expression, :interior]}]
        )

      refute Enum.any?(sites, &(&1.mutator == :collection))
      assert Enum.any?(sites, &(&1.original_code == "1"))
    end
  end

  describe "keyed refinements — [leading, key: treatment, …] over a literal keyword argument" do
    @kw_mutators [
      Mutare.Mutators.IntegerLiteral,
      Mutare.Mutators.AtomLiteral,
      Mutare.Mutators.List
    ]

    defp kw_triples(body, routes, mutators \\ @kw_mutators) do
      {meta, sites, _} =
        Mutare.Transform.transform_string_with_sites("defmodule K do\n  #{body}\nend\n",
          mutators: mutators,
          call_routes: routes
        )

      {meta, for(s <- sites, do: {s.mutator, s.original_code, s.mutated_code})}
    end

    test "a named key's value is held back while its neighbours and the keys still mutate" do
      {meta, triples} =
        kw_triples(
          "def f(r), do: MyApp.get(r, recv_timeout: 500, pool: 5)",
          [{MyApp, :get, 2, [:expression, [recv_timeout: :raw]]}]
        )

      refute Enum.any?(triples, fn {_m, o, _} -> o == "500" end)
      assert {:integer, "5", "0"} in triples

      # The keys go through the ordinary call-option-key policy — a refinement changes values only.
      assert {:atom, "recv_timeout:", "mutare:"} in triples
      assert_compiles(meta)
    end

    test "the explicit-list spelling behaves the same, and the list itself still collapses" do
      {meta, triples} =
        kw_triples(
          "def f(r), do: MyApp.get(r, [recv_timeout: 500, pool: 5])",
          [{MyApp, :get, 2, [:expression, [recv_timeout: :raw]]}]
        )

      refute Enum.any?(triples, fn {_m, o, _} -> o == "500" end)
      assert {:integer, "5", "0"} in triples
      # The container follows the leading `:expression`, so `List` still collapses it.
      assert {:list, "[recv_timeout: 500, pool: 5]", "[]"} in triples
      assert_compiles(meta)
    end

    test "the leading treatment defaults to :expression, so `[key: :raw]` is enough" do
      {_meta, with_lead} =
        kw_triples("def f(r), do: MyApp.get(r, t: 500, p: 5)", [
          {MyApp, :get, 2, [:expression, [:expression, t: :raw]]}
        ])

      {_meta, without_lead} =
        kw_triples("def f(r), do: MyApp.get(r, t: 500, p: 5)", [
          {MyApp, :get, 2, [:expression, [t: :raw]]}
        ])

      assert with_lead == without_lead
      refute Enum.any?(without_lead, fn {_m, o, _} -> o == "500" end)
    end

    test "a :raw leading treatment with one key refined to :expression mutates only that value" do
      {meta, triples} =
        kw_triples(
          "def f(q), do: MyApp.page(q, [limit: 10, order: :asc])",
          [{MyApp, :page, 2, [:expression, [:raw, limit: :expression]]}]
        )

      assert {:integer, "10", "0"} in triples
      refute Enum.any?(triples, fn {_m, o, _} -> o == ":asc" end)
      # The container is `:raw` too: no list collapse.
      refute Enum.any?(triples, fn {m, _o, _} -> m == :list end)
      assert_compiles(meta)
    end

    test "refinements nest: a key's value may itself be a keyed list" do
      {meta, triples} =
        kw_triples(
          "def f(url), do: MyApp.request(url, retry: [max_retries: 3, delay: 100])",
          [{MyApp, :request, 2, [:expression, [retry: [max_retries: :raw]]]}]
        )

      refute Enum.any?(triples, fn {_m, o, _} -> o == "3" end)
      assert {:integer, "100", "0"} in triples
      assert_compiles(meta)
    end

    test "a non-literal argument takes the leading treatment alone — there are no keys to refine" do
      {_meta, computed} =
        kw_triples(
          "def f(r, opts), do: MyApp.get(r, Keyword.merge(opts, recv_timeout: 500))",
          [{MyApp, :get, 2, [:expression, [recv_timeout: :raw]]}]
        )

      # The `500` sits inside a *computed* argument, which routes `:expression`; the refinement
      # is literal-only by contract.
      assert {:integer, "500", "0"} in computed
    end

    test "a keyword list piped as the receiver of an arity-1 call is refined too" do
      # `[timeout: 500] |> MyApp.configure()` is `MyApp.configure([timeout: 500])`: the receiver is
      # effective argument 0, and position 0's refinement reaches it through the piped stamp.
      {meta, triples} =
        kw_triples(
          "def f, do: [timeout: 500, pool: 5] |> MyApp.configure()",
          [{MyApp, :configure, 1, [[timeout: :raw]]}]
        )

      refute Enum.any?(triples, fn {_m, o, _} -> o == "500" end)
      assert {:integer, "5", "0"} in triples
      assert_compiles(meta)
    end

    test "Mutare.Calls.routed_treatments/1 reports a refinement in author form" do
      node =
        "MyApp.get(r, recv_timeout: 500)"
        |> Sourceror.parse_string!()
        |> Mutare.Transform.Resolve.annotate(
          Mutare.CallRouting.Registry.build(
            [{MyApp, :get, 2, [:expression, [recv_timeout: :raw]]}],
            []
          )
        )

      assert Mutare.Calls.routed_treatments(node) == [
               :expression,
               [:expression, recv_timeout: :raw]
             ]
    end
  end

  defp assert_compiles(meta) do
    assert [_ | _] = Mutare.Test.Compile.string(meta)
  end
end
