defmodule Mutare.Transform.Resolve.EnvironmentTest do
  use ExUnit.Case, async: true

  alias Mutare.CallRouting.Registry
  alias Mutare.Transform.{MetaKeys, Resolve}
  alias Mutare.Transform.Resolve.Environment

  test "replacement retention drops reuse ASTs but keeps the island's callback and inputs" do
    owner = self()
    callback = fn ast -> send(owner, {:resolved, ast}) end
    registry = Registry.build([{Function, :identity, 1, [:raw]}], [])
    original = Resolve.annotate(quote(do: Function.identity(1)), registry, on_resolve: callback)
    replacement = Resolve.reroute(quote(do: Function.identity(2)), original)
    context = Resolve.context(replacement, %{})

    assert %Environment{unchanged: nil, on_resolve: ^callback} = context.resolution
    assert context.resolution.inputs.call_routes == registry
    assert context.resolution.diag.warn? == false
    island = Resolve.expression(quote(do: abs(-1)), context)
    assert_receive {:resolved, ^island}

    {_, meta, _} = original
    original_env = Keyword.fetch!(meta, MetaKeys.resolution_key())
    assert original_env.diag.warn? == true
    assert original_env.inputs == context.resolution.inputs
    assert Resolve.reroute(original, original) == original
  end
end
