defmodule Mutare.Mutators.PatternWildcardTest do
  use ExUnit.Case, async: true

  alias Mutare.Mutators.PatternWildcard

  # Render each mutated head-arg list back as `f(...)`. `used` is the set of variable
  # names the clause reads in its body/guard (what FunctionPlan computes).
  defp wildcards(args_src, used \\ []) do
    {:def, _meta, [call | _rest]} = Sourceror.parse_string!("def f(#{args_src}), do: nil")
    {name, meta, args} = call

    args
    |> PatternWildcard.pattern_mutations(MapSet.new(used))
    |> Enum.map(&Sourceror.to_string({name, meta, &1}))
  end

  test "mutate/1 is :skip — it is a structural mutator, not node-level" do
    assert PatternWildcard.mutate({:+, [], [1, 2]}) == :skip
    assert PatternWildcard.name() == :pattern_wildcard
  end

  describe "orphan-fix (duplicate twice, not read elsewhere)" do
    test "replaces both occurrences with _ to avoid a stranded binding" do
      # `equal?(x, x), do: true` — x is not read, so thinning to one occurrence would
      # leave an unused variable; both go to `_`.
      assert wildcards("x, x") == ["f(_, _)"]
    end

    test "works across separate arguments and inside containers" do
      assert wildcards("{a, b}, a") == ["f({_, b}, _)"]
    end
  end

  describe "thin (a binding always remains)" do
    test "one mutant per occurrence when the variable is read in the body/guard" do
      assert wildcards("x, x", [:x]) == ["f(_, x)", "f(x, _)"]
    end

    test "one mutant per occurrence when it appears three or more times" do
      assert wildcards("x, x, x") == ["f(_, x, x)", "f(x, _, x)", "f(x, x, _)"]
    end

    test "thins a duplicate that lives inside a container" do
      assert wildcards("{x, x}", [:x]) == ["f({_, x})", "f({x, _})"]
    end
  end

  describe "no-ops" do
    test "a variable that appears once is never wildcarded" do
      assert wildcards("x, y") == []
      assert wildcards("{x, y}") == []
    end

    test "pinned variables do not count as occurrences" do
      # `^x` reads an existing binding; the plain `x` then appears only once.
      assert wildcards("^x, x") == []
    end

    test "underscore and underscore-prefixed names are ignored" do
      assert wildcards("_, _") == []
      assert wildcards("_a, _a") == []
    end
  end
end
