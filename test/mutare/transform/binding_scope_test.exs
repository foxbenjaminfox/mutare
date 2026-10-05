defmodule Mutare.Transform.BindingScopeTest do
  # The accounting `BindingScope.emit/2` owns, pinned apart from any emitted source: the id
  # interval claimed, the variants actually emitted among those ids, and the reference count
  # beneath the scope's own binding.
  use ExUnit.Case, async: true

  alias Mutare.Transform.{BindingScope, Ctx, SelectorEmit}

  # Stand-ins for `ClaimState.claim/6`: every claim advances `next_id`; only a delivered one
  # (not ignored, poisoned or unselected) also advances `emitted`.
  defp claim(ctx, delivered?) do
    Ctx.update_claim(ctx, fn claim ->
      %{
        claim
        | next_id: claim.next_id + 1,
          emitted: claim.emitted + if(delivered?, do: 1, else: 0)
      }
    end)
  end

  defp ctx, do: Ctx.update_claim(%Ctx{}, &%{&1 | next_id: 7})

  test "with no claims, the id interval is empty and nothing was emitted" do
    {scoped, ctx} = BindingScope.emit(ctx(), &{:body, &1})

    assert scoped.emitted == :body
    assert Enum.empty?(scoped.ids)
    assert scoped.ids == 7..6//1
    assert scoped.variants == 0
    refute BindingScope.referenced?(scoped)
    assert ctx.claim.next_id == 7
  end

  test "claims that emit nothing advance the id interval but not the variant count" do
    {scoped, _ctx} =
      BindingScope.emit(ctx(), fn ctx ->
        {:body, ctx |> claim(false) |> claim(true) |> claim(false)}
      end)

    assert scoped.ids == 7..9//1
    assert scoped.variants == 1
  end

  test "references are counted from zero beneath the scope and the enclosing count is restored" do
    outer = ctx() |> SelectorEmit.reference_active(2)

    {scoped, outer} =
      BindingScope.emit(outer, fn ctx ->
        ctx = SelectorEmit.reference_active(ctx)

        {inner, ctx} =
          BindingScope.emit(ctx, fn ctx -> {:inner, SelectorEmit.reference_active(ctx, 3)} end)

        assert inner.references == 3
        # The inner scope's own binding satisfies its readers: none reach this one.
        assert ctx.scope.active_references == 1

        {:outer, SelectorEmit.reference_active(ctx)}
      end)

    assert scoped.references == 2
    assert BindingScope.referenced?(scoped)
    assert outer.scope.active_references == 2
  end
end
