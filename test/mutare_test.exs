defmodule MutareTest do
  use ExUnit.Case, async: true

  doctest Mutare

  test "transform_string/2 returns a stable public DTO" do
    # Pin to arithmetic so the delegation check sees one predictable site; the
    # default set would also add a return-value mutant on the `a + b` tail.
    result =
      Mutare.transform_string("defmodule A do\n  def f(a, b), do: a + b\nend\n",
        mutators: [Mutare.Mutators.Arithmetic]
      )

    assert %Mutare.Transform.Result{
             metamutant: meta,
             mutants: [%Mutare.MutationSite{} = site],
             next_id: 2
           } = result

    assert is_binary(meta)
    assert site.mutator == :arithmetic
    assert site.original_code == "a + b"
    assert site.mutated_code == "a - b"
    assert site.range == %{start: %{line: 2, column: 20}, end: %{line: 2, column: 25}}
    refute Map.has_key?(site, :kind)
  end
end
