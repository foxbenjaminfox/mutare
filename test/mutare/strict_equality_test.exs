defmodule Mutare.StrictEqualityTest do
  @moduledoc """
  Relax strict equality to value equality, one direction only: `a === b` → `a == b`
  and `a !== b` → `a != b` (never the reverse). In place in a body, lifted in a guard.
  On by default. Polarity flips are `Mutare.Mutators.Relational`'s job — the two are
  orthogonal, so both fire on a bare equality and the relaxation survives a negation
  the flip is suppressed under (see `Mutare.TransformRedundancyTest`'s equivalent-sibling
  block).
  """
  use ExUnit.Case, async: false

  alias Mutare.Mutators.StrictEquality
  alias Mutare.{Selector, Site}

  @compile {:no_warn_undefined, [Mutare.StrictEqualityFixture, Mutare.StrictEqualityGuardFixture]}

  # Isolate the family: with only StrictEquality enabled, every site is a relaxation.
  @only [StrictEquality]

  # strict_equality sites for a one-line function body `def f(a, b), do: <expr>`.
  defp relax_sites(expr) do
    {_meta, sites, _} =
      Mutare.transform_string("defmodule T do\n  def f(a, b), do: #{expr}\nend\n",
        mutators: @only
      )

    Enum.filter(sites, &(&1.mutator == :strict_equality))
  end

  defp mutated_codes(expr), do: expr |> relax_sites() |> Enum.map(& &1.mutated_code)

  describe "relaxes strict equality (one direction)" do
    test "`===` becomes `==` and `!==` becomes `!=`" do
      assert mutated_codes("a === b") == ["a == b"]
      assert mutated_codes("a !== b") == ["a != b"]
    end

    test "the relaxed operators are never tightened (no `==` → `===`, `!=` → `!==`)" do
      assert relax_sites("a == b") == []
      assert relax_sites("a != b") == []
    end

    test "ordering and other operators are left alone" do
      for expr <- ["a > b", "a >= b", "a < b", "a <= b", "a + b", "a in b"] do
        assert relax_sites(expr) == [], "expected no relaxation for #{expr}"
      end
    end

    test "describe/1 renders the relaxation" do
      [site] = relax_sites("a === b")
      assert Site.describe(site) == "strict_equality  a === b → a == b"
    end
  end

  describe "placement is positional" do
    test "a body relaxation is delivered in place" do
      assert [%Site{kind: :in_place}] = relax_sites("a === b")
    end

    test "a relaxation inside a `when` guard is delivered by lifting (===/== are guard-legal)" do
      {_meta, sites, _} =
        Mutare.transform_string(
          """
          defmodule T do
            def f(a, b) when a === b, do: :ok
            def f(_, _), do: :no
          end
          """,
          mutators: @only
        )

      assert [%Site{mutator: :strict_equality, kind: :lifted, original_code: "a === b"}] =
               Enum.filter(sites, &(&1.mutator == :strict_equality))
    end
  end

  describe "runtime semantics (one compile, flip the selector)" do
    setup do
      source = """
      defmodule Mutare.StrictEqualityFixture do
        def same?(a, b), do: a === b
      end
      """

      {metamutant, [site], _} = Mutare.transform_string(source, mutators: @only)
      Mutare.Test.Compile.string(metamutant)
      Selector.put(Selector.baseline())
      on_exit(fn -> Selector.put(Selector.baseline()) end)
      %{site: site}
    end

    test "baseline computes `a === b`; the mutant computes `a == b`", %{site: site} do
      # The whole point: `1 === 1.0` is false (strict), `1 == 1.0` is true (loose).
      assert Mutare.StrictEqualityFixture.same?(1, 1.0) == false
      assert Mutare.StrictEqualityFixture.same?(1, 1) == true

      Selector.put(site.id)
      assert Mutare.StrictEqualityFixture.same?(1, 1.0) == true
    end
  end

  describe "runtime semantics in a lifted guard (one compile, flip the selector)" do
    setup do
      source = """
      defmodule Mutare.StrictEqualityGuardFixture do
        def same?(a, b) when a === b, do: true
        def same?(_a, _b), do: false
      end
      """

      {metamutant, sites, _} = Mutare.transform_string(source, mutators: @only)
      [site] = Enum.filter(sites, &(&1.mutator == :strict_equality))
      Mutare.Test.Compile.string(metamutant)
      Selector.put(Selector.baseline())
      on_exit(fn -> Selector.put(Selector.baseline()) end)
      %{site: site}
    end

    test "baseline guards on `===`; the mutant guards on `==`", %{site: site} do
      assert Mutare.StrictEqualityGuardFixture.same?(1, 1.0) == false

      Selector.put(site.id)
      assert Mutare.StrictEqualityGuardFixture.same?(1, 1.0) == true
    end
  end
end
