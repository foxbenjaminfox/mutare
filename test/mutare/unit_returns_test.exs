defmodule Mutare.UnitReturnsTest do
  @moduledoc """
  Unit-returning functions (`Mutare.Transform.UnitReturns`): a function whose every return
  path, across all its clauses, is literally `:ok` or `nil` returns no data, so its tails are
  not value positions — no return-value constant (`ReturnValue`) and no `:ok → :error` swap
  (`ConventionAtom`) there. The classification is syntactic and one-sided: it can *miss* a
  unit function, never silence a data-returning one.
  """
  use ExUnit.Case, async: true

  alias Mutare.Mutators.{AtomLiteral, ConventionAtom, ReturnValue}

  @compile {:no_warn_undefined, Mutare.UnitReturnsFixture}

  # The three families that can touch an atom tail. Nothing else is enabled, so every site
  # below is one of: a return constant, a convention swap, or an atom sentinel.
  @families [ReturnValue, ConventionAtom, AtomLiteral]

  defp sites(source) do
    {_meta, sites, _} = Mutare.Transform.transform_string_with_sites(source, mutators: @families)
    Enum.map(sites, &{&1.mutator, &1.line, &1.original_code, &1.mutated_code})
  end

  defp t(body), do: "defmodule T do\n#{body}\nend\n"

  # The mutants minted on an `:ok` — `{mutator, mutated_code}` pairs, so a test reads as "which
  # families fired on the `:ok`".
  defp on_ok(source),
    do: for({m, _line, ":ok", mutated} <- sites(source), do: {m, mutated})

  # What a data-carrying `:ok` tail gets: the swap plus the contrasting return pair.
  @ok_mutated [convention: ":error", return_value: "nil", return_value: ":mutare"]

  describe "a unit-returning function's tails are not value positions" do
    test "a bare :ok body gets neither a return constant nor a convention swap" do
      assert sites(t("  def f, do: :ok")) == []
      assert sites(t("  defp f, do: :ok")) == []
    end

    test "a side-effect helper ending in :ok" do
      assert sites(t("  def f(x) do\n    IO.puts(x)\n    :ok\n  end")) == []
    end

    test "nil is the other unit spelling, and mixing the two still counts" do
      # An else-less `if` around a side effect returns `:ok | nil`.
      assert sites(t("  def f(x) do\n    if x do\n      IO.puts(x)\n      :ok\n    end\n  end")) ==
               []

      assert sites(t("  def f(x), do: if(x, do: :ok, else: nil)")) == []
    end

    test "every branch of a tail case" do
      src = t("  def f(x) do\n    case x do\n      1 -> :ok\n      _ -> :ok\n    end\n  end")
      assert sites(src) == []
    end

    test "every clause of a multi-clause function" do
      assert sites(t("  def f(1), do: :ok\n  def f(_), do: :ok")) == []
    end

    test "a bodiless default head defines no return path" do
      assert sites(t("  def f(x \\\\ 1)\n  def f(_x), do: :ok")) == []
    end

    test "rescue paths, block and keyword form alike" do
      block = t("  def f(x) do\n    IO.puts(x)\n    :ok\n  rescue\n    _ -> :ok\n  end")
      assert sites(block) == []
      assert sites(t("  def f(_x), do: :ok, rescue: (_ -> :ok)")) == []
    end

    test "a with whose else is present and unit" do
      src =
        t(
          "  def f(x) do\n    with 1 <- x do\n      :ok\n    else\n      _ -> :ok\n    end\n  end"
        )

      assert sites(src) == []
    end

    test "a tail that never returns is no return path: :ok-or-raise is unit" do
      # The `:ok` is not offered; the raising tail is not stamped and keeps its own return pair
      # (`raise … → nil` asks whether the error path is tested).
      src =
        t(
          "  def f(x) do\n    case x do\n      nil -> :ok\n      _ -> raise \"bad\"\n    end\n  end"
        )

      assert on_ok(src) == []

      assert Enum.map(sites(src), &{elem(&1, 0), elem(&1, 2)}) ==
               [return_value: ~s(raise "bad"), return_value: ~s(raise "bad")]

      for tail <- [
            "raise(\"bad\", [])",
            "reraise(x, [])",
            "throw(1)",
            "exit(1)",
            "Kernel.exit(1)",
            ":erlang.error(1)",
            ":erlang.throw(1)",
            ":erlang.exit(1)"
          ] do
        assert on_ok(t("  def f(x), do: if(x, do: :ok, else: #{tail})")) == [], tail
      end
    end

    test "a raise shadowed by another import, or :erlang.exit/2, is an ordinary call" do
      shadowed =
        t(
          "  import Kernel, except: [raise: 1]\n  import Other, only: [raise: 1]\n  def f(x), do: if(x, do: :ok, else: raise(x))"
        )

      assert on_ok(shadowed) == @ok_mutated
      # `:erlang.exit/2` signals another process and returns `true`.
      assert on_ok(t("  def f(x), do: if(x, do: :ok, else: :erlang.exit(x, 1))")) == @ok_mutated
    end

    test "inside a defimpl body" do
      assert sites("defimpl Inspect, for: T do\n  def inspect(_, _), do: :ok\nend\n") == []
    end

    test "an anonymous function whose every clause returns :ok" do
      # The enclosing def's tail is the `Enum.each` call — a call tail is not classified, so
      # it keeps its own return pair — but the closure's `:ok` is unit.
      src = t("  def f(xs), do: Enum.each(xs, fn x -> IO.puts(x); :ok end)")
      assert on_ok(src) == []
      assert Enum.map(sites(src), &elem(&1, 0)) == [:return_value, :return_value]
    end
  end

  describe "stays a value position" do
    test ":ok beside a data path carries the success bit" do
      assert on_ok(t("  def f(x), do: if(x, do: :ok, else: {:error, :bad})")) == @ok_mutated
    end

    test "a sibling clause returning data disqualifies the group" do
      assert on_ok(t("  def f(1), do: :ok\n  def f(_), do: :pending")) == @ok_mutated
    end

    test "an else-less with has an implicit return path" do
      # The non-matching value passes through, so the function is not unit — while the
      # return mutator still targets the `do` tail, the one path a constant can replace.
      assert on_ok(t("  def f(x), do: with(1 <- x, do: :ok)")) == @ok_mutated
    end

    test "a data atom, and :ok inside data" do
      assert Enum.map(sites(t("  def f, do: :pending")), &elem(&1, 0)) ==
               [:atom, :return_value]

      assert on_ok(t("  def f, do: {:ok, 1}")) == [convention: ":error"]
    end

    test "a call tail is not classified (a known miss)" do
      assert Enum.map(sites(t("  def f(x), do: IO.puts(x)")), &elem(&1, 0)) ==
               [:return_value, :return_value]
    end

    test "an :ok off the tail of a unit function is an ordinary value" do
      src = t("  def f do\n    x = :ok\n    IO.puts(x)\n    :ok\n  end")
      assert sites(src) == [{:convention, 3, ":ok", ":error"}]
    end

    test "an anonymous function with a data path" do
      src = t("  def f(g), do: g.(fn x -> if x, do: :ok, else: :error end)")
      assert on_ok(src) == @ok_mutated
    end
  end

  describe "static visibility" do
    test "a nested module is classified on its own, both ways round" do
      outer_unit = t("  def f, do: :ok\n  defmodule Inner do\n    def f, do: :pending\n  end")
      assert on_ok(outer_unit) == []
      assert Enum.map(sites(outer_unit), &elem(&1, 1)) == [4, 4]

      inner_unit = t("  def f, do: :pending\n  defmodule Inner do\n    def f, do: :ok\n  end")
      assert on_ok(inner_unit) == []
      assert Enum.map(sites(inner_unit), &elem(&1, 1)) == [2, 2]
    end

    test "clauses defined under a module-level if/for are grouped with their siblings" do
      # Only scope boundaries prune the walk, so a conditional definition joins the group and
      # its data-returning branch disqualifies it.
      src = t("  if true do\n    def f, do: :ok\n  else\n    def f, do: :pending\n  end")
      assert on_ok(src) == @ok_mutated

      # …while static heads generated by a `for` are ordinary clauses.
      assert sites(t("  for n <- [:a, :b] do\n    def f(unquote(n)), do: :ok\n  end")) == []
    end

    test "a dynamic head leaves the whole module unclassified" do
      src = t("  for n <- [:g] do\n    def unquote(n)(), do: 1\n  end\n  def f, do: :ok")
      assert on_ok(src) == @ok_mutated
    end

    test "a spliced head blocks its name at every arity, and only its name" do
      src = t("  def f(unquote_splicing(args)), do: 1\n  def f, do: :ok\n  def g, do: :ok")
      assert on_ok(src) == @ok_mutated
      assert Enum.map(sites(src), &elem(&1, 1)) == [3, 3, 3]
    end
  end

  describe "the metamutant" do
    test "renders without the stamp and the unit function still returns :ok" do
      src = """
      defmodule Mutare.UnitReturnsFixture do
        def ping(x) do
          send(self(), x)
          :ok
        end
      end
      """

      {metamutant, sites, _} =
        Mutare.Transform.transform_string_with_sites(src, mutators: @families)

      assert sites == []
      refute metamutant =~ "mutare_unit_tail"

      [{_module, _binary}] = Mutare.Test.Compile.string(metamutant)
      assert Mutare.UnitReturnsFixture.ping(1) == :ok
      assert_received 1
    end
  end
end
