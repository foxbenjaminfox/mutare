defmodule Mutare.OperandSwapTest do
  @moduledoc """
  Operand-order swap for non-commutative binary operators (`a - b` → `b - a`).
  Keeps the operator, transposes the operands — the complement of the operator-swap
  families (Arithmetic/List). In place in a body, lifted in a guard. On by default.
  """
  use ExUnit.Case, async: false

  alias Mutare.Mutators.OperandSwap
  alias Mutare.{Selector, Site}

  @compile {:no_warn_undefined, [Mutare.OperandSwapFixture, Mutare.OperandSwapDateTimeFixture]}

  # Isolate the family: with only OperandSwap enabled, every site is a transpose.
  @only [OperandSwap]

  # operand_swap sites for a one-line function body `def f(a, b), do: <expr>`.
  defp swap_sites(expr) do
    {_meta, sites, _} =
      Mutare.transform_string("defmodule T do\n  def f(a, b), do: #{expr}\nend\n",
        mutators: @only
      )

    Enum.filter(sites, &(&1.mutator == :operand_swap))
  end

  defp mutated_codes(expr), do: expr |> swap_sites() |> Enum.map(& &1.mutated_code)

  describe "swaps non-commutative operators" do
    test "subtraction and division transpose operands" do
      assert mutated_codes("a - b") == ["b - a"]
      assert mutated_codes("a / b") == ["b / a"]
    end

    test "power, concat, and the list operators transpose operands" do
      assert mutated_codes("a ** b") == ["b ** a"]
      assert mutated_codes("a <> b") == ["b <> a"]
      assert mutated_codes("a ++ b") == ["b ++ a"]
      assert mutated_codes("a -- b") == ["b -- a"]
    end

    test "the div/rem call forms transpose their arguments" do
      assert mutated_codes("div(a, b)") == ["div(b, a)"]
      assert mutated_codes("rem(a, b)") == ["rem(b, a)"]
    end

    test "div/rem are swapped only at effective arity 2 (the bare-Kernel safeguard)" do
      # A same-named user call at another arity is left alone (not Kernel's div/2).
      assert swap_sites("div(a, b, c)") == []
      assert swap_sites("rem(a, b, c)") == []
    end

    test "a piped div/rem is skipped — its first operand comes from the pipe" do
      # `a |> div(b)` is `div(a, b)`, but the stage node holds only `b`; the first
      # operand is supplied by the pipe, so there is nothing local to transpose.
      assert swap_sites("a |> div(b)") == []
      assert swap_sites("a |> rem(b)") == []
    end

    test "describe/1 renders the transpose" do
      [site] = swap_sites("a - b")
      assert Site.describe(site) == "operand_swap  a - b → b - a"
    end
  end

  describe "swaps non-commutative date/time calls (operand-swap of a named call)" do
    test "before?/after?/compare transpose their two arguments, on every calendar type" do
      for mod <- ["DateTime", "Time", "NaiveDateTime"], fun <- ["before?", "after?", "compare"] do
        assert mutated_codes("#{mod}.#{fun}(a, b)") == ["#{mod}.#{fun}(b, a)"]
      end
    end

    test "diff transposes the first two args, keeping the trailing unit (ModeSwap owns it)" do
      assert mutated_codes("DateTime.diff(a, b)") == ["DateTime.diff(b, a)"]
      assert mutated_codes("DateTime.diff(a, b, :second)") == ["DateTime.diff(b, a, :second)"]
      assert mutated_codes("Time.diff(a, b, :second)") == ["Time.diff(b, a, :second)"]

      assert mutated_codes("NaiveDateTime.diff(a, b, :hour)") ==
               ["NaiveDateTime.diff(b, a, :hour)"]
    end

    test "a piped stage is skipped — its first operand comes from the pipe" do
      assert swap_sites("a |> DateTime.before?(b)") == []
      assert swap_sites("a |> DateTime.diff(b, :second)") == []
    end

    test "structurally identical first two operands are not swapped" do
      assert swap_sites("DateTime.diff(a, a)") == []
    end

    test "an unrelated module, or a function not in the table, is left alone" do
      assert swap_sites("Foo.before?(a, b)") == []
      # add/2 is not an operand-order swap (commutative-ish offset, no entry in the table)
      assert swap_sites("DateTime.add(a, b)") == []
    end

    test "an aliased call still matches (resolution is shared via Calls)" do
      {_meta, sites, _} =
        Mutare.transform_string(
          """
          defmodule T do
            alias DateTime, as: DT
            def f(a, b), do: DT.before?(a, b)
          end
          """,
          mutators: @only
        )

      assert [%Site{mutator: :operand_swap, mutated_code: "DT.before?(b, a)"}] =
               Enum.filter(sites, &(&1.mutator == :operand_swap))
    end

    test "a shadowing alias resolves to the local module and is left alone" do
      {_meta, sites, _} =
        Mutare.transform_string(
          """
          defmodule T do
            alias MyApp.DateTime
            def f(a, b), do: DateTime.before?(a, b)
          end
          """,
          mutators: @only
        )

      assert Enum.filter(sites, &(&1.mutator == :operand_swap)) == []
    end

    test "a body remote-call swap is delivered in place" do
      assert [%Site{kind: :in_place}] = swap_sites("DateTime.before?(a, b)")
    end
  end

  describe "leaves commutative and relational operators alone" do
    test "commutative arithmetic and equality produce no swap" do
      assert swap_sites("a + b") == []
      assert swap_sites("a * b") == []
      assert swap_sites("a == b") == []
      assert swap_sites("a != b") == []
    end

    test "comparisons are left to Relational's direction flip (no duplicate)" do
      for cmp <- ["a > b", "a >= b", "a < b", "a <= b"] do
        assert swap_sites(cmp) == [], "expected no operand swap for #{cmp}"
      end
    end

    test "membership is not swapped (the swap would not compile)" do
      assert swap_sites("a in b") == []
    end
  end

  describe "equivalent swaps are skipped" do
    test "structurally identical operands (ignoring metadata) are not emitted" do
      assert swap_sites("a - a") == []
      assert swap_sites("x / x") == []
      assert swap_sites("a ++ a") == []
    end
  end

  describe "placement is positional" do
    test "a body operator swap is delivered in place" do
      assert [%Site{kind: :in_place}] = swap_sites("a - b")
    end

    test "a swap inside a when guard is delivered by lifting" do
      {_meta, sites, _} =
        Mutare.transform_string(
          """
          defmodule T do
            def f(a, b) when a - b > 0, do: :ok
            def f(_, _), do: :no
          end
          """,
          mutators: @only
        )

      assert [%Site{mutator: :operand_swap, kind: :lifted, original_code: "a - b"}] =
               Enum.filter(sites, &(&1.mutator == :operand_swap))
    end
  end

  describe "runtime semantics (one compile, flip the selector)" do
    setup do
      source = """
      defmodule Mutare.OperandSwapFixture do
        def sub(a, b), do: a - b
      end
      """

      {metamutant, [site], _} = Mutare.transform_string(source, mutators: @only)
      Code.compile_string(metamutant)
      Selector.put(Selector.baseline())
      on_exit(fn -> Selector.put(Selector.baseline()) end)
      %{site: site}
    end

    test "baseline computes a - b; the mutant computes b - a", %{site: site} do
      assert Mutare.OperandSwapFixture.sub(10, 3) == 7
      Selector.put(site.id)
      assert Mutare.OperandSwapFixture.sub(10, 3) == -7
    end
  end

  describe "runtime semantics of a remote call swap (one compile, flip the selector)" do
    setup do
      source = """
      defmodule Mutare.OperandSwapDateTimeFixture do
        def earlier?(a, b), do: DateTime.before?(a, b)
      end
      """

      {metamutant, sites, _} = Mutare.transform_string(source, mutators: @only)
      [site] = Enum.filter(sites, &(&1.mutator == :operand_swap))
      Code.compile_string(metamutant)
      Selector.put(Selector.baseline())
      on_exit(fn -> Selector.put(Selector.baseline()) end)
      %{site: site}
    end

    test "baseline checks `a before b`; the mutant checks `b before a`", %{site: site} do
      earlier = ~U[2020-01-01 00:00:00Z]
      later = ~U[2020-01-02 00:00:00Z]

      assert Mutare.OperandSwapDateTimeFixture.earlier?(earlier, later) == true
      Selector.put(site.id)
      assert Mutare.OperandSwapDateTimeFixture.earlier?(earlier, later) == false
    end
  end
end
