defmodule Mutare.CallsTest do
  use ExUnit.Case, async: true

  # `Mutare.Calls` is the author-facing facade over `Mutare.Transform.Calls`; the behaviour
  # itself is exercised in `Mutare.Transform.CallsTest`. The doctests here cover the published
  # contract as authors invoke it.
  doctest Mutare.Calls

  describe "resolved_call_to/3" do
    test "accepts an already-encoded module key and a single function name" do
      node = Sourceror.parse_string!("String.upcase(s)")

      assert {:ok, :upcase, [_arg], _rebuild} =
               Mutare.Calls.resolved_call_to(node, [:String], :upcase)

      assert Mutare.Calls.resolved_call_to(node, [:String], :downcase) == :error
    end

    test "matches an Erlang-module call by its atom" do
      node = Sourceror.parse_string!(":binary.first(b)")
      assert {:ok, :first, _args, _rebuild} = Mutare.Calls.resolved_call_to(node, :binary)
      assert Mutare.Calls.resolved_call_to(node, :string) == :error
    end

    test "returns :error for a node that is not a resolved call" do
      assert Mutare.Calls.resolved_call_to(Sourceror.parse_string!("foo(x)"), String) == :error
      assert Mutare.Calls.resolved_call_to(Sourceror.parse_string!("1 + 2"), String) == :error
    end

    # Resolution through alias and import (the transform-integrated path) is covered by
    # `Mutare.Test.AliasCallMutator` — a fixture built on this predicate — in
    # transform_context_test.exs.
  end

  describe "the facade boundary" do
    test "author-facing fixtures and guides never reach for the internal Mutare.Transform.Calls" do
      # The `test/support/` fixtures model what a plugin writes, and the guides tell a plugin
      # what to write — if either needs a reader the facade lacks, the facade has fallen
      # behind, and that's the fix (a `Mutare.Calls` delegate), not a `Transform.Calls` call.
      offenders =
        (Path.wildcard("test/support/**/*.ex") ++ Path.wildcard("guides/*.md"))
        |> Enum.filter(&(File.read!(&1) =~ "Transform.Calls"))

      assert offenders == []
    end
  end
end
