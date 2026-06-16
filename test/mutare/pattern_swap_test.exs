defmodule Mutare.Mutators.PatternSwapTest do
  use ExUnit.Case, async: true

  alias Mutare.Mutators.PatternSwap

  # Render each mutated head-arg list back as `f(...)` so assertions read like source.
  defp swaps(args_src) do
    {:def, _meta, [call | _rest]} = Sourceror.parse_string!("def f(#{args_src}), do: nil")
    {name, meta, args} = call

    args
    |> PatternSwap.pattern_mutations(MapSet.new())
    |> Enum.map(&Sourceror.to_string({name, meta, &1}))
  end

  test "mutate/1 is :skip — it is a structural mutator, not node-level" do
    assert PatternSwap.mutate({:+, [], [1, 2]}) == :skip
    assert PatternSwap.name() == :pattern_swap
  end

  describe "containers" do
    test "swaps the two variables of a 2-tuple" do
      assert swaps("{x, y}") == ["f({y, x})"]
    end

    test "swaps every distinct pair of a 3-tuple" do
      assert swaps("{x, y, z}") == ["f({y, x, z})", "f({z, y, x})", "f({x, z, y})"]
    end

    test "swaps list elements" do
      assert swaps("[a, b]") == ["f([b, a])"]
    end

    test "swaps map values, keeping keys fixed" do
      assert swaps("%{lat: la, lng: ln}") == ["f(%{lat: ln, lng: la})"]
    end

    test "swaps the field values of a struct pattern" do
      assert swaps("%Point{x: a, y: b}") == ["f(%Point{x: b, y: a})"]
    end
  end

  describe "scope" do
    test "does not transpose top-level arguments (containers only)" do
      assert swaps("x, y") == []
    end

    test "swaps inside a container but leaves sibling arguments alone" do
      assert swaps("{x, y}, z") == ["f({y, x}, z)"]
    end

    test "recurses into nested containers" do
      assert swaps("{x, {a, b}}") == ["f({x, {b, a}})"]
    end
  end

  describe "no-ops" do
    test "does not swap two occurrences of the same variable" do
      assert swaps("{x, x}") == []
    end

    test "does not swap a variable with a non-variable" do
      assert swaps("{x, 5}") == []
      assert swaps("{x, {1, 2}}") == []
    end

    test "does not swap pinned or underscore variables" do
      assert swaps("{^x, y}") == []
      assert swaps("{x, _}") == []
      assert swaps("{x, _ignored}") == []
    end

    test "a single variable has nothing to swap with" do
      assert swaps("x") == []
      assert swaps("{x}") == []
    end
  end
end
