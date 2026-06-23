defmodule Mutare.MacrosTest do
  use ExUnit.Case, async: true

  alias Mutare.Macro.Spec
  alias Mutare.Macros
  alias Mutare.Mutator

  doctest Mutare.Macros
  doctest Mutare.Macro.Spec

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
      assert %Spec{args: [:pattern, :expression]} = Macros.lookup(registry, [:Kernel], :match?, 2)
      # `destructure`'s bindings escape, so arg 0 is the richer `:binding_pattern`
      # (structural mutants in a value-discarded position); `match?`'s stay `:pattern`.
      assert %Spec{args: [:binding_pattern, :expression]} =
               Macros.lookup(registry, [:Kernel], :destructure, 2)
    end

    test "an unmatched module/name/arity returns nil" do
      registry = Macros.build([], [])
      assert Macros.lookup(registry, [:SomeMod], :match?, 2) == nil
      assert Macros.lookup(registry, [:Kernel], :other, 2) == nil
      assert Macros.lookup(registry, [:Kernel], :match?, 3) == nil
    end
  end

  describe "Macros.build/2 — merge, precedence, :any fallback" do
    test "declarative entries override a built-in of the same key" do
      registry = Macros.build([{Kernel, :match?, 2, :skip}], [])
      assert %Spec{args: :skip} = Macros.lookup(registry, [:Kernel], :match?, 2)
    end

    test "an exact-arity entry wins over an :any entry" do
      registry = Macros.build([{Foo, :bar, :skip}, {Foo, :bar, 1, [:pattern]}], [])
      assert %Spec{arity: 1, args: [:pattern]} = Macros.lookup(registry, [:Foo], :bar, 1)
      assert %Spec{arity: :any, args: :skip} = Macros.lookup(registry, [:Foo], :bar, 2)
    end

    test "a mutator's macros/0 contributes entries" do
      specs = Mutator.Spec.for_module(Mutare.Test.QueryMutator)
      registry = Macros.build([], [specs])

      assert %Spec{args: :skip} = Macros.lookup(registry, [:Mutare, :Test, :QueryDSL], :query, 1)
    end

    test "a mutator without macros/0 contributes nothing" do
      specs = Mutator.Spec.for_module(Mutare.Test.BooleanMutator)
      assert Macros.from_mutators([specs]) == []
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

    test "classifier?/1 and host_required?/1 recognise the host-needing modes" do
      assert Spec.classifier?(Spec.new(Foo, :bar, :any, :routing))
      refute Spec.classifier?(Spec.new(Foo, :bar, 2, [:expression, :hosted]))

      assert Spec.host_required?(Spec.new(Foo, :bar, :any, :routing))
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

  describe "host stamping (from_mutators/1) and validation (build/2)" do
    test "from_mutators stamps the hosting mutator onto every spec it contributes" do
      specs = Mutator.Spec.for_module(Mutare.Test.HostMutator)
      contributed = Macros.from_mutators([specs])

      # Both of HostMutator's macro registrations (`filter` via `:routing`, `pick` via a static
      # `[:binding_pattern, :hosted]`) are stamped with the contributing mutator as their host.
      assert Enum.all?(contributed, &(&1.host == Mutare.Test.HostMutator))
      assert Enum.all?(contributed, &(&1.module == [:Mutare, :Test, :HostDSL]))

      filter = Enum.find(contributed, &(&1.name == :filter))
      assert filter.args == :routing

      pick = Enum.find(contributed, &(&1.name == :pick))
      assert pick.args == [:binding_pattern, :hosted]
    end

    test "build/2 resolves a host-needing macro through a mutator" do
      specs = Mutator.Spec.for_module(Mutare.Test.HostMutator)
      registry = Macros.build([], [specs])

      assert %Spec{args: :routing, host: Mutare.Test.HostMutator} =
               Macros.lookup(registry, [:Mutare, :Test, :HostDSL], :filter, 2)
    end

    test "build/2 raises when a declarative entry asks for :hosted/:routing (no host)" do
      assert_raise ArgumentError, ~r/needs a hosting mutator/, fn ->
        Macros.build([{Ecto.Query, :where, :any, :routing}], [])
      end

      assert_raise ArgumentError, ~r/needs a hosting mutator/, fn ->
        Macros.build([{Ecto.Query, :where, 2, [:expression, :hosted]}], [])
      end
    end

    test "build/2 raises when a mutator registers :hosted but omits host/2" do
      # The host *is* stamped (the contributing mutator), but it doesn't implement `host/2` —
      # the `validate_host!` host-present-but-missing-callback branch, named clearly at build
      # rather than failing cryptically at delivery.
      specs = Mutator.Spec.for_module(Mutare.Test.IncompleteHostMutator)

      assert_raise ArgumentError, ~r/must implement host\/2/, fn ->
        Macros.build([], [specs])
      end
    end
  end

  describe "Macros.lookup/4" do
    test "returns the whole spec, exact arity over :any" do
      registry = Macros.build([{Foo, :bar, :skip}, {Foo, :bar, 1, [:pattern]}], [])
      assert %Spec{arity: 1, args: [:pattern]} = Macros.lookup(registry, [:Foo], :bar, 1)
      assert %Spec{arity: :any, args: :skip} = Macros.lookup(registry, [:Foo], :bar, 2)
      assert Macros.lookup(registry, [:Foo], :baz, 1) == nil
    end
  end
end
