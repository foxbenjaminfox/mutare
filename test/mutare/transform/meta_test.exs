defmodule Mutare.Transform.MetaTest do
  # `Mutare.Transform.Meta` is the single read/write surface for the transform's internal
  # `:mutare_*` node metadata. These tests pin its contract directly (the candidate API, the
  # macro-routing/tag stamps, and totality over a bare literal) so a regression surfaces here
  # rather than as a mangled metamutant deep in the pipeline.
  use ExUnit.Case, async: true

  alias Mutare.Transform.{Meta, MetaKeys}

  # A metadata-bearing node and a bare literal (no keyword meta) — Meta must be total over both.
  defp sample_node, do: {:call, [line: 1], []}
  defp bare, do: :integer

  describe "candidate delivery" do
    test "candidates/2 reads the list for a kind, [] when absent or a bare literal" do
      assert Meta.candidates(sample_node(), :in_place) == []
      assert Meta.candidates(bare(), :in_place) == []

      n = Meta.put_candidates(sample_node(), :case, [:a, :b])
      assert Meta.candidates(n, :case) == [:a, :b]
      # kinds are independent
      assert Meta.candidates(n, :in_place) == []
    end

    test "put_candidates/3 replaces; an empty list removes the key entirely" do
      n = Meta.put_candidates(sample_node(), :in_place, [:a])
      n = Meta.put_candidates(n, :in_place, [:b, :c])
      assert Meta.candidates(n, :in_place) == [:b, :c]

      {_form, meta, _args} = Meta.put_candidates(n, :in_place, [])
      refute Keyword.has_key?(meta, MetaKeys.in_place_key())
      # a bare literal is returned unchanged
      assert Meta.put_candidates(bare(), :in_place, [:a]) == bare()
    end

    test "append_candidates/3 preserves what is already there" do
      n = Meta.put_candidates(sample_node(), :in_place, [:a])
      n = Meta.append_candidates(n, :in_place, [:b, :c])
      assert Meta.candidates(n, :in_place) == [:a, :b, :c]

      # appending to an absent key just sets it
      n2 = Meta.append_candidates(sample_node(), :hosted, [:x])
      assert Meta.candidates(n2, :hosted) == [:x]
    end

    test "take_candidates/2 pops the list and returns the node without the key" do
      n = Meta.put_candidates(sample_node(), :in_place, [:a, :b])
      {taken, rest} = Meta.take_candidates(n, :in_place)
      assert taken == [:a, :b]
      assert Meta.candidates(rest, :in_place) == []

      assert Meta.take_candidates(bare(), :in_place) == {[], bare()}
    end

    test "update_candidates/3 maps an existing list and is a no-op when the key is absent" do
      n = Meta.put_candidates(sample_node(), :in_place, [1, 2, 3])
      n = Meta.update_candidates(n, :in_place, fn cs -> Enum.reject(cs, &(&1 == 2)) end)
      assert Meta.candidates(n, :in_place) == [1, 3]

      # absent key → untouched (the fun never runs, no empty key materialises)
      untouched =
        Meta.update_candidates(sample_node(), :in_place, fn _ -> [:should_not_appear] end)

      assert untouched == sample_node()
      assert Meta.update_candidates(bare(), :in_place, fn _ -> [:x] end) == bare()
    end

    test "strip_delivery/1 drops every delivery key but keeps other meta" do
      n =
        sample_node()
        |> Meta.put_candidates(:in_place, [:a])
        |> Meta.put_candidates(:case, [:b])
        |> Meta.put_candidates(:hosted, [:c])

      {_form, meta, _args} = Meta.strip_delivery(n)
      for key <- MetaKeys.delivery(), do: refute(Keyword.has_key?(meta, key))
      assert Keyword.get(meta, :line) == 1
      assert Meta.strip_delivery(bare()) == bare()
    end
  end

  describe "known-macro routing stamps" do
    test "macro_routing round-trips through the stamp writer" do
      assert Meta.routing([]) == nil
      assert Meta.routing(:not_meta) == nil

      meta = Meta.stamp_routing([line: 1], [:pattern, :expression])
      assert Meta.routing(meta) == [:pattern, :expression]
    end

    test "stamp_withheld replaces the :skip stamp with positions" do
      meta = [] |> Meta.stamp_routing(:skip) |> Meta.stamp_withheld([:pattern, :raw])
      assert Meta.routing(meta) == [:pattern, :raw]
      assert Meta.withheld?({:match?, meta, []})
      refute Meta.skipped?({:match?, meta, []})
      refute Meta.withheld?({:match?, [], []})
    end

    test "routed_call round-trips the resolved identity, with the arity it matched at" do
      assert Meta.routed_call([]) == nil

      identity = {[:Ecto, :Query], :from, 2}
      assert [] |> Meta.stamp_routed_call(identity) |> Meta.routed_call() == identity
    end

    test "routed_call reads anything but a well-formed identity as absent" do
      key = Mutare.Transform.MetaKeys.route_call_key()

      for malformed <- [{[:Ecto, :Query], :from}, {[:Ecto, :Query], :from, :piped}, :from] do
        assert Meta.routed_call([{key, malformed}]) == nil
      end
    end
  end

  describe "replace-by-tag marker" do
    test "tag/1 and put_tag/2 round-trip; total over a bare literal" do
      assert Meta.tag(sample_node()) == nil
      assert Meta.tag(bare()) == nil

      tagged = Meta.put_tag(sample_node(), 7)
      assert Meta.tag(tagged) == 7
      assert Meta.put_tag(bare(), 7) == bare()
    end
  end

  describe "unit-return tail stamp" do
    test "unit_tail?/1 reads the stamp put_unit_tail/1 sets; false when absent or bare" do
      refute Meta.unit_tail?(sample_node())
      refute Meta.unit_tail?(bare())

      stamped = Meta.put_unit_tail(sample_node())
      assert Meta.unit_tail?(stamped)
      # the stamp is one more meta key, alongside whatever was there
      {_form, meta, _args} = stamped
      assert Keyword.get(meta, :line) == 1
      assert Keyword.has_key?(meta, MetaKeys.unit_tail_key())
      # a bare literal is returned unchanged
      assert Meta.put_unit_tail(bare()) == bare()
    end
  end
end
