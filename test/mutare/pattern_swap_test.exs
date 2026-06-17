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

    test "swaps non-adjacent variables across an intervening literal" do
      assert swaps("{a, 1, b}") == ["f({b, 1, a})"]
      assert swaps("[a, 1, b]") == ["f([b, 1, a])"]
    end

    test "treats every element before a cons tail as a swap sibling, tail fixed" do
      # `[a, b, c | _]` parses with `c` inside the `{:|, …}` node; all three proper
      # elements are still symmetric, while the `_` tail stays pinned.
      assert swaps("[a, b, c | _]") == [
               "f([b, a, c | _])",
               "f([c, b, a | _])",
               "f([a, c, b | _])"
             ]
    end

    test "a cons tail variable is not swapped with the head elements" do
      # In `[a, b | c]` the `c` *is* the tail (binds the remainder), so only a/b swap.
      assert swaps("[a, b | c]") == ["f([b, a | c])"]
      assert swaps("[a, b | rest]") == ["f([b, a | rest])"]
    end

    test "a cons list with a single proper element has nothing to swap" do
      assert swaps("[h | t]") == []
    end

    test "swaps map values, keeping keys fixed" do
      assert swaps("%{lat: la, lng: ln}") == ["f(%{lat: ln, lng: la})"]
    end

    test "swaps the field values of a struct pattern" do
      assert swaps("%Point{x: a, y: b}") == ["f(%Point{x: b, y: a})"]
    end
  end

  describe "bitstrings" do
    test "swaps the values of two segments, keeping the specs pinned in place" do
      assert swaps("<<a::integer, b::integer>>") == ["f(<<b::integer, a::integer>>)"]
      assert swaps("<<a::8, b::16>>") == ["f(<<b::8, a::16>>)"]
    end

    test "swaps bare (spec-less) segments" do
      assert swaps("<<a, b>>") == ["f(<<b, a>>)"]
    end

    test "swaps every distinct pair across three segments" do
      assert swaps("<<a::8, b::16, c::8>>") ==
               [
                 "f(<<b::8, a::16, c::8>>)",
                 "f(<<c::8, b::16, a::8>>)",
                 "f(<<a::8, c::16, b::8>>)"
               ]
    end

    test "swaps a bitstring segment value nested inside another container" do
      assert swaps("{<<a::8, b::8>>, c}") == ["f({<<b::8, a::8>>, c})"]
    end

    # A value read as a size elsewhere in the binary must not be relocated — Elixir
    # requires it bound earlier in the same binary, so moving it is a CompileError.
    test "never moves a value that is read as a size" do
      assert swaps("<<n, rest::binary-size(n)>>") == []
    end

    test "swaps other segment values while leaving a size variable in place" do
      assert swaps("<<a::8, n::8, rest::binary-size(n)>>") ==
               ["f(<<rest::8, n::8, a::binary-size(n)>>)"]
    end

    test "does not swap same-named segment values (wildcard's domain) or literals" do
      assert swaps("<<a::8, a::8>>") == []
      assert swaps("<<a::8, 5::8>>") == []
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
