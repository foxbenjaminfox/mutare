defmodule Mutare.BitwiseTest do
  @moduledoc """
  Bitwise operator/function swaps — `&&&`↔`|||`, `<<<`↔`>>>`, and `~~~x`→`x` (bnot
  strip), in both operator and `Bitwise.*` function spellings. The bit-twiddling
  sibling of Arithmetic. In place in a body, lifted in a guard. On by default.
  """
  use ExUnit.Case, async: false
  import Mutare.Test.Metamutant

  alias Mutare.{Selector, Site}

  @compile {:no_warn_undefined, [Mutare.BitwiseFixture]}

  # Isolate the family: with only Bitwise enabled, every site is a bitwise mutation.
  @only [Mutare.Mutators.Bitwise]

  defp sites(source), do: family_sites(source, @only, :bitwise)

  # Bitwise sites for a one-line body `def f(a, b), do: <expr>`, with `Bitwise` imported
  # (needed for the operator / bare-function forms to resolve and to compile).
  defp swap_sites(expr),
    do: sites("defmodule T do\n  import Bitwise\n  def f(a, b), do: #{expr}\nend\n")

  defp mutated_codes(expr), do: expr |> swap_sites() |> Enum.map(& &1.mutated_code)

  describe "operator swaps" do
    test "AND/OR and the shift pair swap for their complement" do
      assert mutated_codes("a &&& b") == ["a ||| b"]
      assert mutated_codes("a ||| b") == ["a &&& b"]
      assert mutated_codes("a <<< b") == ["a >>> b"]
      assert mutated_codes("a >>> b") == ["a <<< b"]
    end

    test "~~~x drops the complement" do
      assert mutated_codes("~~~a") == ["a"]
    end

    test "a shift by a literal 0 is an equivalent no-op, so it is skipped" do
      # `x <<< 0 == x == x >>> 0`, so the swap changes nothing.
      assert swap_sites("a <<< 0") == []
      assert swap_sites("a >>> 0") == []
    end

    test "AND/OR with a literal 0 is NOT skipped (the directions differ there)" do
      # `a &&& 0 == 0` but `a ||| 0 == a`, so the swap is a real change.
      assert mutated_codes("a &&& 0") == ["a ||| 0"]
    end

    test "describe/1 renders the swap" do
      [site] = swap_sites("a &&& b")
      assert Site.describe(site) == "bitwise  a &&& b → a ||| b"
    end

    test "xor (^^^) has no complementary sibling and is left alone" do
      assert swap_sites("a ^^^ b") == []
    end
  end

  describe "function-form swaps (resolved via Mutare.Transform.Calls)" do
    test "qualified Bitwise.* calls swap for their complement" do
      assert mutated_codes("Bitwise.band(a, b)") == ["Bitwise.bor(a, b)"]
      assert mutated_codes("Bitwise.bor(a, b)") == ["Bitwise.band(a, b)"]
      assert mutated_codes("Bitwise.bsl(a, b)") == ["Bitwise.bsr(a, b)"]
      assert mutated_codes("Bitwise.bsr(a, b)") == ["Bitwise.bsl(a, b)"]
    end

    test "Bitwise.bnot(x) drops the complement" do
      assert mutated_codes("Bitwise.bnot(a)") == ["a"]
    end

    test "a bare imported call swaps, staying bare (whole import)" do
      assert mutated_codes("band(a, b)") == ["bor(a, b)"]
      assert mutated_codes("bnot(a)") == ["a"]
    end

    test "an aliased call still matches and keeps the alias" do
      sites =
        sites("""
        defmodule T do
          alias Bitwise, as: B
          def f(a, b), do: B.band(a, b)
        end
        """)

      assert [%Site{mutator: :bitwise, mutated_code: "B.bor(a, b)"}] = sites
    end

    test "a shift function by a literal 0 is skipped (equivalent), direct and piped" do
      assert swap_sites("Bitwise.bsl(a, 0)") == []
      assert swap_sites("a |> Bitwise.bsl(0)") == []
    end

    test "a piped shift function still swaps (arity-blind rename)" do
      # The Site records the bare pipe *stage* (the diff is the stage, not the whole pipe).
      assert mutated_codes("a |> Bitwise.bsl(b)") == ["Bitwise.bsr(b)"]
    end

    test "xor functions are left alone; an unrelated module is untouched" do
      assert swap_sites("Bitwise.bxor(a, b)") == []
      assert swap_sites("Foo.band(a, b)") == []
    end
  end

  describe "placement is positional" do
    test "a body swap is delivered in place" do
      assert [%Site{kind: :in_place}] = swap_sites("a &&& b")
    end

    test "a swap inside a when guard is delivered by lifting (bitwise is guard-legal)" do
      sites =
        sites("""
        defmodule T do
          import Bitwise
          def f(a, b) when (a &&& b) > 0, do: :ok
          def f(_, _), do: :no
        end
        """)

      assert [%Site{mutator: :bitwise, kind: :lifted, original_code: "a &&& b"}] = sites
    end
  end

  describe "runtime semantics (one compile, flip the selector)" do
    setup do
      source = """
      defmodule Mutare.BitwiseFixture do
        import Bitwise
        def combine(a, b), do: a &&& b
      end
      """

      {metamutant, sites, _} =
        Mutare.Transform.transform_string_with_sites(source, mutators: @only)

      [site] = Enum.filter(sites, &(&1.mutator == :bitwise))
      Mutare.Test.Compile.string(metamutant)
      Selector.put(Selector.baseline())
      on_exit(fn -> Selector.put(Selector.baseline()) end)
      %{site: site}
    end

    test "baseline computes a &&& b; the mutant computes a ||| b", %{site: site} do
      assert Mutare.BitwiseFixture.combine(6, 3) == 2
      Selector.put(site.id)
      assert Mutare.BitwiseFixture.combine(6, 3) == 7
    end
  end
end
