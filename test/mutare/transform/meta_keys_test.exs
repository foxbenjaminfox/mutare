defmodule Mutare.Transform.MetaKeysTest do
  # `delivery/0` and `all/0` are only ever read at *compile time* (as the
  # `@delivery_keys`/`@internal_meta_keys` module attributes in `Mutare.Transform` and
  # `Mutare.Transform.Render`), so they never execute at runtime in a normal run. These
  # direct calls pin the contract: `all/0` is the superset that the render scrub strips, and
  # `delivery/0` is the candidate-delivery subset stripped during emit.
  use ExUnit.Case, async: true

  alias Mutare.Transform.MetaKeys

  test "delivery/0 lists the candidate-delivery keys" do
    assert MetaKeys.delivery() == [:mutare, :mutare_case, :mutare_hosted]
  end

  test "all/0 is a superset of delivery/0 and includes the bookkeeping keys" do
    all = MetaKeys.all()

    assert Enum.all?(MetaKeys.delivery(), &(&1 in all))
    # a representative spread of the bookkeeping stamps
    for key <- [:mutare_tag, :mutare_nid, :mutare_alias, :mutare_import, :mutare_macro] do
      assert key in all
    end

    # No duplicates, and delivery ⊆ all strictly (bookkeeping keys exist).
    assert all == Enum.uniq(all)
    assert length(all) > length(MetaKeys.delivery())
  end
end
