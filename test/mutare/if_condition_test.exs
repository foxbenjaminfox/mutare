defmodule Mutare.IfConditionTest do
  @moduledoc """
  IfCondition mutation: force an `if`/`unless`/`cond` condition to `true`/`false`.
  The positional sibling of `Conditional` — structural (the transform names the
  condition slot), delivered by the in-place selector, on by default. It covers the
  conditions a value family can't reach (a bare predicate call, `is_*`, a remote
  boolean), leaving the boolean-operator ones to `Conditional`.
  """
  use ExUnit.Case, async: false

  alias Mutare.Mutators.{IfCondition, StringCall}
  alias Mutare.Selector

  @only [IfCondition]

  @compile {:no_warn_undefined, Mutare.IfConditionFixture}

  setup do
    Selector.put(Selector.baseline())
    on_exit(fn -> Selector.put(Selector.baseline()) end)
    :ok
  end

  describe "replacements/1 (the true/false pair, and which conditions are skipped)" do
    test "a bare predicate / call / variable condition becomes the pair true and false" do
      assert pair("foo?(x)")
      assert pair("is_nil(x)")
      assert pair("Map.has_key?(m, :k)")
      assert pair("String.contains?(s, \"x\")")
      assert pair("user")
      assert pair("user.active")
    end

    test "a boolean operator is skipped — Conditional already forces it to true/false" do
      assert skipped("a > b")
      assert skipped("a == b")
      assert skipped("a in b")
      assert skipped("a and b")
      assert skipped("a or b")
      assert skipped("a && b")
      assert skipped("a || b")
      assert skipped("not a")
      assert skipped("!a")
    end

    test "a literal true/false/nil condition is skipped (degenerate)" do
      assert skipped("true")
      assert skipped("false")
      assert skipped("nil")
    end

    test "a binding condition is skipped — un-binding it would poison the body" do
      assert skipped("user = fetch()")
      assert skipped("(x = a(); x)")
    end

    test "every boolean op Conditional recognises is skipped (no duplicate mutants)" do
      # The skip is keyed on Conditional.boolean_op?/1, the shared definition.
      for op <- [:>, :>=, :<, :<=, :==, :!=, :===, :!==, :in, :and, :or, :&&, :||] do
        assert IfCondition.replacements({op, [], [var(:a), var(:b)]}) == []
      end

      for op <- [:not, :!] do
        assert IfCondition.replacements({op, [], [var(:a)]}) == []
      end
    end
  end

  describe "the behaviour surface" do
    test "mutate/1 is :skip — it is structural, never a node mutator" do
      assert IfCondition.mutate(Sourceror.parse_string!("foo?(x)")) == :skip
      assert IfCondition.mutate(Sourceror.parse_string!("a > b")) == :skip
    end

    test "name/0" do
      assert IfCondition.name() == :if_condition
    end
  end

  describe "transform integration (which condition positions get sites)" do
    test "an if condition gets a true/false pair of in-place sites" do
      sites = if_sites("def f(x), do: if(foo?(x), do: 1, else: 2)")

      assert Enum.map(sites, &{&1.original_code, &1.mutated_code}) ==
               [{"foo?(x)", "true"}, {"foo?(x)", "false"}]

      assert Enum.all?(sites, &(&1.kind == :in_place))
    end

    test "an unless condition is handled identically" do
      assert mutated_codes("def f(x), do: unless(ok?(x), do: 1, else: 2)") == ["true", "false"]
    end

    test "a cond clause's bare condition gets a pair, but its `true ->` catch-all does not" do
      src = """
      def f(u) do
        cond do
          admin?(u) -> 1
          u > 0 -> 2
          true -> 3
        end
      end
      """

      sites = if_sites(src)
      # admin?(u) → pair; `u > 0` is a boolean op (Conditional's); `true ->` is the
      # degenerate catch-all — neither yields an if_condition site.
      assert Enum.map(sites, &{&1.original_code, &1.mutated_code}) ==
               [{"admin?(u)", "true"}, {"admin?(u)", "false"}]
    end

    test "a boolean-operator if condition yields no if_condition site (Conditional owns it)" do
      assert if_sites("def f(a, b), do: if(a > b, do: 1, else: 2)") == []
      assert if_sites("def f(a, b), do: if(a && b, do: 1, else: 2)") == []
    end

    test "a binding if condition yields no if_condition site" do
      assert if_sites("def f, do: if(u = fetch(), do: u, else: nil)") == []
    end

    test "a module-level (scaffold) if condition is left alone — it runs at compile time" do
      src = """
      defmodule Mutare.IfCondScaffold do
        if function_exported?(Enum, :map, 2) do
          def f, do: 1
        else
          def f, do: 2
        end
      end
      """

      {_meta, sites, _} = Mutare.transform_string(src, mutators: @only)
      assert Enum.filter(sites, &(&1.mutator == :if_condition)) == []
    end

    test "coexists with another mutator on the same condition node — one shared selector" do
      {_meta, sites, _} =
        wrap("def f(s), do: if(String.starts_with?(s, \"x\"), do: 1, else: 2)")
        |> Mutare.transform_string(mutators: [IfCondition, StringCall])

      assert Enum.map(sites, &{&1.mutator, &1.mutated_code}) == [
               {:string_call, "String.ends_with?(s, \"x\")"},
               {:if_condition, "true"},
               {:if_condition, "false"}
             ]
    end
  end

  describe "runtime semantics (the metamutant compiles and the selector forces the branch)" do
    setup do
      src = """
      defmodule Mutare.IfConditionFixture do
        def classify(x) do
          if big?(x) do
            :big
          else
            :small
          end
        end

        def big?(x), do: x > 100
      end
      """

      {metamutant, sites, _} = Mutare.transform_string(src, mutators: @only)
      [{_module, _binary}] = Code.compile_string(metamutant)
      [sites: Enum.filter(sites, &(&1.mutator == :if_condition))]
    end

    test "baseline takes the real branch; forcing true/false overrides it", %{sites: sites} do
      true_id = Enum.find(sites, &(&1.mutated_code == "true")).id
      false_id = Enum.find(sites, &(&1.mutated_code == "false")).id

      Selector.put(Selector.baseline())
      assert Mutare.IfConditionFixture.classify(5) == :small
      assert Mutare.IfConditionFixture.classify(500) == :big

      Selector.put(true_id)
      assert Mutare.IfConditionFixture.classify(5) == :big

      Selector.put(false_id)
      assert Mutare.IfConditionFixture.classify(500) == :small
    end
  end

  # --- helpers --------------------------------------------------------------

  defp pair(condition) do
    IfCondition.replacements(Sourceror.parse_string!(condition))
    |> Enum.map(&Sourceror.to_string/1) == ["true", "false"]
  end

  defp skipped(condition) do
    IfCondition.replacements(Sourceror.parse_string!(condition)) == []
  end

  defp var(name), do: {name, [], nil}

  defp wrap(body), do: "defmodule Mutare.IfCondT do\n  #{body}\nend\n"

  defp if_sites(body) do
    {_meta, sites, _} = Mutare.transform_string(wrap(body), mutators: @only)
    Enum.filter(sites, &(&1.mutator == :if_condition))
  end

  defp mutated_codes(body), do: body |> if_sites() |> Enum.map(& &1.mutated_code)
end
