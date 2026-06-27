defmodule Mutare.Transform.CallsTest do
  use ExUnit.Case, async: true

  alias Mutare.Transform.{Calls, Resolve}

  doctest Mutare.Transform.Calls

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

  describe "resolved_macro_call/1 — normalize a known-macro node across written forms" do
    # Register a macro on a (deliberately un-loadable) DSL module. Module-key resolution for a
    # `:macros` entry is reflection-free, and an `import` of the same module registers in the env
    # regardless of loadability — so the *bare* form exercises the registry-fallback path that
    # `resolved_call/1` cannot resolve (no reflectable import stamp), the whole point of reading
    # the authoritative `MacroStamp` identity instead.
    @registry Mutare.Macros.build([{Mx.DSL, :filter, :any, :skip}], [])

    defp resolved_macro(source) do
      source
      |> Sourceror.parse_string!()
      |> Resolve.annotate(@registry)
      |> Macro.prewalk(nil, fn node, acc -> {node, acc || Calls.resolved_macro_call(node)} end)
      |> elem(1)
    end

    test "a qualified call resolves to its module, name, visible args, and a qualified rebuild" do
      assert {[:Mx, :DSL], :filter, [q, c], rebuild} = resolved_macro("Mx.DSL.filter(q, c)")

      # visible_args are the written arguments, in order.
      assert match?({:q, _, nil}, q)
      assert match?({:c, _, nil}, c)

      # rebuild keeps the written `Mx.DSL.` qualification.
      assert "Mx.DSL.reject(q, c)" == Sourceror.to_string(rebuild.(:reject, [q, c]))
    end

    test "an aliased call resolves through the alias and rebuilds in the aliased form" do
      assert {[:Mx, :DSL], :filter, [_q, _c], rebuild} =
               resolved_macro("""
               alias Mx.DSL, as: D
               D.filter(q, c)
               """)

      # rebuild keeps the source's `D.` alias (the swap stays within the module, minimal diff).
      assert "D.reject(q, c)" ==
               Sourceror.to_string(rebuild.(:reject, [{:q, [], nil}, {:c, [], nil}]))
    end

    test "a bare imported call resolves via the registry fallback, qualifying a renamed sibling" do
      assert {[:Mx, :DSL], :filter, [_q, _c], rebuild} =
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
        |> Resolve.annotate(Mutare.Macros.build([], []))

      assert {[:Kernel], :match?, [_x, _one], rebuild} = Calls.resolved_macro_call(node)

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
      meta = [mutare_macro_call: {[:Mx, :DSL], :filter}, mutare_import: {[:Mx, :DSL], :qualify}]
      node = {:filter, meta, [arg_q, arg_c]}

      assert {[:Mx, :DSL], :filter, [^arg_q, ^arg_c], rebuild} = Calls.resolved_macro_call(node)

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
      registry = Mutare.Macros.build([{:my_dsl, :filter, :any, :skip}], [])

      node =
        ":my_dsl.filter(q, c)"
        |> Sourceror.parse_string!()
        |> Resolve.annotate(registry)

      assert {:my_dsl, :filter, [_q, _c], rebuild} = Calls.resolved_macro_call(node)

      # rebuild keeps the written `:my_dsl.` atom-module receiver.
      assert ":my_dsl.reject(q, c)" ==
               Sourceror.to_string(rebuild.(:reject, [{:q, [], nil}, {:c, [], nil}]))
    end

    test "an ordinary (unregistered) call resolves to nil — not a routable macro" do
      assert resolved_macro("String.upcase(s)") == nil
      assert resolved_macro("filter(q, c)") == nil
      assert Calls.resolved_macro_call({:x, [], nil}) == nil
      assert Calls.resolved_macro_call(:literal) == nil
    end

    test "a name-only registry match keeps the macro identity with a nil module" do
      # `{:*, name, …}` is the escape hatch for a macro whose module the resolver can't see; the
      # reader still surfaces the name so a name-matching classifier works.
      registry = Mutare.Macros.build([{:*, :only_macro, :any, :skip}], [])

      node =
        "only_macro(a, b)"
        |> Sourceror.parse_string!()
        |> Resolve.annotate(registry)

      assert {nil, :only_macro, [_a, _b], rebuild} = Calls.resolved_macro_call(node)

      # A `nil` identity module has nothing to qualify against, so even a renamed sibling stays
      # bare (the name-only hatch's inherent limit).
      assert "renamed(a, b)" ==
               Sourceror.to_string(rebuild.(:renamed, [{:a, [], nil}, {:b, [], nil}]))
    end

    test "a stamped node with an unrebuildable head degrades to nil (total, never raises)" do
      # The identity stamp is only ever placed on a remote `Mod.fun`/`:mod.fun` or a bare `fun`
      # head — the two shapes the rebuild handles. A stamp on a `recv.()` anonymous-call head is an
      # impossible state Mutare never produces; `resolved_macro_call/1` returns nil rather than
      # raising a `FunctionClauseError` from the (otherwise partial) rebuild.
      anon_head = {{:., [], [{:f, [], nil}]}, [mutare_macro_call: {[:X], :f}], [{:a, [], nil}]}
      assert Calls.resolved_macro_call(anon_head) == nil
    end

    test "the registry fallback resolves a deterministic module across several whole imports" do
      # Two un-loadable DSL modules, both whole-imported and both registering `where/2`. Neither
      # reflects, so the bare call falls to the registry; `env.imports` is a map (undefined order),
      # so the resolved identity must be sorted-stable — `[:Alpha, :Dsl]` wins over `[:Zeta, :Dsl]`
      # — and never flip run to run (the stamp feeds id-stable analysis and a module classifier).
      registry =
        Mutare.Macros.build([{Zeta.Dsl, :where, 2, :skip}, {Alpha.Dsl, :where, 2, :skip}], [])

      resolve = fn ->
        "import Zeta.Dsl\nimport Alpha.Dsl\nwhere(q, c)"
        |> Sourceror.parse_string!()
        |> Resolve.annotate(registry)
        |> Macro.prewalk(nil, fn node, acc -> {node, acc || Calls.resolved_macro_call(node)} end)
        |> elem(1)
      end

      assert {[:Alpha, :Dsl], :where, [_q, _c], _rebuild} = resolve.()
      assert Enum.uniq(for _ <- 1..10, do: elem(resolve.(), 0)) == [[:Alpha, :Dsl]]
    end

    test "the identity stamp never leaks into the rendered metamutant" do
      {metamutant, _sites, _next} =
        Mutare.transform_string(
          """
          defmodule M do
            def f(s), do: Mx.DSL.filter(s, s)
          end
          """,
          macros: [{Mx.DSL, :filter, :any, :skip}]
        )

      refute metamutant =~ "mutare_macro_call"
    end
  end
end
