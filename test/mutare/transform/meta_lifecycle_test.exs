defmodule Mutare.Transform.Meta.LifecycleTest do
  use ExUnit.Case, async: true

  alias Mutare.Transform.{Meta, MetaKeys, Resolve, WrittenPipe}
  alias Mutare.Transform.Meta.Lifecycle

  test "invalidating a call keeps its children and positional facts but clears its identity" do
    {:__block__, _, [_alias, call]} =
      "alias Enum, as: E\nE.map(xs, &abs/1)" |> Sourceror.parse_string!() |> Resolve.annotate()

    call =
      call
      |> Meta.put_tag(:kept)
      |> Meta.add_marks([:kept])
      |> Meta.put_candidates(:in_place, [:pending])

    {head, before, args} = call
    {new_head, meta, ^args} = invalidated = Lifecycle.invalidate_call_resolution(call)
    assert Keyword.has_key?(before, MetaKeys.resolution_key())
    refute Keyword.has_key?(meta, MetaKeys.resolution_key())
    assert Meta.tag(invalidated) == :kept
    assert Meta.marks(invalidated) == MapSet.new([:kept])
    assert Meta.candidates(invalidated, :in_place) == [:pending]
    assert Resolve.nid(invalidated) == Resolve.nid(call)
    assert {:., dot, [{:__aliases__, alias_meta, path}, fun]} = head
    assert Keyword.has_key?(alias_meta, MetaKeys.alias_key())

    assert new_head ==
             {:., dot,
              [{:__aliases__, Keyword.delete(alias_meta, MetaKeys.alias_key()), path}, fun]}

    assert Lifecycle.invalidate_call_resolution(invalidated) == invalidated
  end

  test "consuming delivery leaves resolution and spelling available to later emission" do
    call = "xs |> Enum.sum()" |> Sourceror.parse_string!() |> Resolve.annotate()

    annotated =
      Enum.reduce([:in_place, :case, :hosted], call, fn kind, node ->
        Meta.put_candidates(node, kind, [:pending])
      end)

    assert Lifecycle.consume_delivery(annotated) == call
    assert Lifecycle.consume_delivery(call) == call
  end

  test "release reaches nodes carried by metadata without treating their arguments as metadata" do
    key = MetaKeys.resolution_key()
    data = [{key, :program_data}]
    carried = {:f, [{key, :capability}], [data]}
    node = {:g, [history: {[{key, :capability}], carried}], [data]}
    assert Lifecycle.release_analysis(node) == {:g, [history: {[], {:f, [], [data]}}], [data]}
  end

  test "preserving syntax restores grouped pipes and invalidates their resolution" do
    resolved =
      "xs |> (Enum.map(f) |> Enum.sum())" |> Sourceror.parse_string!() |> Resolve.annotate()

    written = Lifecycle.preserve_written(resolved)
    assert {:|>, _, _} = written
    assert Lifecycle.preserve_written(written) == written
    assert Lifecycle.release_analysis(written) == written
    assert Macro.to_string(written) == Macro.to_string(WrittenPipe.resugar(resolved))
  end
end
