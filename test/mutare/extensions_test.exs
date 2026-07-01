defmodule Mutare.ExtensionsTest do
  use ExUnit.Case, async: true

  alias Mutare.{Extension, UseExpansion}
  alias Mutare.MacroRouting.Registry, as: Macros
  alias Mutare.UseExpansion.Dispatch

  alias Mutare.Test.{
    BehaviourExtension,
    BlockDirectiveExtension,
    ContextExtension,
    DecliningExtension,
    DynamicRoutingExtension,
    EmptyExpansionExtension,
    ExitingExtension,
    GettextLike,
    GettextLikeExtension,
    HostingExtension,
    MalformedExtension,
    RaisingExtension,
    StaticRoutingExtension,
    ThrowingExtension
  }

  alias Mutare.Transform.{Imports, Resolve, Uses}

  doctest Mutare.Extension.Spec
  doctest Mutare.UseExpansion

  describe "extension?/1" do
    test "a loaded module exporting an extension callback is an extension" do
      assert Extension.extension?(GettextLikeExtension)
      assert Extension.extension?(DecliningExtension)
      assert Extension.extension?(StaticRoutingExtension)
    end

    test "a module exporting neither extension callback is not an extension" do
      refute Extension.extension?(Mutare.Mutators.Arithmetic)
      refute Extension.extension?(Enum)
    end

    test "a Mutare.Mutator is not an extension, even one that exports macro_routes/0" do
      # QueryMutator is a macro-aware mutator: it exports `macro_routes/0` (which on its own would look
      # extension-like) but declares `@behaviour Mutare.Mutator`, so it is excluded.
      refute Extension.extension?(Mutare.Test.QueryMutator)
    end

    test "a non-module / unloadable atom is not an extension" do
      refute Extension.extension?(:not_a_module)
      refute Extension.extension?("Elixir.Nope")
      refute Extension.extension?(nil)
    end
  end

  describe "Dispatch.handlers/1" do
    test "keeps only the extensions exporting expand_use/3, resolved to specs" do
      # GettextLikeExtension + RaisingExtension + DecliningExtension export it; a macros-only
      # extension would not. Order is preserved (dispatch is first-non-decline-wins) and each
      # entry resolves to a Extension.Spec (a bare module → empty opts).
      assert Dispatch.handlers([
               GettextLikeExtension,
               StaticRoutingExtension,
               DecliningExtension,
               Mutare.Mutators.Arithmetic
             ]) ==
               [
                 %Extension.Spec{module: GettextLikeExtension},
                 %Extension.Spec{module: DecliningExtension}
               ]
    end

    test "carries a {module, opts} entry's opts onto its spec" do
      assert Dispatch.handlers([{GettextLikeExtension, [domain: "errors"]}]) ==
               [%Extension.Spec{module: GettextLikeExtension, opts: [domain: "errors"]}]
    end
  end

  describe "Dispatch.run/4" do
    test "no handlers → :decline" do
      assert Dispatch.run([], GettextLike, [], %{}) == :decline
    end

    test "the first non-declining handler wins" do
      result =
        Dispatch.run([DecliningExtension, GettextLikeExtension], GettextLike, [], %{})

      assert_gettext_import(result)
    end

    test "every handler declining → :decline" do
      assert Dispatch.run([DecliningExtension, DecliningExtension], GettextLike, [], %{}) ==
               :decline
    end

    test "a handler that doesn't match the module declines (falls through)" do
      assert Dispatch.run([GettextLikeExtension], SomeOtherModule, [], %{}) == :decline
    end

    test "a raising handler surfaces loudly as ContractError (not isolated to :decline)" do
      # An extension *crash* is a misconfiguration, so it aborts loudly — it does NOT fall through to
      # the next handler, and a sole raising handler does NOT degrade to :decline. (Contrast a
      # target's un-expandable `use`, which stays silent.)
      assert_raise Mutare.UseExpansion.ContractError, ~r/raised in expand_use\/3/, fn ->
        Dispatch.run([RaisingExtension, GettextLikeExtension], GettextLike, [], %{})
      end

      assert_raise Mutare.UseExpansion.ContractError, ~r/raised in expand_use\/3/, fn ->
        Dispatch.run([RaisingExtension], GettextLike, [], %{})
      end
    end

    test "a throwing handler surfaces as ContractError (the :throw catch arm)" do
      # A non-local `throw` is not an exception, so it bypasses `rescue` and is caught by the
      # `catch :throw, value` clause — still a loud ContractError, never a silent decline.
      assert_raise Mutare.UseExpansion.ContractError,
                   ~r/threw :thrown_from_extension in expand_use\/3/,
                   fn ->
                     Dispatch.run([ThrowingExtension], GettextLike, [], %{})
                   end
    end

    test "an exiting handler surfaces as ContractError (the non-:throw catch arm)" do
      assert_raise Mutare.UseExpansion.ContractError,
                   ~r/signalled exit :exited_from_extension/,
                   fn ->
                     Dispatch.run([ExitingExtension], GettextLike, [], %{})
                   end
    end

    test "an empty Expansion still wins (handle-and-inject-nothing, not fall-through)" do
      # `UseExpansion.expand([])` is a deliberate "I handle this, inject nothing": first-non-:decline
      # wins, so it suppresses the later GettextLikeExtension (and, in Harvest, in-process expansion).
      # An extension that wants to fall through must return :decline, not an empty Expansion.
      assert Dispatch.run(
               [EmptyExpansionExtension, GettextLikeExtension],
               GettextLike,
               [],
               %{}
             ) ==
               %UseExpansion.Expansion{directives: [], behaviours: []}
    end

    test "a malformed return raises loudly (ContractError), not a silent decline" do
      # Returning a non-Expansion/non-:decline value is a *configuration* error (a broken extension),
      # so — unlike a raising handler — it surfaces loudly rather than degrading to :decline.
      assert_raise Mutare.UseExpansion.ContractError, ~r/invalid result from expand_use\/3/, fn ->
        Dispatch.run([MalformedExtension], GettextLike, [], %{
          module: Mutare.Test.SomeCaller
        })
      end
    end

    test "passes the caller :module and the extension's :opts into the context" do
      result =
        Dispatch.run(
          [{ContextExtension, [probe: self(), import: Mutare.Test.GettextLikeMacros]}],
          GettextLike,
          [],
          %{module: Mutare.Test.SomeCaller}
        )

      assert %UseExpansion.Expansion{} = result
      assert_received {:expand_use_context, Mutare.Test.SomeCaller, opts}
      assert opts[:probe] == self()
    end
  end

  describe "expand/2 contract" do
    test "builds an Expansion from lists" do
      assert %UseExpansion.Expansion{directives: [:d], behaviours: [GenServer]} =
               UseExpansion.expand([:d], [GenServer])
    end

    test "a non-list argument raises ContractError (loud, not a swallowed FunctionClauseError)" do
      # `quote do import Foo end` is a single node, not a list — a common extension-author slip. It
      # must fail loudly rather than being swallowed to a silent :decline inside safe_expand.
      assert_raise Mutare.UseExpansion.ContractError, ~r/expects a list of directives/, fn ->
        UseExpansion.expand(quote(do: import(Enum)))
      end
    end
  end

  describe "Mutare.UseExpansion.ContractError" do
    test "exception/1 accepts a bare string message (the is_binary clause)" do
      # The extension code raises it with a `message:` keyword; this pins the binary shortcut so a
      # `raise ContractError, "..."` also carries its text.
      err = Mutare.UseExpansion.ContractError.exception("plain message")
      assert Exception.message(err) == "plain message"
    end
  end

  describe "Macros.from_extensions/1 + build/3" do
    test "an extension's static macro_routes/0 entries carry no callback provider" do
      [_ | _] = specs = Macros.from_extensions([GettextLikeExtension])
      keys = Enum.map(specs, &Mutare.Macro.Spec.key/1)

      assert {[:Mutare, :Test, :GettextLikeMacros], :translate, 1} in keys
      assert {[:Mutare, :Test, :GettextLikeMacros], :ntranslate, 3} in keys

      # Static routing needs neither callback role.
      assert Enum.all?(specs, &is_nil(&1.router))
      assert Enum.all?(specs, &is_nil(&1.host))
    end

    test "an extension module with no macro_routes/0 contributes nothing" do
      assert Macros.from_extensions([DecliningExtension]) == []
    end

    test "a macro-routing-only extension contributes without implementing use expansion" do
      assert [%Mutare.Macro.Spec{args: [:expression, :skip]}] =
               Macros.from_extensions([StaticRoutingExtension])
    end

    test "an extension may provide shape-aware routing without becoming a macro host" do
      assert [
               %Mutare.Macro.Spec{
                 args: :routing,
                 router: DynamicRoutingExtension,
                 host: nil
               }
             ] = Macros.from_extensions([DynamicRoutingExtension])
    end

    test "from_extensions accepts resolved Extension.Specs too (not only bare modules)" do
      from_module = Macros.from_extensions([GettextLikeExtension])
      from_spec = Macros.from_extensions([%Extension.Spec{module: GettextLikeExtension}])

      assert Enum.map(from_spec, &Mutare.Macro.Spec.key/1) ==
               Enum.map(from_module, &Mutare.Macro.Spec.key/1)
    end

    test "an extension macro_routes/0 declaring :hosted is rejected (extensions can't host)" do
      # An extension produces no mutations, so it cannot host one — caught with an extension-specific
      # message rather than build/3's generic "hosting mutator" abort that mislabels the extension.
      assert_raise ArgumentError, ~r/returned hosted route/, fn ->
        Macros.from_extensions([HostingExtension])
      end
    end

    test "build/3 merges extension macros into the registry" do
      registry = Macros.build([], [], [GettextLikeExtension])

      assert Macros.lookup(registry, [:Mutare, :Test, :GettextLikeMacros], :translate, 2).args ==
               [:skip, :expression]

      assert Macros.lookup(registry, [:Mutare, :Test, :GettextLikeMacros], :ntranslate, 3).args ==
               [:skip, :skip, :expression]
    end
  end

  describe "Uses.annotate/2 — use-expansion override" do
    @use_source """
    defmodule Mutare.Test.GettextConsumer do
      use Mutare.Test.GettextLike
    end
    """

    test "without an extension, the raising __using__ harvests nothing" do
      assert use_directives(@use_source, []) == []
    end

    test "an extension override surfaces the directive the raising __using__ can't" do
      [directive] = use_directives(@use_source, [GettextLikeExtension])
      assert Sourceror.to_string(directive) == "import Mutare.Test.GettextLikeMacros"
    end

    test "a raising extension aborts loudly end to end (not swallowed by Harvest's boundary)" do
      # An extension crash must ride *through* the never-raise boundary that absorbs a target's
      # un-expandable `use`, surfacing as a ContractError rather than degrading to no directives.
      assert_raise Mutare.UseExpansion.ContractError, ~r/raised in expand_use\/3/, fn ->
        @use_source |> Sourceror.parse_string!() |> Uses.annotate([RaisingExtension])
      end
    end

    test "a malformed extension return aborts loudly end to end" do
      assert_raise Mutare.UseExpansion.ContractError, ~r/invalid result from expand_use\/3/, fn ->
        @use_source |> Sourceror.parse_string!() |> Uses.annotate([MalformedExtension])
      end
    end

    test "an extension may return a single quoted block of several directives" do
      directives = use_directives(@use_source, [BlockDirectiveExtension])
      rendered = Enum.map(directives, &Sourceror.to_string/1)

      # The block is descended into its two component imports — not folded as one opaque
      # `__block__` node (which would register neither).
      assert length(directives) == 2
      assert "import Mutare.Test.GettextLikeMacros" in rendered
      assert Enum.any?(rendered, &(&1 =~ "reverse: 1"))
    end

    test "a {module, opts} extension receives its opts and the caller module via context" do
      directives =
        use_directives(
          @use_source,
          [{ContextExtension, probe: self(), import: Mutare.Test.GettextLikeMacros}]
        )

      assert [directive] = directives
      assert Sourceror.to_string(directive) == "import Mutare.Test.GettextLikeMacros"

      # expand_use/3 saw the caller module (@use_source's defmodule) and the entry's opts.
      assert_received {:expand_use_context, Mutare.Test.GettextConsumer, opts}
      assert opts[:import] == Mutare.Test.GettextLikeMacros
    end

    test "an extension may inject @behaviours (Expansion behaviours), normalized to module atoms" do
      # BehaviourExtension's behaviours are [GenServer, GettextLikeMacros, "not a module", nil]: the two
      # concrete module atoms are kept (order preserved), while the non-atom string AND the degenerate
      # `nil` are both dropped. (The filter keeps concrete atoms per the Expansion contract; it does
      # not verify behaviour-ness — GettextLikeMacros isn't actually a behaviour, yet is kept.)
      assert use_behaviours(@use_source, [BehaviourExtension]) ==
               [GenServer, Mutare.Test.GettextLikeMacros]

      # The directive is surfaced alongside the behaviours.
      [directive] = use_directives(@use_source, [BehaviourExtension])
      assert Sourceror.to_string(directive) == "import Mutare.Test.GettextLikeMacros"
    end

    @nested_source """
    defmodule Mutare.Test.NestedConsumer do
      use Mutare.Test.NestedGettextUsing
    end
    """

    test "the override is consulted for a use nested inside another use's __using__ body" do
      # The Phoenix shape: `use MyAppWeb, :html` whose body injects `use Gettext, …`. Without the
      # extension, the nested `use GettextLike` is expanded in-process, raises (mutates the compiled
      # caller), and harvests nothing.
      assert use_directives(@nested_source, []) == []

      # With the extension, the nested `use` is overridden too (not only a top-level one), so the
      # injected import surfaces on the enclosing `use NestedGettextUsing` node.
      assert [directive] = use_directives(@nested_source, [GettextLikeExtension])
      assert Sourceror.to_string(directive) == "import Mutare.Test.GettextLikeMacros"
    end

    test "the override makes the bare macro calls resolve" do
      source = """
      defmodule Mutare.Test.GettextConsumer do
        use Mutare.Test.GettextLike

        def f, do: translate("hi")
      end
      """

      assert resolved_module(source, []) == nil

      assert resolved_module(source, [GettextLikeExtension]) ==
               {[:Mutare, :Test, :GettextLikeMacros], :bare}
    end
  end

  describe "end to end — per-position routing through transform_string" do
    @source """
    defmodule Mutare.Test.GettextSample do
      use Mutare.Test.GettextLike

      def greet(n) do
        a = translate("Hello")
        b = translate("Hi", count: n + 1)
        c = ntranslate("one", "many", n + 1)
        {a, b, c}
      end
    end
    """

    @mutators [Mutare.Mutators.StringLiteral, Mutare.Mutators.Arithmetic]

    test "the extension skips the msgid literals but keeps the runtime-arg mutations" do
      {_meta, with_extension, _} =
        Mutare.transform_string(@source, mutators: @mutators, extensions: [GettextLikeExtension])

      {_meta, without_extension, _} = Mutare.transform_string(@source, mutators: @mutators)

      # Without the extension the bare calls don't resolve, so every msgid is mutated as an
      # ordinary runtime string — the path that would poison the build. With the extension the
      # msgid positions are routed :skip, so not one StringLiteral site survives.
      assert count(without_extension, :string) > 0
      assert count(with_extension, :string) == 0

      # The bindings value and the ngettext count (routed :expression) mutate identically
      # either way — the extension removes *only* the literal-position mutations, nothing else.
      assert count(with_extension, :arithmetic) == count(without_extension, :arithmetic)
      assert count(with_extension, :arithmetic) > 0
    end

    test "a non-mutating extension's shape-aware classifier controls transform routing" do
      source = """
      defmodule Mutare.Test.DynamicRoutingSample do
        def value, do: Mutare.Test.SomeDSL.dynamic_frag("skip me")
      end
      """

      {_meta, with_extension, _} =
        Mutare.transform_string(source,
          mutators: [Mutare.Mutators.StringLiteral],
          extensions: [DynamicRoutingExtension]
        )

      {_meta, without_extension, _} =
        Mutare.transform_string(source, mutators: [Mutare.Mutators.StringLiteral])

      assert count(without_extension, :string) > 0
      assert count(with_extension, :string) == 0
    end
  end

  describe "transform_string validates :extensions (fails loudly, never silently drops)" do
    test "raises on a module that is not an extension" do
      assert_raise ArgumentError,
                   ~r/:extensions entries must be loaded non-mutator modules/,
                   fn ->
                     Mutare.transform_string("defmodule Mutare.Test.Z do\nend",
                       extensions: [Enum]
                     )
                   end
    end

    test "raises on a non-list" do
      assert_raise ArgumentError, ~r/:extensions must be a list/, fn ->
        Mutare.transform_string("defmodule Mutare.Test.Z do\nend",
          extensions: GettextLikeExtension
        )
      end
    end
  end

  # --- helpers --------------------------------------------------------------

  defp count(sites, mutator), do: Enum.count(sites, &(&1.mutator == mutator))

  # An extension expansion result carrying exactly the `import Mutare.Test.GettextLikeMacros`
  # directive — compared by rendered form, since the quoted `import` carries a `context:` meta
  # that varies with the calling module.
  defp assert_gettext_import(result) do
    assert %UseExpansion.Expansion{directives: [directive]} = result
    assert Macro.to_string(directive) == "import Mutare.Test.GettextLikeMacros"
  end

  defp use_directives(source, extensions) do
    {_ast, acc} =
      source
      |> Sourceror.parse_string!()
      |> Uses.annotate(extensions)
      |> Macro.prewalk([], fn
        {:use, meta, _} = node, acc when is_list(meta) -> {node, acc ++ Uses.directives(meta)}
        node, acc -> {node, acc}
      end)

    acc
  end

  defp use_behaviours(source, extensions) do
    {_ast, acc} =
      source
      |> Sourceror.parse_string!()
      |> Uses.annotate(extensions)
      |> Macro.prewalk([], fn
        {:use, meta, _} = node, acc when is_list(meta) ->
          {node, acc ++ Uses.injected_behaviours(meta)}

        node, acc ->
          {node, acc}
      end)

    acc
  end

  # The import resolution stamped on the first `translate` call after Uses (with the given
  # extensions) and Resolve — the contract the call-matching families and the macro router read.
  defp resolved_module(source, extensions) do
    {_ast, resolved} =
      source
      |> Sourceror.parse_string!()
      |> Uses.annotate(extensions)
      |> Resolve.annotate()
      |> Macro.prewalk(nil, fn
        {:translate, meta, args} = node, _acc when is_list(args) ->
          {node, Imports.resolved_import(meta)}

        node, acc ->
          {node, acc}
      end)

    resolved
  end
end
