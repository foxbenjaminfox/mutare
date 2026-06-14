defmodule Mutare.TransformTest do
  use ExUnit.Case, async: true

  alias Mutare.Site

  @sample """
  defmodule Sample do
    def classify(total, threshold) do
      if total >= threshold do
        :ok
      else
        :under
      end
    end

    def add(a, b), do: a + b
  end
  """

  test "discovers every arithmetic and relational site, ids assigned sequentially" do
    {_meta, sites} = Mutare.transform_string(@sample, file: "sample.ex")

    # >= -> {>, <=}  (2),  + -> -  (1)
    assert length(sites) == 3
    assert Enum.map(sites, & &1.id) == [1, 2, 3]
    assert Enum.all?(sites, &(&1.file == "sample.ex"))
  end

  test "records operators, lines and a readable description" do
    {_meta, [s1, s2, s3]} = Mutare.transform_string(@sample)

    assert %Site{mutator: :relational, original_op: :>=, mutated_op: :>, line: 3} = s1
    assert %Site{mutator: :relational, original_op: :>=, mutated_op: :<=, line: 3} = s2
    assert %Site{mutator: :arithmetic, original_op: :+, mutated_op: :-, line: 10} = s3

    assert Site.describe(s1) == "relational  total >= threshold → total > threshold"
    assert Site.describe(s3) == "arithmetic  a + b → a - b"
  end

  test "metamutant bakes in the persistent_term selector with the shared key" do
    {meta, _sites} = Mutare.transform_string(@sample)
    assert meta =~ ":persistent_term.get(#{inspect(Mutare.Selector.key())}, 0)"
  end

  test "metamutant is valid, compilable Elixir" do
    {meta, _sites} = Mutare.transform_string(@sample)
    assert {:ok, _ast} = Code.string_to_quoted(meta)
  end

  test ":start_id offsets the first id" do
    {_meta, sites} = Mutare.transform_string(@sample, start_id: 100)
    assert Enum.map(sites, & &1.id) == [100, 101, 102]
  end

  test ":mutators selects which families run" do
    {_meta, sites} = Mutare.transform_string(@sample, mutators: [Mutare.Mutators.Arithmetic])
    assert [%Site{mutator: :arithmetic, original_op: :+}] = sites
  end

  test "nested operator sites both get their own selector" do
    {meta, sites} =
      Mutare.transform_string("defmodule N do\n  def f(a, b), do: a + b == 0\nend\n")

    # + -> - (1) and == -> != (1)
    assert Enum.map(sites, &{&1.mutator, &1.original_op}) ==
             [{:arithmetic, :+}, {:relational, :==}]

    # two independent selectors are present
    assert meta |> String.split(":persistent_term.get") |> length() == 3
    assert {:ok, _} = Code.string_to_quoted(meta)
  end

  test "guard operators become lifted mutants; body operators stay in-place" do
    source = """
    defmodule G do
      def f(x) when x >= 0 and x < 100, do: x + 1
      def f(_), do: 0
    end
    """

    {meta, sites} = Mutare.transform_string(source)

    # Guards are lifted: >= -> {>, <=} and < -> {<=, >}; the body `+` is in-place.
    lifted = Enum.filter(sites, &(&1.kind == :lifted))
    assert Enum.frequencies_by(lifted, & &1.original_op) == %{:>= => 2, :< => 2}

    assert [%Site{kind: :in_place, mutator: :arithmetic, original_op: :+}] =
             Enum.filter(sites, &(&1.kind == :in_place))

    # A `case` must never appear inside a guard (that would compile-poison).
    refute meta =~ "when (case"
    refute meta =~ "when case"
    assert meta =~ "__mutare_f_1_orig"
    assert {:ok, _} = Code.string_to_quoted(meta)
  end

  test "the `/` in a &fun/arity capture is not mutated (it is arity, not division)" do
    source = """
    defmodule C do
      def run, do: Enum.map([1, 2], &double/1)
      def double(x), do: x * 2
    end
    """

    {meta, sites} = Mutare.transform_string(source)

    # Only the body `x * 2` is a site; the capture's `/1` is left alone.
    assert [%Site{mutator: :arithmetic, original_op: :*}] = sites
    assert {:ok, _} = Code.string_to_quoted(meta)
  end

  test "division in a capture body (`& &1 / 2`) is still mutated" do
    {_meta, sites} = Mutare.transform_string("defmodule C do\n  def half, do: &(&1 / 2)\nend\n")
    assert [%Site{mutator: :arithmetic, original_op: :/, mutated_op: :*}] = sites
  end
end
