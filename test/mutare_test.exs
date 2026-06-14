defmodule MutareTest do
  use ExUnit.Case, async: true

  test "transform_string/2 delegates to Mutare.Transform" do
    {meta, sites} = Mutare.transform_string("defmodule A do\n  def f(a), do: a + 1\nend\n")
    assert is_binary(meta)
    assert [%Mutare.Site{mutator: :arithmetic}] = sites
  end
end
