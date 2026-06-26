defmodule Mutare.PluginTest do
  use ExUnit.Case, async: true

  alias Mutare.{Macros, Plugin}

  alias Mutare.Test.{
    BehaviourPlugin,
    BlockDirectivePlugin,
    ContextPlugin,
    DecliningPlugin,
    EmptyExpansionPlugin,
    ExitingPlugin,
    GettextLike,
    GettextLikePlugin,
    HostingPlugin,
    MalformedPlugin,
    RaisingPlugin,
    ThrowingPlugin
  }

  alias Mutare.Transform.{Imports, Resolve, Uses}

  describe "plugin?/1" do
    test "a loaded module exporting a plugin callback is a plugin" do
      assert Plugin.plugin?(GettextLikePlugin)
      assert Plugin.plugin?(DecliningPlugin)
    end

    test "a module exporting neither plugin callback is not a plugin" do
      refute Plugin.plugin?(Mutare.Mutators.Arithmetic)
      refute Plugin.plugin?(Enum)
    end

    test "a Mutare.Mutator is not a plugin, even one that exports macros/0" do
      # QueryMutator is a macro-aware mutator: it exports `macros/0` (which on its own would look
      # plugin-like) but declares `@behaviour Mutare.Mutator`, so it is excluded.
      refute Plugin.plugin?(Mutare.Test.QueryMutator)
    end

    test "a non-module / unloadable atom is not a plugin" do
      refute Plugin.plugin?(:not_a_module)
      refute Plugin.plugin?("Elixir.Nope")
      refute Plugin.plugin?(nil)
    end
  end

  describe "use_handlers/1" do
    test "keeps only the plugins exporting expand_use/3, resolved to specs" do
      # GettextLikePlugin + RaisingPlugin + DecliningPlugin export it; a macros-only
      # plugin would not. Order is preserved (dispatch is first-non-decline-wins) and each
      # entry resolves to a Plugin.Spec (a bare module → empty opts).
      assert Plugin.use_handlers([GettextLikePlugin, DecliningPlugin, Mutare.Mutators.Arithmetic]) ==
               [%Plugin.Spec{module: GettextLikePlugin}, %Plugin.Spec{module: DecliningPlugin}]
    end

    test "carries a {module, opts} entry's opts onto its spec" do
      assert Plugin.use_handlers([{GettextLikePlugin, [domain: "errors"]}]) ==
               [%Plugin.Spec{module: GettextLikePlugin, opts: [domain: "errors"]}]
    end
  end

  describe "expand_use/4 dispatch" do
    test "no handlers → :decline" do
      assert Plugin.expand_use([], GettextLike, [], %{}) == :decline
    end

    test "the first non-declining handler wins" do
      result = Plugin.expand_use([DecliningPlugin, GettextLikePlugin], GettextLike, [], %{})
      assert_gettext_import(result)
    end

    test "every handler declining → :decline" do
      assert Plugin.expand_use([DecliningPlugin, DecliningPlugin], GettextLike, [], %{}) ==
               :decline
    end

    test "a handler that doesn't match the module declines (falls through)" do
      assert Plugin.expand_use([GettextLikePlugin], SomeOtherModule, [], %{}) == :decline
    end

    test "a raising handler surfaces loudly as ContractError (not isolated to :decline)" do
      # A plugin *crash* is a misconfiguration, so it aborts loudly — it does NOT fall through to
      # the next handler, and a sole raising handler does NOT degrade to :decline. (Contrast a
      # target's un-expandable `use`, which stays silent.)
      assert_raise Mutare.Plugin.ContractError, ~r/raised in expand_use\/3/, fn ->
        Plugin.expand_use([RaisingPlugin, GettextLikePlugin], GettextLike, [], %{})
      end

      assert_raise Mutare.Plugin.ContractError, ~r/raised in expand_use\/3/, fn ->
        Plugin.expand_use([RaisingPlugin], GettextLike, [], %{})
      end
    end

    test "a throwing handler surfaces as ContractError (the :throw catch arm)" do
      # A non-local `throw` is not an exception, so it bypasses `rescue` and is caught by the
      # `catch :throw, value` clause — still a loud ContractError, never a silent decline.
      assert_raise Mutare.Plugin.ContractError,
                   ~r/threw :thrown_from_plugin in expand_use\/3/,
                   fn ->
                     Plugin.expand_use([ThrowingPlugin], GettextLike, [], %{})
                   end
    end

    test "an exiting handler surfaces as ContractError (the non-:throw catch arm)" do
      assert_raise Mutare.Plugin.ContractError, ~r/signalled exit :exited_from_plugin/, fn ->
        Plugin.expand_use([ExitingPlugin], GettextLike, [], %{})
      end
    end

    test "an empty Expansion still wins (handle-and-inject-nothing, not fall-through)" do
      # `Plugin.expand([])` is a deliberate "I handle this, inject nothing": first-non-:decline
      # wins, so it suppresses the later GettextLikePlugin (and, in Harvest, in-process expansion).
      # A plugin that wants to fall through must return :decline, not an empty Expansion.
      assert Plugin.expand_use([EmptyExpansionPlugin, GettextLikePlugin], GettextLike, [], %{}) ==
               %Plugin.Expansion{directives: [], behaviours: []}
    end

    test "a malformed return raises loudly (ContractError), not a silent decline" do
      # Returning a non-Expansion/non-:decline value is a *configuration* error (a broken plugin),
      # so — unlike a raising handler — it surfaces loudly rather than degrading to :decline.
      assert_raise Mutare.Plugin.ContractError, ~r/invalid result from expand_use\/3/, fn ->
        Plugin.expand_use([MalformedPlugin], GettextLike, [], %{module: Mutare.Test.SomeCaller})
      end
    end

    test "passes the caller :module and the plugin's :opts into the context" do
      result =
        Plugin.expand_use(
          [{ContextPlugin, [probe: self(), import: Mutare.Test.GettextLikeMacros]}],
          GettextLike,
          [],
          %{module: Mutare.Test.SomeCaller}
        )

      assert %Plugin.Expansion{} = result
      assert_received {:expand_use_context, Mutare.Test.SomeCaller, opts}
      assert opts[:probe] == self()
    end
  end

  describe "expand/2 contract" do
    test "builds an Expansion from lists" do
      assert %Plugin.Expansion{directives: [:d], behaviours: [GenServer]} =
               Plugin.expand([:d], [GenServer])
    end

    test "a non-list argument raises ContractError (loud, not a swallowed FunctionClauseError)" do
      # `quote do import Foo end` is a single node, not a list — a common plugin-author slip. It
      # must fail loudly rather than being swallowed to a silent :decline inside safe_expand.
      assert_raise Mutare.Plugin.ContractError, ~r/expects a list of directives/, fn ->
        Plugin.expand(quote(do: import(Enum)))
      end
    end
  end

  describe "Mutare.Plugin.ContractError" do
    test "exception/1 accepts a bare string message (the is_binary clause)" do
      # The plugin code raises it with a `message:` keyword; this pins the binary shortcut so a
      # `raise ContractError, "..."` also carries its text.
      err = Mutare.Plugin.ContractError.exception("plain message")
      assert Exception.message(err) == "plain message"
    end
  end

  describe "Macros.from_plugins/1 + build/3" do
    test "a plugin's macros/0 entries are collected, carrying no host (a plugin can't host)" do
      [_ | _] = specs = Macros.from_plugins([GettextLikePlugin])
      keys = Enum.map(specs, &Mutare.Macro.Spec.key/1)

      assert {[:Mutare, :Test, :GettextLikeMacros], :translate, 1} in keys
      assert {[:Mutare, :Test, :GettextLikeMacros], :ntranslate, 3} in keys

      # A plugin produces no mutations, so it can never host one — its specs carry no host, keeping
      # Spec.host a true invariant (a non-nil host always names a real hosting mutator).
      assert Enum.all?(specs, &is_nil(&1.host))
    end

    test "a plugin module with no macros/0 contributes nothing" do
      assert Macros.from_plugins([DecliningPlugin]) == []
    end

    test "from_plugins accepts resolved Plugin.Specs too (not only bare modules)" do
      from_module = Macros.from_plugins([GettextLikePlugin])
      from_spec = Macros.from_plugins([%Plugin.Spec{module: GettextLikePlugin}])

      assert Enum.map(from_spec, &Mutare.Macro.Spec.key/1) ==
               Enum.map(from_module, &Mutare.Macro.Spec.key/1)
    end

    test "a plugin macros/0 declaring a :hosted/:routing treatment is rejected (plugins can't host)" do
      # A plugin produces no mutations, so it cannot host one — caught with a plugin-specific
      # message rather than build/3's generic "hosting mutator" abort that mislabels the plugin.
      assert_raise ArgumentError, ~r/plugin produces no mutations and cannot host one/, fn ->
        Macros.from_plugins([HostingPlugin])
      end
    end

    test "build/3 merges plugin macros into the registry" do
      registry = Macros.build([], [], [GettextLikePlugin])

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

    test "without a plugin, the raising __using__ harvests nothing" do
      assert use_directives(@use_source, []) == []
    end

    test "a plugin override surfaces the directive the raising __using__ can't" do
      [directive] = use_directives(@use_source, [GettextLikePlugin])
      assert Sourceror.to_string(directive) == "import Mutare.Test.GettextLikeMacros"
    end

    test "a raising plugin aborts loudly end to end (not swallowed by Harvest's boundary)" do
      # A plugin crash must ride *through* the never-raise boundary that absorbs a target's
      # un-expandable `use`, surfacing as a ContractError rather than degrading to no directives.
      assert_raise Mutare.Plugin.ContractError, ~r/raised in expand_use\/3/, fn ->
        @use_source |> Sourceror.parse_string!() |> Uses.annotate([RaisingPlugin])
      end
    end

    test "a malformed plugin return aborts loudly end to end" do
      assert_raise Mutare.Plugin.ContractError, ~r/invalid result from expand_use\/3/, fn ->
        @use_source |> Sourceror.parse_string!() |> Uses.annotate([MalformedPlugin])
      end
    end

    test "a plugin may return a single quoted block of several directives" do
      directives = use_directives(@use_source, [BlockDirectivePlugin])
      rendered = Enum.map(directives, &Sourceror.to_string/1)

      # The block is descended into its two component imports — not folded as one opaque
      # `__block__` node (which would register neither).
      assert length(directives) == 2
      assert "import Mutare.Test.GettextLikeMacros" in rendered
      assert Enum.any?(rendered, &(&1 =~ "reverse: 1"))
    end

    test "a {module, opts} plugin receives its opts and the caller module via context" do
      directives =
        use_directives(
          @use_source,
          [{ContextPlugin, probe: self(), import: Mutare.Test.GettextLikeMacros}]
        )

      assert [directive] = directives
      assert Sourceror.to_string(directive) == "import Mutare.Test.GettextLikeMacros"

      # expand_use/3 saw the caller module (@use_source's defmodule) and the entry's opts.
      assert_received {:expand_use_context, Mutare.Test.GettextConsumer, opts}
      assert opts[:import] == Mutare.Test.GettextLikeMacros
    end

    test "a plugin may inject @behaviours (Expansion behaviours), normalized to module atoms" do
      # BehaviourPlugin's behaviours are [GenServer, GettextLikeMacros, "not a module", nil]: the two
      # concrete module atoms are kept (order preserved), while the non-atom string AND the degenerate
      # `nil` are both dropped. (The filter keeps concrete atoms per the Expansion contract; it does
      # not verify behaviour-ness — GettextLikeMacros isn't actually a behaviour, yet is kept.)
      assert use_behaviours(@use_source, [BehaviourPlugin]) ==
               [GenServer, Mutare.Test.GettextLikeMacros]

      # The directive is surfaced alongside the behaviours.
      [directive] = use_directives(@use_source, [BehaviourPlugin])
      assert Sourceror.to_string(directive) == "import Mutare.Test.GettextLikeMacros"
    end

    @nested_source """
    defmodule Mutare.Test.NestedConsumer do
      use Mutare.Test.NestedGettextUsing
    end
    """

    test "the override is consulted for a use nested inside another use's __using__ body" do
      # The Phoenix shape: `use MyAppWeb, :html` whose body injects `use Gettext, …`. Without the
      # plugin, the nested `use GettextLike` is expanded in-process, raises (mutates the compiled
      # caller), and harvests nothing.
      assert use_directives(@nested_source, []) == []

      # With the plugin, the nested `use` is overridden too (not only a top-level one), so the
      # injected import surfaces on the enclosing `use NestedGettextUsing` node.
      assert [directive] = use_directives(@nested_source, [GettextLikePlugin])
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

      assert resolved_module(source, [GettextLikePlugin]) ==
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

    test "the plugin skips the msgid literals but keeps the runtime-arg mutations" do
      {_meta, with_plugin, _} =
        Mutare.transform_string(@source, mutators: @mutators, plugins: [GettextLikePlugin])

      {_meta, without_plugin, _} = Mutare.transform_string(@source, mutators: @mutators)

      # Without the plugin the bare calls don't resolve, so every msgid is mutated as an
      # ordinary runtime string — the path that would poison the build. With the plugin the
      # msgid positions are routed :skip, so not one StringLiteral site survives.
      assert count(without_plugin, :string) > 0
      assert count(with_plugin, :string) == 0

      # The bindings value and the ngettext count (routed :expression) mutate identically
      # either way — the plugin removes *only* the literal-position mutations, nothing else.
      assert count(with_plugin, :arithmetic) == count(without_plugin, :arithmetic)
      assert count(with_plugin, :arithmetic) > 0
    end
  end

  describe "transform_string validates :plugins (fails loudly, never silently drops)" do
    test "raises on a module that is not a plugin" do
      assert_raise ArgumentError, ~r/:plugins entries must be loaded modules/, fn ->
        Mutare.transform_string("defmodule Mutare.Test.Z do\nend", plugins: [Enum])
      end
    end

    test "raises on a non-list" do
      assert_raise ArgumentError, ~r/:plugins must be a list/, fn ->
        Mutare.transform_string("defmodule Mutare.Test.Z do\nend", plugins: GettextLikePlugin)
      end
    end
  end

  # --- helpers --------------------------------------------------------------

  defp count(sites, mutator), do: Enum.count(sites, &(&1.mutator == mutator))

  # A plugin expansion result carrying exactly the `import Mutare.Test.GettextLikeMacros`
  # directive — compared by rendered form, since the quoted `import` carries a `context:` meta
  # that varies with the calling module.
  defp assert_gettext_import(result) do
    assert %Plugin.Expansion{directives: [directive]} = result
    assert Macro.to_string(directive) == "import Mutare.Test.GettextLikeMacros"
  end

  defp use_directives(source, plugins) do
    {_ast, acc} =
      source
      |> Sourceror.parse_string!()
      |> Uses.annotate(plugins)
      |> Macro.prewalk([], fn
        {:use, meta, _} = node, acc when is_list(meta) -> {node, acc ++ Uses.directives(meta)}
        node, acc -> {node, acc}
      end)

    acc
  end

  defp use_behaviours(source, plugins) do
    {_ast, acc} =
      source
      |> Sourceror.parse_string!()
      |> Uses.annotate(plugins)
      |> Macro.prewalk([], fn
        {:use, meta, _} = node, acc when is_list(meta) ->
          {node, acc ++ Uses.injected_behaviours(meta)}

        node, acc ->
          {node, acc}
      end)

    acc
  end

  # The import resolution stamped on the first `translate` call after Uses (with the given
  # plugins) and Resolve — the contract the call-matching families and the macro router read.
  defp resolved_module(source, plugins) do
    {_ast, resolved} =
      source
      |> Sourceror.parse_string!()
      |> Uses.annotate(plugins)
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
