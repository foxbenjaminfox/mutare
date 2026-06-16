defmodule MutareTest do
  use ExUnit.Case, async: true

  test "transform_string/2 delegates to Mutare.Transform" do
    # Pin to arithmetic so the delegation check sees one predictable site; the
    # default set would also add a return-value mutant on the `a + b` tail.
    {meta, sites, _next_id} =
      Mutare.transform_string("defmodule A do\n  def f(a, b), do: a + b\nend\n",
        mutators: [Mutare.Mutators.Arithmetic]
      )

    assert is_binary(meta)
    assert [%Mutare.Site{mutator: :arithmetic}] = sites
  end
end
