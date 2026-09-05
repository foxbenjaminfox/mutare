defmodule Mutare.Transform.CallsTest do
  use ExUnit.Case, async: true

  alias Mutare.Transform.{Calls, Meta, Resolve}
  alias Mutare.CallRouting.Call

  describe "resolved_call/1 — a `:qualify` rebuild over an Erlang-atom module" do
    test "a renamed sibling is requalified with the Erlang atom module, a same-name swap stays bare" do
      # A bare call stamped as imported from an Erlang atom module under a *selective* import
      # (`:qualify`). The stamp is what `Mutare.Transform.Resolve` writes; here we set it directly
      # to drive the rebuild's Erlang-atom `qualifier/1` branch.
      arg = {:x, [], nil}
      node = {:reverse, [mutare_import: {:binary, :qualify}], [arg]}

      assert {:binary, :reverse, [^arg], rebuild} = Calls.resolved_call(node)

      # Same name + arity → left bare (the value-only/no-op path).
      assert {:reverse, _meta, [^arg]} = rebuild.(:reverse, [arg])

      # A rename requalifies through the Erlang atom module (never alias-expanded).
      assert {{:., [], [{:__block__, [], [:binary]}, :part]}, _meta, [^arg]} =
               rebuild.(:part, [arg])
    end
  end

  describe "resolved_routed_call/1 — normalize a known-macro node across written forms" do
    # Register a macro on a (deliberately un-loadable) DSL module. Module-key resolution for a
    # `:call_routes` entry is reflection-free, and an `import` of the same module registers in the env
    # regardless of loadability — so the *bare* form exercises the registry-fallback path that
    # `resolved_call/1` cannot resolve (no reflectable import stamp), the whole point of reading
    # the authoritative `RouteStamp` identity instead.
    @registry Mutare.CallRouting.Registry.build([{Mx.DSL, :filter, :any, :raw}], [])

    defp resolved_macro(source) do
      source
      |> Sourceror.parse_string!()
      |> Resolve.annotate(@registry)
      |> Macro.prewalk(nil, fn node, acc -> {node, acc || Calls.resolved_routed_call(node)} end)
      |> elem(1)
    end

    test "a qualified call resolves to its module, name, visible args, and a qualified rebuild" do
      assert %Call{module: Mx.DSL, name: :filter, arguments: [q, c], rebuild: rebuild} =
               resolved_macro("Mx.DSL.filter(q, c)")

      # visible_args are the written arguments, in order.
      assert match?({:q, _, nil}, q)
      assert match?({:c, _, nil}, c)

      # rebuild keeps the written `Mx.DSL.` qualification.
      assert "Mx.DSL.reject(q, c)" == Sourceror.to_string(rebuild.(:reject, [q, c]))
    end

    test "an aliased call resolves through the alias and rebuilds in the aliased form" do
      assert %Call{module: Mx.DSL, name: :filter, arguments: [_q, _c], rebuild: rebuild} =
               resolved_macro("""
               alias Mx.DSL, as: D
               D.filter(q, c)
               """)

      # rebuild keeps the source's `D.` alias (the swap stays within the module, minimal diff).
      assert "D.reject(q, c)" ==
               Sourceror.to_string(rebuild.(:reject, [{:q, [], nil}, {:c, [], nil}]))
    end

    test "a bare imported call resolves via the registry fallback, qualifying a renamed sibling" do
      assert %Call{module: Mx.DSL, name: :filter, arguments: [_q, _c], rebuild: rebuild} =
               resolved_macro("""
               import Mx.DSL
               filter(q, c)
               """)

      # A value-only swap (same name + arity) stays bare — it resolves as the compiling original did.
      assert "filter(q, c)" ==
               Sourceror.to_string(rebuild.(:filter, [{:q, [], nil}, {:c, [], nil}]))

      # A renamed sibling requalifies through the alias-proof module: the import carried no
      # `:mutare_import` stamp (registry-fallback resolution, Mutare can't reflect on `Mx.DSL`),
      # so the sole-whole-import guarantee a `:bare` rebuild rests on is absent — a bare `reject`
      # could be ambiguous under an overlapping import, so it is qualified to be compile-safe.
      assert "Elixir.Mx.DSL.reject(q, c)" ==
               Sourceror.to_string(rebuild.(:reject, [{:q, [], nil}, {:c, [], nil}]))
    end

    test "a bare Kernel macro (no import stamp) requalifies a renamed sibling, keeps a value-only swap bare" do
      # `match?` is a built-in known macro resolving to Kernel with *no* `:mutare_import` stamp
      # (Kernel is auto-imported). A renamed/re-aritied sibling could have been displaced out of
      # Kernel (`import Kernel, except: [destructure: 2]`), so the bare rebuild must requalify it
      # via the alias-proof Kernel module rather than emit the excluded sibling bare.
      node =
        "match?(x, 1)"
        |> Sourceror.parse_string!()
        |> Resolve.annotate(Mutare.CallRouting.Registry.build([], []))

      assert %Call{module: Kernel, name: :match?, arguments: [_x, _one], rebuild: rebuild} =
               Calls.resolved_routed_call(node)

      x = {:x, [], nil}
      one = {:__block__, [], [1]}

      # A value-only swap stays bare (resolves as the compiling original did).
      assert "match?(x, 1)" == Sourceror.to_string(rebuild.(:match?, [x, one]))

      # A renamed sibling requalifies with the alias-proof `Elixir.Kernel` module.
      assert "Elixir.Kernel.destructure(x, 1)" ==
               Sourceror.to_string(rebuild.(:destructure, [x, one]))
    end

    test "a selectively-imported bare macro requalifies a renamed sibling, keeps a value-only swap bare" do
      arg_q = {:q, [], nil}
      arg_c = {:c, [], nil}

      # The stamps `Mutare.Transform.Resolve` writes for a bare macro reached through a *selective*
      # import (`import Mx.DSL, only: [filter: 2]` — a `:qualify` kind): the resolved identity plus
      # the import resolution. Set directly to drive the bare rebuild's `:qualify` branch.
      meta = [
        mutare_route_call: {[:Mx, :DSL], :filter, :unpiped},
        mutare_import: {[:Mx, :DSL], :qualify}
      ]

      node = {:filter, meta, [arg_q, arg_c]}

      assert %Call{
               module: Mx.DSL,
               name: :filter,
               arguments: [^arg_q, ^arg_c],
               rebuild: rebuild
             } = Calls.resolved_routed_call(node)

      # A value-only swap (same name + arity) stays bare — it resolves as the compiling original did.
      assert "filter(q, c)" == Sourceror.to_string(rebuild.(:filter, [arg_q, arg_c]))

      # A renamed sibling is requalified with the alias-proof `Elixir.`-prefixed module: bare
      # `reject` may not be imported under `only: [filter: 2]`.
      assert "Elixir.Mx.DSL.reject(q, c)" ==
               Sourceror.to_string(rebuild.(:reject, [arg_q, arg_c]))

      # An arity change requalifies too (the lower/higher arity is not selectively imported).
      assert "Elixir.Mx.DSL.filter(q)" == Sourceror.to_string(rebuild.(:filter, [arg_q]))
    end

    test "a direct atom-module macro call is stamped by Resolve and rebuilt in the atom form" do
      registry = Mutare.CallRouting.Registry.build([{:my_dsl, :filter, :any, :raw}], [])

      node =
        ":my_dsl.filter(q, c)"
        |> Sourceror.parse_string!()
        |> Resolve.annotate(registry)

      assert %Call{module: :my_dsl, name: :filter, arguments: [_q, _c], rebuild: rebuild} =
               Calls.resolved_routed_call(node)

      # rebuild keeps the written `:my_dsl.` atom-module receiver.
      assert ":my_dsl.reject(q, c)" ==
               Sourceror.to_string(rebuild.(:reject, [{:q, [], nil}, {:c, [], nil}]))
    end

    test "an ordinary (unregistered) call resolves to nil — not a routable macro" do
      assert resolved_macro("String.upcase(s)") == nil
      assert resolved_macro("filter(q, c)") == nil
      assert Calls.resolved_routed_call({:x, [], nil}) == nil
      assert Calls.resolved_routed_call(:integer) == nil
    end

    test "a name-only registry match keeps the macro identity with a nil module" do
      # `{:*, name, …}` is the escape hatch for a macro whose module the resolver can't see; the
      # reader still surfaces the name so a name-matching classifier works.
      registry = Mutare.CallRouting.Registry.build([{:*, :only_macro, :any, :raw}], [])

      node =
        "only_macro(a, b)"
        |> Sourceror.parse_string!()
        |> Resolve.annotate(registry)

      assert %Call{module: nil, name: :only_macro, arguments: [_a, _b], rebuild: rebuild} =
               Calls.resolved_routed_call(node)

      # A `nil` identity module has nothing to qualify against, so even a renamed sibling stays
      # bare (the name-only hatch's inherent limit).
      assert "renamed(a, b)" ==
               Sourceror.to_string(rebuild.(:renamed, [{:a, [], nil}, {:b, [], nil}]))
    end

    test "a stamped node with an unrebuildable head degrades to nil (total, never raises)" do
      # The identity stamp is only ever placed on a remote `Mod.fun`/`:mod.fun` or a bare `fun`
      # head — the two shapes the rebuild handles. A stamp on a `recv.()` anonymous-call head is an
      # impossible state Mutare never produces; `resolved_routed_call/1` returns nil rather than
      # raising a `FunctionClauseError` from the (otherwise partial) rebuild.
      anon_head =
        {{:., [], [{:f, [], nil}]}, [mutare_route_call: {[:X], :f, :unpiped}], [{:a, [], nil}]}

      assert Calls.resolved_routed_call(anon_head) == nil
    end

    test "the registry fallback resolves a deterministic module across several whole imports" do
      # Two un-loadable DSL modules, both whole-imported and both registering `where/2`. Neither
      # reflects, so the bare call falls to the registry; `env.imports` is a map (undefined order),
      # so the resolved identity must be sorted-stable — `[:Alpha, :Dsl]` wins over `[:Zeta, :Dsl]`
      # — and never flip run to run (the stamp feeds id-stable analysis and a module classifier).
      registry =
        Mutare.CallRouting.Registry.build(
          [{Zeta.Dsl, :where, 2, :raw}, {Alpha.Dsl, :where, 2, :raw}],
          []
        )

      resolve = fn ->
        "import Zeta.Dsl\nimport Alpha.Dsl\nwhere(q, c)"
        |> Sourceror.parse_string!()
        |> Resolve.annotate(registry)
        |> Macro.prewalk(nil, fn node, acc -> {node, acc || Calls.resolved_routed_call(node)} end)
        |> elem(1)
      end

      assert %Call{module: Alpha.Dsl, name: :where, arguments: [_q, _c]} = resolve.()
      assert Enum.uniq(for _ <- 1..10, do: resolve.().module) == [Alpha.Dsl]
    end

    test "the identity stamp never leaks into the rendered metamutant" do
      {metamutant, _sites, _next} =
        Mutare.Transform.transform_string_with_sites(
          """
          defmodule M do
            def f(s), do: Mx.DSL.filter(s, s)
          end
          """,
          call_routes: [{Mx.DSL, :filter, :any, :raw}]
        )

      refute metamutant =~ "mutare_route_call"
    end
  end

  describe "routed_treatments/1 — inspect how a node's macro is registered, per argument" do
    @skip_registry Mutare.CallRouting.Registry.build([{Mx.DSL, :filter, :any, :raw}], [])

    # Find the macro *node* (not the resolved tuple) so the reader can be applied to it.
    defp macro_node(source, registry) do
      source
      |> Sourceror.parse_string!()
      |> Resolve.annotate(registry)
      |> Macro.prewalk(nil, fn node, acc ->
        {node, acc || (Calls.resolved_routed_call(node) && node)}
      end)
      |> elem(1)
    end

    test "a uniformly :skip-registered macro reports :skip for every visible argument" do
      node = macro_node("Mx.DSL.filter(q, c)", @skip_registry)

      assert Calls.routed_treatments(node) == [:raw, :raw]
    end

    test "a per-position registration reports each argument's own treatment" do
      registry =
        Mutare.CallRouting.Registry.build([{Mx.DSL, :filter, 2, [:raw, :expression]}], [])

      node = macro_node("Mx.DSL.filter(q, c)", registry)

      assert Calls.routed_treatments(node) == [:raw, :expression]
    end

    test "a pattern macro (match?) reports its routing" do
      node = macro_node("match?({:ok, x}, v)", Mutare.CallRouting.Registry.build([], []))

      assert Calls.routed_treatments(node) == [:pattern, :expression]
    end

    test "an unregistered call reports nil; the reader is total over any term" do
      node = "plain(q, c)" |> Sourceror.parse_string!() |> Resolve.annotate(@skip_registry)

      assert Calls.routed_treatments(node) == nil
      assert Calls.routed_treatments(:integer) == nil
      assert Calls.routed_treatments({:x, [], nil}) == nil
    end

    test "the internal {:hosted, host}/{:keyword, …} stamp reads back as the author vocabulary" do
      hosted = Meta.stamp_routing([], [:expression, {:hosted, [SomeHost]}])

      assert Calls.routed_treatments({:filter, hosted, [{:q, [], nil}, {:c, [], nil}]}) ==
               [:expression, :hosted]

      keyword =
        Meta.stamp_routing([], [:expression, {:keyword, [{:hosted, [SomeHost]}, :raw]}])

      assert Calls.routed_treatments({:set, keyword, [{:q, [], nil}, {:c, [], nil}]}) ==
               [:expression, {:keyword, [:hosted, :raw]}]
    end

    test "a 0-arg known macro reports [] (recognised, but nothing inside) — distinct from nil" do
      registry = Mutare.CallRouting.Registry.build([{Mx.DSL, :thing, 0, :raw}], [])
      node = macro_node("Mx.DSL.thing()", registry)

      assert Calls.routed_treatments(node) == []
    end
  end
end
