defmodule Mutare.MacrosTest do
  use ExUnit.Case, async: true

  alias Mutare.Macro.Spec
  alias Mutare.Macros
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

  describe "Macros.builtin/0 and routing/4" do
    test "match? and destructure are built in, routing arg 0 as a pattern" do
      registry = Macros.build([], [])
      assert Macros.routing(registry, [:Kernel], :match?, 2) == [:pattern, :expression]
      # `destructure`'s bindings escape, so arg 0 is the richer `:binding_pattern`
      # (structural mutants in a value-discarded position); `match?`'s stay `:pattern`.
      assert Macros.routing(registry, [:Kernel], :destructure, 2) == [
               :binding_pattern,
               :expression
             ]
    end

    test "an unmatched module/name/arity returns nil" do
      registry = Macros.build([], [])
      assert Macros.routing(registry, [:SomeMod], :match?, 2) == nil
      assert Macros.routing(registry, [:Kernel], :other, 2) == nil
      assert Macros.routing(registry, [:Kernel], :match?, 3) == nil
    end
  end

  describe "Macros.build/2 — merge, precedence, :any fallback" do
    test "declarative entries override a built-in of the same key" do
      registry = Macros.build([{Kernel, :match?, 2, :skip}], [])
      assert Macros.routing(registry, [:Kernel], :match?, 2) == [:skip, :skip]
    end

    test "an exact-arity entry wins over an :any entry" do
      registry = Macros.build([{Foo, :bar, :skip}, {Foo, :bar, 1, [:pattern]}], [])
      assert Macros.routing(registry, [:Foo], :bar, 1) == [:pattern]
      assert Macros.routing(registry, [:Foo], :bar, 2) == [:skip, :skip]
    end

    test "a mutator's macros/0 contributes entries" do
      specs = Mutator.Spec.for_module(Mutare.Test.QueryMutator)
      registry = Macros.build([], [specs])

      assert Macros.routing(registry, [:Mutare, :Test, :QueryDSL], :query, 1) == [:skip]
    end

    test "a mutator without macros/0 contributes nothing" do
      specs = Mutator.Spec.for_module(Mutare.Test.BooleanMutator)
      assert Macros.from_mutators([specs]) == []
    end
  end
end
