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

  test "does not implement mutate/1 — it is a structural mutator, not node-level" do
    refute function_exported?(PatternWildcard, :mutate, 1)
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

  describe "bitstring segment specifiers are not variables" do
    # `<<v::spec>>` parses its type specifier (`binary`, `integer`, a `size(k)` ref)
    # as plain-var-shaped nodes identical to the value var. They must not be counted
    # or wildcarded — replacing one yields an illegal `<<v::_>>`, and counting one
    # invents a phantom duplicate of a same-named value/arg (the plug poison).
    test "a type specifier atom is not a duplicate of the same-named value var" do
      assert wildcards("<<binary::binary>>", [:binary]) == []
    end

    test "an arg is not a duplicate of a same-named specifier atom" do
      assert wildcards("<<rest::binary>>, binary", [:binary]) == []
    end

    test "a variable inside a size() specifier is never counted or wildcarded" do
      assert wildcards("<<n::size(k)>>, k", []) == []
    end

    test "the value side of a segment is still a real, wildcardable variable" do
      assert wildcards("<<x::binary>>, x", [:x]) == ["f(<<_::binary>>, x)", "f(<<x::binary>>, _)"]
    end

    # A size variable bound in-binary *and* again as a plain arg looks like a duplicate,
    # but wildcarding the in-binary binding strands the `size(n)` read (a CompileError).
    # A spec-read name is excluded from wildcarding even when bound elsewhere.
    test "a name read in a spec is excluded even when bound again outside the bitstring" do
      assert wildcards("<<n, rest::binary-size(n)>>, n", []) == []
    end
  end

  describe "module-attribute reads are not variables" do
    # `%{@key => v}` reads the attribute as a compile-time constant key; its inner
    # AST node (`{:key, meta, nil}`) merely looks like a variable. Wildcarding it
    # yields the nonsense `@_`, and counting it invents a phantom duplicate of a
    # same-named real binding — wildcarding *that* strands the body read (the
    # phoenix_live_view `%{@lifecycle => lifecycle}` poison).
    test "an attribute key is neither counted nor wildcarded" do
      assert wildcards("%{@lifecycle => lifecycle} = socket", [:lifecycle]) == []
    end

    test "an attribute is not a duplicate of a same-named real variable" do
      # `key` really does appear twice (both real occurrences); the attribute must
      # not inflate the count or be offered as a target itself.
      assert wildcards("%{@key => key}, key", [:key]) ==
               ["f(%{@key => _}, key)", "f(%{@key => key}, _)"]
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
