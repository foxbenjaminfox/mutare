defmodule Mutare.MacroRouting.RegistryTest do
  use ExUnit.Case, async: true

  alias Mutare.Macro.Spec
  alias Mutare.MacroRouting.Registry, as: Macros
  alias Mutare.MacroRouting.Registry.Entry
  alias Mutare.Mutator

  describe "Macro.Spec.normalize_module/1" do
    test "an Elixir-module alias becomes its path as atoms (without the Elixir. prefix)" do
      assert Spec.normalize_module(Ecto.Query) == [:Ecto, :Query]
      assert Spec.normalize_module(Kernel) == [:Kernel]
      assert Spec.normalize_module(String) == [:String]
    end

    test "an Erlang-module atom is kept verbatim" do
      assert Spec.normalize_module(:binary) == :binary
      assert Spec.normalize_module(:string) == :string
    end

    test "an already-normalized atom path is kept verbatim" do
      assert Spec.normalize_module([:Ecto, :Query]) == [:Ecto, :Query]
    end

    test "a malformed module reference raises" do
      assert_raise ArgumentError, fn -> Spec.normalize_module("Ecto.Query") end
      assert_raise ArgumentError, fn -> Spec.normalize_module([:Ecto, "Query"]) end
    end
  end

  describe "Macro.Spec.new/4 and routing/2" do
    test "a uniform-atom args repeats for the arity" do
      spec = Spec.new(Ecto.Query, :from, :any, :skip)
      assert spec == %Spec{module: [:Ecto, :Query], name: :from, arity: :any, args: :skip}
      assert Spec.routing(spec, 2) == [:skip, :skip]
      assert Spec.routing(spec, 0) == []
    end

    test "a per-position list pads later positions with :expression" do
      spec = Spec.new(Kernel, :match?, 2, [:pattern])
      assert Spec.routing(spec, 2) == [:pattern, :expression]
      assert Spec.routing(spec, 3) == [:pattern, :expression, :expression]
    end

    test "validates name, arity, and treatments" do
      assert_raise ArgumentError, fn -> Spec.new(Kernel, "match?", 2, :pattern) end
      assert_raise ArgumentError, fn -> Spec.new(Kernel, :match?, -1, :pattern) end
      assert_raise ArgumentError, fn -> Spec.new(Kernel, :match?, 2, :bogus) end
      assert_raise ArgumentError, fn -> Spec.new(Kernel, :match?, 2, [:pattern, :bogus]) end
    end

    test "static routes accept pinned and recursive keyword treatments" do
      assert %Spec{args: [:expression, {:keyword, [:pinned, :skip]}]} =
               Spec.new(Foo, :set, 2, [:expression, {:keyword, [:pinned, :skip]}])
    end
  end

  describe "Macros.resolve/1" do
    test "accepts the 4-tuple and 3-tuple (arity :any) forms" do
      assert [%Spec{module: [:Kernel], name: :match?, arity: 2, args: [:pattern, :expression]}] =
               Macros.resolve([{Kernel, :match?, 2, [:pattern, :expression]}])

      assert [%Spec{module: [:Ecto, :Query], name: :from, arity: :any, args: :skip}] =
               Macros.resolve([{Ecto.Query, :from, :skip}])
    end

    test "is idempotent on an already-resolved spec" do
      spec = Spec.new(Kernel, :match?, 2, [:pattern])
      assert Macros.resolve([spec]) == [spec]
    end

    test "raises on a malformed entry" do
      assert_raise ArgumentError, fn -> Macros.resolve([{Kernel, :match?}]) end
      assert_raise ArgumentError, fn -> Macros.resolve(:nope) end
    end
  end

  describe "Macros.builtin/0" do
    test "match? and destructure are built in, routing arg 0 as a pattern" do
      registry = Macros.build([], [])
      # `match?` routes arg 0 as `:pattern`, arg 1 as `:expression`.
      assert %Entry{spec: %Spec{args: [:pattern, :expression]}} =
               Macros.lookup(registry, [:Kernel], :match?, 2)

      # `destructure`'s bindings escape, so arg 0 is the richer `:binding_pattern`
      # (structural mutants in a value-discarded position); `match?`'s stay `:pattern`.
      assert %Entry{spec: %Spec{args: [:binding_pattern, :expression]}} =
               Macros.lookup(registry, [:Kernel], :destructure, 2)
    end

    test "an unmatched module/name/arity returns nil" do
      registry = Macros.build([], [])
      assert Macros.lookup(registry, [:SomeMod], :match?, 2) == nil
      assert Macros.lookup(registry, [:Kernel], :other, 2) == nil
      assert Macros.lookup(registry, [:Kernel], :match?, 3) == nil
    end
  end

  describe "Macros.build/3 — merge, precedence, :any fallback" do
    test "declarative entries override a built-in of the same key" do
      registry = Macros.build([{Kernel, :match?, 2, :skip}], [])
      assert %Entry{spec: %Spec{args: :skip}} = Macros.lookup(registry, [:Kernel], :match?, 2)
    end

    test "an exact-arity entry wins over an :any entry" do
      registry = Macros.build([{Foo, :bar, :skip}, {Foo, :bar, 1, [:pattern]}], [])

      assert %Entry{spec: %Spec{arity: 1, args: [:pattern]}} =
               Macros.lookup(registry, [:Foo], :bar, 1)

      assert %Entry{spec: %Spec{arity: :any, args: :skip}} =
               Macros.lookup(registry, [:Foo], :bar, 2)
    end

    test "a mutator's macro_routes/0 contributes entries" do
      specs = Mutator.Spec.for_module(Mutare.Test.QueryMutator)
      registry = Macros.build([], [specs])

      assert %Entry{spec: %Spec{args: :skip}} =
               Macros.lookup(registry, [:Mutare, :Test, :QueryDSL], :query, 1)
    end

    test "a mutator without macro_routes/0 contributes nothing" do
      specs = Mutator.Spec.for_module(Mutare.Test.BooleanMutator)
      assert Macros.from_mutators([specs]) == []
    end

    test "an explicit :macro_routes config entry wins over a mutator's macro_routes/0 for the same key" do
      # QueryMutator registers {Mutare.Test.QueryDSL, :query, 1, :skip}; an explicit config entry
      # for the same key overrides it (config is the final authority — folded last).
      specs = Mutator.Spec.for_module(Mutare.Test.QueryMutator)
      registry = Macros.build([{Mutare.Test.QueryDSL, :query, 1, [:expression]}], [specs])

      assert %Entry{spec: %Spec{args: [:expression]}} =
               Macros.lookup(registry, [:Mutare, :Test, :QueryDSL], :query, 1)
    end

    test "an explicit :macro_routes config entry resolves code-provider conflicts for the same key" do
      # Config is the final authority. If a user explicitly routes the same macro, the registry
      # must not reject two enabled code providers before the override can break the tie.
      specs = Mutator.Spec.for_module(Mutare.Test.QueryMutator)

      registry =
        Macros.build(
          [{Mutare.Test.QueryDSL, :query, 1, [:expression]}],
          [specs],
          [Mutare.Test.ConflictingQueryRoutingExtension]
        )

      assert %Entry{spec: %Spec{args: [:expression]}, sources: [:config]} =
               Macros.lookup(registry, [:Mutare, :Test, :QueryDSL], :query, 1)
    end
  end

  describe "the :hosted treatment and :routing classifier" do
    test "treatments/0 includes :hosted" do
      assert :hosted in Spec.treatments()
    end

    test "Spec.new accepts :hosted in a list and the :routing classifier sentinel" do
      assert %Spec{args: [:expression, :hosted]} =
               Spec.new(Ecto.Query, :where, 2, [:expression, :hosted])

      assert %Spec{args: :routing} = Spec.new(Ecto.Query, :where, :any, :routing)
    end

    test "classifier?/1 and host_required?/1 distinguish routing from hosting" do
      assert Spec.classifier?(Spec.new(Foo, :bar, :any, :routing))
      refute Spec.classifier?(Spec.new(Foo, :bar, 2, [:expression, :hosted]))

      refute Spec.host_required?(Spec.new(Foo, :bar, :any, :routing))
      assert Spec.host_required?(Spec.new(Foo, :bar, 2, [:expression, :hosted]))
      assert Spec.host_required?(Spec.new(Foo, :bar, 1, :hosted))
      refute Spec.host_required?(Spec.new(Foo, :bar, 2, [:pattern, :expression]))
    end

    test "routing/2 refuses to expand a :routing spec without the call node" do
      assert_raise ArgumentError, ~r/resolved per call node/, fn ->
        Spec.routing(Spec.new(Foo, :bar, :any, :routing), 2)
      end
    end
  end

  describe "router and host composition" do
    test "from_mutators stamps only routing provenance; hosts are independent subscriptions" do
      specs = Mutator.Spec.for_module(Mutare.Test.HostMutator)
      contributed = Macros.from_mutators([specs])

      assert Enum.all?(contributed, &(&1.hosts == []))
      assert Enum.all?(contributed, &(&1.spec.module == [:Mutare, :Test, :HostDSL]))

      filter = Enum.find(contributed, &(&1.spec.name == :filter))
      assert filter.spec.args == :routing
      assert filter.router == Mutare.Test.HostMutator

      pick = Enum.find(contributed, &(&1.spec.name == :pick))
      assert pick.spec.args == [:binding_pattern, :hosted]
      assert pick.router == nil
    end

    test "build/3 resolves a host-needing macro through a mutator" do
      specs = Mutator.Spec.for_module(Mutare.Test.HostMutator)
      registry = Macros.build([], [specs])

      assert %Entry{
               spec: %Spec{args: :routing},
               router: Mutare.Test.HostMutator,
               hosts: [Mutare.Test.HostMutator]
             } =
               Macros.lookup(registry, [:Mutare, :Test, :HostDSL], :filter, 2)
    end

    test "several host mutators subscribe to one independently-owned route" do
      router = Mutator.Spec.for_module(Mutare.Test.HostMutator)
      second_host = Mutator.Spec.for_module(Mutare.Test.SecondHostMutator)
      registry = Macros.build([], [router, second_host])

      assert %Entry{hosts: hosts} =
               Macros.lookup(registry, [:Mutare, :Test, :HostDSL], :filter, 2)

      assert MapSet.new(hosts) ==
               MapSet.new([Mutare.Test.HostMutator, Mutare.Test.SecondHostMutator])
    end

    test "an explicit static hosted route composes with a host-only mutator" do
      host = Mutator.Spec.for_module(Mutare.Test.SecondHostMutator)

      registry =
        Macros.build(
          [{Mutare.Test.HostDSL, :filter, 2, [:expression, :hosted]}],
          [host]
        )

      assert %Entry{router: nil, hosts: [Mutare.Test.SecondHostMutator]} =
               Macros.lookup(registry, [:Mutare, :Test, :HostDSL], :filter, 2)
    end

    test "conflicting code-provided routes raise instead of depending on provider order" do
      mutator = Mutator.Spec.for_module(Mutare.Test.QueryMutator)

      assert_raise Mutare.MacroRouting.ContractError, ~r/conflicting macro routes/, fn ->
        Macros.build([], [mutator], [Mutare.Test.ConflictingQueryRoutingExtension])
      end
    end

    test "identical static declarations from independent providers coalesce" do
      mutator = Mutator.Spec.for_module(Mutare.Test.QueryMutator)

      registry = Macros.build([], [mutator], [Mutare.Test.IdenticalQueryRoutingExtension])

      assert %Entry{spec: %Spec{args: :skip}, sources: sources} =
               Macros.lookup(registry, [:Mutare, :Test, :QueryDSL], :query, 1)

      assert {:mutator, Mutare.Test.QueryMutator} in sources
      assert {:extension, Mutare.Test.IdenticalQueryRoutingExtension} in sources
    end

    test "a broad static hosted route requires a host subscription covering its full selector" do
      host = Mutator.Spec.for_module(Mutare.Test.SecondHostMutator)

      assert_raise Mutare.MacroRouting.ContractError, ~r/no enabled.*MacroHost/s, fn ->
        Macros.build([{Mutare.Test.HostDSL, :*, :hosted}], [host])
      end
    end

    test "a broader dynamic route does not make a host reachable through a shadowing exact route" do
      host = Mutator.Spec.for_module(Mutare.Test.ShadowedHostMutator)

      assert_raise Mutare.MacroRouting.ContractError, ~r/no active.*route can reach/s, fn ->
        Macros.build([], [host], [Mutare.Test.ShadowingRoutingExtension])
      end
    end

    test "a host-only mutator must subscribe to at least one macro" do
      host = Mutator.Spec.for_module(Mutare.Test.EmptySubscriptionHostMutator)

      assert_raise Mutare.MacroRouting.ContractError, ~r/returned an empty list/, fn ->
        Macros.build([], [host])
      end
    end

    test "build/3 raises when a declarative entry asks for callback-backed routing" do
      assert_raise ArgumentError, ~r/requires macro_routes\/0 and route_arguments\/2/, fn ->
        Macros.build([{Ecto.Query, :where, :any, :routing}], [])
      end

      assert_raise Mutare.MacroRouting.ContractError, ~r/no enabled.*MacroHost/s, fn ->
        Macros.build([{Ecto.Query, :where, 2, [:expression, :hosted]}], [])
      end
    end

    test "build/3 raises when a mutator registers :hosted but omits host/2" do
      # A static `:hosted` route requires its contributing mutator to export `host/2` to deliver
      # it; the missing callback is named clearly at build rather than failing cryptically at
      # delivery later.
      specs = Mutator.Spec.for_module(Mutare.Test.IncompleteHostMutator)

      assert_raise Mutare.MacroRouting.ContractError, ~r/no enabled.*MacroHost/s, fn ->
        Macros.build([], [specs])
      end
    end

    test "a shape-aware router need not implement MacroHost" do
      specs = Mutator.Spec.for_module(Mutare.Test.NoDeliveryHostMutator)
      registry = Macros.build([], [specs])

      assert %Entry{
               spec: %Spec{args: :routing},
               router: Mutare.Test.NoDeliveryHostMutator,
               hosts: []
             } = Macros.lookup(registry, [:Mutare, :Test, :HostDSL], :filter, 2)
    end

    test "build/3 rejects a host/2 no route reaches (silently-inert safety net)" do
      specs = Mutator.Spec.for_module(Mutare.Test.DeadHostMutator)

      assert_raise Mutare.MacroRouting.ContractError,
                   ~r/subscribes to.*no active/s,
                   fn ->
                     Macros.build([], [specs])
                   end
    end

    test "build/3 rejects a route_arguments/2 no :routing route reaches" do
      specs = Mutator.Spec.for_module(Mutare.Test.DeadRouterMutator)

      assert_raise Mutare.MacroRouting.ContractError,
                   ~r/implements route_arguments\/2 but registers no :routing route/,
                   fn ->
                     Macros.build([], [specs])
                   end
    end
  end

  describe "Macros.lookup/4" do
    test "returns the whole entry, exact arity over :any" do
      registry = Macros.build([{Foo, :bar, :skip}, {Foo, :bar, 1, [:pattern]}], [])

      assert %Entry{spec: %Spec{arity: 1, args: [:pattern]}} =
               Macros.lookup(registry, [:Foo], :bar, 1)

      assert %Entry{spec: %Spec{arity: :any, args: :skip}} =
               Macros.lookup(registry, [:Foo], :bar, 2)

      assert Macros.lookup(registry, [:Foo], :baz, 1) == nil
    end
  end

  describe "wildcard entries (`:*`)" do
    test "Spec.wildcard/0 is the glob atom" do
      assert Spec.wildcard() == :*
    end

    test "a whole-module entry routes every macro in the module" do
      registry = Macros.build([{Foo, :*, :skip}], [])

      assert %Entry{spec: %Spec{module: [:Foo], name: :*, args: :skip}} =
               Macros.lookup(registry, [:Foo], :bar, 1)

      assert %Entry{spec: %Spec{args: :skip}} = Macros.lookup(registry, [:Foo], :anything_else, 3)
      # …but only in that module.
      assert Macros.lookup(registry, [:Other], :bar, 1) == nil
    end

    test "a more specific entry overrides a whole-module one (per-macro override)" do
      registry = Macros.build([{Foo, :*, :skip}, {Foo, :bar, 2, [:pattern, :expression]}], [])

      assert %Entry{spec: %Spec{args: [:pattern, :expression]}} =
               Macros.lookup(registry, [:Foo], :bar, 2)

      # The override is arity-specific; bar/1 still falls through to the whole-module :skip.
      assert %Entry{spec: %Spec{name: :*, args: :skip}} = Macros.lookup(registry, [:Foo], :bar, 1)
      assert %Entry{spec: %Spec{name: :*, args: :skip}} = Macros.lookup(registry, [:Foo], :baz, 9)
    end

    test "a name-only entry matches the name in any module — including an unresolved (nil) one" do
      registry = Macros.build([{:*, :sigil_X, :skip}], [])

      assert %Entry{spec: %Spec{module: :*, name: :sigil_X, args: :skip}} =
               Macros.lookup(registry, [:AnyMod], :sigil_X, 1)

      assert %Entry{spec: %Spec{args: :skip}} =
               Macros.lookup(registry, [:Totally, :Different], :sigil_X, 2)

      # The escape hatch's whole point: it fires even when the module couldn't be resolved.
      assert %Entry{spec: %Spec{args: :skip}} = Macros.lookup(registry, nil, :sigil_X, 0)
      # but not for a different name
      assert Macros.lookup(registry, [:AnyMod], :other, 1) == nil
    end

    test "name-only is the last resort — a module-specific or built-in entry wins" do
      registry =
        Macros.build([{:*, :match?, :skip}, {Foo, :match?, 2, [:pattern, :expression]}], [])

      # The built-in Kernel.match?/2 (a pattern) is not shadowed by the name-only :skip.
      assert %Entry{spec: %Spec{module: [:Kernel], args: [:pattern, :expression]}} =
               Macros.lookup(registry, [:Kernel], :match?, 2)

      # A module-specific entry beats the name-only one too.
      assert %Entry{spec: %Spec{module: [:Foo], args: [:pattern, :expression]}} =
               Macros.lookup(registry, [:Foo], :match?, 2)

      # An unrelated module falls through to the name-only escape hatch.
      assert %Entry{spec: %Spec{module: :*, args: :skip}} =
               Macros.lookup(registry, [:Bar], :match?, 2)
    end

    test ":* is a synonym for :any in the arity slot" do
      assert %Spec{arity: :any} = Spec.new(Foo, :bar, :*, :skip)
    end

    test "rejects wildcarding both module and name" do
      assert_raise ArgumentError, ~r/cannot wildcard both/, fn ->
        Spec.new(:*, :*, :any, :skip)
      end

      assert_raise ArgumentError, ~r/cannot wildcard both/, fn ->
        Macros.resolve([{:*, :*, :skip}])
      end
    end

    test "rejects a whole-module entry pinned to a specific arity" do
      assert_raise ArgumentError, ~r/cannot also pin arity/, fn -> Spec.new(Foo, :*, 2, :skip) end

      assert_raise ArgumentError, ~r/cannot also pin arity/, fn ->
        Macros.resolve([{Foo, :*, 2, :skip}])
      end
    end
  end
end
