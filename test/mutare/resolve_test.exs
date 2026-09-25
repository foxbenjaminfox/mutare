defmodule Mutare.ResolveTest do
  use ExUnit.Case, async: true

  alias Mutare.Transform.Resolve

  # The per-node identity token `meta[:mutare_nid]` that `Mutare.Transform.Overlap`
  # prunes redundant leaf mutants on. These pin its contract *directly* — total
  # coverage, injectivity, and the load-bearing "no metadata → no nid" fact — rather
  # than via a downstream mutator symptom. The whole correctness argument for Overlap
  # (a false prune is unrepresentable) rests on these properties, so they earn an
  # explicit, mechanism-level guard.
  describe "node id stamping (mutare_nid)" do
    defp annotate(source), do: source |> Sourceror.parse_string!() |> Resolve.annotate()

    # Every `{form, meta, args}` node with list metadata, in DFS order.
    defp meta_nodes(ast) do
      {_ast, nodes} =
        Macro.prewalk(ast, [], fn
          {_f, meta, _a} = node, acc when is_list(meta) -> {node, [node | acc]}
          node, acc -> {node, acc}
        end)

      Enum.reverse(nodes)
    end

    test "stamps a unique nid on every metadata-bearing node (total + injective)" do
      # Two structurally identical `DateTime.truncate(a, :second)` calls make injectivity
      # non-trivial: range-equality could not tell them (or their `:second` leaves) apart,
      # node identity must.
      ast =
        annotate("""
        defmodule M do
          def f(a), do: DateTime.truncate(a, :second)
          def g(a), do: DateTime.truncate(a, :second)
        end
        """)

      nids = ast |> meta_nodes() |> Enum.map(&Resolve.nid/1)

      # Total: no metadata-bearing node is left unstamped.
      assert Enum.all?(nids, &is_integer/1)
      # Injective: every node — including the duplicated calls and their `:second` leaves —
      # gets a distinct id.
      assert nids == Enum.uniq(nids)
    end

    test "a bare atom and a list carry no nid — why operator/arity footprints never cover" do
      # An operator swap changes a bare form atom (`:-`); an arity drop / operand swap changes
      # the argument *list*. Neither shape carries metadata, so neither can be stamped — which
      # is exactly why Overlap treats those footprints as non-covering, with no special case.
      assert Resolve.nid(:-) == nil
      assert Resolve.nid([1, 2]) == nil

      # The operator *node* (`{:-, meta, [a, b]}`) — which actually hosts candidates — does
      # carry one, so a leaf swap on a genuine descendant can still be covered.
      {:-, _meta, [_a, _b]} = node = annotate("a - b")
      assert is_integer(Resolve.nid(node))
    end

    test "nids never leak into the rendered metamutant (stripped before render)" do
      # `:mutare_nid` is internal bookkeeping; like the other `mutare_*` meta keys it must be
      # stripped before Sourceror renders the build artifact.
      %{metamutant: metamutant} =
        Mutare.Transform.transform_string_with_sites(
          """
          defmodule M do
            def f(a), do: DateTime.truncate(a, :second)
          end
          """,
          mutators: [Mutare.Mutators.ModeSwap, Mutare.Mutators.AtomLiteral]
        )

      refute metamutant =~ "mutare_nid"
    end
  end

  describe "syntax the pass leaves as written" do
    alias Mutare.Transform.{MetaKeys, WrittenPipe}

    @internal MetaKeys.all()

    # The tree less Mutare's own stamps; meta is a keyword list, whose order nothing promises.
    defp comparable(ast) do
      Macro.prewalk(ast, fn
        {form, meta, args} when is_list(meta) ->
          {form, meta |> Keyword.drop(@internal) |> Map.new(), args}

        other ->
          other
      end)
    end

    # A stage `Kernel.|>/2` refuses stays a pipe: a macro may still take it as its argument.
    for source <- [
          "x |> 1",
          ~S(x |> "s"),
          "x |> [y]",
          "x |> {a, b}",
          "def unquote(name)(x), do: x |> unquote(fun)",
          "def unquote(name)(x), do: x |> unquote_splicing(fun)"
        ] do
      test "a stage Kernel cannot pipe into: #{source}" do
        parsed = Sourceror.parse_string!(unquote(source))
        resolved = Resolve.annotate(parsed)

        assert Enum.any?(Macro.prewalker(resolved), &match?({:|>, _, _}, &1))
        assert comparable(resolved) == comparable(parsed)
      end
    end

    for source <- [
          "&foo / bar",
          "import Kernel, except: [defmodule: 2]\ndefmodule Foo do\n  x |> f()\nend",
          "import Kernel, except: [defimpl: 3]\ndefimpl Foo, for: Bar do\n  x |> f()\nend"
        ] do
      test "resolving and resugaring gives back #{inspect(source)}" do
        parsed = Sourceror.parse_string!(unquote(source))
        resugared = parsed |> Resolve.annotate() |> WrittenPipe.resugar()
        assert comparable(resugared) == comparable(parsed)
      end
    end

    for {skipped, callee} <- [quote: Mixpanel, unquote: Sentry] do
      test "a skipped #{skipped} resolves nothing inside it, and keeps it as written" do
        source = """
        defmodule M do
          def f(x), do: quote(do: [unquote(#{inspect(unquote(callee))}.track(x))])
        end
        """

        route = {unquote(callee), :track, 1, :skip}
        key = {Module.split(unquote(callee)) |> Enum.map(&String.to_atom/1), :track, 1}

        %{matches: matches} = Mutare.Transform.count_report(source, call_routes: [route])
        assert key in matches.routes

        routes = [{Kernel.SpecialForms, unquote(skipped), :skip}, route]
        %{matches: matches} = Mutare.Transform.count_report(source, call_routes: routes)
        refute key in matches.routes

        parsed = Sourceror.parse_string!(source)
        resolved = Resolve.annotate(parsed, Mutare.CallRouting.Registry.build(routes, []))
        assert comparable(resolved) == comparable(parsed)
      end
    end
  end

  describe "readers of preserved syntax" do
    alias Mutare.CallRouting.Registry
    alias Mutare.Transform.MetaKeys

    test "a routed call's own environment replaces the enclosing one" do
      routed = [{MetaKeys.route_key(), [:raw]}, {MetaKeys.resolution_key(), :inner_env}]
      node = {:inner, routed, []}
      assert Resolve.context(node, %{resolution: :outer_env}).resolution == :inner_env
      assert Resolve.context({:plain, [], []}, %{resolution: :outer_env}).resolution == :outer_env
    end

    # Every resolved call retains its environment (for `Resolve.reroute/2`); only a route
    # leaves syntax beneath a call for the readers to resolve in it.
    test "an unrouted call's retained environment does not enter" do
      node = {:inner, [{MetaKeys.resolution_key(), :inner_env}], []}
      assert Resolve.context(node, %{resolution: :outer_env}).resolution == :outer_env
      refute Map.has_key?(Resolve.context(node, %{}), :resolution)
    end

    test "an island re-enters the environment its call retained" do
      registry = Registry.build([{Foo, :bar, 1, :raw}], [])
      call = Resolve.annotate(Sourceror.parse_string!("Foo.bar(x |> f())"), registry)
      {_dot, _meta, [island]} = call

      assert {:|>, _, _} = island
      resolved = Resolve.expression(island, Resolve.context(call, %{}))
      assert Macro.to_string(resolved) == "f(x)"
    end

    test "a preserved Kernel pipe reads as the call it expands to" do
      pipe = Sourceror.parse_string!("x |> (f() |> g())")
      assert Macro.to_string(Resolve.preserved_pipe_call(pipe, %{})) == "g(x |> f())"

      {:|>, meta, args} = Sourceror.parse_string!("x |> f()")
      assert Macro.to_string(Resolve.preserved_pipe_call({:|>, meta, args}, %{})) == "f(x)"

      displaced = [{MetaKeys.kernel_displaced_key(), true} | meta]
      assert Resolve.preserved_pipe_call({:|>, displaced, args}, %{}) == nil
    end
  end
end
