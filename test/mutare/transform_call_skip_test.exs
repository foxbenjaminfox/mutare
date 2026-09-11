# A macro with a `do:` block head, for the keyed-refinement block-key test: a real macro, so the
# metamutant is compiled against it and a selector spliced into the key would fail loudly.
defmodule Mutare.Test.WrapDSL do
  defmacro wrap(do: body), do: body
end

# A module-level macro whose head demands a literal body: a selector spliced into the body would
# fail to expand, so a `[[do: :raw]]` route must keep it as written.
defmodule Mutare.Test.LiteralBlockDSL do
  defmacro literal(do: 42), do: nil
end

defmodule Mutare.TransformCallSkipTest do
  # The user-tier call-routing vocabulary beyond `:raw`: the call-level `:skip` (an inert leaf),
  # the `:interior` treatment (contents mutate, container doesn't), and keyed refinements
  # (`[leading, key: treatment, …]` over a literal keyword argument). Functions and macros alike —
  # routing keys on the resolved `{module, fun, arity}`, never on macro-ness. See NOTES "Call
  # routing: `:skip`, `:raw`, `:interior`, keyed refinements".
  use ExUnit.Case, async: true
  import Mutare.Test.Metamutant

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

    test "a skipped condition gets no decision pair and is never hoisted (if, unless, cond)" do
      # `IfCondition`'s `true`/`false` arrive through a structural pass on the condition, not the
      # node offer, so the pass reads the stamp itself — as `Conditional`'s `true`/`false` on a
      # skipped operator condition are already withheld by the dispatcher.
      source = """
      defmodule Decisions do
        def a(x), do: if(String.valid?(x), do: :yes, else: :no)
        def b(x), do: unless(String.valid?(x), do: :no, else: :yes)

        def c(x) do
          cond do
            String.valid?(x) -> :yes
            true -> :no
          end
        end

        def d(x), do: if(String.valid?(y = x), do: y, else: :no)
      end
      """

      mutators = [Mutare.Mutators.IfCondition, Mutare.Mutators.Conditional]

      {meta, sites, _} = transform(source, mutators, [{String, :valid?, 1, :skip}])
      assert sites == []
      assert_compiles(meta)

      {_m, plain, _} = transform(source, mutators, [])

      for line <- [2, 3, 7],
          do:
            assert(
              Enum.any?(plain, &(&1.line == line and &1.mutator == :if_condition)),
              "line #{line}"
            )
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

    test "the RHS of a guard `in` is routed too: a skipped or :interior range keeps its endpoints" do
      # `tag_in_rhs/3` walks the membership RHS with its own redundancy filter; it must honour the
      # RHS head's route first.
      source = "defmodule R do\n  def f(x) when x in 1..5, do: x\nend\n"
      mutators = [Mutare.Mutators.IntegerLiteral]

      for route <- [{Kernel, :.., 2, :skip}, {Kernel, :.., 2, :interior}] do
        {_m, sites, _} = transform(source, mutators, [route])
        assert sites == [], "expected the endpoints held back under #{inspect(route)}"
      end

      {_m, plain, _} = transform(source, mutators, [])
      assert Enum.any?(plain, &(&1.original_code == "5"))
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

  describe "structural heads — :skip is honoured on every form, and is the only route they take" do
    # A route names a resolved head, whatever the analyzer does with it: `Kernel.if/2` is a macro
    # like any other to the registry. The analyzer's dedicated clauses (`if`, the connectives, the
    # negations, `case`, …) run *after* its dispatcher has honoured `:skip`, so the inert-leaf
    # promise holds for them exactly as for `Mixpanel.track/3`. Positional routes never get there:
    # an explicit key is rejected (`call_routing_spec_test.exs`), a wildcard's positions are not
    # applied (`schema_test.exs` checks the match accounting).

    test "the resolver stamps the pipe, quote and capture heads too, so :skip reaches them" do
      # These heads have specialized resolver clauses (pipe-mode bookkeeping, the live-parts-only
      # quote walk, the `&fun/N` ref shape); each must stamp its head before its own descent.
      source = """
      defmodule Heads do
        def piped(x), do: x |> Enum.take(2)
        def quoted(v), do: quote(do: unquote(v + 1))
      end
      """

      mutators = [Mutare.Mutators.IntegerLiteral, Mutare.Mutators.Arithmetic]

      {meta, sites, _} =
        transform(source, mutators, [
          {Kernel, :|>, 2, :skip},
          {Kernel.SpecialForms, :quote, :skip}
        ])

      assert sites == []
      assert_compiles(meta)

      {_m, plain, _} = transform(source, mutators, [])
      assert Enum.any?(plain, &(&1.line == 2 and &1.original_code == "2"))
      assert Enum.any?(plain, &(&1.line == 3 and &1.mutator == :arithmetic))

      registry = Mutare.CallRouting.Registry.build([{Kernel.SpecialForms, :&, :skip}], [])

      capture =
        "&Enum.map/2" |> Sourceror.parse_string!() |> Mutare.Transform.Resolve.annotate(registry)

      assert Mutare.Calls.routed_treatments(capture) == :skip
    end

    test "a skipped Kernel head inside a pattern is inert wherever the pattern sits — head and case clause" do
      # Patterns can hold routable Kernel heads (`"a" <> rest`, `-1`); the literal forms themselves
      # cannot be routed. The pattern walks honour the stamp at their entry, and the structural
      # families are gated on it (`PatternStructure.node_mutations/3`) as a contract guard — the
      # built-ins never restructure across such a head, a custom `pattern_mutations/2` might.
      source = """
      defmodule Pats do
        def head("a" <> x), do: x

        def clause(v) do
          case v do
            "a" <> x -> x
          end
        end
      end
      """

      mutators = [
        Mutare.Mutators.StringLiteral,
        Mutare.Mutators.PatternWildcard,
        Mutare.Mutators.PatternSwap
      ]

      {meta, sites, _} = transform(source, mutators, [{Kernel, :<>, 2, :skip}])
      assert sites == []
      assert_compiles(meta)

      # Not vacuous: unrouted, the literal mutates in both positions. (A `=` match's LHS is a
      # `:pattern` position the in-place walk never mutates, so it is no control here.)
      {_m, plain, _} = transform(source, mutators, [])

      for line <- [2, 6],
          do:
            assert(Enum.any?(plain, &(&1.line == line and &1.mutator == :string)), "line #{line}")
    end

    test "a skipped unquote leaves its escaping argument as written (the quote walks honour :skip)" do
      # Quoted data is walked by the quote-specific passes, not by the dispatcher, so both the
      # resolver's quoted-data walk (the stamp) and `QuoteEscape` (the check) take part.
      source = """
      defmodule Quoted do
        def one(x), do: quote(do: unquote(x + 1))
        def many(xs), do: quote(do: f(unquote_splicing(xs ++ [1])))
      end
      """

      mutators = [Mutare.Mutators.Arithmetic, Mutare.Mutators.IntegerLiteral]

      routes = [
        {Kernel.SpecialForms, :unquote, :skip},
        {Kernel.SpecialForms, :unquote_splicing, :skip}
      ]

      {meta, sites, _} = transform(source, mutators, routes)
      assert sites == []
      assert_compiles(meta)

      {_m, plain, _} = transform(source, mutators, [])
      assert Enum.any?(plain, &(&1.line == 2 and &1.mutator == :arithmetic))
      assert Enum.any?(plain, &(&1.line == 3 and &1.original_code == "1"))
    end

    test "a skipped pipe whose stage is a binding-pattern macro attaches no pattern mutants" do
      # `destructure/2` is routed `:binding_pattern` by core, and `analyze_statement/2` discovers
      # that route on the pipe's RHS stage — it must stop at the skipped pipe.
      source = """
      defmodule Destructured do
        def f(v) do
          [x, y] |> destructure(v)
          {y, x}
        end
      end
      """

      mutators = [Mutare.Mutators.PatternSwap]

      {meta, sites, _} = transform(source, mutators, [{Kernel, :|>, 2, :skip}])
      assert sites == []
      assert_compiles(meta)

      {_m, plain, _} = transform(source, mutators, [])
      assert Enum.any?(plain, &(&1.mutator == :pattern_swap))
    end

    @if_source """
    defmodule Branches do
      def f(x), do: if(x, do: 1, else: 2)

      def g(x) do
        y = if x > 0, do: 10, else: 20
        y + 3
      end
    end
    """

    @flow_mutators [
      Mutare.Mutators.IntegerLiteral,
      Mutare.Mutators.Arithmetic,
      Mutare.Mutators.Relational,
      Mutare.Mutators.Conditional,
      Mutare.Mutators.ReturnValue
    ]

    test "{Kernel, :if, 2, :skip} leaves nothing inside the if — no branch literals, no condition mutants" do
      {meta, sites, _} =
        Mutare.Transform.transform_string_with_sites(@if_source,
          mutators: @flow_mutators,
          call_routes: [{Kernel, :if, 2, :skip}]
        )

      inside = Enum.filter(sites, &(&1.line in [2, 5]))

      # Line 2: the `if` is the function's tail, so the *function's* return-value mutants stay —
      # on the leaf as a whole, never inside a branch. Line 5: nothing at all (`y =` is no tail).
      assert inside != []
      assert Enum.all?(inside, &(&1.mutator == :return_value and &1.line == 2))
      assert Enum.all?(inside, &String.starts_with?(&1.original_code, "if("))
      # Line 6 is untouched control: `y + 3` keeps its swap, literal, and return mutants.
      assert Enum.any?(sites, &(&1.line == 6 and &1.mutator == :arithmetic))
      assert_compiles(meta)
    end

    test "without the route the same ifs mutate inside (the :skip is doing the work)" do
      {_meta, sites, _} =
        Mutare.Transform.transform_string_with_sites(@if_source, mutators: @flow_mutators)

      assert Enum.any?(sites, &(&1.line == 2 and &1.original_code == "1"))
      assert Enum.any?(sites, &(&1.line == 5 and &1.mutator == :conditional))
    end

    test "a skipped connective is a leaf — operands included — while its own enclosing operator still mutates" do
      source = """
      defmodule Ops do
        def f(a, b), do: (a > 1 && b > 2) || false
      end
      """

      {meta, sites, _} =
        Mutare.Transform.transform_string_with_sites(source,
          mutators: [
            Mutare.Mutators.Relational,
            Mutare.Mutators.IntegerLiteral,
            Mutare.Mutators.Logical,
            Mutare.Mutators.Conditional
          ],
          call_routes: [{Kernel, :&&, 2, :skip}]
        )

      # Nothing from inside the `&&` (no relational swaps, no literals); the `||` — a different
      # head — is still offered.
      refute Enum.any?(sites, &(&1.mutator in [:relational, :integer]))
      assert Enum.any?(sites, &(&1.mutator == :logical and &1.original_code =~ "||"))
      assert_compiles(meta)
    end

    test "a skipped `in` under `not` is a leaf (the negation clauses check their inner operand)" do
      # `x not in [1, 2]` parses as `not(x in [1, 2])`, and the analyzer has a dedicated clause for
      # that shape which reads the inner operands directly. It must still see the inner `:skip`.
      source = """
      defmodule NotIn do
        def f(x), do: x not in [1, 2]
      end
      """

      {meta, sites, _} =
        Mutare.Transform.transform_string_with_sites(source,
          mutators: [
            Mutare.Mutators.IntegerLiteral,
            Mutare.Mutators.Logical,
            Mutare.Mutators.Conditional
          ],
          call_routes: [{Kernel, :in, 2, :skip}]
        )

      refute Enum.any?(sites, &(&1.mutator == :integer))
      # The outer `not` is an ordinary offered node.
      assert Enum.any?(sites, &(&1.mutator in [:logical, :conditional]))
      assert_compiles(meta)
    end

    test "a special form is skipped by name: {Kernel.SpecialForms, :case, :skip}, and :with at any arity" do
      source = """
      defmodule Forms do
        def f(x) do
          case x do
            1 -> 2
            _ -> 3
          end
        end

        def g(m) do
          with {:ok, v} <- Map.fetch(m, :k), do: v + 1, else: (_ -> 0)
        end
      end
      """

      mutators = [
        Mutare.Mutators.IntegerLiteral,
        Mutare.Mutators.Arithmetic,
        Mutare.Mutators.ReturnValue
      ]

      {meta, sites, _} =
        Mutare.Transform.transform_string_with_sites(source,
          mutators: mutators,
          call_routes: [
            {Kernel.SpecialForms, :case, :skip},
            {Kernel.SpecialForms, :with, :skip}
          ]
        )

      # Both constructs are their function's tail: the return-value mutants on the whole node are
      # the function's; nothing from inside either.
      assert sites != []
      assert Enum.all?(sites, &(&1.mutator == :return_value))
      assert_compiles(meta)

      {_meta, plain, _} = Mutare.Transform.transform_string_with_sites(source, mutators: mutators)
      assert Enum.any?(plain, &(&1.original_code == "3"))
      assert Enum.any?(plain, &(&1.mutator == :arithmetic))
    end

    test "in a guard, a skipped connective is inert too (the guard walk honours :skip at its entry)" do
      source = "defmodule G do\n  def f(x) when x > 1 and x < 9, do: x\nend\n"
      mutators = [Mutare.Mutators.Relational, Mutare.Mutators.IntegerLiteral]

      {_m, sites, _} =
        Mutare.Transform.transform_string_with_sites(source,
          mutators: mutators,
          call_routes: [{Kernel, :and, 2, :skip}]
        )

      assert sites == []

      {_m, plain, _} = Mutare.Transform.transform_string_with_sites(source, mutators: mutators)
      assert Enum.any?(plain, &(&1.original_code == "9"))
    end

    test "in a head pattern, a skipped Kernel head is inert (the pattern walk honours :skip at its entry)" do
      # `<>` is a Kernel macro a pattern can hold; the literal forms themselves are not routable.
      source = "defmodule P do\n  def f(\"a\" <> rest), do: rest\nend\n"
      mutators = [Mutare.Mutators.StringLiteral]

      {_m, sites, _} = transform(source, mutators, [{Kernel, :<>, 2, :skip}])
      assert sites == []

      {_m, plain, _} = transform(source, mutators, [])
      assert Enum.any?(plain, &(&1.original_code == ~s("a")))
    end

    test "a wildcard route's :skip reaches the structural heads but never a definition" do
      # `{Kernel, :*, :skip}` skips every Kernel *call* — the `+` here — but `def` is a
      # declaration the cascade declines, so the clause is still analyzed and its tail (the
      # skipped `+`, a leaf) still carries the function's return-value mutants.
      source = "defmodule W do\n  def f(x), do: x + 1\nend\n"

      {meta, sites, _} =
        Mutare.Transform.transform_string_with_sites(source,
          mutators: [
            Mutare.Mutators.Arithmetic,
            Mutare.Mutators.IntegerLiteral,
            Mutare.Mutators.ReturnValue
          ],
          call_routes: [{Kernel, :*, :skip}]
        )

      assert sites != []
      assert Enum.all?(sites, &(&1.mutator == :return_value))
      assert_compiles(meta)
    end

    test "a wildcard route's positions apply to the Kernel calls, not to a structural head" do
      source = """
      defmodule Wild do
        def f(x), do: if(x, do: 1 + 1, else: inspect(x, limit: 3))
      end
      """

      {meta, sites, _} =
        Mutare.Transform.transform_string_with_sites(source,
          mutators: [Mutare.Mutators.Arithmetic, Mutare.Mutators.IntegerLiteral],
          call_routes: [{Kernel, :*, :raw}]
        )

      # `:raw` reaches `+` and `inspect` — their arguments are left as written (no `1`, no `3`)
      # while the nodes are still offered (the arithmetic swap fires). The `if` is analyzed as
      # usual, which is what lets the `+` inside its branch be seen at all.
      assert Enum.any?(sites, &(&1.mutator == :arithmetic))
      refute Enum.any?(sites, &(&1.original_code in ["1", "3"]))
      assert_compiles(meta)
    end
  end

  describe "the :interior treatment — contents mutate, the container doesn't" do
    test "under a negation too: a positional route on the inner equality holds, in a body and in a guard" do
      # `not (x == 2)` has dedicated clauses on both walks (negation-redundancy suppression) that
      # build the inner node from its operands; they must route those operands by the inner
      # node's own positions.
      source = """
      defmodule Neg do
        def body(x), do: not (x == 2)
        def guard(x) when not (x == 2), do: x
      end
      """

      mutators = [Mutare.Mutators.IntegerLiteral]

      {meta, sites, _} = transform(source, mutators, [{Kernel, :==, 2, :interior}])
      assert sites == []
      assert_compiles(meta)

      {_m, plain, _} = transform(source, mutators, [])
      assert Enum.any?(plain, &(&1.line == 2 and &1.original_code == "2"))
      assert Enum.any?(plain, &(&1.line == 3 and &1.original_code == "2"))
    end

    test "in a guard too: the container's own collapse goes, its contents keep mutating" do
      # The guard walk registers targets as it goes, so `:interior` there is "walk, then drop the
      # target on the argument's own node" — the twin of the body path's strip. Tuples and maps
      # are guard-legal, so the treatment has real work to do here.
      source = "defmodule GI do\n  def f(x) when is_tuple({x, 1}), do: x\nend\n"
      mutators = [Mutare.Mutators.TupleLiteral, Mutare.Mutators.IntegerLiteral]

      {meta, sites, _} =
        Mutare.Transform.transform_string_with_sites(source,
          mutators: mutators,
          call_routes: [{Kernel, :is_tuple, 1, :interior}]
        )

      refute Enum.any?(sites, &(&1.mutator == :tuple))
      assert Enum.any?(sites, &(&1.original_code == "1"))
      assert_compiles(meta)

      # Not vacuous: unrouted, the tuple collapses.
      {_m, plain, _} = Mutare.Transform.transform_string_with_sites(source, mutators: mutators)
      assert Enum.any?(plain, &(&1.mutator == :tuple))
    end

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

  # A selector host reached through a keyed refinement: the DSL takes its fragment as a named
  # option (`query(q, where: cond)`), so the adapter routes `[:expression, [:raw, where: :hosted]]`.
  # (`KeyedDSL` is deliberately *not* defined here: a nested `defmodule` would make the route's
  # alias resolve to `#{__MODULE__}.KeyedDSL`, not the bare `KeyedDSL` the source names — and a
  # route never reflects on its module anyway.)
  defmodule KeyedHost do
    @behaviour Mutare.Mutator
    @behaviour Mutare.CallRouting
    @behaviour Mutare.Mutator.MacroHost

    alias Mutare.CallRouting.Call
    alias Mutare.Mutator.MacroHost.Target

    @impl Mutare.Mutator
    def name, do: :keyed_host

    @impl Mutare.CallRouting
    def call_routes, do: [{KeyedDSL, :query, 2, [:expression, [:raw, where: :hosted]]}]

    @impl Mutare.Mutator.MacroHost
    def hosted_macros, do: [{KeyedDSL, :query, 2}]

    # Flip the `where:` comparison in place (the options are the trailing sugar: a bare pair list).
    @impl Mutare.Mutator.MacroHost
    def host(%Call{node: {_form, _meta, [_q, opts]}}, _context) when is_list(opts) do
      case Enum.find_index(opts, fn {key, _value} -> Mutare.AST.key_atom(key) == :where end) do
        nil ->
          []

        index ->
          {_key, {op, meta, [left, right]} = original} = Enum.at(opts, index)

          splice = fn {form, cmeta, [q, current]}, case_node ->
            {form, cmeta,
             [q, List.update_at(current, index, fn {key, _} -> {key, case_node} end)]}
          end

          [Target.new(original, [{flip(op), meta, [left, right]}], splice)]
      end
    end

    def host(_call, _context), do: []

    defp flip(:>), do: :<
    defp flip(:<), do: :>
    defp flip(op), do: op
  end

  # Counts how often the literal `1` is offered — the once-per-node probe for nested keyed routes.
  defmodule OfferCounter do
    @behaviour Mutare.Mutator

    @impl true
    def name, do: :offer_counter

    @impl true
    def mutate({:__block__, _meta, [1]}) do
      :ets.update_counter(:mutare_keyed_offer_count, :offers, 1)
      :skip
    end

    def mutate(_node), do: :skip
  end

  describe "keyed refinements — [leading, key: treatment, …] over a literal keyword argument" do
    test "a block key stays raw under a keyed refinement, as the ordinary walk keeps it" do
      # `do:` is a structural label: a selector in its place is malformed, and a macro matching
      # `wrap(do: body)` would not even expand. The value still follows its own position.
      source = """
      defmodule Wrapped do
        require Mutare.Test.WrapDSL
        def f, do: Mutare.Test.WrapDSL.wrap(do: 1 + 1)
      end
      """

      mutators = [
        Mutare.Mutators.AtomLiteral,
        Mutare.Mutators.Arithmetic,
        Mutare.Mutators.IntegerLiteral
      ]

      {meta, sites, _} =
        transform(source, mutators, [{Mutare.Test.WrapDSL, :wrap, 1, [[do: :raw]]}])

      assert sites == []
      assert_compiles(meta)

      {meta, sites, _} =
        transform(source, mutators, [{Mutare.Test.WrapDSL, :wrap, 1, [[do: :expression]]}])

      refute Enum.any?(sites, &(&1.mutator == :atom))
      assert Enum.any?(sites, &(&1.mutator == :arithmetic))
      assert_compiles(meta)
    end

    test "on a module-level block macro too: [[do: :raw]] keeps the body as written" do
      # `analyze_module_macro_block/2` is its own path (module-level contexts, no dispatcher); it
      # routes each position as the body path does.
      source = """
      defmodule Lit do
        require Mutare.Test.LiteralBlockDSL
        Mutare.Test.LiteralBlockDSL.literal(do: 42)
      end
      """

      mutators = [Mutare.Mutators.IntegerLiteral]

      {meta, sites, _} =
        transform(source, mutators, [{Mutare.Test.LiteralBlockDSL, :literal, 1, [[do: :raw]]}])

      assert sites == []
      assert_compiles(meta)

      # Not vacuous: unrouted, the body takes the runtime-body guess and mutates — a metamutant
      # this strict macro would refuse to expand, the poison case the route exists for.
      {_m, plain, _} = transform(source, mutators, [])
      assert Enum.any?(plain, &(&1.original_code == "42"))
    end

    test "a :hosted value under a keyed refinement reaches its host" do
      source = """
      defmodule KeyedHosted do
        def f(q, x), do: KeyedDSL.query(q, limit: 1 + 1, where: x > 1)
      end
      """

      {meta, sites, _} =
        Mutare.Transform.transform_string_with_sites(source,
          mutators: [
            KeyedHost,
            Mutare.Mutators.Relational,
            Mutare.Mutators.Arithmetic,
            Mutare.Mutators.IntegerLiteral
          ]
        )

      # The host's flip is the only mutant: the `where:` fragment is core-raw (hosted), and under
      # the `:raw` leading treatment the `limit:` value and both keys are left as written.
      assert [%{mutator: :keyed_host, mutated_code: mutated}] = sites
      assert mutated =~ "x < 1"
      assert_compiles(meta)
    end

    test "each value is routed once — nested keyed routes do not compound the offers" do
      # Six nested `f(k: …)` calls, each routed `[[k: :expression]]`. Routing the whole argument
      # by the leading treatment and then re-routing the named value would offer the innermost
      # literal 2^6 times; choosing the final position before descending offers it once.
      :ets.new(:mutare_keyed_offer_count, [:named_table, :public])
      :ets.insert(:mutare_keyed_offer_count, {:offers, 0})

      inner = Enum.reduce(1..6, "1", fn _, acc -> "KeyedCountDSL.f(k: #{acc})" end)
      source = "defmodule KeyedNested do\n  def g, do: #{inner}\nend\n"

      {meta, sites, _} =
        Mutare.Transform.transform_string_with_sites(source,
          mutators: [OfferCounter, Mutare.Mutators.IntegerLiteral],
          call_routes: [{KeyedCountDSL, :f, 1, [[k: :expression]]}]
        )

      assert :ets.lookup(:mutare_keyed_offer_count, :offers) == [offers: 1]
      # The innermost literal's own mutants, exactly once each.
      assert Enum.count(sites, &(&1.original_code == "1")) == 2
      assert_compiles(meta)
    end

    test "in a guard too: the named value is held back, the rest follows the leading treatment" do
      source = "defmodule GK do\n  def f(x) when is_list([timeout: 5, limit: 2]), do: x\nend\n"

      mutators = [
        Mutare.Mutators.IntegerLiteral,
        Mutare.Mutators.List,
        Mutare.Mutators.AtomLiteral
      ]

      {meta, sites, _} =
        Mutare.Transform.transform_string_with_sites(source,
          mutators: mutators,
          call_routes: [{Kernel, :is_list, 1, [[timeout: :raw]]}]
        )

      # `timeout:`'s value is raw; the sibling pair, the keys, and the list's own collapse follow
      # the (default) `:expression` leading treatment.
      refute Enum.any?(sites, &(&1.original_code == "5"))
      assert Enum.any?(sites, &(&1.original_code == "2"))
      assert Enum.any?(sites, &(&1.original_code == "timeout:"))
      assert Enum.any?(sites, &(&1.mutator == :list))
      assert_compiles(meta)

      # An `:interior` leading treatment withholds the container only.
      {_m, interior, _} =
        Mutare.Transform.transform_string_with_sites(source,
          mutators: mutators,
          call_routes: [{Kernel, :is_list, 1, [[:interior, timeout: :raw]]}]
        )

      refute Enum.any?(interior, &(&1.mutator == :list))
      refute Enum.any?(interior, &(&1.original_code == "5"))
      assert Enum.any?(interior, &(&1.original_code == "2"))
    end

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

  describe "a call-level :skip and the pipe's left operand" do
    # `:skip` says nothing about positions, so the receiver would fall back to ordinary runtime.
    # Where the skip displaced a code-provided route, that route still governs the position: a
    # piped receiver is the call's effective argument 0, and `Kernel.match?/2` routes 0 as
    # `:pattern`. Getting this wrong splices a selector `case` into a match — uncompilable.
    test "a skipped macro's piped receiver keeps the displaced route's pattern context" do
      source = "defmodule PipedSkip do\n  def f(x), do: 1 |> match?(x)\nend\n"

      {skipped_meta, skipped, _} =
        Mutare.Transform.transform_string_with_sites(source,
          call_routes: [{Kernel, :match?, 2, :skip}]
        )

      {_meta, default, _} = Mutare.Transform.transform_string_with_sites(source)

      # The receiver is a pattern either way: no `integer` selector lands on the `1`.
      refute Enum.any?(skipped, &(&1.mutator == :integer))

      assert Enum.map(skipped, &{&1.mutator, &1.mutated_code}) ==
               Enum.map(default, &{&1.mutator, &1.mutated_code})

      assert_compiles(skipped_meta)
    end

    test "the same holds for a binding-pattern macro" do
      {meta, sites, _} =
        Mutare.Transform.transform_string_with_sites(
          "defmodule PipedDestructure do\n  def f(x), do: [1] |> destructure(x)\nend\n",
          call_routes: [{Kernel, :destructure, 2, :skip}]
        )

      refute Enum.any?(sites, &(&1.mutator == :integer))
      assert_compiles(meta)
    end

    test "displacing nothing leaves the receiver ordinary runtime, mutants and all" do
      source = "defmodule PipedPlain do\n  def f(u), do: Enum.reverse(u) |> List.wrap()\nend\n"

      {meta, skipped, _} =
        Mutare.Transform.transform_string_with_sites(source,
          call_routes: [{List, :wrap, 1, :skip}]
        )

      {_meta, unrouted, _} = Mutare.Transform.transform_string_with_sites(source)

      assert Enum.map(skipped, &{&1.mutator, &1.mutated_code}) ==
               Enum.map(unrouted, &{&1.mutator, &1.mutated_code})

      assert {:call_removal, "u"} in Enum.map(skipped, &{&1.mutator, &1.mutated_code})
      assert_compiles(meta)
    end
  end

  describe ":interior over an operand the equivalent-sibling suppression withheld" do
    # Analyze withholds the operand because the negation carries the mutation for both; `:interior`
    # then drops the negation. Without accounting for the withheld root the pair vanishes together
    # and the argument yields nothing at all.
    test "each suppressed shape yields its operand's mutants once the root is withheld" do
      for {body, original, expected} <- [
            {"not not x", "not x", [logical: "x", conditional: "true", conditional: "false"]},
            {"not (x in [1])", "x in [1]",
             [conditional: "true", conditional: "false", relational: "x not in [1]"]},
            {"not (x == 1)", "x == 1",
             [conditional: "true", conditional: "false", relational: "x != 1"]}
          ] do
        {meta, sites, _} =
          Mutare.Transform.transform_string_with_sites(
            "defmodule Withheld do\n  def f(x), do: MyApp.render(x, #{body})\nend\n",
            mutators: [
              Mutare.Mutators.Logical,
              Mutare.Mutators.Conditional,
              Mutare.Mutators.Relational
            ],
            call_routes: [{MyApp, :render, 2, [:expression, :interior]}]
          )

        assert Enum.map(sites, &{&1.mutator, &1.mutated_code}) == expected
        # The mutants are the *operand's*, not the withheld negation's.
        assert Enum.all?(sites, &(&1.original_code == original))
        assert_compiles(meta)
      end
    end

    test "an ordering operator under the negation is unaffected — it was never withheld" do
      {_meta, sites, _} =
        Mutare.Transform.transform_string_with_sites(
          "defmodule Ordering do\n  def f(x), do: MyApp.render(x, not (x > 1))\nend\n",
          mutators: [Mutare.Mutators.Relational],
          call_routes: [{MyApp, :render, 2, [:expression, :interior]}]
        )

      assert Enum.map(sites, &{&1.original_code, &1.mutated_code}) == [
               {"x > 1", "x >= 1"},
               {"x > 1", "x < 1"}
             ]
    end

    test "a plain argument still loses only its own node's mutants" do
      {_meta, sites, _} =
        Mutare.Transform.transform_string_with_sites(
          "defmodule Plain do\n  def f(x), do: MyApp.render(x, x + 1)\nend\n",
          mutators: [Mutare.Mutators.Arithmetic, Mutare.Mutators.IntegerLiteral],
          call_routes: [{MyApp, :render, 2, [:expression, :interior]}]
        )

      refute Enum.any?(sites, &(&1.mutator == :arithmetic))
      assert Enum.all?(sites, &(&1.original_code == "1"))
    end
  end

  defp transform(source, mutators, routes),
    do:
      Mutare.Transform.transform_string_with_sites(source,
        mutators: mutators,
        call_routes: routes
      )
end
