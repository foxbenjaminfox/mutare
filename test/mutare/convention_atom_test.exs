defmodule Mutare.ConventionAtomTest do
  @moduledoc """
  Convention-atom swaps (`:ok` ↔ `:error`, `:cont` ↔ `:halt`, `:lt` ↔ `:gt`) — the
  high-signal, same-shape sibling in place of the generic `:mutare` sentinel. Owns these
  atoms (AtomLiteral defers); configurable with extra `:pairs`. A `mutate/2`-only family,
  so unit calls pass a context. On by default.
  """
  use ExUnit.Case, async: true

  alias Mutare.Mutators.{AtomLiteral, ConventionAtom}

  # The default (unconfigured) context: opts default to [].
  @ctx %{opts: []}

  defp parse(source), do: Sourceror.parse_string!(source)
  defp render(nodes), do: Enum.map(nodes, &Sourceror.to_string/1)

  defp mutate(source, opts \\ []),
    do: ConventionAtom.mutate(parse(source), %{opts: opts})

  # convention sites for a one-line body `def f(a, b), do: <expr>`, isolated to this family.
  defp body_sites(expr) do
    {_meta, sites, _} =
      Mutare.transform_string("defmodule T do\n  def f(a, b), do: #{expr}\nend\n",
        mutators: [ConventionAtom]
      )

    Enum.filter(sites, &(&1.mutator == :convention))
  end

  defp mutated_codes(expr), do: expr |> body_sites() |> Enum.map(& &1.mutated_code)

  describe "mutate/2 — built-in pairs" do
    test "swaps :ok and :error both ways" do
      assert render(mutate(":ok")) == [":error"]
      assert render(mutate(":error")) == [":ok"]
    end

    test "swaps :cont and :halt both ways" do
      assert render(mutate(":cont")) == [":halt"]
      assert render(mutate(":halt")) == [":cont"]
    end

    test "swaps :lt and :gt; :eq (the unpaired middle) yields nothing" do
      assert render(mutate(":lt")) == [":gt"]
      assert render(mutate(":gt")) == [":lt"]
      assert mutate(":eq") == :skip
    end

    test "skips non-convention atoms, true/false/nil, and non-atoms" do
      assert mutate(":waiting") == :skip
      assert mutate("true") == :skip
      assert mutate("false") == :skip
      assert mutate("nil") == :skip
      assert mutate("1") == :skip
      assert mutate(~s("ok")) == :skip
    end

    test "skips a bare (un-wrapped) atom — a function name, never a value" do
      assert ConventionAtom.mutate(:ok, @ctx) == :skip
    end

    test "does not implement mutate/1 (logic lives in mutate/2)" do
      refute function_exported?(ConventionAtom, :mutate, 1)
    end
  end

  describe "mutate/2 — configurable :pairs" do
    test "adds a user pair alongside the built-ins" do
      assert render(mutate(":active", pairs: [[:active, :inactive]])) == [":inactive"]
      assert render(mutate(":inactive", pairs: [[:active, :inactive]])) == [":active"]
      # built-ins still apply under a configured instance
      assert render(mutate(":ok", pairs: [[:active, :inactive]])) == [":error"]
    end

    test "ignores an ill-formed or non-keyword :pairs" do
      assert mutate(":active", pairs: [:not_a_pair]) == :skip
      assert ConventionAtom.mutate(parse(":ok"), %{opts: %{pairs: []}}) |> render() == [":error"]
    end
  end

  describe "in a body (value position)" do
    test "swaps the tag of an :ok / :error tuple, payload untouched" do
      assert mutated_codes("{:ok, a}") == [":error"]
      assert mutated_codes("{:error, a}") == [":ok"]
    end

    test "swaps a bare returned atom" do
      assert mutated_codes(":halt") == [":cont"]
    end

    test "leaves a non-convention atom to AtomLiteral (no convention site)" do
      assert body_sites(":waiting") == []
    end
  end

  describe "pattern positions — same reach as AtomLiteral" do
    # The mutated node lives in a head/clause pattern; the convention swap rides the existing
    # literal machinery (lifting for a def head, tuple-the-scrutinee for a `case` clause).
    defp pattern_sites(src) do
      {_m, sites, _} = Mutare.transform_string(src, mutators: [ConventionAtom])

      sites
      |> Enum.filter(&(&1.mutator == :convention))
      |> Enum.map(&{&1.kind, &1.original_code, &1.mutated_code})
    end

    test "a def head pattern literal is swapped by lifting" do
      src = "defmodule T do\n  def h({:ok, v}), do: v\n  def h(o), do: o\nend\n"
      assert pattern_sites(src) == [{:lifted, ":ok", ":error"}]
    end

    test "a case clause pattern is swapped in place (tuple-the-scrutinee)" do
      src =
        "defmodule T do\n  def f(x) do\n    case x do\n      {:ok, v} -> v\n      _ -> :none\n    end\n  end\nend\n"

      assert pattern_sites(src) == [{:in_place, ":ok", ":error"}]
    end
  end

  describe "ownership split with AtomLiteral" do
    # With both enabled, a convention atom yields ONLY the sibling; a plain atom ONLY :mutare.
    defp both_codes(expr) do
      {_meta, sites, _} =
        Mutare.transform_string("defmodule T do\n  def f, do: #{expr}\nend\n",
          mutators: [ConventionAtom, AtomLiteral]
        )

      Enum.map(sites, &{&1.mutator, &1.mutated_code})
    end

    test ":ok yields the convention sibling, not the sentinel" do
      assert both_codes(":ok") == [{:convention, ":error"}]
    end

    test "a non-convention atom yields only the sentinel" do
      assert both_codes(":waiting") == [{:atom, ":mutare"}]
    end
  end

  describe "name" do
    test "is :convention" do
      assert ConventionAtom.name() == :convention
    end
  end

  describe "members/0" do
    test "is the flat, de-duplicated list of built-in convention atoms" do
      # `AtomLiteral` reads this at compile time to exclude these atoms; the direct call pins
      # the contract (and that the accessor itself runs).
      members = ConventionAtom.members()

      assert is_list(members)
      assert :ok in members and :error in members
      assert :cont in members and :halt in members
      assert members == Enum.uniq(members)
    end
  end
end
