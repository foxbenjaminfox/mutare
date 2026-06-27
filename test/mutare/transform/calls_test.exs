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

    test "a bare imported call resolves via the registry fallback and rebuilds bare" do
      assert {[:Mx, :DSL], :filter, [_q, _c], rebuild} =
               resolved_macro("""
               import Mx.DSL
               filter(q, c)
               """)

      assert "reject(q, c)" ==
               Sourceror.to_string(rebuild.(:reject, [{:q, [], nil}, {:c, [], nil}]))
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

      assert {nil, :only_macro, [_a, _b], _rebuild} = Calls.resolved_macro_call(node)
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
