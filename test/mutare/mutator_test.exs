defmodule Mutare.MutatorTest.WrapHost do
  @moduledoc false
  # A minimal hosting mutator whose target supplies a custom 1-arity `:wrap` — to exercise
  # `host_targets/3`'s `target_wrap/1` non-default clause.
  def name, do: :wrap_host

  def host(_node, _context) do
    [
      %{
        original: {:x, [], nil},
        mutants: [{:y, [], nil}],
        splice: fn macro_node, _case_node -> macro_node end,
        wrap: fn branch -> branch end
      }
    ]
  end
end

defmodule Mutare.MutatorTest.BadHost do
  @moduledoc false
  # A hosting mutator that returns a malformed target — to exercise the `normalize_target/1`
  # raise (a library bug, surfaced loudly at transform time).
  def name, do: :bad_host
  def host(_node, _context), do: [:not_a_valid_target]
end

defmodule Mutare.MutatorTest do
  use ExUnit.Case, async: true

  alias Mutare.Mutator
  alias Mutare.Mutator.Spec
  alias Mutare.MutatorTest.{BadHost, WrapHost}

  doctest Mutare.Mutator
  doctest Mutare.Mutator.Dispatch
  doctest Mutare.Mutator.Spec

  describe "implementing/3" do
    test "keeps only the specs whose module exports the callback at that arity" do
      specs = [
        Spec.for_module(Mutare.Mutators.ReturnValue),
        Spec.for_module(Mutare.Mutators.Arithmetic)
      ]

      impls = Mutator.implementing(specs, :return_replacements, 1)

      assert Enum.map(impls, & &1.module) == [Mutare.Mutators.ReturnValue]
    end

    test "is empty when no spec implements the callback" do
      specs = [Spec.for_module(Mutare.Mutators.Arithmetic)]
      assert Mutator.implementing(specs, :return_replacements, 1) == []
    end
  end

  describe "host_targets/3" do
    test "keeps a target's custom 1-arity :wrap function" do
      [target] = Mutator.host_targets(Spec.for_module(WrapHost), {:x, [], nil}, %{})
      assert is_function(target.wrap, 1)
      assert target.range == nil
    end

    test "raises on a malformed target (a hosting-mutator bug, surfaced loudly)" do
      assert_raise ArgumentError, ~r/a host target must be a map/, fn ->
        Mutator.host_targets(Spec.for_module(BadHost), {:x, [], nil}, %{})
      end
    end
  end
end
